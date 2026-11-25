# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "json"
require "minitest/autorun"
require "kosa8"

# 0.6.0: browsers, AI gateway, jobs, benchmarks, RL alerts, audit, API keys,
# webhooks, recordings, embeds, preview domains, burst, org egress, small
# sizes, and retries on database_busy / template_building / 429.
class CloudMoreTest < Minitest::Test
  KEY = "k8c_live_testkey"
  BASE = "https://more.test"

  class Stub
    attr_reader :seen

    def initialize(&answer)
      @answer = answer
      @seen = []
    end

    def call(method, url, headers, body, _timeout)
      json = headers["Content-Type"] == "application/json"
      s = { method: method, path: url.sub(BASE, ""), headers: headers, body: json && body ? JSON.parse(body) : nil }
      @seen << s
      status, payload, resp_headers = @answer.call(s)
      out = if payload.nil? then ""
            elsif payload.is_a?(String) then payload
            else JSON.generate(payload)
            end
      [status, out, resp_headers]
    end
  end

  def setup
    @waits = []
  end

  def cloud(stub, **kw)
    Kosa8::Cloud.new(api_key: KEY, base_url: BASE, env: {}, transport: stub, sleeper: ->(s) { @waits << s }, **kw)
  end

  def box(c)
    Kosa8::CloudSandbox.new(c, { "id" => "sbx_1", "state" => "running" })
  end

  def ok_stub(answer = {})
    Stub.new { |_| [200, answer] }
  end

  def last(stub)
    s = stub.seen.last
    [s[:method], s[:path], s[:body]]
  end

  def test_version
    assert_equal "0.10.0", Kosa8::VERSION
  end

  # ---- retries ----

  def test_database_busy_post_is_retried_after_retry_after
    n = 0
    st = Stub.new do |_|
      n += 1
      next [200, { "webhook" => { "id" => "wh_1" } }] if n > 1

      [503, { "error" => "database_busy", "message" => "busy", "failure_class" => "infra", "retryable" => true,
              "retry_after" => 2 }]
    end
    wh = cloud(st).webhooks.create(url: "https://x.test/hook")
    assert_equal "wh_1", wh["id"]
    assert_equal 2, st.seen.size
    assert_operator @waits.first, :>=, 2.0
  end

  def test_database_busy_honours_retry_after_header_without_body_hint
    n = 0
    st = Stub.new do |_|
      n += 1
      next [200, { "ok" => true }] if n > 1

      [503, { "error" => "database_busy", "retryable" => true }, { "Retry-After" => "3" }]
    end
    cloud(st).request("POST", "/v1/limits/request", { "max_running" => 5 })
    assert_equal 2, st.seen.size
    assert_operator @waits.first, :>=, 3.0
  end

  def test_template_building_create_is_retried
    n = 0
    st = Stub.new do |_|
      n += 1
      if n == 1
        [409, { "error" => "template_building", "message" => "building", "eta_s" => 40, "retry_after_s" => 10,
                "failure_class" => "infra", "retryable" => true }, { "Retry-After" => "10" }]
      else
        [201, { "sandbox" => { "id" => "sbx_9", "state" => "running" } }]
      end
    end
    b = cloud(st).sandboxes.create(template: "swe-bench/django-1")
    assert_equal "sbx_9", b.id
    assert_equal 2, st.seen.size
    keys = st.seen.map { |s| s[:headers]["Idempotency-Key"] }
    assert_equal 1, keys.uniq.size, "the same Idempotency-Key on the retry"
    assert_operator @waits.first, :>=, 10.0
  end

  def test_template_building_is_retried_on_any_post_even_without_a_body_class
    n = 0
    st = Stub.new do |_|
      n += 1
      n == 1 ? [409, { "error" => "template_building" }] : [200, { "ok" => true }]
    end
    cloud(st).request("POST", "/v1/benchmarks/swe/prepare", { "instances" => ["a"] })
    assert_equal 2, st.seen.size
  end

  def test_rate_limited_post_is_retried
    n = 0
    st = Stub.new do |_|
      n += 1
      n == 1 ? [429, { "error" => "rate_limited" }, { "Retry-After" => "1" }] : [200, { "delivery" => { "id" => "d" } }]
    end
    assert_equal "d", cloud(st).webhooks.test("wh_1")["id"]
    assert_equal 2, st.seen.size
  end

  def test_retries_are_bounded
    st = Stub.new { |_| [503, { "error" => "database_busy", "retryable" => true, "retry_after" => 1 }] }
    assert_raises(Kosa8::ApiError) { cloud(st).limits }
    assert_equal 3, st.seen.size
    assert_equal 2, @waits.size
  end

  def test_retry_after_is_capped
    st = Stub.new { |_| [503, { "error" => "database_busy", "retryable" => true, "retry_after" => 9999 }] }
    assert_raises(Kosa8::ApiError) { cloud(st).pricing }
    assert(@waits.all? { |w| w <= 60.0 })
  end

  def test_a_plain_500_on_a_post_is_not_retried
    st = Stub.new { |_| [500, { "error" => "internal" }] }
    assert_raises(Kosa8::ApiError) { cloud(st).webhooks.create(url: "https://x.test") }
    assert_equal 1, st.seen.size
  end

  def test_retryable_false_is_never_retried
    st = Stub.new { |_| [503, { "error" => "no_capacity", "failure_class" => "infra", "retryable" => false }] }
    assert_raises(Kosa8::ApiError) { cloud(st).limits }
    assert_equal 1, st.seen.size
  end

  def test_quota_exceeded_429_is_not_retried
    st = Stub.new { |_| [429, { "error" => "quota_exceeded" }] }
    assert_raises(Kosa8::RateLimitError) { cloud(st).limits }
    assert_equal 1, st.seen.size
  end

  def test_retry_policy_none_turns_retries_off
    st = Stub.new { |_| [503, { "error" => "database_busy", "retryable" => true }] }
    assert_raises(Kosa8::ApiError) { cloud(st, retry_policy: Kosa8::RetryPolicy::NONE).limits }
    assert_equal 1, st.seen.size
  end

  def test_failure_of_follows_the_server
    assert_equal ["infra", true], Kosa8.failure_of(503, "database_busy")
    assert_equal ["infra", true], Kosa8.failure_of(409, "template_building")
    assert_equal ["client", false], Kosa8.failure_of(400, "invalid_timeout")
  end

  def test_overflow_refusal_is_unsupported_and_not_retried
    msg = "Fork is not available for this sandbox: it runs on kosa8's overflow capacity (Cloudflare), which has no fork"
    st = Stub.new { |_| [501, { "error" => "not_available", "message" => msg, "failure_class" => "infra", "retryable" => false }] }
    e = assert_raises(Kosa8::UnsupportedError) { box(cloud(st)).fork(2) }
    assert_includes e.message, "overflow capacity"
    assert_equal "not_available", e.code
    assert_equal 1, st.seen.size
  end

  def test_jobs_and_rollouts_carry_an_idempotency_key
    assert Kosa8::Cloud.keyed?("POST", "/v1/jobs")
    assert Kosa8::Cloud.keyed?("POST", "/v1/rl/runs/run_1/rollouts")
    refute Kosa8::Cloud.keyed?("POST", "/v1/jobs/estimate")
    refute Kosa8::Cloud.keyed?("POST", "/v1/webhooks")
  end

  # ---- sizes ----

  def test_small_sizes
    st = Stub.new { |_| [201, { "sandbox" => { "id" => "sbx_s", "state" => "running" } }] }
    c = cloud(st)
    c.sandboxes.create(cpus: 0.25, mem_mb: 512)
    assert_equal({ "cpus" => 0.25, "mem_mb" => 512 }, st.seen.last[:body])
    c.sandboxes.create(size: "0.5x1")
    assert_equal({ "size" => "0.5x1" }, st.seen.last[:body])
    c.sandboxes.create(cpus: 2, mem_mb: 4096)
    assert_equal 2, st.seen.last[:body]["cpus"]
    assert_kind_of Integer, st.seen.last[:body]["cpus"]
    assert_raises(ArgumentError) { c.sandboxes.create(size: "3x6") }
    assert_raises(ArgumentError) { c.sandboxes.create(cpus: 0, mem_mb: 512) }
    assert_includes Kosa8::Cloud::SANDBOX_SIZES, "0.25x0.5"
  end

  def test_record_and_ai_gateway_on_create
    st = Stub.new { |_| [201, { "sandbox" => { "id" => "sbx_r", "state" => "running" } }] }
    cloud(st).sandboxes.create(template: "base", record: true, ai_gateway: true)
    assert_equal({ "template" => "base", "record" => true, "ai_gateway" => true }, st.seen.last[:body])
  end

  # ---- browsers ----

  def test_browsers
    info = { "id" => "brw_1", "state" => "open", "cdp_url" => "wss://api/v1/browsers/brw_1/cdp?token=t" }
    st = Stub.new do |s|
      case [s[:method], s[:path]]
      when ["POST", "/v1/browsers"] then [201, { "browser" => info }]
      when ["GET", "/v1/browsers?state=all"] then [200, { "browsers" => [info.reject { |k, _| k == "cdp_url" }], "enabled" => true }]
      when ["GET", "/v1/browsers/brw_1"] then [200, { "browser" => info }]
      when ["POST", "/v1/browsers/brw_1/page"]
        [200, { "page" => { "url" => "https://e.test", "title" => "E", "screenshot_png_base64" => ["PNG"].pack("m0") } }]
      when ["DELETE", "/v1/browsers/brw_1"] then [200, { "ok" => true, "id" => "brw_1" }]
      else [404, { "error" => "not_found" }]
      end
    end
    c = cloud(st)
    b = c.browsers.create(ttl_s: 60, name: "t")
    assert_equal({ "ttl_s" => 60, "name" => "t" }, st.seen.last[:body])
    assert_equal "wss://api/v1/browsers/brw_1/cdp?token=t", b.cdp_url
    assert_equal "/v1/browsers/brw_1/cdp", b.cdp_path
    refute_includes b.inspect, "token"
    assert_nil c.browsers.list(state: "all").first.cdp_url
    assert_equal "brw_1", c.browsers.get("brw_1").id
    assert_equal "PNG", b.screenshot("https://e.test")
    assert_equal({ "url" => "https://e.test", "screenshot" => true }, st.seen.last[:body])
    b.close
    assert_equal "closed", b.state
    assert_nil b.cdp_url
    assert_raises(ArgumentError) { c.browsers.create(ttl_s: 5) }
    r = c.browser(ttl_s: 60) { |x| x.id }
    assert_equal "brw_1", r
    assert_equal "DELETE", st.seen.last[:method]
  end

  # ---- AI gateway ----

  def test_ai_gateway
    st = ok_stub("keys" => [{ "provider" => "openai", "hint" => "abcd" }])
    c = cloud(st)
    assert_equal "openai", c.ai.keys.first["provider"]
    assert_equal ["GET", "/v1/ai/keys", nil], last(st)
    c.ai.set_key("openai", "sk-1")
    assert_equal ["PUT", "/v1/ai/keys/openai", { "key" => "sk-1" }], last(st)
    c.ai.delete_key("anthropic")
    assert_equal ["DELETE", "/v1/ai/keys/anthropic", nil], last(st)
    c.ai.settings
    assert_equal ["GET", "/v1/ai/settings", nil], last(st)
    c.ai.update_settings(enabled: true, rate_per_min: 60)
    assert_equal ["PATCH", "/v1/ai/settings", { "enabled" => true, "rate_per_min" => 60 }], last(st)
    c.ai.usage("2026-11")
    assert_equal ["GET", "/v1/ai/usage?month=2026-11", nil], last(st)
    assert_raises(ArgumentError) { c.ai.usage("2026-13") }
    assert_equal "https://more.test/v1/ai/gw/anthropic", c.ai.gateway_url("anthropic")
    c.ai.call("openai", "/chat/completions", { "model" => "gpt" })
    assert_equal ["POST", "/v1/ai/gw/openai/chat/completions", { "model" => "gpt" }], last(st)
    assert_raises(ArgumentError) { c.ai.gateway_url("../x") }
  end

  # ---- jobs ----

  def job_opts
    { name: "eval", tasks: [{ id: 1, input: { "q" => 1 }, files: { "/w/a.txt" => "hi" } }], solver: "python solve.py",
      grader: { cmd: ["python", "grade.py"], timeout_s: 30 }, template: "python", solver_timeout_s: 60 }
  end

  def test_jobs
    st = Stub.new do |s|
      case [s[:method], s[:path].split("?")[0]]
      when ["POST", "/v1/jobs"] then [201, { "job" => { "status" => "queued" }, "job_id" => "job_1", "run_id" => "run_1" }]
      when ["GET", "/v1/jobs/job_1"] then [200, { "job" => { "id" => "job_1", "status" => "done" } }]
      when ["GET", "/v1/jobs"] then [200, { "jobs" => [{ "id" => "job_1" }] }]
      when ["POST", "/v1/jobs/job_1/cancel"] then [200, { "job" => { "id" => "job_1", "status" => "cancelled" } }]
      when ["POST", "/v1/jobs/estimate"] then [200, { "usd_list" => { "low" => 1, "high" => 2 } }]
      else [404, {}]
      end
    end
    c = cloud(st)
    j = c.jobs.submit(**job_opts)
    assert_equal "job_1", j["id"]
    assert_equal "run_1", j["run_id"]
    body = st.seen.last[:body]
    assert_equal({ "id" => "1", "input" => { "q" => 1 }, "files" => { "/w/a.txt" => "aGk=" } }, body["tasks"].first)
    assert_equal({ "cmd" => "python solve.py", "timeout_s" => 60 }, body["solver"])
    assert_equal({ "cmd" => %w[python grade.py], "timeout_s" => 30 }, body["grader"])
    assert_equal "python", body["template"]
    refute_nil st.seen.last[:headers]["Idempotency-Key"]
    assert_equal "done", c.jobs.wait("job_1")["status"]
    assert_equal 1, c.jobs.list(status: "running", limit: 5).size
    assert_equal "/v1/jobs?status=running&limit=5", st.seen.last[:path]
    assert_equal "cancelled", c.jobs.cancel("job_1")["status"]
    c.jobs.estimate(sample: 3, **job_opts)
    assert_equal 3, st.seen.last[:body]["sample"]
    assert_raises(ArgumentError) { c.jobs.submit(**job_opts.merge(image: "x")) }
    assert_raises(ArgumentError) { c.jobs.submit(**job_opts.merge(solver_timeout_s: nil)) }
    tasks = Kosa8::CloudJobs.load_tasks(%({"id":"a"}\n\n{"id":"b","files":{"/x":"eA=="}}\n))
    assert_equal [{ "id" => "a" }, { "id" => "b", "files" => { "/x" => "eA==" } }], tasks
    assert_raises(ArgumentError) { Kosa8::CloudJobs.load_tasks([{ id: "a" }, { id: "a" }]) }
  end

  # ---- org-level reads ----

  def test_org_reads
    st = ok_stub("egress" => { "default" => { "internet" => false }, "enforce" => true })
    c = cloud(st)
    { usage_insights: "/v1/usage/insights", pricing: "/v1/pricing", limits: "/v1/limits", lineage: "/v1/lineage",
      checkpoints: "/v1/checkpoints", images: "/v1/images", usage: "/v1/usage" }.each do |m, p|
      c.public_send(m)
      assert_equal ["GET", p, nil], last(st)
    end
    assert_equal true, c.org_egress["enforce"]
    c.set_org_egress({ internet: false, allow: ["pypi.org"] }, enforce: true)
    assert_equal ["PUT", "/v1/org/egress",
                  { "default" => { "internet" => false, "allow" => ["pypi.org"], "deny" => [], "presets" => [] },
                    "enforce" => true }], last(st)
    c.set_org_egress(nil)
    assert_equal({ "default" => nil }, st.seen.last[:body])
    c.request_limit(10, reason: "evals")
    assert_equal ["POST", "/v1/limits/request", { "max_running" => 10, "reason" => "evals" }], last(st)
    c.rl_compare("run_a", "run_b")
    assert_equal "/v1/rl/compare?ids=run_a%2Crun_b", st.seen.last[:path]
    assert_raises(ArgumentError) { c.rl_compare("run_a") }
    c.functions.invocations("hello", limit: 5)
    assert_equal ["GET", "/v1/functions/hello/invocations?limit=5", nil], last(st)
    c.burst.get
    assert_equal ["GET", "/v1/billing/burst", nil], last(st)
    c.burst.activate(2)
    assert_equal ["POST", "/v1/billing/burst", { "quantity" => 2 }], last(st)
  end

  # ---- benchmarks, alerts, audit, keys, webhooks ----

  def test_benchmarks
    st = ok_stub("benchmarks" => [{ "name" => "swe" }], "benchmark" => { "name" => "swe" }, "instance" => { "id" => "i" })
    c = cloud(st)
    assert_equal "swe", c.benchmarks.list.first["name"]
    assert_equal "swe", c.benchmarks.get("swe")["name"]
    assert_equal ["GET", "/v1/benchmarks/swe", nil], last(st)
    c.benchmarks.instances("swe", state: "ready", limit: 10)
    assert_equal "/v1/benchmarks/swe/instances?state=ready&limit=10", st.seen.last[:path]
    c.benchmarks.instance("swe", "django__1")
    assert_equal "/v1/benchmarks/swe/instances/django__1", st.seen.last[:path]
    c.benchmarks.prepare("swe", %w[a b], seed: 1)
    assert_equal ["POST", "/v1/benchmarks/swe/prepare", { "instances" => %w[a b], "seed" => 1 }], last(st)
  end

  def test_rl_alerts
    st = ok_stub("alert" => { "id" => "rla_1" })
    c = cloud(st)
    c.rl_alerts.list(run_id: "run_1")
    assert_equal "/v1/rl/alerts?run_id=run_1", st.seen.last[:path]
    c.rl_alerts.create(kind: "reward_drop", threshold: 0.2, run_id: "run_1")
    assert_equal ["POST", "/v1/rl/alerts", { "kind" => "reward_drop", "threshold" => 0.2, "run_id" => "run_1" }], last(st)
    c.rl_alerts.update("rla_1", enabled: false)
    assert_equal ["PATCH", "/v1/rl/alerts/rla_1", { "enabled" => false }], last(st)
    c.rl_alerts.delete("rla_1")
    assert_equal ["DELETE", "/v1/rl/alerts/rla_1", nil], last(st)
  end

  def test_audit
    pages = { nil => { "events" => [{ "seq" => 3 }, { "seq" => 2 }], "next_before_seq" => 2 },
              "2" => { "events" => [{ "seq" => 1 }], "next_before_seq" => nil } }
    st = Stub.new do |s|
      if s[:path].start_with?("/v1/audit/export")
        [200, %({"seq":1}\n{"seq":2}\n)]
      elsif s[:path].start_with?("/v1/audit/verify")
        [200, { "ok" => true }]
      else
        [200, pages[s[:path][/before_seq=(\d+)/, 1]]]
      end
    end
    c = cloud(st)
    assert_equal [3, 2, 1], c.audit.each(action: "sandbox.create").map { |e| e["seq"] }
    assert_equal "/v1/audit?action=sandbox.create&before_seq=2", st.seen.last[:path]
    assert_equal true, c.audit.verify["ok"]
    assert_equal [1, 2], c.audit.export.map { |e| e["seq"] }
  end

  def test_api_keys
    st = ok_stub("api_keys" => [{ "id" => "key_1" }], "api_key" => { "id" => "key_2", "secret" => "k8c_live_s" })
    c = cloud(st)
    assert_equal "key_1", c.api_keys.list.first["id"]
    c.api_keys.create(name: "ci", scopes: ["sandboxes:read"], expires_in_s: 3600)
    assert_equal ["POST", "/v1/api-keys", { "name" => "ci", "scopes" => ["sandboxes:read"], "expires_in_s" => 3600 }],
                 last(st)
    c.api_keys.rotate("key_1", grace_s: 60)
    assert_equal ["POST", "/v1/api-keys/key_1/rotate", { "grace_s" => 60 }], last(st)
    c.api_keys.revoke("key_1")
    assert_equal ["DELETE", "/v1/api-keys/key_1", nil], last(st)
  end

  def test_webhooks
    st = ok_stub("webhooks" => [{ "id" => "wh_1" }], "deliveries" => [{ "id" => "d" }])
    c = cloud(st)
    assert_equal "wh_1", c.webhooks.list.first["id"]
    c.webhooks.create(url: "https://x.test/h", events: ["sandbox.deleted"], description: "d")
    assert_equal ["POST", "/v1/webhooks", { "url" => "https://x.test/h", "events" => ["sandbox.deleted"],
                                            "description" => "d" }], last(st)
    assert_equal 1, c.webhooks.deliveries("wh_1", limit: 3).size
    assert_equal "/v1/webhooks/wh_1/deliveries?limit=3", st.seen.last[:path]
    c.webhooks.test("wh_1")
    assert_equal ["POST", "/v1/webhooks/wh_1/test", {}], last(st)
    c.webhooks.delete("wh_1")
    assert_equal ["DELETE", "/v1/webhooks/wh_1", nil], last(st)
  end

  # ---- per sandbox ----

  def test_sandbox_extras
    st = ok_stub("recordings" => [{ "id" => "rec_1" }], "embeds" => [], "embed" => { "id" => "emb_1", "url" => "u" },
                 "exec" => { "id" => "bg_1", "state" => "exited" }, "domain" => { "hostname" => "a.example.com" },
                 "link" => { "url" => "https://dl" })
    c = cloud(st)
    b = box(c)
    assert_equal "rec_1", b.recordings.first["id"]
    assert_equal ["GET", "/v1/sandboxes/sbx_1/recordings", nil], last(st)
    b.embeds.create(origins: ["https://app.test"], mode: "view", ttl_s: 600)
    assert_equal ["POST", "/v1/sandboxes/sbx_1/embed", { "origins" => ["https://app.test"], "mode" => "view",
                                                          "ttl_s" => 600 }], last(st)
    b.embeds.list
    assert_equal ["GET", "/v1/sandboxes/sbx_1/embeds", nil], last(st)
    b.embeds.revoke("emb_1")
    assert_equal ["DELETE", "/v1/sandboxes/sbx_1/embeds/emb_1", nil], last(st)
    assert_raises(ArgumentError) { b.embeds.create(origins: []) }
    assert_equal "exited", b.stop_background("bg_1")["state"]
    assert_equal ["POST", "/v1/sandboxes/sbx_1/exec/bg_1/stop", {}], last(st)
    b.background_exec("bg_1")
    assert_equal ["GET", "/v1/sandboxes/sbx_1/exec/bg_1", nil], last(st)
    d = b.previews.domains(3000)
    d.add("a.example.com", ssl_method: "txt")
    assert_equal ["POST", "/v1/sandboxes/sbx_1/previews/3000/domains", { "hostname" => "a.example.com",
                                                                         "ssl_method" => "txt" }], last(st)
    d.get("a.example.com")
    assert_equal ["GET", "/v1/sandboxes/sbx_1/previews/3000/domains/a.example.com", nil], last(st)
    d.remove("a.example.com")
    assert_equal "DELETE", st.seen.last[:method]
    pd = c.preview_domains("sbx_1:3000")
    pd.list
    assert_equal ["GET", "/v1/previews/sbx_1%3A3000/domains", nil], last(st)
    pd.get("a.example.com")
    assert_equal "/v1/previews/sbx_1%3A3000/domains/a.example.com", st.seen.last[:path]
    b.previews.delete(3000)
    assert_equal ["DELETE", "/v1/sandboxes/sbx_1/previews/3000", nil], last(st)
    b.schedules.delete("sch_1")
    assert_equal ["DELETE", "/v1/sandboxes/sbx_1/schedules/sch_1", nil], last(st)
    b.delete_code_context("default")
    assert_equal ["DELETE", "/v1/sandboxes/sbx_1/code/contexts/default", nil], last(st)
  end

  def test_recordings
    st = ok_stub("recordings" => [{ "id" => "rec_1" }], "configured" => true, "link" => { "url" => "https://dl" })
    c = cloud(st)
    assert_equal "rec_1", c.recordings.list(sandbox_id: "sbx_1", limit: 5).first["id"]
    assert_equal "/v1/recordings?sandbox_id=sbx_1&limit=5", st.seen.last[:path]
    assert_equal "https://dl", c.recordings.link("rec_1", ttl_s: 120)["url"]
    assert_equal ["POST", "/v1/recordings/rec_1/link", { "ttl_s" => 120 }], last(st)
    c.recordings.delete("rec_1")
    assert_equal ["DELETE", "/v1/recordings/rec_1", nil], last(st)
  end

  def test_pipeline_artifact_and_scorecards
    st = Stub.new { |s| s[:path].include?("/artifacts/") ? [200, "TARGZ"] : [200, { "scorecards" => [], "scorecard" => { "id" => "sc" } }] }
    c = cloud(st)
    assert_equal "TARGZ", c.pipelines.download_artifact("run_1", "build", 0)
    assert_equal "/v1/pipelines/runs/run_1/artifacts/build/0", st.seen.last[:path]
    assert_equal [], c.attack_scorecards
    assert_equal "sc", c.upload_attack_scorecard('{"a":1}')["id"]
    assert_equal({ "signed" => { "a" => 1 } }, st.seen.last[:body])
    assert_raises(ArgumentError) { c.upload_attack_scorecard("not json") }
  end
end
