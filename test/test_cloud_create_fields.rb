# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift __dir__
require "minitest/autorun"
require "kosa8"
require "fake_cloud"

# Create and exec fields the API takes or answers that the SDK refused or dropped.
class CloudCreateFieldsTest < Minitest::Test
  def setup
    @fake = FakeCloud.new do |req|
      case req[:path]
      when %r{/exec\z}
        if req[:body]["background"]
          [202, { "exec" => { "id" => "bg_1", "state" => "running" } }]
        else
          [200, { "exit" => 0, "stdout" => "a[k8agent: 5 bytes of output dropped]b", "stderr" => "",
                  "stdout_truncated" => true, "stdout_bytes" => 2_097_157, "stderr_bytes" => 0 }]
        end
      else [201, { "sandbox" => { "id" => "sbx_1", "state" => "running", "template" => "base" } }]
      end
    end
    @cloud = @fake.cloud
  end

  def teardown
    @fake.close
  end

  def test_disk_gb_up_to_500
    @cloud.sandboxes.create(size: "4x8", disk_gb: 500)
    assert_equal 500, @fake.seen.last[:body]["disk_gb"]
    @cloud.sandboxes.create(size: "4x8", disk_gb: 256)
    assert_equal 256, @fake.seen.last[:body]["disk_gb"]
    assert_raises(ArgumentError) { @cloud.sandboxes.create(disk_gb: 501) }
    assert_raises(ArgumentError) { @cloud.sandboxes.create(disk_gb: 7) }
  end

  def test_kvm
    @cloud.sandboxes.create(image: "ghcr.io/azmxai/kosa8-android", kvm: true)
    assert_equal true, @fake.seen.last[:body]["kvm"]
  end

  def test_snapshot_clash_includes_mem_mb_and_kvm
    assert_raises(ArgumentError) { @cloud.sandboxes.create(snapshot: "snap_abcdefgh", kvm: true) }
    assert_raises(ArgumentError) { @cloud.sandboxes.create(snapshot: "snap_abcdefgh", cpus: 2, mem_mb: 4096) }
  end

  def test_background_timeout
    box = Kosa8::CloudSandbox.new(@cloud, { "id" => "sbx_1", "state" => "running" })
    box.exec_background("make", timeout_s: 7200)
    assert_equal 7200, @fake.seen.last[:body]["timeout_s"]
    assert_raises(ArgumentError) { box.exec_background("make", timeout_s: 86_401) }
  end

  def test_exec_truncation_fields
    box = Kosa8::CloudSandbox.new(@cloud, { "id" => "sbx_1", "state" => "running" })
    r = box.exec("yes | head -c 2097157")
    assert_equal true, r.stdout_truncated
    assert_equal false, r.stderr_truncated
    assert_equal 2_097_157, r.stdout_bytes
  end
end
