# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "json"
require "minitest/autorun"
require "socket"
require "kosa8"

class CloudTest < Minitest::Test
  KEY = "k8c_live_testkey"

  # A transport that records each request and answers from a block.
  class Stub
    attr_reader :seen

    def initialize(&answer)
      @answer = answer
      @seen = []
    end

    def call(method, url, headers, body, _timeout)
      s = { method: method, url: url, headers: headers, body: body ? JSON.parse(body) : nil }
      @seen << s
      status, payload = @answer.call(s)
      [status, payload.nil? ? "" : JSON.generate(payload)]
    end
  end

  def sbx(over = {})
    { "id" => "sbx_1", "state" => "running", "template" => "python", "cpus" => 1, "mem_mb" => 512 }.merge(over)
  end

  def test_key_and_address
    c = Kosa8::Cloud.new(env: { "KOSA8_API_KEY" => KEY })
    assert_equal "https://api.kosa8.cloud", c.base_url
    refute_includes c.inspect, KEY
    refute_includes c.to_s, KEY
    refute_includes c.sandboxes.inspect, KEY
    assert_equal "https://cp.test", Kosa8::Cloud.new(env: { "KOSA8_API_KEY" => KEY, "KOSA8_CLOUD_URL" => "https://cp.test" }).base_url

    e = assert_raises(Kosa8::Error) { Kosa8::Cloud.new(env: {}) }
    assert_match(/KOSA8_API_KEY/, e.message)
    e = assert_raises(Kosa8::Error) { Kosa8::Cloud.new(api_key: "sk-other", env: {}) }
    assert_match(/k8c_live_/, e.message)
    e = assert_raises(Kosa8::Error) { Kosa8::Cloud.new(api_key: KEY, base_url: "http://cp.example.com", env: {}) }
    assert_match(/https/, e.message)
    assert_raises(Kosa8::Error) { Kosa8::Cloud.new(api_key: KEY, base_url: "not a url", env: {}) }
    assert_equal "http://localhost:8787", Kosa8::Cloud.new(api_key: KEY, base_url: "http://localhost:8787/", env: {}).base_url
    assert_equal "http://127.0.0.1:1", Kosa8::Cloud.new(api_key: KEY, base_url: "http://127.0.0.1:1", env: {}).base_url
    assert_equal "http://[::1]:1", Kosa8::Cloud.new(api_key: KEY, base_url: "http://[::1]:1", env: {}).base_url
  end

  def test_sandbox_lifecycle
    stub = Stub.new do |s|
      u = s[:url]
      m = s[:method]
      if m == "POST" && u.end_with?("/v1/sandboxes") then [201, { "sandbox" => sbx, "host_ms" => 6 }]
      elsif u.end_with?("/exec") then [200, { "exit" => 0, "stdout" => "42\n", "stderr" => "", "woke_ms" => 70 }]
      elsif u.end_with?("/sleep") then [200, { "sandbox" => sbx("state" => "sleeping") }]
      elsif u.end_with?("/wake") then [200, { "sandbox" => sbx }]
      elsif m == "GET" && u.end_with?("/v1/sandboxes?all=1") then [200, { "sandboxes" => [sbx, sbx("id" => "sbx_2", "state" => "deleted")] }]
      elsif m == "GET" && u.end_with?("/v1/sandboxes/sbx_1") then [200, { "sandbox" => sbx("state" => "sleeping") }]
      elsif m == "DELETE" then [200, { "ok" => true, "id" => "sbx_1" }]
      else [404, { "error" => "not_found", "message" => "no route" }]
      end
    end
    cloud = Kosa8::Cloud.new(api_key: KEY, base_url: "https://cp.test", env: {}, transport: stub)
    box = cloud.sandboxes.create(template: "python", sleep_after_s: 600)
    assert_equal({ "template" => "python", "sleep_after_s" => 600 }, stub.seen[0][:body])
    assert_equal "Bearer #{KEY}", stub.seen[0][:headers]["Authorization"]
    assert_equal "application/json", stub.seen[0][:headers]["Content-Type"]
    refute_includes box.inspect, KEY

    r = box.exec('python3 -c "print(6*7)"', env: { "A" => "1" })
    assert_equal({ "cmd" => ["sh", "-c", 'python3 -c "print(6*7)"'], "env" => ["A=1"] }, stub.seen[1][:body])
    assert_equal [0, "42\n", 70], [r.exit_code, r.stdout, r.woke_ms]
    assert r.ok?
    box.exec(%w[python3 -V], image: "python:3.12")
    assert_equal({ "cmd" => %w[python3 -V], "image" => "python:3.12" }, stub.seen[2][:body])

    assert_equal "sleeping", box.sleep.state
    assert_equal "running", box.wake.state
    assert_equal "sleeping", box.refresh.state
    assert_nil box.delete
    assert_equal %w[sbx_1 sbx_2], cloud.sandboxes.list(all: true).map(&:id)
    assert_equal "sleeping", cloud.sandboxes.get("sbx_1").state
    assert_equal [
      %w[POST /v1/sandboxes], %w[POST /v1/sandboxes/sbx_1/exec], %w[POST /v1/sandboxes/sbx_1/exec],
      %w[POST /v1/sandboxes/sbx_1/sleep], %w[POST /v1/sandboxes/sbx_1/wake], %w[GET /v1/sandboxes/sbx_1],
      %w[DELETE /v1/sandboxes/sbx_1], ["GET", "/v1/sandboxes?all=1"], %w[GET /v1/sandboxes/sbx_1]
    ], stub.seen.map { |s| [s[:method], s[:url].sub("https://cp.test", "")] }
    assert_nil stub.seen[3][:body], "sleep sends no body"
  end

  def test_functions
    stub = Stub.new do |s|
      case s[:url]
      when %r{/invoke\z} then [200, { "invocation" => { "id" => "inv_1" }, "ok" => true, "result" => { "hello" => "kosa8" } }]
      when %r{/map\z} then [200, { "count" => 2, "results" => [] }]
      when %r{/v1/functions\z} then [200, { "functions" => [{ "name" => "hello" }] }]
      else [200, { "name" => "hello", "version" => 1 }]
      end
    end
    cloud = Kosa8::Cloud.new(api_key: KEY, env: {}, transport: stub)
    assert_equal({ "hello" => "kosa8" }, cloud.functions.invoke("hello", "name" => "kosa8")["result"])
    assert_equal({ "event" => { "name" => "kosa8" } }, stub.seen[0][:body])
    cloud.functions.invoke("hello")
    assert_equal({ "event" => nil }, stub.seen[1][:body])
    cloud.functions.map("hello", [1, 2], concurrency: 4)
    assert_equal({ "events" => [1, 2], "concurrency" => 4 }, stub.seen[2][:body])
    spec = { "runtime" => "python3.12", "code" => "def handler(e):\n    return e\n" }
    assert_equal 1, cloud.functions.deploy("hello", spec)["version"]
    assert_equal ["PUT", "https://api.kosa8.cloud/v1/functions/hello", spec], stub.seen[3].values_at(:method, :url, :body)
    assert_equal ["hello"], cloud.functions.list.map { |f| f["name"] }
    cloud.functions.get("a b")
    assert_equal "https://api.kosa8.cloud/v1/functions/a%20b", stub.seen[5][:url]
    assert_nil cloud.functions.delete("hello")
    assert_equal "DELETE", stub.seen[6][:method]
  end

  def test_me_and_usage
    stub = Stub.new { |s| [200, { "path" => s[:url] }] }
    cloud = Kosa8::Cloud.new(api_key: KEY, env: {}, transport: stub)
    assert_match %r{/v1/me\z}, cloud.me["path"]
    assert_match %r{/v1/usage\z}, cloud.usage["path"]
    assert_nil stub.seen[0][:headers]["Content-Type"]
  end

  def test_typed_errors_keep_the_message_and_code
    answers = [
      [402, { "error" => "payment_required", "message" => "add a payment method to start running work" }],
      [429, { "error" => "quota_exceeded", "message" => "this organization already has 20 active sandboxes" }],
      [404, { "error" => "not_found", "message" => "no such sandbox" }],
      [401, { "error" => "unauthorized" }],
      [500, nil]
    ]
    cloud = Kosa8::Cloud.new(api_key: KEY, env: {}, transport: Stub.new { answers.shift })
    e = assert_raises(Kosa8::PaymentRequiredError) { cloud.sandboxes.create }
    assert_kind_of Kosa8::ApiError, e
    assert_equal "payment_required", e.code
    assert_equal "add a payment method to start running work", e.message
    assert_equal 402, e.status
    assert_equal "payment_required", e.body["error"], "body is the cloud's own answer"
    e = assert_raises(Kosa8::RateLimitError) { cloud.sandboxes.create }
    assert_equal "quota_exceeded", e.code
    e = assert_raises(Kosa8::NotFoundError) { cloud.sandboxes.get("sbx_x") }
    assert_equal "not_found", e.code
    e = assert_raises(Kosa8::AuthError) { cloud.me }
    assert_equal "unauthorized", e.message
    e = assert_raises(Kosa8::ApiError) { cloud.me }
    assert_nil e.code
    assert_equal "request failed with HTTP 500", e.message
  end

  def test_unreachable
    boom = ->(*) { raise Errno::ECONNREFUSED, "connect(2)" }
    cloud = Kosa8::Cloud.new(api_key: KEY, env: {}, transport: boom)
    e = assert_raises(Kosa8::ConnectionError) { cloud.me }
    assert_match(/could not reach kosa8 Cloud/, e.message)
    refute_includes e.message, KEY

    slow = ->(*) { raise Net::ReadTimeout }
    assert_raises(Kosa8::TimeoutError) { Kosa8::Cloud.new(api_key: KEY, env: {}, transport: slow).me }
  end

  # The default Net::HTTP transport, against a real socket.
  def test_net_http_transport
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    got = Queue.new
    t = Thread.new do
      c = server.accept
      head = +""
      head << c.gets until head.end_with?("\r\n\r\n")
      len = head[/content-length: *(\d+)/i, 1].to_i
      body = len.positive? ? c.read(len) : ""
      got << [head, body]
      out = JSON.generate("error" => "payment_required", "message" => "add a payment method")
      c.write "HTTP/1.1 402 Payment Required\r\nContent-Type: application/json\r\nContent-Length: #{out.bytesize}\r\nConnection: close\r\n\r\n#{out}"
      c.close
    end
    cloud = Kosa8::Cloud.new(api_key: KEY, base_url: "http://127.0.0.1:#{port}", env: {}, timeout: 5)
    e = assert_raises(Kosa8::PaymentRequiredError) { cloud.sandboxes.create(region: "eu-hel1") }
    assert_equal "payment_required", e.code
    head, body = got.pop
    assert_match %r{\APOST /v1/sandboxes HTTP/1.1}, head
    assert_match(/authorization: Bearer #{KEY}/i, head)
    assert_equal({ "region" => "eu-hel1" }, JSON.parse(body))
    t.join

    server.close
    e = assert_raises(Kosa8::ConnectionError) do
      Kosa8::Cloud.new(api_key: KEY, base_url: "http://127.0.0.1:#{port}", env: {}, timeout: 5).me
    end
    assert_match(/could not reach kosa8 Cloud at http:/, e.message)
  ensure
    server&.close unless server&.closed?
  end
end
