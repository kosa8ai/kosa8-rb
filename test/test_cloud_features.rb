# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "json"
require "minitest/autorun"
require "stringio"
require "kosa8"

# kosa8 Cloud features: sized/Docker creates, env, background exec,
# snapshots, previews, terminal, raw files and links, egress, secrets,
# schedules, code interpreter, metrics, logs, labels and Pipelines.
class CloudFeaturesTest < Minitest::Test
  KEY = "k8c_live_testkey"
  BASE = "https://cp.test"

  class Stub
    attr_reader :seen

    def initialize(&answer)
      @answer = answer
      @seen = []
    end

    def call(method, url, headers, body, _timeout)
      json = headers["Content-Type"] == "application/json"
      s = { method: method, path: url.sub(BASE, ""), headers: headers,
            body: json && body ? JSON.parse(body) : nil, raw: body }
      @seen << s
      status, payload = @answer.call(s)
      [status, payload.is_a?(String) ? payload : JSON.generate(payload), {}]
    end

    def last
      @seen[-1]
    end
  end

  def cloud(stub)
    Kosa8::Cloud.new(api_key: KEY, base_url: BASE, env: {}, transport: stub)
  end

  def box(stub)
    Kosa8::CloudSandbox.new(cloud(stub), { "id" => "sbx_1", "state" => "running" })
  end

  def test_user_agent_is_explicit
    stub = Stub.new { [200, {}] }
    cloud(stub).me
    # api.kosa8.com's edge refuses some default library user agents.
    assert_equal "kosa8-ruby/#{Kosa8::VERSION}", stub.last[:headers]["User-Agent"]
  end

  def test_sized_create_sends_everything_and_waits
    gets = 0
    stub = Stub.new do |r|
      if r[:method] == "POST"
        [202, { "sandbox" => { "id" => "sbx_9", "state" => "creating" } }]
      else
        gets += 1
        [200, { "sandbox" => { "id" => "sbx_9", "state" => gets > 1 ? "running" : "creating" } }]
      end
    end
    b = cloud(stub).sandboxes.create(size: "4x8", image: "kosa8-template/universal-24.04-20261115.2", disk_gb: 64,
                                     docker: true, persistent: true, cpu: "dedicated", region: "us", name: "web",
                                     labels: { team: "a" }, env: { "GREETING" => "hi" }, secrets: ["openai"],
                                     egress: { allow: ["pypi.org"] }, ttl_s: 3600, poll_interval: 0)
    assert_equal "running", b.state
    assert_equal 2, gets
    assert_equal({ "size" => "4x8", "image" => "kosa8-template/universal-24.04-20261115.2", "disk_gb" => 64,
                   "docker" => true, "persistent" => true, "cpu" => "dedicated", "region" => "us", "name" => "web",
                   "labels" => { "team" => "a" }, "env" => { "GREETING" => "hi" }, "secrets" => ["openai"],
                   "egress" => { "internet" => false, "allow" => ["pypi.org"], "deny" => [], "presets" => [] },
                   "ttl_s" => 3600 }, stub.seen[0][:body])
  end

  def test_create_wait_false_and_failed_boot
    stub = Stub.new do |r|
      if r[:method] == "POST"
        [202, { "sandbox" => { "id" => "sbx_9", "state" => "creating" } }]
      else
        [200, { "sandbox" => { "id" => "sbx_9", "state" => "error", "last_error" => "no image" } }]
      end
    end
    b = cloud(stub).sandboxes.create(cpus: 2, mem_mb: 4096, wait: false)
    assert_equal "creating", b.state
    e = assert_raises(Kosa8::Error) { b.wait_running(poll_interval: 0) }
    assert_match(/no image/, e.message)
  end

  def test_create_validation
    stub = Stub.new { flunk "no request expected" }
    c = cloud(stub)
    [{ size: "3x5" }, { cpus: 2 }, { size: "2x4", cpus: 2, mem_mb: 4096 }, { disk_gb: 4 }, { cpu: "fast" },
     { name: "-x" }, { env: { "1X" => "y" } }, { env: { "X" => "a" * 8193 } }, { labels: { "bad key" => "v" } },
     { snapshot: "sbx_1" }, { snapshot: "snap_abcdefgh", size: "2x4" }, { secrets: ["Bad_Name"] }].each do |kw|
      assert_raises(ArgumentError, kw.inspect) { c.sandboxes.create(**kw) }
    end
  end

  def test_create_from_snapshot_and_list_filters
    stub = Stub.new { |r| r[:method] == "POST" ? [201, { "sandbox" => { "id" => "sbx_3", "state" => "running" } }] : [200, { "sandboxes" => [] }] }
    c = cloud(stub)
    c.sandboxes.create(snapshot: "snap_abcdefgh", env: { A: 1 }, name: "copy")
    assert_equal({ "snapshot" => "snap_abcdefgh", "env" => { "A" => "1" }, "name" => "copy" }, stub.last[:body])
    c.sandboxes.list(name: "web", labels: { "team" => "a", "ci" => nil })
    assert_equal "/v1/sandboxes?name=web&label=ci&label=team%3Da", stub.last[:path]
    c.sandboxes.list
    assert_equal "/v1/sandboxes", stub.last[:path]
  end

  def test_background_exec
    polls = 0
    stub = Stub.new do |r|
      if r[:method] == "POST"
        [202, { "exec" => { "id" => "bg_0123456789abcdef", "state" => "running" } }]
      else
        polls += 1
        [200, { "exec" => polls > 1 ? { "id" => "bg_0123456789abcdef", "state" => "exited", "exit" => 0, "output" => "ab" } : { "state" => "running" } }]
      end
    end
    b = box(stub)
    e = b.exec_background(%w[sleep 60], env: { "B" => "2", "A" => "1" })
    assert_equal "bg_0123456789abcdef", e["id"]
    assert_equal({ "cmd" => %w[sleep 60], "background" => true, "env" => ["A=1", "B=2"] }, stub.last[:body])
    done = b.wait_background(e, poll_interval: 0)
    assert_equal 0, done["exit"]
    assert_equal "/v1/sandboxes/sbx_1/exec/bg_0123456789abcdef", stub.last[:path]
    assert_raises(ArgumentError) { b.exec_background([]) }
  end

  def test_snapshots
    snap = { "id" => "snap_abcdefgh", "state" => "ready" }
    stub = Stub.new do |r|
      case r[:method]
      when "POST" then [201, { "snapshot" => snap }]
      when "DELETE" then [200, { "ok" => true }]
      else r[:path].start_with?("/v1/snapshots/") ? [200, { "snapshot" => snap }] : [200, { "snapshots" => [snap] }]
      end
    end
    assert_equal "snap_abcdefgh", box(stub).snapshot("warm")["id"]
    assert_equal({ "name" => "warm" }, stub.last[:body])
    assert_equal "/v1/sandboxes/sbx_1/snapshots", stub.last[:path]
    c = cloud(stub)
    assert_equal 1, c.snapshots.list(sandbox_id: "sbx_1").size
    assert_equal "/v1/snapshots?sandbox_id=sbx_1", stub.last[:path]
    assert_equal "ready", c.snapshots.get("snap_abcdefgh")["state"]
    assert_nil c.snapshots.delete("snap_abcdefgh")
    assert_equal "DELETE", stub.last[:method]
  end

  def test_previews
    pv = { "port" => 3000, "url" => "https://p.kosa8labs.com/?t=x" }
    stub = Stub.new do |r|
      case r[:method]
      when "GET" then [200, { "previews" => [pv] }]
      when "DELETE" then [200, { "deleted" => true }]
      else [200, { "preview" => pv }]
      end
    end
    p = box(stub).previews
    assert_match(/kosa8labs/, p.create(3000, expires_in_s: 600, wake: true)["url"])
    assert_equal({ "port" => 3000, "expires_in_s" => 600, "wake" => true }, stub.last[:body])
    assert_equal 1, p.list.size
    p.link(3000, expires_in_s: 60)
    assert_equal "/v1/sandboxes/sbx_1/previews/3000/link", stub.last[:path]
    p.rotate(3000)
    assert_equal "/v1/sandboxes/sbx_1/previews/3000/rotate", stub.last[:path]
    p.delete(3000)
    assert_equal "/v1/sandboxes/sbx_1/previews/3000", stub.last[:path]
    assert_raises(ArgumentError) { p.create(0) }
  end

  def test_terminal_files_raw_and_link
    stub = Stub.new do |r|
      if r[:path].end_with?("/terminal") then [200, { "terminal" => { "url" => "wss://h/t" } }]
      elsif r[:path].end_with?("/files/link") then [200, { "link" => { "url" => "https://h/f", "method" => "PUT" } }]
      elsif r[:method] == "GET" then [200, "big file"]
      else [200, { "file" => { "size" => r[:raw].bytesize } }]
      end
    end
    b = box(stub)
    assert_equal "wss://h/t", b.terminal(cols: 80, rows: 24, command: ["bash"])["url"]
    assert_equal({ "cols" => 80, "rows" => 24, "command" => ["bash"] }, stub.last[:body])
    assert_equal "PUT", b.files.link("/workspace/a", method: "put", ttl_s: 120)["method"]
    assert_equal({ "path" => "/workspace/a", "method" => "PUT", "ttl_s" => 120 }, stub.last[:body])
    assert_raises(ArgumentError) { b.files.link("/a", method: "POST") }
    assert_equal "big file", b.files.download("/workspace/a")
    assert_equal "/v1/sandboxes/sbx_1/files/raw?path=%2Fworkspace%2Fa", stub.last[:path]
    assert_equal 5, b.files.upload("/workspace/a", StringIO.new("hello"))["size"]
    assert_equal "application/octet-stream", stub.last[:headers]["Content-Type"]
  end

  def test_egress
    stub = Stub.new do |r|
      r[:path].end_with?("/presets") ? [200, { "presets" => { "pypi" => ["pypi.org"] } }] : [200, { "egress" => { "source" => "sandbox" } }]
    end
    b = box(stub)
    assert_equal "sandbox", b.set_egress(presets: ["pypi"], allow: ["github.com"])["source"]
    assert_equal({ "internet" => false, "allow" => ["github.com"], "deny" => [], "presets" => ["pypi"] }, stub.last[:body])
    b.egress
    assert_equal "GET", stub.last[:method]
    b.reset_egress
    assert_equal "DELETE", stub.last[:method]
    assert_equal ["pypi.org"], cloud(stub).egress_presets["pypi"]
  end

  def test_secrets
    stub = Stub.new do |r|
      case r[:method]
      when "PUT" then [201, { "secret" => { "name" => "npm-token", "pipelines" => true } }]
      when "DELETE" then [200, { "still_held_by" => ["sbx_1"] }]
      else r[:path].include?("sandboxes") ? [200, { "secrets" => ["npm-token"] }] : [200, { "secrets" => [{ "name" => "npm-token" }] }]
      end
    end
    c = cloud(stub)
    assert c.secrets.set("npm-token", value: "s3cr3t", upstream: "https://registry.npmjs.org", pipelines: true)["pipelines"]
    assert_equal({ "value" => "s3cr3t", "upstream" => "https://registry.npmjs.org", "pipelines" => true }, stub.last[:body])
    assert_equal 1, c.secrets.list.size
    assert_equal ["sbx_1"], c.secrets.delete("npm-token")
    assert_equal ["npm-token"], box(stub).secrets
    assert_raises(ArgumentError) { c.secrets.set("Bad Name", value: "x") }
    assert_raises(ArgumentError) { c.secrets.set("ok", value: "") }
  end

  def test_schedules
    stub = Stub.new do |r|
      if r[:method] == "DELETE" then [200, { "deleted" => true }]
      elsif r[:path].end_with?("/run") then [200, { "run" => { "status" => "ok", "output" => "hi" } }]
      elsif r[:method] == "POST" then [201, { "schedule" => { "id" => "sch_1" } }]
      else [200, { "schedules" => [{ "id" => "sch_1" }] }]
      end
    end
    s = box(stub).schedules
    assert_equal "sch_1", s.create(cron: "0 * * * *", cmd: %w[echo hi], env: { "A" => "1" }, name: "hourly", wake: true)["id"]
    assert_equal({ "cron" => "0 * * * *", "cmd" => %w[echo hi], "env" => ["A=1"], "name" => "hourly", "wake" => true }, stub.last[:body])
    assert_equal 1, s.list.size
    assert_equal "hi", s.run("sch_1")["output"]
    assert_nil s.delete("sch_1")
    assert_raises(ArgumentError) { s.create(cron: "* * * * *", cmd: []) }
  end

  def test_code_interpreter
    stub = Stub.new do |r|
      if r[:path].end_with?("/code") then [200, { "stdout" => "42\n", "results" => [{ "type" => "image/png" }] }]
      elsif r[:path].end_with?("/reset") then [200, { "reset" => "a" }]
      elsif r[:method] == "DELETE" then [200, { "deleted" => "a" }]
      elsif r[:method] == "POST" then [201, { "context" => { "name" => "a" } }]
      else [200, { "contexts" => [{ "name" => "a" }] }]
      end
    end
    b = box(stub)
    assert_equal "42\n", b.run_code("print(42)", context: "a", timeout_s: 10)["stdout"]
    assert_equal({ "code" => "print(42)", "language" => "python", "context" => "a", "timeout_s" => 10 }, stub.last[:body])
    assert_equal "a", b.create_code_context("a")["name"]
    assert_equal 1, b.code_contexts.size
    b.reset_code_context("a")
    assert_equal "/v1/sandboxes/sbx_1/code/contexts/a/reset", stub.last[:path]
    b.delete_code_context("a")
    assert_equal "DELETE", stub.last[:method]
    assert_raises(ArgumentError) { b.run_code("") }
  end

  def test_metrics_logs_labels_capabilities
    stub = Stub.new do |r|
      if r[:path].end_with?("/metrics") then [200, { "metrics" => { "cpu_pct" => 12.5 } }]
      elsif r[:path].include?("/logs") then [200, { "entries" => [{ "stdout_tail" => "a" }] }]
      elsif r[:path].end_with?("/capabilities") then [200, { "background_exec" => true }]
      else [200, { "labels" => r[:body]["labels"] || {} }]
      end
    end
    b = box(stub)
    assert_equal 12.5, b.metrics["cpu_pct"]
    assert_equal "a", b.logs(limit: 5)[0]["stdout_tail"]
    assert_equal "/v1/sandboxes/sbx_1/logs?limit=5", stub.last[:path]
    assert_equal({ "env" => "prod" }, b.set_labels(env: "prod"))
    assert_equal({ "env" => "prod" }, b.info["labels"])
    b.set_labels(nil)
    assert_equal({ "labels" => nil }, stub.last[:body])
    assert cloud(stub).capabilities["background_exec"]
  end

  def test_pipelines
    gets = 0
    stub = Stub.new do |r|
      p = r[:path]
      if p.end_with?("/cancel") then [200, { "run" => { "state" => "cancelled" } }]
      elsif p.include?("/logs") then [200, { "done" => true, "logs" => [{ "job" => "test", "next" => 4 }] }]
      elsif p.include?("/artifacts/") then [200, "tgz"]
      elsif p.end_with?("/artifacts") then [200, { "artifacts" => [{ "path" => "dist" }] }]
      elsif p.start_with?("/v1/pipelines/hooks") && r[:method] == "POST" then [201, { "hook" => { "id" => "hk_1", "secret" => "whsec" } }]
      elsif p.start_with?("/v1/pipelines/hooks") && r[:method] == "DELETE" then [200, { "deleted" => "hk_1" }]
      elsif p.start_with?("/v1/pipelines/hooks") then [200, { "hooks" => [{ "id" => "hk_1" }] }]
      elsif r[:method] == "POST" then [201, { "run" => { "id" => "run_1", "state" => "queued" } }]
      elsif p == "/v1/pipelines/runs/run_1"
        gets += 1
        [200, { "run" => { "id" => "run_1", "state" => gets > 1 ? "success" : "running" } }]
      else [200, { "runs" => [{ "id" => "run_1" }] }]
      end
    end
    pl = cloud(stub).pipelines
    assert_equal "run_1", pl.run(repo_url: "https://github.com/me/app", ref: "main", size: "4x8", secrets: ["npm-token"], inputs: { "x" => "1" })["id"]
    assert_equal({ "repo_url" => "https://github.com/me/app", "ref" => "main", "size" => "4x8", "secrets" => ["npm-token"], "inputs" => { "x" => "1" } }, stub.last[:body])
    assert_equal "success", pl.wait("run_1", poll_interval: 0)["state"]
    pl.runs(state: "running", limit: 10)
    assert_equal "/v1/pipelines/runs?state=running&limit=10", stub.last[:path]
    assert_equal 4, pl.logs("run_1", job: "test", after: 2)["logs"][0]["next"]
    assert_equal "/v1/pipelines/runs/run_1/logs?job=test&after=2", stub.last[:path]
    assert_equal "cancelled", pl.cancel("run_1")["state"]
    assert_equal "dist", pl.artifacts("run_1")[0]["path"]
    assert_equal "tgz", pl.download_artifact("run_1", "build", 0)
    assert_equal "whsec", pl.create_hook(repo_url: "https://github.com/me/app", cron: "0 3 * * *", cron_ref: "main")["secret"]
    assert_equal 1, pl.hooks.size
    assert_nil pl.delete_hook("hk_1")
    assert_raises(ArgumentError) { pl.run(repo_url: "") }
  end
end
