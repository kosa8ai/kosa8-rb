# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "json"
require "minitest/autorun"
require "kosa8"

# kosa8 Cloud API parity (0.4.0): lifetimes, update, paging, files,
# checkpoints, rewind, fork, ports, templates and the new error mappings.
class CloudParityTest < Minitest::Test
  KEY = "k8c_live_testkey"
  BASE = "https://cp.test"

  # Records each request; the block answers [status, payload] or
  # [status, payload, headers]. A String payload is sent as raw bytes.
  class Stub
    attr_reader :seen

    def initialize(&answer)
      @answer = answer
      @seen = []
    end

    def call(method, url, headers, body, _timeout)
      json = headers["Content-Type"] == "application/json"
      s = { method: method, url: url, path: url.sub(BASE, ""), headers: headers,
            body: json && body ? JSON.parse(body) : nil, raw: body }
      @seen << s
      status, payload, resp_headers = @answer.call(s)
      out = if payload.nil? then ""
            elsif payload.is_a?(String) then payload
            else JSON.generate(payload)
            end
      [status, out, resp_headers]
    end
  end

  def sbx(over = {})
    { "id" => "sbx_1", "state" => "running", "template" => "base" }.merge(over)
  end

  def cloud(stub)
    Kosa8::Cloud.new(api_key: KEY, base_url: BASE, env: {}, transport: stub)
  end

  def box(stub)
    Kosa8::CloudSandbox.new(cloud(stub), sbx)
  end

  def test_default_url_is_api_kosa8_com
    assert_equal "https://api.kosa8.com", Kosa8::Cloud::DEFAULT_URL
    seen = []
    c = Kosa8::Cloud.new(api_key: KEY, env: {}, transport: ->(_m, u, *) { seen << u && [200, "{}"] })
    assert_equal "https://api.kosa8.com", c.base_url
    c.me
    assert_equal ["https://api.kosa8.com/v1/me"], seen
  end

  def test_version
    assert_equal "0.4.0", Kosa8::VERSION
  end

  def test_create_with_lifetime_and_price
    stub = Stub.new { [201, { "sandbox" => sbx }] }
    c = cloud(stub)
    c.sandboxes.create(ttl_s: 3600)
    assert_equal({ "ttl_s" => 3600 }, stub.seen[-1][:body])
    c.sandboxes.create(template: "alice/tool@1.2.3", delete_after: 1_900_000_000_000, accept_price: 0.5,
                       sleep_after_s: 0, region: "eu-hel1")
    assert_equal({ "template" => "alice/tool@1.2.3", "region" => "eu-hel1", "sleep_after_s" => 0,
                   "delete_after" => 1_900_000_000_000, "accept_price" => 0.5 }, stub.seen[-1][:body])
    c.sandboxes.create
    assert_equal({}, stub.seen[-1][:body])
  end

  def test_create_rejects_bad_arguments_before_any_request
    stub = Stub.new { [201, { "sandbox" => sbx }] }
    c = cloud(stub)
    [
      { ttl_s: 59 }, { ttl_s: 7_776_001 }, { ttl_s: 60.5 }, { ttl_s: "3600" },
      { ttl_s: 60, delete_after: 1 }, { delete_after: 1.5 },
      { sleep_after_s: -1 }, { sleep_after_s: 604_801 }, { accept_price: "1" }
    ].each do |kw|
      assert_raises(ArgumentError, kw.inspect) { c.sandboxes.create(**kw) }
    end
    assert_empty stub.seen
    c.sandboxes.create(ttl_s: 60)
    c.sandboxes.create(ttl_s: 7_776_000, sleep_after_s: 604_800)
    assert_equal 2, stub.seen.size
  end

  def test_update
    stub = Stub.new { [200, { "sandbox" => sbx("delete_after" => 5), "notes" => ["recorded"] }] }
    b = box(stub)
    assert_same b, b.update(ttl_s: 600, sleep_after_s: 0)
    assert_equal ["PATCH", "/v1/sandboxes/sbx_1", { "ttl_s" => 600, "sleep_after_s" => 0 }],
                 stub.seen[-1].values_at(:method, :path, :body)
    assert_equal 5, b.info["delete_after"]
    assert_equal ["recorded"], b.notes
    b.update(clear_lifetime: true)
    assert_equal '{"ttl_s":null}', stub.seen[-1][:raw]
    b.update(delete_after: 1_900_000_000_000)
    assert_equal({ "delete_after" => 1_900_000_000_000 }, stub.seen[-1][:body])
    n = stub.seen.size
    assert_raises(ArgumentError) { b.update }
    assert_raises(ArgumentError) { b.update(clear_lifetime: true, ttl_s: 60) }
    assert_raises(ArgumentError) { b.update(ttl_s: 10) }
    assert_raises(ArgumentError) { b.update(ttl_s: 60, delete_after: 1) }
    assert_equal n, stub.seen.size
  end

  def test_list_stays_an_array_and_takes_limit_and_cursor
    stub = Stub.new { [200, { "sandboxes" => [sbx, sbx("id" => "sbx_2")] }] }
    c = cloud(stub)
    l = c.sandboxes.list
    assert_kind_of Array, l
    assert_equal %w[sbx_1 sbx_2], l.map(&:id)
    assert_equal "/v1/sandboxes", stub.seen[-1][:path]
    c.sandboxes.list(all: true, limit: 50, cursor: "c 1")
    assert_equal "/v1/sandboxes?all=1&limit=50&cursor=c+1", stub.seen[-1][:path]
    assert_raises(ArgumentError) { c.sandboxes.list(limit: 0) }
  end

  def test_list_page
    stub = Stub.new { [200, { "sandboxes" => [sbx], "next_cursor" => "abc" }] }
    page = cloud(stub).sandboxes.list_page(limit: 1)
    assert_equal ["sbx_1"], page.sandboxes.map(&:id)
    assert_equal "abc", page.next_cursor
    stub2 = Stub.new { [200, { "sandboxes" => [sbx], "next_cursor" => "" }] }
    assert_nil cloud(stub2).sandboxes.list_page.next_cursor
    stub3 = Stub.new { [200, { "sandboxes" => [] }] }
    assert_nil cloud(stub3).sandboxes.list_page.next_cursor
  end

  def test_each_follows_cursors
    pages = {
      nil => { "sandboxes" => [sbx("id" => "a"), sbx("id" => "b")], "next_cursor" => "p2" },
      "p2" => { "sandboxes" => [sbx("id" => "c")], "next_cursor" => "p3" },
      "p3" => { "sandboxes" => [sbx("id" => "d")] }
    }
    stub = Stub.new { |s| [200, pages[s[:path][/cursor=([^&]+)/, 1]]] }
    c = cloud(stub)
    e = c.sandboxes.each(all: true, page_size: 2)
    assert_kind_of Enumerator, e
    assert_empty stub.seen, "an Enumerator is lazy"
    assert_equal %w[a b c d], e.map(&:id)
    assert_equal ["/v1/sandboxes?all=1&limit=2", "/v1/sandboxes?all=1&limit=2&cursor=p2",
                  "/v1/sandboxes?all=1&limit=2&cursor=p3"], stub.seen.map { |s| s[:path] }
    got = []
    c.sandboxes.each { |b| got << b.id }
    assert_equal %w[a b c d], got
  end

  def test_each_one_page_when_the_server_does_not_page
    stub = Stub.new { [200, { "sandboxes" => [sbx, sbx("id" => "sbx_2")] }] }
    assert_equal %w[sbx_1 sbx_2], cloud(stub).sandboxes.each.map(&:id)
    assert_equal 1, stub.seen.size
  end

  def test_each_stops_on_a_repeated_cursor
    stub = Stub.new { [200, { "sandboxes" => [sbx], "next_cursor" => "same" }] }
    assert_equal 2, cloud(stub).sandboxes.each.to_a.size
    assert_equal 2, stub.seen.size
  end

  def test_files
    stub = Stub.new do |s|
      case [s[:method], s[:path].split("?")[0]]
      when %w[GET /v1/sandboxes/sbx_1/files] then [200, "h\xC3\xA9\x00\xFF".b]
      when %w[PUT /v1/sandboxes/sbx_1/files] then [200, { "file" => { "path" => "/workspace/a b.txt", "size" => 3 } }]
      when %w[GET /v1/sandboxes/sbx_1/files/list]
        [200, { "path" => "/workspace", "files" => [{ "name" => "x", "type" => "dir" }] }]
      when %w[POST /v1/sandboxes/sbx_1/files/mkdir] then [200, { "file" => { "path" => "/workspace/d", "type" => "dir" } }]
      when %w[DELETE /v1/sandboxes/sbx_1/files] then [200, { "removed" => "/workspace/d" }]
      else [404, { "error" => "not_found", "message" => "no route" }]
      end
    end
    f = box(stub).files
    data = f.read("/workspace/a b.txt")
    assert_equal Encoding::ASCII_8BIT, data.encoding
    assert_equal "h\xC3\xA9\x00\xFF".b, data
    assert_equal "/v1/sandboxes/sbx_1/files?path=%2Fworkspace%2Fa%20b.txt", stub.seen[-1][:path]
    assert_equal "application/octet-stream", stub.seen[-1][:headers]["Accept"]
    assert_nil stub.seen[-1][:raw]

    stub2 = Stub.new { [200, "héllo"] }
    t = box(stub2).files.read_text("/workspace/t")
    assert_equal Encoding::UTF_8, t.encoding
    assert_equal "héllo", t

    assert_equal 3, f.write("/workspace/a b.txt", "hé")["size"]
    w = stub.seen[-1]
    assert_equal "PUT", w[:method]
    assert_equal "application/octet-stream", w[:headers]["Content-Type"]
    assert_equal "h\xC3\xA9".b, w[:raw]
    assert_equal Encoding::ASCII_8BIT, w[:raw].encoding
    f.write("/workspace/bin", "\x00\xFF".b)
    assert_equal "\x00\xFF".b, stub.seen[-1][:raw]

    assert_equal [{ "name" => "x", "type" => "dir" }], f.list
    assert_equal "/v1/sandboxes/sbx_1/files/list?path=%2Fworkspace", stub.seen[-1][:path]
    f.list("/tmp")
    assert_equal "/v1/sandboxes/sbx_1/files/list?path=%2Ftmp", stub.seen[-1][:path]

    assert_equal "dir", f.mkdir("/workspace/d")["type"]
    assert_equal({ "path" => "/workspace/d" }, stub.seen[-1][:body])

    assert_nil f.delete("/workspace/d")
    assert_equal "/v1/sandboxes/sbx_1/files?path=%2Fworkspace%2Fd", stub.seen[-1][:path]
    f.delete("/workspace/d", recursive: true)
    assert_equal ["DELETE", "/v1/sandboxes/sbx_1/files?path=%2Fworkspace%2Fd&recursive=1"],
                 stub.seen[-1].values_at(:method, :path)

    n = stub.seen.size
    assert_raises(ArgumentError) { f.read("") }
    assert_raises(ArgumentError) { f.mkdir(nil) }
    assert_equal n, stub.seen.size
  end

  def test_file_read_error_is_typed
    stub = Stub.new { [404, { "error" => "not_found", "message" => "no such file" }] }
    e = assert_raises(Kosa8::NotFoundError) { box(stub).files.read("/workspace/nope") }
    assert_equal "no such file", e.message
  end

  def test_checkpoints_rewind_fork_ports
    ck = { "id" => "ck_1", "label" => "clean", "auto" => false, "created_at" => "2026-11-12T00:00:00Z", "bytes" => 9 }
    stub = Stub.new do |s|
      case [s[:method], s[:path]]
      when %w[POST /v1/sandboxes/sbx_1/checkpoints] then [201, { "checkpoint" => ck, "evicted" => [], "ms" => 40 }]
      when %w[GET /v1/sandboxes/sbx_1/checkpoints] then [200, { "checkpoints" => [ck], "max" => 10 }]
      when %w[POST /v1/sandboxes/sbx_1/rewind]
        [200, { "sandbox" => sbx("state" => "running", "last_error" => nil), "checkpoint" => ck,
                "backup" => ck.merge("id" => "ck_2", "auto" => true), "ms" => 80 }]
      when %w[POST /v1/sandboxes/sbx_1/fork]
        [201, { "parent" => "sbx_1", "sandboxes" => [sbx("id" => "sbx_f1", "parent_id" => "sbx_1", "source" => "fork"),
                                                     sbx("id" => "sbx_f2", "parent_id" => "sbx_1", "source" => "fork")] }]
      when %w[GET /v1/sandboxes/sbx_1/ports]
        [200, { "ports" => [{ "port" => 8000, "address" => "0.0.0.0", "container" => "c1", "loopback" => false }] }]
      else [404, { "error" => "not_found", "message" => "no route" }]
      end
    end
    b = box(stub)
    assert_equal ck, b.checkpoint("clean")
    assert_equal({ "label" => "clean" }, stub.seen[-1][:body])
    b.checkpoint
    assert_equal({}, stub.seen[-1][:body])
    assert_equal [ck], b.checkpoints

    r = b.rewind("ck_1")
    assert_kind_of Kosa8::CloudRewindResult, r
    assert_equal ["ck_1", "ck_2", 80], [r.checkpoint["id"], r.backup["id"], r.ms]
    assert_equal({ "checkpoint_id" => "ck_1" }, stub.seen[-1][:body])
    assert b.info.key?("last_error"), "info refreshed from the answer"
    b.rewind(ck)
    assert_equal({ "checkpoint_id" => "ck_1" }, stub.seen[-1][:body])

    forks = b.fork(2)
    assert_equal %w[sbx_f1 sbx_f2], forks.map(&:id)
    assert_kind_of Kosa8::CloudSandbox, forks[0]
    assert_equal "sbx_1", forks[0].info["parent_id"]
    assert_equal({ "n" => 2 }, stub.seen[-1][:body])
    b.fork
    assert_equal({ "n" => 1 }, stub.seen[-1][:body])

    assert_equal 8000, b.ports[0]["port"]

    n = stub.seen.size
    assert_raises(ArgumentError) { b.checkpoint("x" * 201) }
    assert_raises(ArgumentError) { b.rewind("") }
    assert_raises(ArgumentError) { b.fork(0) }
    assert_raises(ArgumentError) { b.fork(101) }
    assert_raises(ArgumentError) { b.fork(1.5) }
    assert_equal n, stub.seen.size
  end

  def test_templates
    stub = Stub.new { [200, { "templates" => [{ "key" => "base" }, { "key" => "python" }], "default_template" => "base" }] }
    assert_equal %w[base python], cloud(stub).templates.map { |t| t["key"] }
    assert_equal %w[GET /v1/templates], stub.seen[-1].values_at(:method, :path)
  end

  def test_dataplane_501_is_unsupported
    %w[not_available not_supported].each do |code|
      stub = Stub.new { [501, { "error" => code, "message" => "this host has no data plane yet" }] }
      b = box(stub)
      [-> { b.checkpoint }, -> { b.checkpoints }, -> { b.rewind("ck") }, -> { b.fork },
       -> { b.ports }, -> { b.files.read("/workspace/a") }, -> { b.files.list }].each do |call|
        e = assert_raises(Kosa8::UnsupportedError) { call.call }
        assert_equal code, e.code
        assert_equal 501, e.status
      end
    end
  end

  def test_payment_required_fields
    body = { "error" => "spending_cap_reached", "message" => "the spending cap is reached",
             "upgrade_url" => "https://app.kosa8.com/#billing", "agent_message" => "Tell your person to raise the cap." }
    e = assert_raises(Kosa8::PaymentRequiredError) { cloud(Stub.new { [402, body] }).sandboxes.create }
    assert_equal "spending_cap_reached", e.code
    assert_equal "https://app.kosa8.com/#billing", e.upgrade_url
    assert_equal "Tell your person to raise the cap.", e.agent_message
    assert_equal "the spending cap is reached", e.message
    e = assert_raises(Kosa8::PaymentRequiredError) do
      cloud(Stub.new { [402, { "error" => "payment_required", "message" => "add a card" }] }).sandboxes.create
    end
    assert_nil e.upgrade_url
    assert_nil e.agent_message
  end

  def test_org_frozen
    stub = Stub.new { [423, { "error" => "org_frozen", "message" => "this organization is frozen" }] }
    e = assert_raises(Kosa8::OrgFrozenError) { cloud(stub).sandboxes.create }
    assert_kind_of Kosa8::ApiError, e
    assert_equal ["org_frozen", 423, "this organization is frozen"], [e.code, e.status, e.message]
  end

  def test_rate_limit_retry_after
    body = { "error" => "quota_exceeded", "message" => "too many" }
    e = assert_raises(Kosa8::RateLimitError) { cloud(Stub.new { [429, body, { "Retry-After" => "7" }] }).me }
    assert_equal 7.0, e.retry_after
    e = assert_raises(Kosa8::RateLimitError) { cloud(Stub.new { [429, body, { "retry-after" => ["2.5"] }] }).me }
    assert_equal 2.5, e.retry_after
    e = assert_raises(Kosa8::RateLimitError) { cloud(Stub.new { [429, body] }).me }
    assert_nil e.retry_after
    e = assert_raises(Kosa8::RateLimitError) { cloud(Stub.new { [429, body, { "Retry-After" => "soon" }] }).me }
    assert_nil e.retry_after
    assert_equal "quota_exceeded", e.code
  end

  def test_exec_timeout
    answers = [
      [504, { "error" => "exec_timeout", "message" => "the command ran past 30 s" }],
      [502, { "error" => "exec_timeout", "message" => "cut off" }],
      [502, { "error" => "host_failed", "message" => "exec failed on the host: request Timed Out" }],
      [504, nil]
    ]
    b = box(Stub.new { answers.shift })
    e = assert_raises(Kosa8::ExecTimeoutError) { b.exec("sleep 60") }
    assert_kind_of Kosa8::ApiError, e
    assert_equal ["exec_timeout", 504], [e.code, e.status]
    assert_match(/the command ran past 30 s/, e.message)
    assert_match(/30 s.*background/, e.message)
    assert_raises(Kosa8::ExecTimeoutError) { b.exec("sleep 60") }
    e = assert_raises(Kosa8::ExecTimeoutError) { b.exec("sleep 60") }
    assert_equal "host_failed", e.code
    assert_match(/exec failed on the host: request Timed Out/, e.message)
    e = assert_raises(Kosa8::ExecTimeoutError) { b.exec("sleep 60") }
    assert_match(/HTTP 504/, e.message)
  end

  def test_502_timed_out_elsewhere_is_not_an_exec_timeout
    stub = Stub.new { [502, { "error" => "host_failed", "message" => "the host timed out" }] }
    e = assert_raises(Kosa8::ApiError) { box(stub).sleep }
    refute_kind_of Kosa8::ExecTimeoutError, e
    stub = Stub.new { [502, { "error" => "host_failed", "message" => "exec failed on the host: boom" }] }
    e = assert_raises(Kosa8::ApiError) { box(stub).exec("true") }
    refute_kind_of Kosa8::ExecTimeoutError, e
  end

  def test_client_side_exec_timeout
    slow = ->(*) { raise Net::ReadTimeout }
    b = Kosa8::CloudSandbox.new(Kosa8::Cloud.new(api_key: KEY, env: {}, transport: slow), sbx)
    e = assert_raises(Kosa8::ExecTimeoutError) { b.exec("sleep 99") }
    assert_equal "exec_timeout", e.code
    assert_raises(Kosa8::TimeoutError) { b.refresh }
  end
end
