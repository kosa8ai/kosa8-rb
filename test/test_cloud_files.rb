# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift __dir__
require "minitest/autorun"
require "stringio"
require "kosa8"
require "fake_cloud"

# Files: Range reads, offset / append / mode writes, uploads in parts, and
# no retry of an append that may have landed.
class CloudFilesTest < Minitest::Test
  BOX = { "id" => "sbx_1", "state" => "running", "template" => "base" }.freeze

  def setup
    @answers = []
    @fake = FakeCloud.new do |req|
      a = @answers.shift
      a ? a.call(req) : [200, { "file" => { "path" => "/workspace/f", "size" => req[:raw].to_s.bytesize } }]
    end
    @box = Kosa8::CloudSandbox.new(@fake.cloud, BOX.dup)
  end

  def teardown
    @fake.close
  end

  def q(req)
    URI.decode_www_form(req[:path].split("?", 2)[1].to_s).to_h
  end

  def test_range_read
    @answers << ->(_r) { [206, "abc"] }
    assert_equal "abc", @box.files.read("/workspace/f", range: 10..12)
    assert_equal "bytes=10-12", @fake.seen.last[:headers]["range"]
    @answers << ->(_r) { [206, "x"] }
    @box.files.download("/workspace/f", range: 5..)
    assert_equal "bytes=5-", @fake.seen.last[:headers]["range"]
    @answers << ->(_r) { [206, "x"] }
    @box.files.read("/workspace/f", range: -100)
    assert_equal "bytes=-100", @fake.seen.last[:headers]["range"]
    @answers << ->(_r) { [206, "x"] }
    @box.files.read("/workspace/f", range: 0...4)
    assert_equal "bytes=0-3", @fake.seen.last[:headers]["range"]
    n = @fake.seen.size
    [5, 3..1, "bytes=1-2,4-5", 1.5].each { |bad| assert_raises(ArgumentError) { @box.files.read("/x", range: bad) } }
    assert_equal n, @fake.seen.size
  end

  def test_write_offset_append_mode
    @box.files.write("/workspace/f", "part", offset: 1024)
    assert_equal({ "path" => "/workspace/f", "offset" => "1024" }, q(@fake.seen.last))
    @box.files.write("/workspace/f", "more", append: true, mode: 0o755)
    assert_equal({ "path" => "/workspace/f", "append" => "1", "mode" => "755" }, q(@fake.seen.last))
    assert_equal "more", @fake.seen.last[:raw]
    assert_raises(ArgumentError) { @box.files.write("/x", "a", offset: 1, append: true) }
    assert_raises(ArgumentError) { @box.files.write("/x", "a", offset: -1) }
    assert_raises(ArgumentError) { @box.files.write("/x", "a", mode: "rwx") }
  end

  def test_append_is_not_retried_after_a_5xx
    @answers << ->(_r) { [502, { "error" => "host_failed", "message" => "the host failed", "retryable" => true }] }
    assert_raises(Kosa8::ApiError) { @box.files.write("/workspace/log", "line\n", append: true) }
    assert_equal 1, @fake.calls("PUT", "/v1/sandboxes/sbx_1/files").size
    # a plain write (idempotent) still is
    @answers << ->(_r) { [502, { "error" => "host_failed", "message" => "the host failed", "retryable" => true }] }
    @box.files.write("/workspace/f", "x")
    assert_equal 3, @fake.calls("PUT", "/v1/sandboxes/sbx_1/files").size
  end

  def test_upload_in_parts_from_an_io
    data = ("0123456789" * 3).b # 30 bytes, parts of 8: 8, 8, 8, 6
    info = @box.files.upload("/workspace/big", StringIO.new(data), part_size: 8, mode: "644")
    puts_ = @fake.calls("PUT", "/v1/sandboxes/sbx_1/files/raw")
    assert_equal 4, puts_.size
    assert_equal data, puts_.map { |r| r[:raw] }.join
    assert_nil q(puts_[0])["offset"], "the first part replaces the file"
    assert_equal %w[8 16 24], puts_[1..-1].map { |r| q(r)["offset"] }
    assert_equal [nil, nil, nil, "644"], puts_.map { |r| q(r)["mode"] }
    assert_equal 6, info["size"]
  end

  def test_upload_exact_multiple_and_small_and_empty
    @box.files.upload("/workspace/a", "x" * 16, part_size: 8)
    assert_equal 2, @fake.calls("PUT", "/v1/sandboxes/sbx_1/files/raw").size
    @box.files.upload("/workspace/b", "small")
    assert_equal 3, @fake.calls("PUT", "/v1/sandboxes/sbx_1/files/raw").size
    @box.files.upload("/workspace/c", "")
    last = @fake.calls("PUT", "/v1/sandboxes/sbx_1/files/raw").last
    assert_equal({ "path" => "/workspace/c" }, q(last))
    assert_raises(ArgumentError) { @box.files.upload("/x", "a", mode: "999") }
  end

  def test_path_is_escaped_not_traversed_client_side
    @box.files.read_text("/workspace/a b+c&d=e/../x?y#z")
    assert_equal "/workspace/a b+c&d=e/../x?y#z", q(@fake.seen.last)["path"]
    assert_equal "/v1/sandboxes/sbx_1/files", @fake.seen.last[:path].split("?", 2)[0]
  end
end
