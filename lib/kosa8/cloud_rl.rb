# frozen_string_literal: true

require "json"
require "uri"

# Fan-out on kosa8 Cloud, for RL rollouts and evals: many sandboxes at once
# (create_many, fork up to 1000), leases so a crashed trainer leaks none
# (lease_s, heartbeat), a drain to clean up a run, the sealed grader, retries
# with backoff, fork_map, org templates and capability tokens.
module Kosa8
  # How often and how long to retry.
  #
  # +attempts+ counts the first try (1 turns retries off). The n-th retry
  # waits a random time up to min(max_s, base_s * 2**(n-1)) ("full jitter",
  # so a thousand rollouts that failed together do not come back together),
  # and never less than the server's Retry-After (capped at
  # max_retry_after_s). Only what can pass is retried: infra failures and
  # rate limits (Kosa8.classify_failure).
  class RetryPolicy
    attr_reader :attempts, :base_s, :max_s, :max_retry_after_s

    def initialize(attempts: 3, base_s: 0.5, max_s: 8.0, max_retry_after_s: 60.0, rng: nil)
      raise ArgumentError, "attempts must be a whole number of at least 1" unless attempts.is_a?(Integer) && attempts >= 1
      raise ArgumentError, "base_s and max_s must not be negative" if base_s.negative? || max_s.negative?

      @attempts = attempts
      @base_s = base_s.to_f
      @max_s = max_s.to_f
      @max_retry_after_s = max_retry_after_s.to_f
      @rng = rng || Random.new
    end

    def inspect
      "#<Kosa8::RetryPolicy attempts=#{@attempts} base_s=#{@base_s} max_s=#{@max_s}>"
    end

    # Whether to try again after +exc+ on attempt +attempt+ (1-based).
    def retry?(exc, attempt)
      attempt < @attempts && Kosa8.classify_failure(exc)[1]
    end

    # Seconds to wait before attempt +attempt+ + 1.
    def delay(exc, attempt)
      cap = [@max_s, @base_s * (2**[0, attempt - 1].max)].min
      wait = cap.positive? ? @rng.rand * cap : 0.0
      ra = exc.respond_to?(:retry_after) ? exc.retry_after : nil
      wait = [wait, [ra.to_f, @max_retry_after_s].min].max if ra.is_a?(Numeric) && ra.positive?
      wait
    end

    # No retries.
    NONE = new(attempts: 1)
  end

  # Call the block until it returns, retrying what +policy+ allows; waits
  # with +sleeper+ (default Kernel#sleep). The block gets the attempt number.
  def self.with_retry(policy, sleeper: nil, on_retry: nil)
    attempt = 1
    loop do
      begin
        return yield(attempt)
      rescue StandardError => e
        raise unless policy.retry?(e, attempt)

        wait = policy.delay(e, attempt)
        on_retry&.call(e, attempt, wait)
        (sleeper || Kernel.method(:sleep)).call(wait)
        attempt += 1
      end
    end
  end

  # The sandboxes a batch or a fork made: an Array of CloudSandbox, with
  # +failed+ (Hashes: "index", "code", "message", "failure_class",
  # "retryable") for those it could not make, +requested+ and +run_id+.
  class SandboxBatch < Array
    attr_accessor :failed, :requested, :run_id

    def initialize(sandboxes = [], failed: [], requested: nil, run_id: nil)
      super(sandboxes)
      @failed = failed
      @requested = requested.nil? ? sandboxes.size : requested
      @run_id = run_id
    end

    # How many were made.
    def created
      size
    end

    # Whether all that were asked for were made.
    def complete?
      @failed.empty? && size >= @requested.to_i
    end

    def self.from(cloud, answer, requested)
      r = answer.is_a?(Hash) ? answer : {}
      new((r["sandboxes"] || []).map { |s| CloudSandbox.new(cloud, s) }, failed: Array(r["failed"]),
                                                                       requested: r["requested"] || requested,
                                                                       run_id: r["run_id"])
    end
  end

  # What a sealed grade answered. +reward+ is nil when the grader did not
  # finish (+failure_class+ "timeout" or "infra"): mask it, never score it 0.
  # +recorded+ is true when kosa8 Cloud recorded it as a rollout of +run_id+.
  GradeResult = Struct.new(:reward, :metrics, :reward_from, :exit_code, :stdout, :stderr, :failure_class,
                           :retryable, :ms, :grader_id, :kept, :sandbox_id, :run_id, :recorded, :error, :message,
                           keyword_init: true) do
    def ok?
      failure_class == "ok"
    end

    def self.from(r)
      r = {} unless r.is_a?(Hash)
      new(reward: r["reward"], metrics: r["metrics"].is_a?(Hash) ? r["metrics"] : {}, reward_from: r["reward_from"],
          exit_code: r["exit"], stdout: r["stdout"].to_s, stderr: r["stderr"].to_s,
          failure_class: (r["failure_class"] || "ok").to_s, retryable: r["retryable"] == true, ms: r["ms"],
          grader_id: r["grader_id"], kept: r["kept"] == true, sandbox_id: r["sandbox_id"], run_id: r["run_id"],
          recorded: r["recorded"], error: r["error"], message: r["message"])
    end
  end

  class Cloud
    RUN_LABEL = "kosa8.run"
    MAX_BATCH = 1000
    MIN_LEASE_S = 60
    MAX_LEASE_S = 86_400
    DRAIN_MAX = 1000
    DRAIN_ROUNDS = 100
    GRADE_MAX_FILES = 64
    GRADE_MAX_BYTES = 8 * 1024 * 1024
    RUN_ID = /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/.freeze
    PREFIX = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,58}\z/.freeze
    ORG_TEMPLATE_NAME = /\A[a-z0-9][a-z0-9._-]{0,62}\z/.freeze
    TOKEN_SCOPES = %w[sandboxes:read sandboxes:write functions:invoke].freeze

    alias initialize_without_rl initialize
    def initialize(**kw)
      initialize_without_rl(**kw)
      @org_templates = CloudOrgTemplates.new(self)
      @tokens = CloudTokens.new(self)
    end

    # The org's own templates (built from an image or a Dockerfile, kept as a snapshot).
    attr_reader :org_templates
    # Short-lived capability tokens.
    attr_reader :tokens

    def self.check_lease(lease_s)
      return lease_s if lease_s.is_a?(Integer) && lease_s.between?(MIN_LEASE_S, MAX_LEASE_S)

      raise ArgumentError, "lease_s must be a whole number of seconds from #{MIN_LEASE_S} to #{MAX_LEASE_S}"
    end

    def self.check_run_id(run_id)
      return run_id.to_s if RUN_ID.match?(run_id.to_s)

      raise ArgumentError, "run_id must be 1-128 letters, digits, '_', '.', ':' or '-', starting with a letter or digit"
    end

    # The fan-out fields a batch and a fork share, with the open Run's
    # run_id and lease_s when not given.
    def self.fanout_body(cloud, labels: nil, run_id: nil, lease_s: nil, prefix: nil, partial_ok: nil)
      amb = cloud.run_defaults || {}
      run_id = amb["run_id"] if run_id.nil?
      lease_s = amb["lease_s"] if lease_s.nil?
      body = {}
      body["labels"] = check_labels(labels) unless labels.nil?
      unless run_id.nil?
        body["run_id"] = check_run_id(run_id)
        if (body["labels"] || {}).merge(RUN_LABEL => run_id).size > MAX_LABELS
          raise ArgumentError, "at most #{MAX_LABELS} labels, kosa8.run included"
        end
      end
      body["lease_s"] = check_lease(lease_s) unless lease_s.nil?
      unless prefix.nil?
        unless PREFIX.match?(prefix.to_s)
          raise ArgumentError, "prefix must be 1-59 letters, digits, '.', '_' or '-', starting with a letter or digit"
        end

        body["prefix"] = prefix.to_s
      end
      unless partial_ok.nil?
        raise ArgumentError, "partial_ok must be true or false" unless [true, false].include?(partial_ok)

        body["partial_ok"] = partial_ok
      end
      body
    end

    # run_id, labels and ids (at least one) for heartbeat and drain.
    def self.selector(run_id, labels, ids)
      body = {}
      body["run_id"] = check_run_id(run_id) unless run_id.nil?
      body["labels"] = check_labels(labels) unless labels.nil?
      unless ids.nil?
        list = Array(ids).map { |x| x.is_a?(CloudSandbox) ? x.id : x.to_s }
        raise ArgumentError, "ids must be 1 to #{DRAIN_MAX} sandbox ids" if list.empty? || list.size > DRAIN_MAX

        body["ids"] = list
      end
      raise ArgumentError, "give run_id:, labels: or ids: (which sandboxes)" if body.empty?

      body
    end

    # The body of POST /v1/sandboxes/{id}/grade.
    def self.grade_body(cmd, files: nil, timeout_s: nil, env: nil, keep: false, run_id: nil, rollout: nil)
      argv = cmd.is_a?(String) ? ["sh", "-c", cmd] : Array(cmd).map(&:to_s)
      raise ArgumentError, "cmd must be a command: a String or a non-empty Array" if argv.empty?

      body = { "cmd" => argv }
      unless files.nil?
        raise ArgumentError, "files is a Hash of {\"/absolute/path\" => content}" unless files.is_a?(Hash)
        raise ArgumentError, "at most #{GRADE_MAX_FILES} files" if files.size > GRADE_MAX_FILES

        total = 0
        body["files"] = files.map do |p, v|
          p = p.to_s
          raise ArgumentError, "file path #{p.inspect} must be absolute, without .." if !p.start_with?("/") || p.split("/").include?("..")

          bytes = v.to_s.b
          total += bytes.bytesize
          raise ArgumentError, "files add up to more than 8 MiB" if total > GRADE_MAX_BYTES

          [p, [bytes].pack("m0")]
        end.to_h
      end
      unless timeout_s.nil?
        t = timeout_s.is_a?(Float) && timeout_s == timeout_s.floor ? timeout_s.to_i : timeout_s
        raise ArgumentError, "timeout_s must be a whole number of seconds from 1 to 90" unless t.is_a?(Integer) && t.between?(1, 90)

        body["timeout_s"] = t
      end
      unless env.nil?
        body["env"] = env.is_a?(Hash) ? Cloud.env_list(Cloud.check_env(env)) : Array(env).map(&:to_s)
      end
      body["keep"] = true if keep
      body["run_id"] = check_run_id(run_id) unless run_id.nil?
      unless rollout.nil?
        raise ArgumentError, "rollout is a Hash of step, group, index, meta" unless rollout.is_a?(Hash)

        ro = rollout.map { |k, v| [k.to_s, v] }.to_h
        ro["group"] = ro["group"].to_s if ro.key?("group") && !ro["group"].nil?
        body["rollout"] = ro.reject { |_, v| v.nil? }
      end
      body
    end

    # Run +block+ (sandbox, item) in a fork of +base+ for every item; see
    # CloudSandbox#fork_map.
    def fork_map(base, items, **opts, &block)
      ForkMap.run(self, base, items, **opts, &block)
    end
  end

  class CloudSandboxes
    # Make +count+ (1 to 1000) sandboxes in one call, paced by kosa8 (16 at a
    # time), as a SandboxBatch. Takes the options of #create (template:,
    # size:, image:, env:, egress:, ttl_s:, ...) for every one, plus labels:,
    # run_id: (labels them kosa8.run), lease_s:, prefix: (names them
    # <prefix>-0001, ...) and partial_ok: (default true: make what fits and
    # list the rest in +failed+; false: all or nothing). Nothing made raises
    # the first refusal. Carries an Idempotency-Key (+idempotency_key+,
    # default a new UUID) reused after a timeout, so a retried batch never
    # doubles the fleet (the default is renewed after a 5xx).
    def create_many(count, labels: nil, run_id: nil, lease_s: nil, prefix: nil, partial_ok: nil,
                    idempotency_key: nil, **create_opts)
      unless count.is_a?(Integer) && count.between?(1, Cloud::MAX_BATCH)
        raise ArgumentError, "count must be a whole number from 1 to #{Cloud::MAX_BATCH}"
      end
      raise ArgumentError, "a batch names its sandboxes with prefix:, not name:" if create_opts.key?(:name)

      unknown = create_opts.keys - %i[template region sleep_after_s ttl_s delete_after accept_price size cpus mem_mb
                                      image disk_gb persistent docker cpu env secrets egress snapshot]
      raise ArgumentError, "unknown option #{unknown.first}: for create_many" unless unknown.empty?
      if !lease_s.nil? && (create_opts[:ttl_s] || create_opts[:delete_after])
        raise ArgumentError, "give lease_s or ttl_s/delete_after, not both"
      end

      body = create_body(**create_opts)
      fan_lease = lease_s
      fan_lease = (@cloud.run_defaults || {})["lease_s"] if fan_lease.nil? && !body.key?("ttl_s") && !body.key?("delete_after")
      fan = Cloud.fanout_body(@cloud, labels: labels, run_id: run_id, lease_s: fan_lease, prefix: prefix,
                                      partial_ok: partial_ok)
      fan.delete("lease_s") if fan_lease.nil?
      body = { "count" => count }.merge(body).merge(fan)
      Cloud.check_idempotency_key(idempotency_key)
      r = @cloud.request("POST", "/v1/sandboxes/batch", body, idempotency_key: idempotency_key)
      SandboxBatch.from(@cloud, r, count)
    end

    # Push back the lease of the matching leased sandboxes to now + extend_s
    # (default each one's own lease_s). Returns how many were extended.
    def heartbeat(run_id: nil, labels: nil, ids: nil, extend_s: nil)
      body = Cloud.selector(run_id, labels, ids)
      body["extend_s"] = Cloud.check_lease(extend_s) unless extend_s.nil?
      r = @cloud.request("POST", "/v1/sandboxes/heartbeat", body)
      r.is_a?(Hash) ? r["extended"].to_i : 0
    end

    # Delete every matching sandbox of the org: {"deleted" => n, "ids" =>
    # [...], "failed" => [...]}. kosa8 Cloud deletes up to 1000 a call; this
    # calls again while it says there are more (and stops if a call deleted none).
    def drain(run_id: nil, labels: nil, ids: nil)
      sel = Cloud.selector(run_id, labels, ids)
      out = { "deleted" => 0, "ids" => [], "failed" => [] }
      Cloud::DRAIN_ROUNDS.times do
        r = @cloud.request("POST", "/v1/sandboxes/drain", sel)
        r = {} unless r.is_a?(Hash)
        n = r["deleted"].to_i
        out["deleted"] += n
        out["ids"].concat(Array(r["ids"]))
        out["failed"].concat(Array(r["failed"]))
        break unless r["more"] == true && n.positive?
      end
      out
    end

    # Grade a solved sandbox (an id or a CloudSandbox) in a sealed fork; see CloudSandbox#grade.
    def grade(sandbox, cmd, **opts)
      box = sandbox.is_a?(CloudSandbox) ? sandbox : CloudSandbox.new(@cloud, { "id" => sandbox.to_s })
      box.grade(cmd, **opts)
    end
  end

  class CloudSandbox
    # Push back this sandbox's lease; see CloudSandboxes#heartbeat.
    def heartbeat(extend_s: nil)
      @cloud.sandboxes.heartbeat(ids: [id], extend_s: extend_s)
    end

    # Grade this sandbox's state with hidden tests, in a sealed fork.
    #
    # kosa8 Cloud forks one copy, takes all network away from it, writes
    # +files+ ({"/grader/test.py" => "..."}; this sandbox never sees them),
    # runs +cmd+ and deletes the copy (unless keep: true). The reward is the
    # last stdout line that is JSON with a numeric "reward", else 1.0 for exit
    # 0 and 0.0 otherwise; nil when the command did not finish. With run_id:
    # it is recorded as a rollout of that run (rollout: step, group, index,
    # meta), so do not record it again. files: at most 64, 8 MiB in all;
    # timeout_s: 1 to 90. The call carries an Idempotency-Key reused after a
    # timeout: that retry gets the first answer and records nothing twice.
    def grade(cmd, files: nil, timeout_s: nil, env: nil, keep: false, run_id: nil, rollout: nil, idempotency_key: nil)
      run_id = (@cloud.run_defaults || {})["run_id"] if run_id.nil?
      body = Cloud.grade_body(cmd, files: files, timeout_s: timeout_s, env: env, keep: keep, run_id: run_id,
                                   rollout: rollout)
      Cloud.check_idempotency_key(idempotency_key)
      GradeResult.from(@cloud.request("POST", path("/grade"), body, idempotency_key: idempotency_key))
    end

    # Run the block (child, item) for every item, each in its own fork of
    # this sandbox, +concurrency+ at a time; results (ForkResult) in item
    # order. A failure is the item's result, never raised; infra failures and
    # rate limits are retried +retries+ times on a fresh fork with backoff.
    # Every fork is deleted when its item is done, and all that are left when
    # the map ends for any reason (an exception, Ctrl-C). timeout_s: caps
    # each item (its fork is deleted). labels:, run_id:, lease_s: go on each fork.
    def fork_map(items, **opts, &block)
      ForkMap.run(@cloud, self, items, **opts, &block)
    end
  end

  # cloud.org_templates: the org's own templates, built on a kosa8 Cloud host
  # and kept as a snapshot, so a sandbox created from one
  # (sandboxes.create(template: name)) is a restore, not a cold pull.
  class CloudOrgTemplates
    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudOrgTemplates>"
    end

    # Build a template from +image+ (a tag or @sha256 digest) or a
    # +dockerfile+ (its text). Answers the template, queued or building; poll
    # #wait_ready. setup_cmd: runs once in the booted template before it is saved.
    def build(name, image: nil, dockerfile: nil, build_args: nil, setup_cmd: nil, size: nil, cpus: nil, mem_mb: nil,
              region: nil)
      raise ArgumentError, "give image: or dockerfile:, not both" if !image.nil? && !dockerfile.nil?
      raise ArgumentError, "give image: or dockerfile:" if image.nil? && dockerfile.nil?

      body = { "name" => check_name(name) }
      body["image"] = image.to_s unless image.nil?
      body["dockerfile"] = dockerfile.to_s unless dockerfile.nil?
      body["build_args"] = build_args.map { |k, v| [k.to_s, v.to_s] }.to_h unless build_args.nil?
      sizing(body, setup_cmd, size, cpus, mem_mb, region)
      r = @cloud.request("POST", "/v1/templates", body)
      r.is_a?(Hash) ? r["template"] : nil
    end

    # Queue many image templates at once (such as RL task images by
    # digest): +images+ is an Array of {name:, image:}. Answers "queued",
    # "templates" and "failed" (with partial_ok: true).
    def import(images, setup_cmd: nil, size: nil, cpus: nil, mem_mb: nil, region: nil, partial_ok: nil)
      list = Array(images).map do |i|
        h = i.to_h.map { |k, v| [k.to_s, v] }.to_h
        raise ArgumentError, "each image is {name:, image:}" if h["name"].nil? || h["image"].nil?

        { "name" => check_name(h["name"]), "image" => h["image"].to_s }
      end
      raise ArgumentError, "images must be 1 to 1000 {name:, image:}" if list.empty? || list.size > 1000

      body = { "images" => list }
      sizing(body, setup_cmd, size, cpus, mem_mb, region)
      body["partial_ok"] = partial_ok == true unless partial_ok.nil?
      @cloud.request("POST", "/v1/templates/import", body)
    end

    # The org's templates (Cloud#templates lists kosa8's).
    def list
      r = @cloud.request("GET", "/v1/templates")
      r.is_a?(Hash) ? (r["org_templates"] || []) : []
    end

    # One template (by id tpl_... or name), with its build log.
    def get(id_or_name)
      r = @cloud.request("GET", "/v1/templates/#{Kosa8.enc(id_or_name)}")
      r.is_a?(Hash) ? r["template"] : nil
    end

    # Delete it: a build in flight stops and its snapshot is deleted.
    def delete(id_or_name)
      @cloud.request("DELETE", "/v1/templates/#{Kosa8.enc(id_or_name)}")
      nil
    end

    # Poll until it is ready (returns it); raises Kosa8::Error if it failed
    # or is gone, Kosa8::TimeoutError past +timeout+ seconds.
    def wait_ready(id_or_name, timeout: 3600, poll_interval: 5)
      deadline = Time.now + timeout
      loop do
        t = get(id_or_name) || {}
        case t["state"]
        when "ready" then return t
        when "failed", "deleted"
          raise Error.new("template #{id_or_name} #{t['state']}: #{t['last_error'] || 'no reason given'}",
                          body: t, code: "template_#{t['state']}")
        end
        raise TimeoutError, "template #{id_or_name} still #{t['state']} after #{timeout} s" if Time.now >= deadline

        @cloud.sleeper.call(poll_interval)
      end
    end

    private

    def check_name(name)
      return name.to_s if Cloud::ORG_TEMPLATE_NAME.match?(name.to_s)

      raise ArgumentError, "a template name is 1-63 lowercase letters, digits, '.', '_' or '-'"
    end

    def sizing(body, setup_cmd, size, cpus, mem_mb, region)
      body["setup_cmd"] = setup_cmd.is_a?(String) ? setup_cmd : Array(setup_cmd).map(&:to_s) unless setup_cmd.nil?
      unless size.nil?
        raise ArgumentError, "size must be one of #{Cloud::SIZES.join(', ')}" unless Cloud::SIZES.include?(size.to_s)

        body["size"] = size.to_s
      end
      raise ArgumentError, "give cpus: and mem_mb: together" if cpus.nil? != mem_mb.nil?

      unless cpus.nil?
        body["cpus"] = Integer(cpus)
        body["mem_mb"] = Integer(mem_mb)
      end
      body["region"] = region.to_s unless region.nil?
    end
  end

  # cloud.tokens: short-lived bearer tokens (k8c_tok_...) limited to some
  # scopes and, optionally, some sandboxes, to hand a sandbox to your own end
  # user without handing over the API key. Kosa8::Cloud.new(api_key: secret)
  # works with one.
  class CloudTokens
    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudTokens>"
    end

    # Make a token; its "secret" is in the answer once and never again.
    # +scopes+ from sandboxes:read, sandboxes:write, functions:invoke;
    # sandbox_ids: (up to 100) or labels: limit what it reaches; ttl_s: 60 to
    # 86400 (default 3600).
    def create(scopes, sandbox_ids: nil, labels: nil, ttl_s: nil, name: nil)
      list = Array(scopes).map(&:to_s)
      if list.empty? || list.uniq.size != list.size || !(list - Cloud::TOKEN_SCOPES).empty?
        raise ArgumentError, "scopes must be a non-empty list from #{Cloud::TOKEN_SCOPES.join(', ')}"
      end

      body = { "scopes" => list }
      unless sandbox_ids.nil?
        ids = Array(sandbox_ids).map { |x| x.is_a?(CloudSandbox) ? x.id : x.to_s }
        raise ArgumentError, "sandbox_ids must be 1 to 100 sandbox ids" if ids.empty? || ids.size > 100

        body["sandbox_ids"] = ids
      end
      body["labels"] = Cloud.check_labels(labels) unless labels.nil?
      unless ttl_s.nil?
        raise ArgumentError, "ttl_s must be a whole number of seconds from 60 to 86400" unless ttl_s.is_a?(Integer) && ttl_s.between?(60, 86_400)

        body["ttl_s"] = ttl_s
      end
      body["name"] = name.to_s unless name.nil?
      r = @cloud.request("POST", "/v1/tokens", body)
      r.is_a?(Hash) ? r["token"] : nil
    end

    # The tokens (never their secrets); all: true adds the last day's revoked and expired ones.
    def list(all: false)
      r = @cloud.request("GET", "/v1/tokens#{all ? '?all=1' : ''}")
      r.is_a?(Hash) ? (r["tokens"] || []) : []
    end

    # Revoke a token; it stops at once. Answers the token.
    def revoke(id)
      r = @cloud.request("DELETE", "/v1/tokens/#{Kosa8.enc(id)}")
      r.is_a?(Hash) ? r["token"] : nil
    end
  end
end
