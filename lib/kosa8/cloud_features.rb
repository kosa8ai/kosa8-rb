# frozen_string_literal: true

require "json"
require "stringio"
require "uri"

# More of kosa8 Cloud: sized and Docker creates, env, background commands,
# durable snapshots, previews, terminals, streamed files and presigned links,
# egress, secrets, schedules, the code interpreter, metrics, logs, labels and
# Pipelines. Hosts that lack a feature answer 501, raised as
# Kosa8::UnsupportedError; Cloud#capabilities says what the org can do.
module Kosa8
  class Cloud
    # The standard sizes (vCPU x GiB), which every sized call takes
    # (sandboxes, org templates, pipelines).
    SIZES = %w[2x4 4x8 8x16 16x32].freeze
    # Small sizes, for fleets of mostly idle sandboxes (RL rollouts, evals):
    # a fraction of a vCPU reserved, bursting while the host has idle CPU.
    # Only a sandbox create takes them, and only hosts that run them (else
    # 501 not_available, Kosa8::UnsupportedError). As cpus:/mem_mb:
    # 0.25/512, 0.5/1024, 1/2048.
    SMALL_SIZES = %w[0.25x0.5 0.5x1 1x2].freeze
    # Every size a sandbox create takes.
    SANDBOX_SIZES = (SMALL_SIZES + SIZES).freeze
    ENV_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze
    SANDBOX_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/.freeze
    SNAPSHOT_ID = /\Asnap_[A-Za-z0-9]{8,40}\z/.freeze
    SECRET_NAME = /\A[a-z0-9-]{1,32}\z/.freeze
    LABEL_KEY = %r{\A[A-Za-z0-9._/-]{1,63}\z}.freeze
    MAX_ENV = 64
    MAX_ENV_VALUE = 8192
    MAX_LABELS = 16
    MAX_LABEL_VALUE = 256
    FINISHED_RUN_STATES = %w[success failure cancelled skipped error].freeze

    attr_reader :snapshots, :secrets, :pipelines

    alias initialize_without_features initialize
    def initialize(**kw)
      initialize_without_features(**kw)
      @snapshots = CloudSnapshots.new(self)
      @secrets = CloudSecrets.new(self)
      @pipelines = CloudPipelines.new(self)
    end

    # What the org and its hosts can do (GET /v1/capabilities), for feature detection.
    def capabilities
      request("GET", "/v1/capabilities")
    end

    # The named host lists an egress policy's "presets" can use.
    def egress_presets
      r = request("GET", "/v1/egress/presets")
      r.is_a?(Hash) ? (r["presets"] || {}) : {}
    end

    def self.check_env(env)
      raise ArgumentError, "env is a Hash of NAME => value" unless env.is_a?(Hash)
      raise ArgumentError, "at most #{MAX_ENV} environment variables" if env.size > MAX_ENV

      env.each do |k, v|
        unless ENV_NAME.match?(k.to_s)
          raise ArgumentError, "environment variable name #{k.to_s.inspect}: letters, digits and _, not starting with a digit"
        end
        raise ArgumentError, "environment variable #{k} is longer than 8 KiB" if v.to_s.bytesize > MAX_ENV_VALUE
      end
      env.map { |k, v| [k.to_s, v.to_s] }.to_h
    end

    def self.check_labels(labels)
      raise ArgumentError, "labels is a Hash of key => value" unless labels.is_a?(Hash)
      raise ArgumentError, "at most #{MAX_LABELS} labels" if labels.size > MAX_LABELS

      labels.each do |k, v|
        raise ArgumentError, "label key #{k.to_s.inspect}: 1 to 63 of letters, digits, '.', '_', '/' or '-'" unless LABEL_KEY.match?(k.to_s)
        raise ArgumentError, "label #{k} is longer than #{MAX_LABEL_VALUE} characters" if v.to_s.length > MAX_LABEL_VALUE
      end
      labels.map { |k, v| [k.to_s, v.to_s] }.to_h
    end

    def self.check_secret_name(name)
      return name.to_s if SECRET_NAME.match?(name.to_s)

      raise ArgumentError, "secret name #{name.to_s.inspect}: 1 to 32 of lowercase letters, digits and -"
    end

    def self.egress_body(egress)
      e = egress.to_h.map { |k, v| [k.to_s, v] }.to_h
      { "internet" => e["internet"] == true, "allow" => Array(e["allow"]), "deny" => Array(e["deny"]),
        "presets" => Array(e["presets"]) }
    end

    def self.env_list(env)
      env.map { |k, v| [k.to_s, v.to_s] }.sort.map { |k, v| "#{k}=#{v}" }
    end
  end

  class CloudSandboxes
    alias create_without_features create

    # Start a sandbox. Besides template:, region:, sleep_after_s:, ttl_s:,
    # delete_after: and accept_price:
    #
    # - size: "2x4", "4x8", "8x16" or "16x32" (vCPU x GiB), a small size
    #   "0.25x0.5", "0.5x1" or "1x2" (Cloud::SMALL_SIZES), or cpus: and
    #   mem_mb: (cpus: 0.25, mem_mb: 512 is the smallest); image: an OCI image (such as
    #   "kosa8-template/universal-24.04-20261115.2"); disk_gb: 8..500 (past 200 only on plans with a bigger sandbox disk:
    #   Team 256, Scale 500; GET /v1/templates max_disk_gb is yours). Any of
    #   these boots the sandbox cold at that size: create waits for it to
    #   run unless wait: false (then call #wait_running).
    # - kvm: true (preview) gives it /dev/kvm for an emulator at hardware
    #   speed; needs a size or image, implies persistent and docker, never
    #   sleeps (501 not_available while no host has nested KVM).
    # - docker: true lets it run its own Docker engine (start dockerd first);
    #   persistent: true runs every exec in one long-lived container;
    #   cpu: "dedicated" gives it whole physical cores.
    # - name:, labels: (up to 16), env: (given to every command; values are
    #   never logged or returned), secrets: (names from cloud.secrets),
    #   egress: ({internet:, allow:, deny:, presets:}).
    # - record: true saves its desktop as an MP4 to cloud.recordings when
    #   it is deleted; ai_gateway: true points OPENAI_BASE_URL,
    #   ANTHROPIC_BASE_URL and the like at the org's AI gateway (cloud.ai).
    # - snapshot: "snap_..." starts it from a durable snapshot; then give
    #   only env:, name:, labels:, a lifetime or sleep_after_s:.
    #
    # - lease_s: (60..86400) leases it: deleted lease_s from now unless
    #   #heartbeat extends it, so a crashed client leaks nothing (not with
    #   ttl_s: or delete_after:). run_id: labels it kosa8.run=<run_id>.
    # - idempotency_key: is sent as the Idempotency-Key header (default a new
    #   UUID). The default is reused after a timeout, a dropped connection,
    #   a 429 or a 409, so a retried create makes one sandbox, not two, and
    #   renewed after a 5xx, so that retry is a new attempt. A key you pass
    #   goes unchanged with every retry.
    #
    # Bad arguments raise ArgumentError before any request.
    def create(template: nil, region: nil, sleep_after_s: nil, ttl_s: nil, delete_after: nil, accept_price: nil,
               size: nil, cpus: nil, mem_mb: nil, image: nil, disk_gb: nil, persistent: nil, docker: nil, cpu: nil,
               name: nil, labels: nil, env: nil, secrets: nil, egress: nil, snapshot: nil, wait: true,
               poll_interval: 1, lease_s: nil, run_id: nil, idempotency_key: nil, record: nil, ai_gateway: nil,
               kvm: nil)
      body = create_body(template: template, region: region, sleep_after_s: sleep_after_s, ttl_s: ttl_s,
                         delete_after: delete_after, accept_price: accept_price, size: size, cpus: cpus,
                         mem_mb: mem_mb, image: image, disk_gb: disk_gb, persistent: persistent, docker: docker,
                         cpu: cpu, name: name, labels: labels, env: env, secrets: secrets, egress: egress,
                         snapshot: snapshot, record: record, ai_gateway: ai_gateway, kvm: kvm)
      amb = @cloud.run_defaults || {}
      run_id = amb["run_id"] if run_id.nil?
      if lease_s.nil? && ttl_s.nil? && delete_after.nil?
        lease_s = amb["lease_s"]
      end
      unless lease_s.nil?
        raise ArgumentError, "give lease_s or ttl_s/delete_after, not both" unless ttl_s.nil? && delete_after.nil?

        body["lease_s"] = Cloud.check_lease(lease_s)
      end
      unless run_id.nil?
        body["labels"] = (body["labels"] || {}).merge(Cloud::RUN_LABEL => Cloud.check_run_id(run_id))
        raise ArgumentError, "at most #{Cloud::MAX_LABELS} labels, kosa8.run included" if body["labels"].size > Cloud::MAX_LABELS
      end
      Cloud.check_idempotency_key(idempotency_key)
      r = @cloud.request("POST", "/v1/sandboxes", body, idempotency_key: idempotency_key)
      box = CloudSandbox.new(@cloud, r["sandbox"])
      box.wait_running(poll_interval: poll_interval) if wait && box.state == "creating"
      box
    end

    # The body of POST /v1/sandboxes for these options (ArgumentError on a bad one).
    def create_body(template: nil, region: nil, sleep_after_s: nil, ttl_s: nil, delete_after: nil,
                    accept_price: nil, size: nil, cpus: nil, mem_mb: nil, image: nil, disk_gb: nil,
                    persistent: nil, docker: nil, cpu: nil, name: nil, labels: nil, env: nil, secrets: nil,
                    egress: nil, snapshot: nil, record: nil, ai_gateway: nil, kvm: nil)
      Cloud.check_lifetime(ttl_s, delete_after)
      Cloud.check_sleep_after(sleep_after_s)
      if !accept_price.nil? && !accept_price.is_a?(Numeric)
        raise ArgumentError, "accept_price must be a number (USD)"
      end

      body = {}
      body["template"] = template unless template.nil?
      body["region"] = region unless region.nil?
      body["sleep_after_s"] = sleep_after_s unless sleep_after_s.nil?
      body["ttl_s"] = ttl_s unless ttl_s.nil?
      body["delete_after"] = delete_after unless delete_after.nil?
      body["accept_price"] = accept_price unless accept_price.nil?
      sized(body, size, cpus, mem_mb, image, disk_gb, persistent, docker, cpu)
      unless name.nil?
        raise ArgumentError, "name: 1 to 64 of letters, digits, '.', '_' or '-'" unless Cloud::SANDBOX_NAME.match?(name.to_s)

        body["name"] = name.to_s
      end
      body["labels"] = Cloud.check_labels(labels) unless labels.nil?
      body["env"] = Cloud.check_env(env) unless env.nil?
      body["secrets"] = secrets.to_a.map { |n| Cloud.check_secret_name(n) } unless secrets.nil?
      body["egress"] = Cloud.egress_body(egress) unless egress.nil?
      body["record"] = record == true unless record.nil?
      body["ai_gateway"] = ai_gateway == true unless ai_gateway.nil?
      body["kvm"] = kvm == true unless kvm.nil?
      unless snapshot.nil?
        raise ArgumentError, "snapshot: is a snapshot id (snap_...)" unless Cloud::SNAPSHOT_ID.match?(snapshot.to_s)

        clash = %w[template region size cpus mem_mb image disk_gb persistent docker kvm cpu] & body.keys
        unless clash.empty?
          raise ArgumentError, "a create from a snapshot takes the snapshot's #{clash.join(', ')}; give only env:, name:, labels:, a lifetime or sleep_after_s:"
        end

        body["snapshot"] = snapshot.to_s
      end
      body
    end

    # One page of sandboxes; name: finds one by name, labels: keeps those
    # with every label ({"team" => "a"}; a nil value matches any value).
    alias list_page_without_features list_page
    def list_page(all: false, limit: nil, cursor: nil, name: nil, labels: nil)
      return list_page_without_features(all: all, limit: limit, cursor: cursor) if name.nil? && labels.nil?

      q = []
      q << %w[all 1] if all
      q << ["limit", Integer(limit).to_s] unless limit.nil?
      q << ["cursor", cursor.to_s] if cursor && !cursor.to_s.empty?
      q << ["name", name.to_s] unless name.nil?
      (labels || {}).sort_by { |k, _| k.to_s }.each { |k, v| q << ["label", v.nil? ? k.to_s : "#{k}=#{v}"] }
      r = @cloud.request("GET", "/v1/sandboxes?#{URI.encode_www_form(q)}")
      r = {} unless r.is_a?(Hash)
      nxt = r["next_cursor"]
      CloudSandboxPage.new(sandboxes: (r["sandboxes"] || []).map { |s| CloudSandbox.new(@cloud, s) },
                           next_cursor: nxt.is_a?(String) && !nxt.empty? ? nxt : nil)
    end

    alias list_without_features list
    def list(all: false, limit: nil, cursor: nil, name: nil, labels: nil)
      list_page(all: all, limit: limit, cursor: cursor, name: name, labels: labels).sandboxes
    end

    private

    def sized(body, size, cpus, mem_mb, image, disk_gb, persistent, docker, cpu)
      unless size.nil?
        unless Cloud::SANDBOX_SIZES.include?(size.to_s)
          raise ArgumentError, "size must be one of #{Cloud::SANDBOX_SIZES.join(', ')}"
        end

        body["size"] = size.to_s
      end
      raise ArgumentError, "give cpus: and mem_mb: together" if cpus.nil? != mem_mb.nil?

      unless cpus.nil?
        raise ArgumentError, "give size: or cpus: and mem_mb:, not both" unless size.nil?
        unless cpus.is_a?(Numeric) && cpus.positive?
          raise ArgumentError, "cpus must be a positive number (0.25, 0.5, 1, 2, 4, 8 or 16)"
        end

        # 0.25 and 0.5 are sent as they are; a whole number as an Integer.
        body["cpus"] = cpus == cpus.to_i ? cpus.to_i : cpus.to_f
        body["mem_mb"] = Integer(mem_mb)
      end
      body["image"] = image.to_s unless image.nil?
      unless disk_gb.nil?
        raise ArgumentError, "disk_gb must be 8 to 500" unless disk_gb.is_a?(Integer) && disk_gb.between?(8, 500)

        body["disk_gb"] = disk_gb
      end
      body["persistent"] = persistent == true unless persistent.nil?
      body["docker"] = docker == true unless docker.nil?
      return if cpu.nil?
      raise ArgumentError, 'cpu must be "shared" or "dedicated"' unless %w[shared dedicated].include?(cpu.to_s)

      body["cpu"] = cpu.to_s
    end
  end

  class CloudSandbox
    # Poll until it is no longer "creating" (a sized create boots cold);
    # raises Kosa8::Error if it ends in any state but running.
    def wait_running(timeout: 600, poll_interval: 1)
      deadline = Time.now + timeout
      while state == "creating"
        raise TimeoutError, "sandbox #{id} was still creating after #{timeout} s" if Time.now > deadline

        Kernel.sleep(poll_interval)
        refresh
      end
      return self if state == "running"

      raise Error, "sandbox #{id} is #{state}, not running#{@info['last_error'] ? ": #{@info['last_error']}" : ''}"
    end

    # Start a command that keeps running after this returns (no 90 s
    # limit). Returns the background command (a Hash: "id" (bg_...),
    # "state", "pid", "output_path", ...); poll it with #background_exec or
    # #wait_background.
    # +timeout_s+ (1 s to a day) has the host end it then ("timed_out" in
    # #background_exec).
    def exec_background(cmd, image: nil, env: nil, timeout_s: nil)
      argv = cmd.is_a?(String) ? ["sh", "-c", cmd] : cmd.to_a
      raise ArgumentError, "exec_background needs a command" if argv.empty?
      unless timeout_s.nil? || (timeout_s.is_a?(Integer) && timeout_s.between?(1, 86_400))
        raise ArgumentError, "timeout_s must be a whole number of seconds from 1 to 86400"
      end

      body = { "cmd" => argv, "background" => true }
      body["timeout_s"] = timeout_s unless timeout_s.nil?
      body["image"] = image unless image.nil?
      body["env"] = Cloud.env_list(env) if env && !env.empty?
      @cloud.request("POST", path("/exec"), body)["exec"]
    end

    # A background command: "state" ("running" or "exited"), "exit" and the
    # "output" so far.
    def background_exec(exec_id)
      raise ArgumentError, "background_exec needs an exec id (bg_...)" if exec_id.nil? || exec_id.to_s.empty?

      @cloud.request("GET", "/v1/sandboxes/#{Kosa8.enc(id)}/exec/#{Kosa8.enc(exec_id)}")["exec"]
    end

    # Stop a background command and what it started (SIGTERM, then SIGKILL
    # after 5 s); returns the command as it now is.
    def stop_background(exec_id)
      exec_id = exec_id["id"] if exec_id.is_a?(Hash)
      raise ArgumentError, "stop_background needs an exec id (bg_...)" if exec_id.nil? || exec_id.to_s.empty?

      r = @cloud.request("POST", "/v1/sandboxes/#{Kosa8.enc(id)}/exec/#{Kosa8.enc(exec_id)}/stop", {})
      r.is_a?(Hash) ? (r["exec"] || r) : {}
    end

    # Poll a background command until it exits; returns it.
    def wait_background(exec_id, timeout: 3600, poll_interval: 2)
      exec_id = exec_id["id"] if exec_id.is_a?(Hash)
      deadline = Time.now + timeout
      loop do
        e = background_exec(exec_id)
        return e if e["state"] == "exited" || !e["exit"].nil?
        raise TimeoutError, "background command #{exec_id} was still running after #{timeout} s" if Time.now > deadline

        Kernel.sleep(poll_interval)
      end
    end

    # Save it as a durable snapshot (kept until deleted, whatever happens to
    # the sandbox) and return it (a Hash: "id" (snap_...), "state", "bytes",
    # ...). Start new sandboxes from it with create(snapshot: id).
    def snapshot(name = nil)
      body = {}
      body["name"] = name.to_s unless name.nil?
      @cloud.request("POST", path("/snapshots"), body)["snapshot"]
    end

    # Its previews: a CloudPreviews (ports at https URLs).
    def previews
      CloudPreviews.new(@cloud, self)
    end

    # A short-lived wss:// URL for an interactive terminal (a Hash: "url",
    # "expires_at", "protocol"). The URL carries its token: keep it secret.
    def terminal(cols: nil, rows: nil, command: nil)
      body = {}
      body["cols"] = cols unless cols.nil?
      body["rows"] = rows unless rows.nil?
      body["command"] = command.to_a unless command.nil?
      @cloud.request("POST", path("/terminal"), body)["terminal"]
    end

    # The egress policy it runs with ("internet", "allow", "deny", "presets", "source").
    def egress
      @cloud.request("GET", path("/egress"))["egress"]
    end

    # Change what it may reach, at once: internet:, allow:, deny:, presets:.
    def set_egress(internet: false, allow: [], deny: [], presets: [])
      body = Cloud.egress_body(internet: internet, allow: allow, deny: deny, presets: presets)
      @cloud.request("PUT", path("/egress"), body)["egress"]
    end

    # Back to the organization's default egress policy.
    def reset_egress
      @cloud.request("DELETE", path("/egress"))["egress"]
    end

    # The names of the secrets it holds.
    def secrets
      r = @cloud.request("GET", path("/secrets"))
      r.is_a?(Hash) ? (r["secrets"] || []) : []
    end

    # Its schedules: a CloudSchedules.
    def schedules
      CloudSchedules.new(@cloud, self)
    end

    # Run a Python cell in a stateful context (globals persist; charts come
    # back as images in "results"). A cell that raised has "error" set; it
    # is not an exception. Needs a persistent sandbox with python3.
    def run_code(code, context: nil, timeout_s: nil)
      raise ArgumentError, "run_code needs code" if code.nil? || code.to_s.empty?

      body = { "code" => code.to_s, "language" => "python" }
      body["context"] = context.to_s unless context.nil?
      body["timeout_s"] = timeout_s unless timeout_s.nil?
      @cloud.request("POST", path("/code"), body)
    end

    def code_contexts
      r = @cloud.request("GET", path("/code/contexts"))
      r.is_a?(Hash) ? (r["contexts"] || []) : []
    end

    def create_code_context(name = nil)
      body = {}
      body["name"] = name.to_s unless name.nil?
      @cloud.request("POST", path("/code/contexts"), body)["context"]
    end

    def reset_code_context(name)
      @cloud.request("POST", path("/code/contexts/#{Kosa8.enc(name)}/reset"), {})
      nil
    end

    def delete_code_context(name)
      @cloud.request("DELETE", "/v1/sandboxes/#{Kosa8.enc(id)}/code/contexts/#{Kosa8.enc(name)}")
      nil
    end

    # CPU, memory, disk and network use, read on the host.
    def metrics
      @cloud.request("GET", path("/metrics"))["metrics"]
    end

    # Its last commands, with exit codes and output tails.
    def logs(limit: nil)
      r = @cloud.request("GET", path("/logs") + (limit.nil? ? "" : "?limit=#{Integer(limit)}"))
      r.is_a?(Hash) ? (r["entries"] || []) : []
    end

    # Replace its labels (nil or {} clears them); returns the new labels.
    def set_labels(labels)
      body = { "labels" => labels.nil? || labels.empty? ? nil : Cloud.check_labels(labels) }
      r = @cloud.request("PUT", path("/labels"), body)
      @info = @info.merge("labels" => r["labels"] || {}) if r.is_a?(Hash)
      r.is_a?(Hash) ? (r["labels"] || {}) : {}
    end
  end

  class CloudFiles
    # The most one upload request carries; a bigger file goes in parts.
    UPLOAD_PART_BYTES = 64 * 1024 * 1024

    # A file of any size (no 8 MiB cap), as a binary String; +range:+ as #read.
    def download(path, range: nil)
      @cloud.request_bytes("GET", query("/files/raw", path), raw: true, headers: CloudFiles.range_header(range))
    end

    # Write +content+ (a String, or an IO such as a File, read a part at a
    # time) to a file of any size; returns its info Hash. Past +part_size+
    # bytes (default 64 MiB; one request through the API is at most 100 MB)
    # it is sent in parts with offset=, each retried on its own; a host
    # without offset writes answers 501 (Kosa8::UnsupportedError): use
    # #link(path, method: "PUT") then. +mode:+ as #write.
    def upload(path, content, part_size: UPLOAD_PART_BYTES, mode: nil)
      unless part_size.is_a?(Integer) && part_size.positive?
        raise ArgumentError, "part_size: a whole number of bytes, more than 0"
      end

      CloudFiles.put_params(nil, false, mode) # a bad mode: is refused before any part is sent
      io = content.respond_to?(:read) ? content : StringIO.new(content.to_s.b)
      cur = (io.read(part_size) || +"").b
      offset = 0
      loop do
        nxt = cur.bytesize == part_size ? io.read(part_size) : nil
        last = nxt.nil? || nxt.empty?
        # The first part replaces the file; the rest are written at their offset.
        params = CloudFiles.put_params(offset.zero? ? nil : offset, false, last ? mode : nil)
        r = @cloud.request_bytes("PUT", query("/files/raw", path, params), data: cur)
        offset += cur.bytesize
        return r.is_a?(Hash) ? (r["file"] || {}) : {} if last

        cur = nxt.b
      end
    end

    # A presigned URL for one download (GET) or upload (PUT) of +path+,
    # straight to the host (a Hash: "url", "method", "path", "expires_at").
    def link(path, method: "GET", ttl_s: nil)
      raise ArgumentError, "a path is required, e.g. /workspace/app.py" if path.nil? || path.to_s.empty?

      m = method.to_s.upcase
      raise ArgumentError, 'method must be "GET" or "PUT"' unless %w[GET PUT].include?(m)

      body = { "path" => path.to_s, "method" => m }
      body["ttl_s"] = ttl_s unless ttl_s.nil?
      @cloud.request("POST", @sandbox.path("/files/link"), body)["link"]
    end
  end

  # sandbox.previews: a port of the sandbox at its own https URL, private (a
  # signed link) unless public.
  class CloudPreviews
    def initialize(cloud, sandbox)
      @cloud = cloud
      @sandbox = sandbox
    end

    def inspect
      "#<Kosa8::CloudPreviews sandbox=#{@sandbox.id.inspect}>"
    end

    # Open +port+; returns the preview (a Hash: "url", "host", "token", ...).
    def create(port, public: false, expires_in_s: nil, wake: nil, wake_per_hour: nil)
      body = { "port" => check(port) }
      body["public"] = true if public
      body["expires_in_s"] = expires_in_s unless expires_in_s.nil?
      body["wake"] = wake unless wake.nil?
      body["wake_per_hour"] = wake_per_hour unless wake_per_hour.nil?
      @cloud.request("POST", @sandbox.path("/previews"), body)["preview"]
    end

    # Its previews (without tokens).
    def list
      r = @cloud.request("GET", @sandbox.path("/previews"))
      r.is_a?(Hash) ? (r["previews"] || []) : []
    end

    # A new signed link for a private preview.
    def link(port, expires_in_s: nil)
      body = {}
      body["expires_in_s"] = expires_in_s unless expires_in_s.nil?
      @cloud.request("POST", @sandbox.path("/previews/#{check(port)}/link"), body)["preview"]
    end

    # A new host name, so every old link stops working.
    def rotate(port)
      @cloud.request("POST", @sandbox.path("/previews/#{check(port)}/rotate"), {})["preview"]
    end

    def delete(port)
      @cloud.request("DELETE", "/v1/sandboxes/#{Kosa8.enc(@sandbox.id)}/previews/#{check(port)}")
      nil
    end

    private

    def check(port)
      return port if port.is_a?(Integer) && port.between?(1, 65_535)

      raise ArgumentError, "a port is 1 to 65535"
    end
  end

  # sandbox.schedules: commands run in the sandbox on a cron schedule (UTC).
  class CloudSchedules
    def initialize(cloud, sandbox)
      @cloud = cloud
      @sandbox = sandbox
    end

    def inspect
      "#<Kosa8::CloudSchedules sandbox=#{@sandbox.id.inspect}>"
    end

    def create(cron:, cmd:, env: nil, name: nil, wake: nil)
      argv = cmd.is_a?(String) ? ["sh", "-c", cmd] : cmd.to_a
      raise ArgumentError, "a schedule needs cron: and cmd:" if cron.to_s.empty? || argv.empty?

      body = { "cron" => cron.to_s, "cmd" => argv }
      body["env"] = Cloud.env_list(env) if env && !env.empty?
      body["name"] = name.to_s unless name.nil?
      body["wake"] = wake unless wake.nil?
      @cloud.request("POST", @sandbox.path("/schedules"), body)["schedule"]
    end

    def list
      r = @cloud.request("GET", @sandbox.path("/schedules"))
      r.is_a?(Hash) ? (r["schedules"] || []) : []
    end

    def delete(id)
      @cloud.request("DELETE", "/v1/sandboxes/#{Kosa8.enc(@sandbox.id)}/schedules/#{Kosa8.enc(id)}")
      nil
    end

    # Run it now; returns the run ("status", "exit", "output", ...).
    def run(id)
      @cloud.request("POST", @sandbox.path("/schedules/#{Kosa8.enc(id)}/run"), {})["run"]
    end
  end

  # cloud.snapshots: the org's durable snapshots.
  class CloudSnapshots
    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudSnapshots>"
    end

    # Newest first; sandbox_id: only one sandbox's.
    def list(sandbox_id: nil)
      q = sandbox_id.nil? ? "" : "?#{URI.encode_www_form([['sandbox_id', sandbox_id.to_s]])}"
      r = @cloud.request("GET", "/v1/snapshots#{q}")
      r.is_a?(Hash) ? (r["snapshots"] || []) : []
    end

    def get(id)
      @cloud.request("GET", "/v1/snapshots/#{Kosa8.enc(id)}")["snapshot"]
    end

    def delete(id)
      @cloud.request("DELETE", "/v1/snapshots/#{Kosa8.enc(id)}")
      nil
    end
  end

  # cloud.secrets: the org's secrets. A sandbox created with secrets: holds
  # only a placeholder; its egress broker adds the value on the way out.
  class CloudSecrets
    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudSecrets>"
    end

    # Store (or replace) a secret. +value+ is never logged or returned; read
    # it from a file or $stdin, not from code. pipelines: true lets Pipelines
    # runs use it. Returns the secret (without its value).
    def set(name, value:, upstream: nil, header: nil, scheme: nil, methods: nil, paths: nil, env: nil,
            pipelines: false)
      raise ArgumentError, "a secret needs a value" if value.nil? || value.to_s.empty?

      body = { "value" => value.to_s }
      body["upstream"] = upstream.to_s unless upstream.nil?
      body["header"] = header.to_s unless header.nil?
      body["scheme"] = scheme.to_s unless scheme.nil?
      body["methods"] = methods.to_a unless methods.nil?
      body["paths"] = paths.to_a unless paths.nil?
      body["env"] = env.to_h unless env.nil?
      body["pipelines"] = true if pipelines
      @cloud.request("PUT", "/v1/secrets/#{Kosa8.enc(Cloud.check_secret_name(name))}", body)["secret"]
    end

    def list
      r = @cloud.request("GET", "/v1/secrets")
      r.is_a?(Hash) ? (r["secrets"] || []) : []
    end

    # Delete it; returns the ids of sandboxes still holding it.
    def delete(name)
      r = @cloud.request("DELETE", "/v1/secrets/#{Kosa8.enc(Cloud.check_secret_name(name))}")
      r.is_a?(Hash) ? (r["still_held_by"] || []) : []
    end
  end

  # cloud.pipelines: kosa8 Pipelines, CI on kosa8 Cloud.
  #
  #   run = cloud.pipelines.run(repo_url: "https://github.com/me/app", ref: "main")
  #   run = cloud.pipelines.wait(run["id"])
  #   run["state"] # => "success"
  class CloudPipelines
    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudPipelines>"
    end

    # Start a run of the repository's .kosa8/pipeline.yml (or its
    # .github/workflows through act). secrets: names secrets marked
    # pipelines: true.
    def run(repo_url:, ref: nil, event: nil, workflow: nil, job: nil, inputs: nil, size: nil, secrets: nil,
            token_secret: nil, status_secret: nil, timeout_s: nil)
      raise ArgumentError, "a run needs repo_url:" if repo_url.to_s.empty?

      body = { "repo_url" => repo_url.to_s }
      { "ref" => ref, "event" => event, "workflow" => workflow, "job" => job, "size" => size,
        "token_secret" => token_secret, "status_secret" => status_secret }.each { |k, v| body[k] = v.to_s unless v.nil? }
      body["inputs"] = inputs.to_h unless inputs.nil?
      body["secrets"] = secrets.to_a unless secrets.nil?
      body["timeout_s"] = timeout_s unless timeout_s.nil?
      @cloud.request("POST", "/v1/pipelines/runs", body)["run"]
    end

    # Runs, newest first.
    def runs(state: nil, limit: nil)
      q = []
      q << ["state", state.to_s] unless state.nil?
      q << ["limit", Integer(limit).to_s] unless limit.nil?
      r = @cloud.request("GET", "/v1/pipelines/runs" + (q.empty? ? "" : "?#{URI.encode_www_form(q)}"))
      r.is_a?(Hash) ? (r["runs"] || []) : []
    end

    def get(id)
      @cloud.request("GET", run_path(id))["run"]
    end

    # Poll a run until it finishes; returns it.
    def wait(id, timeout: 6 * 3600, poll_interval: 5)
      deadline = Time.now + timeout
      loop do
        r = get(id)
        return r if Cloud::FINISHED_RUN_STATES.include?(r["state"])
        raise TimeoutError, "pipeline run #{id} was still #{r['state']} after #{timeout} s" if Time.now > deadline

        Kernel.sleep(poll_interval)
      end
    end

    # Its logs by job ("logs": [{"job", "text", "next", ...}], "done"),
    # secrets replaced with ***. after: a previous answer's "next" reads only
    # newer text.
    def logs(id, job: nil, after: nil)
      q = []
      q << ["job", job.to_s] unless job.nil?
      q << ["after", Integer(after).to_s] unless after.nil?
      @cloud.request("GET", run_path(id, "/logs") + (q.empty? ? "" : "?#{URI.encode_www_form(q)}"))
    end

    def cancel(id)
      @cloud.request("POST", run_path(id, "/cancel"), {})["run"]
    end

    def artifacts(id)
      r = @cloud.request("GET", run_path(id, "/artifacts"))
      r.is_a?(Hash) ? (r["artifacts"] || []) : []
    end

    # One artifact's bytes (a .tar.gz), as a binary String.
    def download_artifact(id, job, idx)
      @cloud.request_bytes("GET", "/v1/pipelines/runs/#{Kosa8.enc(id)}/artifacts/#{Kosa8.enc(job)}/#{Integer(idx)}",
                           raw: true)
    end

    # A webhook URL for a repository's pushes and pull requests, and with
    # cron: a schedule. The answer's "secret" is shown only now: give it and
    # "url" to the git host.
    def create_hook(repo_url:, provider: nil, name: nil, secret: nil, size: nil, secrets: nil, token_secret: nil,
                    status_secret: nil, workflow: nil, timeout_s: nil, cron: nil, cron_ref: nil)
      raise ArgumentError, "a hook needs repo_url:" if repo_url.to_s.empty?

      body = { "repo_url" => repo_url.to_s }
      { "provider" => provider, "name" => name, "secret" => secret, "size" => size, "token_secret" => token_secret,
        "status_secret" => status_secret, "workflow" => workflow, "cron" => cron,
        "cron_ref" => cron_ref }.each { |k, v| body[k] = v.to_s unless v.nil? }
      body["secrets"] = secrets.to_a unless secrets.nil?
      body["timeout_s"] = timeout_s unless timeout_s.nil?
      @cloud.request("POST", "/v1/pipelines/hooks", body)["hook"]
    end

    def hooks
      r = @cloud.request("GET", "/v1/pipelines/hooks")
      r.is_a?(Hash) ? (r["hooks"] || []) : []
    end

    def delete_hook(id)
      @cloud.request("DELETE", "/v1/pipelines/hooks/#{Kosa8.enc(id)}")
      nil
    end

    private

    def run_path(id, suffix = "")
      "/v1/pipelines/runs/#{Kosa8.enc(id)}#{suffix}"
    end
  end
end
