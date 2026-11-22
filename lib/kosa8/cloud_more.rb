# frozen_string_literal: true

require "json"
require "time"
require "uri"

# More of kosa8 Cloud (0.6.0), to match @kosa8/sdk and the Python SDK:
# browsers, the AI gateway, hosted jobs, benchmarks, RL compare and alerts,
# usage insights, limits and pricing, the audit log, API keys, webhooks,
# function invocations, org egress, Burst Passes, embeds, custom preview
# domains and desktop recordings. Answers are the API's own Hashes
# (snake_case keys, times in Unix ms unless the API says otherwise).
module Kosa8
  class Cloud
    # Headless Chromium on demand (a CloudBrowsers).
    attr_reader :browsers
    # The org's AI gateway: provider keys kept server-side, usage (a CloudAi).
    attr_reader :ai
    # Hosted eval/RL jobs: tasks, a solver and a grader (a CloudJobs).
    attr_reader :jobs
    # Ready-made benchmarks and their environments (a CloudBenchmarks).
    attr_reader :benchmarks
    # Alert rules on RL runs (a CloudRlAlerts).
    attr_reader :rl_alerts
    # The audit log (a CloudAudit).
    attr_reader :audit
    # The org's API keys (a CloudApiKeys; needs a key with keys:manage).
    attr_reader :api_keys
    # Webhook endpoints (a CloudWebhooks).
    attr_reader :webhooks
    # Desktop recordings (a CloudRecordings).
    attr_reader :recordings
    # Burst Passes (a CloudBurst).
    attr_reader :burst

    alias initialize_without_more initialize
    def initialize(**kw)
      initialize_without_more(**kw)
      @browsers = CloudBrowsers.new(self)
      @ai = CloudAi.new(self)
      @jobs = CloudJobs.new(self)
      @benchmarks = CloudBenchmarks.new(self)
      @rl_alerts = CloudRlAlerts.new(self)
      @audit = CloudAudit.new(self)
      @api_keys = CloudApiKeys.new(self)
      @webhooks = CloudWebhooks.new(self)
      @recordings = CloudRecordings.new(self)
      @burst = CloudBurst.new(self)
    end

    # Open a browser (cloud.browsers.create); with a block, it is closed
    # when the block ends, error or not, and the block's value is returned.
    def browser(ttl_s: nil, sandbox_id: nil, name: nil)
      b = @browsers.create(ttl_s: ttl_s, sandbox_id: sandbox_id, name: name)
      return b unless block_given?

      begin
        yield b
      ensure
        begin
          b.close
        rescue Error
          nil # closing on the way out must not hide the real error
        end
      end
    end

    # Spend day by day this month, top sandboxes, credit left and the
    # projected month-end spend.
    def usage_insights
      request("GET", "/v1/usage/insights")
    end

    # The rate card: prices per vCPU, GiB, storage, browsers and so on.
    def pricing
      request("GET", "/v1/pricing")
    end

    # The running-sandbox limit: "active", "max_running", "reached" and the
    # last request for more.
    def limits
      request("GET", "/v1/limits")
    end

    # Ask kosa8 for a higher running-sandbox limit (once a day); kosa8
    # answers the owner by email.
    def request_limit(max_running, reason: nil)
      body = { "max_running" => Integer(max_running) }
      body["reason"] = reason.to_s unless reason.nil?
      request("POST", "/v1/limits/request", body)
    end

    # Sandboxes with their fork parents ("nodes", "roots", "forked"), for
    # drawing the fork tree.
    def lineage
      request("GET", "/v1/lineage")
    end

    # Checkpoints of every running or sleeping sandbox (up to 25), asked of
    # each host; wakes nothing. One sandbox's own: box.checkpoints.
    def checkpoints
      request("GET", "/v1/checkpoints")
    end

    # The images behind the templates the org's hosts offer, with tag and
    # digest ("images", "default_template").
    def images
      request("GET", "/v1/images")
    end

    # The org's default egress policy ("default", "enforce"), or nil when
    # there is none (open internet).
    def org_egress
      r = request("GET", "/v1/org/egress")
      r.is_a?(Hash) ? r["egress"] : nil
    end

    # Set the org's default egress policy (an admin key); nil clears it. With
    # +enforce+ it is a ceiling sandboxes cannot widen. Pushed at once to the
    # running and sleeping sandboxes it changes.
    def set_org_egress(policy, enforce: nil)
      body = { "default" => policy.nil? ? nil : Cloud.egress_body(policy) }
      body["enforce"] = enforce == true if !policy.nil? && !enforce.nil?
      request("PUT", "/v1/org/egress", body)
    end

    # The custom domains of a preview by its id ("{sandbox_id}:{port}", a
    # preview's "id"); box.previews.domains(port) is the same.
    def preview_domains(preview_id)
      raise ArgumentError, "preview_domains needs a preview id" if preview_id.nil? || preview_id.to_s.empty?

      CloudPreviewDomains.new(self, preview_id: preview_id.to_s)
    end

    # Two to four RL runs side by side: reward by step, failure classes, cost.
    def rl_compare(*ids)
      ids = ids.flatten.map(&:to_s)
      raise ArgumentError, "rl_compare takes 2 to 4 run ids" unless ids.size.between?(2, 4)

      request("GET", "/v1/rl/compare?#{URI.encode_www_form([['ids', ids.join(',')]])}")
    end

    # Agent attack scorecards the org uploaded (from `kosa8 attack run`),
    # newest first.
    def attack_scorecards(limit: nil)
      r = request("GET", "/v1/attack/scorecards#{Cloud.query_string([['limit', limit]])}")
      r.is_a?(Hash) ? (r["scorecards"] || []) : []
    end

    # One scorecard, with the signed file as uploaded.
    def attack_scorecard(id)
      request("GET", "/v1/attack/scorecards/#{Kosa8.enc(id)}")["scorecard"]
    end

    # Upload a signed scorecard (the file `kosa8 attack run` wrote, as a
    # String or parsed); its signature is checked before it is stored.
    def upload_attack_scorecard(signed)
      if signed.is_a?(String)
        begin
          signed = JSON.parse(signed)
        rescue JSON::ParserError
          raise ArgumentError, "the signed scorecard is not JSON"
        end
      end
      request("POST", "/v1/attack/scorecards", { "signed" => signed })["scorecard"]
    end

    def self.check_range(name, v, min, max)
      return v if v.is_a?(Integer) && v.between?(min, max)

      raise ArgumentError, "#{name} must be a whole number from #{min} to #{max}"
    end

    # "?k=v&..." for the pairs whose value is not nil, or "".
    def self.query_string(pairs)
      q = pairs.reject { |_, v| v.nil? }.map { |k, v| [k.to_s, v.to_s] }
      q.empty? ? "" : "?#{URI.encode_www_form(q)}"
    end
  end

  class CloudSandbox
    # Signed, expiring iframe URLs for its terminal or desktop (a CloudEmbeds).
    def embeds
      CloudEmbeds.new(@cloud, self)
    end

    # Its desktop recordings (made when it is deleted, for a sandbox created
    # with record: true).
    def recordings
      r = @cloud.request("GET", path("/recordings"))
      r.is_a?(Hash) ? (r["recordings"] || []) : []
    end
  end

  class CloudPreviews
    # The custom domains of the preview on +port+ (a CloudPreviewDomains).
    def domains(port)
      CloudPreviewDomains.new(@cloud, sandbox_id: @sandbox.id, port: check(port))
    end
  end

  class CloudFunctions
    # Its recent calls, newest first (with logs for keys that may read its code).
    def invocations(name, limit: nil)
      q = limit.nil? ? "" : "?limit=#{Cloud.check_range('limit', limit, 1, 1000)}"
      r = @cloud.request("GET", "/v1/functions/#{Kosa8.enc(name)}/invocations#{q}")
      r.is_a?(Hash) ? (r["invocations"] || []) : []
    end
  end

  # ---------------------------------------------------------------------------
  # Browsers

  # One cloud browser. +info+ is its state as of the last call; #cdp_url
  # (valid 10 minutes) connects a CDP client (Playwright's
  # connect_over_cdp, Ferrum, Puppeteer); #refresh gets a fresh one.
  # $0.12 per browser-hour, billed per second.
  class CloudBrowser
    attr_reader :info

    def initialize(cloud, info)
      @cloud = cloud
      @info = info.is_a?(Hash) ? info : {}
    end

    def id
      @info["id"]
    end

    def state
      @info["state"].to_s
    end

    # wss://.../v1/browsers/{id}/cdp?token=... while open; nil when closed or
    # from a list (refresh it).
    def cdp_url
      @info["cdp_url"]
    end

    def cdp_url_expires_at
      @info["cdp_url_expires_at"]
    end

    # Never the cdp_url (it carries a token).
    def inspect
      "#<Kosa8::CloudBrowser id=#{id.inspect} state=#{state.inspect}>"
    end

    # The path of its CDP WebSocket (GET /v1/browsers/{id}/cdp?token=...);
    # #cdp_url is this with a token, ready to open.
    def cdp_path
      "/v1/browsers/#{Kosa8.enc(id)}/cdp"
    end

    # Read it again: its state and, while open, a fresh #cdp_url.
    def refresh
      @info = @cloud.request("GET", "/v1/browsers/#{Kosa8.enc(id)}")["browser"]
      self
    end

    # Load +url+: "url", "title" and, if asked, "text" and
    # "screenshot_png_base64".
    def page(url, screenshot: nil, text: nil, full_page: nil)
      raise ArgumentError, "page needs a url" if url.nil? || url.to_s.empty?

      body = { "url" => url.to_s }
      body["screenshot"] = screenshot == true unless screenshot.nil?
      body["text"] = text == true unless text.nil?
      body["full_page"] = full_page == true unless full_page.nil?
      @cloud.request("POST", "/v1/browsers/#{Kosa8.enc(id)}/page", body)["page"]
    end

    # Load +url+; "url", "title" and (unless text: false) the page's "text".
    def goto(url, text: true)
      page(url, text: text)
    end

    # Load +url+ and return a PNG of it (a binary String): the viewport, or
    # the whole page with full_page: true.
    def screenshot(url, full_page: false)
      p = page(url, screenshot: true, full_page: full_page ? true : nil)
      b64 = p.is_a?(Hash) ? p["screenshot_png_base64"] : nil
      raise Error, "the API sent no screenshot" if b64.nil? || b64.empty?

      b64.unpack1("m").b
    end

    # Close it; billing stops.
    def close
      r = @cloud.request("DELETE", "/v1/browsers/#{Kosa8.enc(id)}")
      @info = @info.merge("state" => "closed", "cdp_url" => nil)
      r
    end
  end

  # cloud.browsers: headless Chromium on demand.
  class CloudBrowsers
    # USD per browser-hour, billed per second (the API's price_per_hour_usd is the live figure).
    PRICE_PER_HOUR_USD = 0.12

    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudBrowsers>"
    end

    # Open a browser. +ttl_s+ 30..3600 (default 300): it closes on its own
    # after this. +sandbox_id+ ties it to a sandbox.
    def create(ttl_s: nil, sandbox_id: nil, name: nil)
      body = {}
      body["ttl_s"] = Cloud.check_range("ttl_s", ttl_s, 30, 3600) unless ttl_s.nil?
      body["sandbox_id"] = sandbox_id.to_s unless sandbox_id.nil?
      body["name"] = name.to_s unless name.nil?
      CloudBrowser.new(@cloud, @cloud.request("POST", "/v1/browsers", body)["browser"])
    end

    # The list answer as sent: "browsers" (no cdp_url), "enabled", "limit",
    # "price_per_hour_usd". state: "open" (default) or "all".
    def info(state: nil)
      raise ArgumentError, 'state must be "open" or "all"' unless state.nil? || %w[open all].include?(state.to_s)

      r = @cloud.request("GET", "/v1/browsers#{Cloud.query_string([['state', state]])}")
      r.is_a?(Hash) ? r : {}
    end

    # Open browsers (state: "all" for closed ones too), as CloudBrowsers.
    def list(state: nil)
      (info(state: state)["browsers"] || []).map { |b| CloudBrowser.new(@cloud, b) }
    end

    # One browser, with a fresh cdp_url while open.
    def get(id)
      CloudBrowser.new(@cloud, @cloud.request("GET", "/v1/browsers/#{Kosa8.enc(id)}")["browser"])
    end

    # Close a browser by id.
    def delete(id)
      @cloud.request("DELETE", "/v1/browsers/#{Kosa8.enc(id)}")
    end
  end

  # ---------------------------------------------------------------------------
  # AI gateway

  # cloud.ai: the org's AI gateway. Provider keys stay on kosa8 Cloud; a
  # sandbox created with ai_gateway: true gets OPENAI_BASE_URL,
  # ANTHROPIC_BASE_URL, KOSA8_AI_GATEWAY_URL and KOSA8_AI_TOKEN. Outside a
  # sandbox, point a client at #gateway_url with the kosa8 API key as its key.
  class CloudAi
    PROVIDER = /\A[a-z0-9][a-z0-9-]{0,39}\z/.freeze

    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudAi>"
    end

    # "settings" ("enabled", "all_sandboxes", "cache_ttl_s", "rate_per_min"),
    # "available", "base_url", "providers", ...
    def settings
      @cloud.request("GET", "/v1/ai/settings")
    end

    # Change the given settings only.
    def update_settings(enabled: nil, all_sandboxes: nil, cache_ttl_s: nil, rate_per_min: nil)
      body = {}
      body["enabled"] = enabled == true unless enabled.nil?
      body["all_sandboxes"] = all_sandboxes == true unless all_sandboxes.nil?
      body["cache_ttl_s"] = Integer(cache_ttl_s) unless cache_ttl_s.nil?
      body["rate_per_min"] = Integer(rate_per_min) unless rate_per_min.nil?
      raise ArgumentError, "give at least one setting to change" if body.empty?

      @cloud.request("PATCH", "/v1/ai/settings", body)
    end

    # Store a provider's API key ("openai", "anthropic", ...). It is never sent back.
    def set_key(provider, key)
      raise ArgumentError, "provider and key are required" if key.nil? || key.to_s.empty?

      @cloud.request("PUT", "/v1/ai/keys/#{check(provider)}", { "key" => key.to_s })
    end

    # Stored keys ("provider", "hint", ...: never the key).
    def keys
      r = @cloud.request("GET", "/v1/ai/keys")
      r.is_a?(Hash) ? (r["keys"] || []) : []
    end

    def delete_key(provider)
      @cloud.request("DELETE", "/v1/ai/keys/#{check(provider)}")
    end

    # A month's ("YYYY-MM", default this one) calls and cost: "total",
    # "by_model", "by_sandbox", "recent".
    def usage(month = nil)
      unless month.nil? || /\A\d{4}-(0[1-9]|1[0-2])\z/.match?(month.to_s)
        raise ArgumentError, "month must be YYYY-MM"
      end

      @cloud.request("GET", "/v1/ai/usage#{Cloud.query_string([['month', month]])}")
    end

    # The base URL for a provider's own SDK, through the gateway:
    # "https://api.kosa8.com/v1/ai/gw/openai" (OpenAI's client appends
    # /chat/completions, Anthropic's /v1/messages). Use the kosa8 API key
    # as the client's API key.
    def gateway_url(provider)
      "#{@cloud.base_url}/v1/ai/gw/#{check(provider)}"
    end

    # One model call through the gateway, in the provider's own request
    # shape: call("openai", "chat/completions", {"model" => ..., "messages" => [...]}).
    # Not retried unless the gateway refused it first (429 ai_rate_limit).
    def call(provider, api_path, body)
      p = api_path.to_s.sub(%r{\A/+}, "")
      raise ArgumentError, "api_path is the provider's API path, e.g. chat/completions" if p.empty? || p.include?("..")

      @cloud.request("POST", "/v1/ai/gw/#{check(provider)}/#{p}", body.to_h)
    end

    private

    def check(provider)
      return provider.to_s if PROVIDER.match?(provider.to_s)

      raise ArgumentError, "provider is a name such as openai or anthropic"
    end
  end

  # ---------------------------------------------------------------------------
  # Jobs

  # cloud.jobs: hosted eval and RL jobs. kosa8 runs each task in its own
  # sandbox (template:, image: or snapshot:), runs the solver then the sealed
  # grader, records every rollout under the job's RL run and stops at
  # +budget_usd+. A submit carries an Idempotency-Key reused on every retry.
  class CloudJobs
    DONE_STATES = %w[done failed cancelled budget_reached].freeze
    MAX_TASKS = 10_000

    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudJobs>"
    end

    # Whether a job (a Hash) has finished.
    def self.done?(job)
      DONE_STATES.include?(job.is_a?(Hash) ? job["status"].to_s : "")
    end

    # Submit a job; returns it (a Hash: "id", "run_id", "status", ...).
    #
    # name:, tasks: (an Array of {"id" =>, "input" =>, "files" => {path =>
    # bytes}} or a JSONL String), solver: and grader: (a command, String or
    # Array, or a Hash with "cmd", "timeout_s", "env" and for the grader
    # "files"), exactly one of template:/image:/snapshot:, and
    # solver_timeout_s: unless the solver Hash has one. Optional: project:,
    # size:, grader_timeout_s:, grader_files:, concurrency:,
    # retries_on_infra:, lease_s:, budget_usd:.
    def submit(idempotency_key: nil, **opts)
      Cloud.check_idempotency_key(idempotency_key)
      job_of(@cloud.request("POST", "/v1/jobs", CloudJobs.body(**opts), idempotency_key: idempotency_key))
    end

    # What a job would cost (sandbox hours, USD low/high), without running it;
    # sample: n runs n tasks first to measure, or sample_job_id: uses a job's.
    def estimate(sample: nil, sample_job_id: nil, **opts)
      raise ArgumentError, "give sample or sample_job_id, not both" if !sample.nil? && !sample_job_id.nil?

      body = CloudJobs.body(**opts)
      body["sample"] = Integer(sample) unless sample.nil?
      body["sample_job_id"] = sample_job_id.to_s unless sample_job_id.nil?
      @cloud.request("POST", "/v1/jobs/estimate", body) || {}
    end

    def get(id)
      job_of(@cloud.request("GET", "/v1/jobs/#{Kosa8.enc(id)}"))
    end

    def list(status: nil, project: nil, limit: nil, cursor: nil)
      q = Cloud.query_string([["status", status], ["project", project], ["limit", limit], ["cursor", cursor]])
      r = @cloud.request("GET", "/v1/jobs#{q}")
      r.is_a?(Hash) ? (r["jobs"] || []) : []
    end

    # Stop it: no new tasks start, running ones are stopped.
    def cancel(id)
      job_of(@cloud.request("POST", "/v1/jobs/#{Kosa8.enc(id)}/cancel", {}))
    end

    # Poll until it is done; the block (if given) gets each poll's job.
    def wait(id, timeout: nil, poll_interval: 5)
      deadline = timeout.nil? ? nil : Time.now + timeout
      loop do
        job = get(id)
        yield job if block_given?
        return job if CloudJobs.done?(job)
        if deadline && Time.now + poll_interval > deadline
          raise TimeoutError, "job #{id} not finished after #{timeout} s (status #{job['status']})"
        end

        @cloud.sleeper.call(poll_interval)
      end
    end

    # The body of POST /v1/jobs (ArgumentError on a bad option).
    def self.body(name:, tasks:, solver:, grader:, template: nil, image: nil, snapshot: nil, size: nil, project: nil,
                  solver_timeout_s: nil, grader_timeout_s: nil, grader_files: nil, concurrency: nil,
                  retries_on_infra: nil, lease_s: nil, budget_usd: nil)
      raise ArgumentError, "a job needs a name" if name.to_s.empty?
      if [template, image, snapshot].compact.size != 1
        raise ArgumentError, "give exactly one of template:, image: or snapshot:"
      end

      s = cmd_spec(solver, "solver", false)
      s["timeout_s"] = solver_timeout_s unless solver_timeout_s.nil?
      if s["timeout_s"].nil?
        raise ArgumentError, "solver needs timeout_s (seconds; a solver past it is recorded as timeout)"
      end

      g = cmd_spec(grader, "grader", true)
      g["timeout_s"] = grader_timeout_s unless grader_timeout_s.nil?
      g["files"] = (g["files"] || {}).merge(encode_files(grader_files)) if grader_files && !grader_files.empty?
      body = { "name" => name.to_s, "tasks" => load_tasks(tasks), "solver" => s, "grader" => g }
      { "project" => project, "template" => template, "image" => image, "snapshot" => snapshot, "size" => size,
        "concurrency" => concurrency, "retries_on_infra" => retries_on_infra, "lease_s" => lease_s,
        "budget_usd" => budget_usd }.each { |k, v| body[k] = v unless v.nil? }
      body
    end

    # {path => base64} for {absolute path => bytes}.
    def self.encode_files(files)
      files.to_h.map do |p, v|
        raise ArgumentError, "file paths are absolute (in the sandbox), got #{p.to_s.inspect}" unless p.to_s.start_with?("/")

        [p.to_s, [v.to_s].pack("m0")]
      end.to_h
    end

    def self.load_tasks(tasks)
      text = tasks.is_a?(String)
      rows = if text
               tasks.each_line.with_index.map do |line, i|
                 t = line.strip
                 next nil if t.empty?

                 begin
                   JSON.parse(t)
                 rescue JSON::ParserError => e
                   raise ArgumentError, "tasks line #{i + 1}: not JSON: #{e.message}"
                 end
               end.compact
             else
               tasks.to_a
             end
      raise ArgumentError, "a job has 1 to #{MAX_TASKS} tasks, got #{rows.size}" unless rows.size.between?(1, MAX_TASKS)

      seen = {}
      rows.each_with_index.map do |t, i|
        raise ArgumentError, "tasks[#{i}] must be a Hash with an id" unless t.is_a?(Hash)

        t = t.map { |k, v| [k.to_s, v] }.to_h
        id = t["id"].is_a?(Integer) ? t["id"].to_s : t["id"]
        raise ArgumentError, "tasks[#{i}] needs an id (a String)" unless id.is_a?(String) && !id.empty?
        raise ArgumentError, "task id #{id.inspect} appears twice" if seen[id]

        seen[id] = true
        row = { "id" => id }
        row["input"] = t["input"] unless t["input"].nil?
        if t["files"].is_a?(Hash) && !t["files"].empty?
          # Already base64 in JSONL: kept as is.
          row["files"] = text ? t["files"] : encode_files(t["files"])
        end
        row
      end
    end

    def self.cmd_spec(spec, what, files)
      s = spec.is_a?(String) || spec.is_a?(Array) ? { "cmd" => spec } : spec.to_h.map { |k, v| [k.to_s, v] }.to_h
      cmd = s["cmd"]
      if cmd.nil? || (cmd.respond_to?(:empty?) && cmd.empty?)
        raise ArgumentError, "#{what} needs cmd (a String run with sh -c, or an Array of arguments)"
      end

      extra = s.keys - ["cmd", "timeout_s", "env"] - (files ? ["files"] : [])
      raise ArgumentError, "#{what}: unknown fields #{extra.sort.join(', ')}" unless extra.empty?

      out = { "cmd" => cmd.is_a?(String) ? cmd : cmd.to_a.map(&:to_s) }
      out["timeout_s"] = s["timeout_s"] unless s["timeout_s"].nil?
      out["env"] = s["env"].to_h.map { |k, v| [k.to_s, v.to_s] }.to_h if s["env"] && !s["env"].empty?
      out["files"] = encode_files(s["files"]) if files && s["files"] && !s["files"].empty?
      out
    end

    private

    def job_of(answer)
      return {} unless answer.is_a?(Hash)

      job = answer["job"].is_a?(Hash) ? answer["job"].dup : {}
      job["id"] ||= answer["job_id"] if answer["job_id"]
      job["run_id"] ||= answer["run_id"] if answer["run_id"]
      job
    end
  end

  # ---------------------------------------------------------------------------
  # Benchmarks

  # cloud.benchmarks: ready-made benchmarks (SWE-bench and the like). Create a
  # sandbox from an instance with template: "<benchmark>/<instance id>"; one
  # whose environment is still being built answers 409 template_building,
  # which the SDK waits out (Retry-After) within its retry policy.
  class CloudBenchmarks
    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudBenchmarks>"
    end

    def list
      r = @cloud.request("GET", "/v1/benchmarks")
      r.is_a?(Hash) ? (r["benchmarks"] || []) : []
    end

    def get(name)
      @cloud.request("GET", "/v1/benchmarks/#{Kosa8.enc(name)}")["benchmark"]
    end

    # One page of its instances: {"instances" => [...], "next_cursor" => ...}.
    # state: ready, building, queued, failed or not_built; limit: 1..1000.
    def instances(name, state: nil, limit: nil, cursor: nil)
      Cloud.check_range("limit", limit, 1, 1000) unless limit.nil?
      q = Cloud.query_string([["state", state], ["limit", limit], ["cursor", cursor]])
      @cloud.request("GET", "/v1/benchmarks/#{Kosa8.enc(name)}/instances#{q}")
    end

    # One instance: the solver's input and its environment's state and ETA.
    def instance(name, id)
      @cloud.request("GET", "/v1/benchmarks/#{Kosa8.enc(name)}/instances/#{Kosa8.enc(id)}")["instance"]
    end

    # Build environments ahead of use (at most 100 a call): +instances+ is
    # an Array of instance ids (or what the API takes for a sample, with seed:).
    def prepare(name, instances, seed: nil)
      body = { "instances" => instances }
      body["seed"] = Integer(seed) unless seed.nil?
      @cloud.request("POST", "/v1/benchmarks/#{Kosa8.enc(name)}/prepare", body)
    end
  end

  # ---------------------------------------------------------------------------
  # RL alerts

  # cloud.rl_alerts: alert rules on RL runs (reward drop, infra failure
  # rate, ...); list answers the kinds too.
  class CloudRlAlerts
    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudRlAlerts>"
    end

    # {"alerts" => [...], "kinds" => {...}}; run_id: one run's rules.
    def list(run_id: nil)
      @cloud.request("GET", "/v1/rl/alerts#{Cloud.query_string([['run_id', run_id]])}")
    end

    def create(kind:, threshold:, run_id: nil, window: nil)
      body = { "kind" => kind.to_s, "threshold" => threshold }
      body["run_id"] = run_id.to_s unless run_id.nil?
      body["window"] = window unless window.nil?
      @cloud.request("POST", "/v1/rl/alerts", body)["alert"]
    end

    # Change, pause (enabled: false) or resume a rule.
    def update(id, threshold: nil, window: nil, enabled: nil)
      body = {}
      body["threshold"] = threshold unless threshold.nil?
      body["window"] = window unless window.nil?
      body["enabled"] = enabled == true unless enabled.nil?
      raise ArgumentError, "give threshold:, window: or enabled:" if body.empty?

      @cloud.request("PATCH", "/v1/rl/alerts/#{Kosa8.enc(id)}", body)["alert"]
    end

    def delete(id)
      @cloud.request("DELETE", "/v1/rl/alerts/#{Kosa8.enc(id)}")
    end
  end

  # ---------------------------------------------------------------------------
  # Audit

  # cloud.audit: the org's tamper-evident audit log.
  class CloudAudit
    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudAudit>"
    end

    # One page, newest first: {"events" => [...], "next_before_seq" => n}.
    def list(sandbox_id: nil, actor: nil, action: nil, since: nil, until_ms: nil, before_seq: nil, limit: nil)
      q = Cloud.query_string([["sandbox_id", sandbox_id], ["actor", actor], ["action", action], ["since", since],
                              ["until", until_ms], ["before_seq", before_seq], ["limit", limit]])
      @cloud.request("GET", "/v1/audit#{q}")
    end

    # Every event matching, walking next_before_seq. Without a block, an Enumerator.
    def each(**filters)
      return enum_for(:each, **filters) unless block_given?

      before = nil
      loop do
        page = list(**filters, before_seq: before)
        (page["events"] || []).each { |e| yield e }
        nxt = page["next_before_seq"]
        break if nxt.nil? || nxt == before

        before = nxt
      end
      self
    end

    # Recompute the org's hash chain: "ok", "checked", "verified_at", ...
    def verify
      @cloud.request("GET", "/v1/audit/verify")
    end

    # Every event, oldest first, with its hashes (parsed from NDJSON).
    def export
      text = @cloud.request_bytes("GET", "/v1/audit/export", raw: true).force_encoding(Encoding::UTF_8)
      text.each_line.map(&:strip).reject(&:empty?).map { |l| JSON.parse(l) }
    end
  end

  # ---------------------------------------------------------------------------
  # API keys

  # cloud.api_keys: the org's API keys (a key with keys:manage). Secrets are
  # shown once, in the answer that made them.
  class CloudApiKeys
    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudApiKeys>"
    end

    def list
      r = @cloud.request("GET", "/v1/api-keys")
      r.is_a?(Hash) ? (r["api_keys"] || []) : []
    end

    # A new key ("secret" only here). scopes: nil for a full key.
    def create(name:, scopes: nil, expires_in_s: nil)
      body = { "name" => name.to_s }
      body["scopes"] = scopes.to_a.map(&:to_s) unless scopes.nil?
      body["expires_in_s"] = Integer(expires_in_s) unless expires_in_s.nil?
      @cloud.request("POST", "/v1/api-keys", body)["api_key"]
    end

    # Revoke a key; it stops at once.
    def revoke(id)
      @cloud.request("DELETE", "/v1/api-keys/#{Kosa8.enc(id)}")
    end
    alias delete revoke

    # A new key with the same name and scopes; the old one works grace_s more.
    def rotate(id, grace_s: nil)
      body = {}
      body["grace_s"] = Integer(grace_s) unless grace_s.nil?
      @cloud.request("POST", "/v1/api-keys/#{Kosa8.enc(id)}/rotate", body)["api_key"]
    end
  end

  # ---------------------------------------------------------------------------
  # Webhooks

  # cloud.webhooks: endpoints kosa8 Cloud POSTs events to, signed with the
  # endpoint's whsec_ secret (shown once, on create).
  class CloudWebhooks
    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudWebhooks>"
    end

    # {"webhooks" => [...], "events" => [the event names]}.
    def info
      r = @cloud.request("GET", "/v1/webhooks")
      r.is_a?(Hash) ? r : {}
    end

    def list
      info["webhooks"] || []
    end

    def create(url:, events: nil, description: nil)
      body = { "url" => url.to_s }
      body["events"] = events.to_a.map(&:to_s) unless events.nil?
      body["description"] = description.to_s unless description.nil?
      @cloud.request("POST", "/v1/webhooks", body)["webhook"]
    end

    # Stop sending, including retries.
    def delete(id)
      @cloud.request("DELETE", "/v1/webhooks/#{Kosa8.enc(id)}")
    end

    def deliveries(id, limit: nil)
      r = @cloud.request("GET", "/v1/webhooks/#{Kosa8.enc(id)}/deliveries#{Cloud.query_string([['limit', limit]])}")
      r.is_a?(Hash) ? (r["deliveries"] || []) : []
    end

    # Send a webhook.test event now; returns the delivery.
    def test(id)
      @cloud.request("POST", "/v1/webhooks/#{Kosa8.enc(id)}/test", {})["delivery"]
    end
  end

  # ---------------------------------------------------------------------------
  # Recordings, embeds, preview domains, Burst Passes

  # cloud.recordings: desktop recordings (MP4), made when a sandbox created
  # with record: true is deleted.
  class CloudRecordings
    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudRecordings>"
    end

    # Newest first: {"recordings" => [...], "configured" => bool,
    # "retention_days" => n}. sandbox_id: one sandbox's; limit: 1..200.
    def info(sandbox_id: nil, limit: nil)
      Cloud.check_range("limit", limit, 1, 200) unless limit.nil?
      r = @cloud.request("GET", "/v1/recordings#{Cloud.query_string([['sandbox_id', sandbox_id], ['limit', limit]])}")
      r.is_a?(Hash) ? r : {}
    end

    def list(sandbox_id: nil, limit: nil)
      info(sandbox_id: sandbox_id, limit: limit)["recordings"] || []
    end

    # A signed download URL for its MP4 ("url", "expires_at", "bytes");
    # ttl_s 60..86400 (default 900).
    def link(id, ttl_s: nil)
      body = {}
      body["ttl_s"] = Cloud.check_range("ttl_s", ttl_s, 60, 86_400) unless ttl_s.nil?
      @cloud.request("POST", "/v1/recordings/#{Kosa8.enc(id)}/link", body)["link"]
    end

    def delete(id)
      @cloud.request("DELETE", "/v1/recordings/#{Kosa8.enc(id)}")
      nil
    end
  end

  # sandbox.embeds: signed, expiring iframe URLs for its terminal or desktop.
  # The framed page posts {source: "kosa8", type} messages to the listed
  # origins: ready, exited, approval_requested, expired.
  class CloudEmbeds
    def initialize(cloud, sandbox)
      @cloud = cloud
      @sandbox = sandbox
    end

    def inspect
      "#<Kosa8::CloudEmbeds sandbox=#{@sandbox.id.inspect}>"
    end

    # origins: 1..10 (e.g. https://app.example.com); mode: "view" (default)
    # or "interact"; ui: "terminal" (default) or "desktop"; ttl_s 60..604800.
    # The answer's "url" is the credential: give it only to pages you trust.
    def create(origins:, mode: nil, ui: nil, ttl_s: nil, command: nil)
      list = origins.to_a.map(&:to_s)
      raise ArgumentError, "an embed takes 1 to 10 origins" unless list.size.between?(1, 10)

      body = { "origins" => list }
      body["mode"] = mode.to_s unless mode.nil?
      body["ui"] = ui.to_s unless ui.nil?
      body["ttl_s"] = Cloud.check_range("ttl_s", ttl_s, 60, 604_800) unless ttl_s.nil?
      body["command"] = command.to_a.map(&:to_s) unless command.nil?
      @cloud.request("POST", "/v1/sandboxes/#{Kosa8.enc(@sandbox.id)}/embed", body)["embed"]
    end

    # Its live embeds (no URLs).
    def list
      r = @cloud.request("GET", "/v1/sandboxes/#{Kosa8.enc(@sandbox.id)}/embeds")
      r.is_a?(Hash) ? (r["embeds"] || []) : []
    end

    # End an embed's URL before it expires.
    def revoke(embed_id)
      raise ArgumentError, "revoke needs an embed id (emb_...)" if embed_id.nil? || embed_id.to_s.empty?

      @cloud.request("DELETE", "/v1/sandboxes/#{Kosa8.enc(@sandbox.id)}/embeds/#{Kosa8.enc(embed_id)}")
      nil
    end
  end

  # A preview's custom domains (at most 5 a preview). The domain serves the
  # preview as it is and follows it across a rotate. 501 not_available
  # where custom hostnames are not configured.
  class CloudPreviewDomains
    # Give preview_id: (cloud.preview_domains), or sandbox_id: and port:
    # (box.previews.domains(port)).
    def initialize(cloud, preview_id: nil, sandbox_id: nil, port: nil)
      @cloud = cloud
      @preview_id = preview_id
      @sandbox_id = sandbox_id
      @port = port
    end

    def inspect
      "#<Kosa8::CloudPreviewDomains #{collection}>"
    end

    # {"domains" => [...], "configured" => bool, "cname_target" => host}.
    def info
      r = @cloud.request("GET", collection)
      r.is_a?(Hash) ? r : {}
    end

    def list
      info["domains"] || []
    end

    # Serve the preview at +hostname+; make the "records" it answers at your
    # DNS provider. ssl_method: "http" or "txt".
    def add(hostname, ssl_method: nil)
      body = { "hostname" => hostname.to_s }
      body["ssl_method"] = ssl_method.to_s unless ssl_method.nil?
      @cloud.request("POST", collection, body)["domain"]
    end

    # Its status, asked of the certificate provider again.
    def get(hostname)
      @cloud.request("GET", item(hostname))["domain"]
    end

    def remove(hostname)
      @cloud.request("DELETE", item(hostname))
      nil
    end

    private

    # "/v1/sandboxes/{id}/previews/{port}/domains" or "/v1/previews/{preview_id}/domains".
    def collection
      return "/v1/previews/#{Kosa8.enc(@preview_id)}/domains" if @preview_id

      "/v1/sandboxes/#{Kosa8.enc(@sandbox_id)}/previews/#{@port}/domains"
    end

    def item(hostname)
      raise ArgumentError, "a hostname is required" if hostname.nil? || hostname.to_s.empty?

      h = Kosa8.enc(hostname)
      return "/v1/previews/#{Kosa8.enc(@preview_id)}/domains/#{h}" if @preview_id

      "/v1/sandboxes/#{Kosa8.enc(@sandbox_id)}/previews/#{@port}/domains/#{h}"
    end
  end

  # cloud.burst: Burst Passes, each raising the running limit for its hours.
  class CloudBurst
    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudBurst>"
    end

    # "available", "pass", "held", "active", "adds_now".
    def get
      @cloud.request("GET", "/v1/billing/burst")
    end

    # Activate +quantity+ passes (an owner's admin key). Holding fewer, the
    # answer is a checkout "url" for the rest.
    def activate(quantity = 1)
      raise ArgumentError, "quantity must be a whole number of at least 1" unless quantity.is_a?(Integer) && quantity >= 1

      @cloud.request("POST", "/v1/billing/burst", { "quantity" => quantity })
    end
  end
end
