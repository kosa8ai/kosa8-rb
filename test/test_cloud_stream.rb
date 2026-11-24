# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift __dir__
require "minitest/autorun"
require "base64"
require "kosa8"
require "fake_cloud"

# Streamed exec: NDJSON frames split anywhere, heartbeats, UTF-8 across
# chunks, done/error/exec_timeout, refusals before the stream, and routing
# from #exec.
class CloudStreamTest < Minitest::Test
  BOX = { "id" => "sbx_1", "state" => "running", "template" => "base" }.freeze

  def frame(h)
    JSON.generate(h) + "\n"
  end

  def out(stream, bytes)
    frame("stream" => stream, "data" => Base64.strict_encode64(bytes))
  end

  # A cloud whose stream transport yields +chunks+ (or answers +status+ / +err+).
  def cloud_with(chunks, status: 200, err: nil, seen: [])
    st = lambda do |m, url, headers, body, timeout, &blk|
      seen << { method: m, url: url, headers: headers, body: JSON.parse(body), timeout: timeout }
      if status.is_a?(Array)
        s = status.shift
        return [s, JSON.generate(err), { "retry-after" => ["0"] }] if s >= 400
      elsif status >= 400
        return [status, JSON.generate(err), {}]
      end
      chunks.each { |c| blk.call(c) }
      [200, nil, {}]
    end
    c = Kosa8::Cloud.new(api_key: "k8c_live_x", env: {}, timeout: 10, stream_transport: st,
                         transport: ->(*) { raise "buffered transport used" }, sleeper: ->(_) {})
    [c, Kosa8::CloudSandbox.new(c, BOX.dup)]
  end

  def test_frames_split_across_chunks_with_heartbeat_and_utf8
    whole = out("stdout", "héllo ") + frame("stream" => "stdout", "data" => "", "heartbeat" => true) +
            out("stderr", "warn\n") + out("stdout", "wörld\n") + frame("done" => true, "exit" => 3)
    # split every 7 bytes: lines and the base64 of the frames cut anywhere
    chunks = whole.b.scan(/.{1,7}/m)
    seen = []
    _c, box = cloud_with(chunks, seen: seen)
    got = []
    r = box.exec_stream(["sh", "-c", "x"], env: { "A" => "1" }, timeout_s: 600) { |s, t| got << [s, t] }
    assert_equal 3, r.exit_code
    assert_equal "héllo wörld\n", r.stdout
    assert_equal "warn\n", r.stderr
    assert_equal "exit_nonzero", r.failure_class
    assert_equal "héllo wörld\n", got.select { |s, _| s == "stdout" }.map(&:last).join
    b = seen[0][:body]
    assert_equal true, b["stream"]
    assert_equal ["A=1"], b["env"]
    assert_equal 600, b["timeout_s"]
    assert seen[0][:timeout] >= 30
    assert_match %r{x-ndjson}, seen[0][:headers]["Accept"]
  end

  def test_utf8_character_split_between_frames
    bytes = "→ok".b # U+2192 is three bytes
    _c, box = cloud_with([out("stdout", bytes[0, 2]), out("stdout", bytes[2..-1]), frame("done" => true, "exit" => 0)])
    texts = []
    r = box.exec_stream("x", on_stdout: ->(t) { texts << t })
    assert_equal "→ok", r.stdout
    assert_equal ["→ok"], texts
    assert r.ok?
  end

  def test_exec_timeout_frame_raises_with_output_so_far
    _c, box = cloud_with([out("stdout", "partial"), frame("done" => true, "error" => "ran past timeout_s", "code" => "exec_timeout")])
    e = assert_raises(Kosa8::ExecTimeoutError) { box.exec_stream("sleep 1000", timeout_s: 5) }
    assert_equal "partial", e.stdout
    assert_equal "exec_timeout", e.code
    assert_equal "timeout", e.failure_class
  end

  def test_error_frame_raises_stream_error
    _c, box = cloud_with([out("stderr", "boom"), frame("done" => true, "error" => "host lost", "code" => "host_failed")])
    e = assert_raises(Kosa8::StreamError) { box.exec_stream("x") }
    assert_equal "boom", e.stderr
    assert_equal "host_failed", e.code
  end

  def test_no_final_frame_raises
    _c, box = cloud_with([out("stdout", "a")])
    e = assert_raises(Kosa8::StreamError) { box.exec_stream("x") }
    assert_equal "a", e.stdout
  end

  def test_not_json_raises
    _c, box = cloud_with(["<html>\n"])
    assert_raises(Kosa8::StreamError) { box.exec_stream("x") }
  end

  def test_whole_result_from_a_server_that_ignored_stream
    _c, box = cloud_with([JSON.generate("exit" => 0, "stdout" => "hi\n", "stderr" => "")])
    got = []
    r = box.exec_stream("x") { |s, t| got << [s, t] }
    assert_equal "hi\n", r.stdout
    assert_equal [["stdout", "hi\n"]], got
  end

  def test_refusal_before_stream_is_typed
    _c, box = cloud_with([], status: 402, err: { "error" => "payment_required", "message" => "add a card",
                                                 "upgrade_url" => "https://x" })
    e = assert_raises(Kosa8::PaymentRequiredError) { box.exec_stream("x") }
    assert_equal "https://x", e.upgrade_url
  end

  def test_429_before_stream_is_retried
    seen = []
    _c, box = cloud_with([frame("done" => true, "exit" => 0)], status: [429, 200],
                         err: { "error" => "rate_limited", "message" => "slow down" }, seen: seen)
    assert_equal 0, box.exec_stream("x").exit_code
    assert_equal 2, seen.size
  end

  def test_callback_error_propagates_unchanged
    _c, box = cloud_with([out("stdout", "a"), frame("done" => true, "exit" => 0)])
    assert_raises(ZeroDivisionError) { box.exec_stream("x") { |_s, _t| 1 / 0 } }
  end

  def test_timeout_bounds
    _c, box = cloud_with([])
    assert_raises(ArgumentError) { box.exec_stream("x", timeout_s: 0) }
    assert_raises(ArgumentError) { box.exec_stream("x", timeout_s: 86_401) }
  end

  def test_exec_routes_to_stream
    _c, box = cloud_with([out("stdout", "s"), frame("done" => true, "exit" => 0)])
    assert_equal "s", box.exec("x", timeout_s: 300).stdout
    _c, box = cloud_with([out("stdout", "s"), frame("done" => true, "exit" => 0)])
    seen = []
    assert_equal "s", box.exec("x", on_stdout: ->(t) { seen << t }).stdout
    assert_equal ["s"], seen
    _c, box = cloud_with([out("stdout", "s"), frame("done" => true, "exit" => 0)])
    assert_equal "s", box.exec("x", stream: true).stdout
  end

  # Over a real socket with the SDK's own Net::HTTP stream transport.
  def test_over_net_http
    body = out("stdout", "over the wire\n") + frame("done" => true, "exit" => 0)
    fake = FakeCloud.new { |req| req[:body] && req[:body]["stream"] ? [200, body] : [500, { "error" => "x", "message" => "x" }] }
    box = Kosa8::CloudSandbox.new(fake.cloud, BOX.dup)
    r = box.exec_stream("echo")
    assert_equal "over the wire\n", r.stdout
    assert_equal 0, r.exit_code
  ensure
    fake&.close
  end
end
