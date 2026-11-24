# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift __dir__
require "minitest/autorun"
require "kosa8"
require "fake_cloud"

# The 402 / 429 / 504 contract fields of the API's Error schema, readable
# off the raised error (not only off e.body).
class ErrorContractTest < Minitest::Test
  def raised(status, body)
    @fake = FakeCloud.new { |_req| [status, body] }
    cloud = @fake.cloud(retry_policy: Kosa8::RetryPolicy::NONE)
    yield cloud
    flunk "no error raised"
  rescue Kosa8::Error => e
    e
  end

  def teardown
    @fake&.close
  end

  def test_429_quota_exceeded_has_agent_message_and_request_url
    e = raised(429, { "error" => "quota_exceeded", "message" => "at your running limit",
                      "agent_message" => "Tell your person: raise the limit.",
                      "request_url" => "https://app.kosa8.com/app#limits", "failure_class" => "quota",
                      "retryable" => false }) { |c| c.sandboxes.create }
    assert_kind_of Kosa8::RateLimitError, e
    assert_equal "quota_exceeded", e.code
    assert_equal "Tell your person: raise the limit.", e.agent_message
    assert_equal "https://app.kosa8.com/app#limits", e.request_url
    refute e.retryable?
  end

  def test_402_plan_limit_fields
    opts = [{ "kind" => "pack", "addon" => "running-10", "label" => "10 more", "monthly_usd" => 20, "url" => "https://x/p" },
            { "kind" => "upgrade", "plan" => "team", "monthly_usd" => 99, "url" => "https://x/u" }]
    e = raised(402, { "error" => "plan_limit", "message" => "the plan's running limit", "limit_name" => "running",
                      "limit" => 5, "used" => 5, "plan" => "starter", "next_plan" => "team", "options" => opts,
                      "pack_url" => "https://x/p", "upgrade_url" => "https://x/u",
                      "agent_message" => "Relay this." }) { |c| c.sandboxes.create }
    assert_kind_of Kosa8::PaymentRequiredError, e
    assert_equal "running", e.limit_name
    assert_equal 5, e.limit
    assert_equal 5, e.used
    assert_equal "starter", e.plan
    assert_equal "team", e.next_plan
    assert_equal opts, e.options
    assert_equal "https://x/p", e.pack_url
    assert_equal "https://x/u", e.upgrade_url
    assert_equal "Relay this.", e.agent_message
    assert_equal "quota", e.failure_class
  end

  def test_402_plan_feature
    e = raised(402, { "error" => "plan_feature", "message" => "no GPUs on this plan", "feature" => "gpu",
                      "plan" => "starter", "next_plan" => nil }) { |c| c.sandboxes.create }
    assert_equal "gpu", e.feature
    assert_nil e.next_plan
    assert_equal [], e.options
    assert_nil e.limit
  end

  def test_504_exec_timeout_keeps_output_so_far
    e = raised(504, { "error" => "exec_timeout", "message" => "the command ran longer than its timeout_s of 5 s",
                      "limit_s" => 5, "timeout_s" => 5, "stdout" => "partial\n", "stderr" => "warn\n" }) do |c|
      box = Kosa8::CloudSandbox.new(c, { "id" => "sbx_1", "state" => "running" })
      box.exec("sleep 10", timeout_s: 5)
    end
    assert_kind_of Kosa8::ExecTimeoutError, e
    assert_equal "partial\n", e.stdout
    assert_equal "warn\n", e.stderr
    assert_equal 5, e.limit_s
  end

  def test_fields_nil_without_body
    e = raised(500, "oops") { |c| c.me }
    assert_nil e.agent_message
    assert_nil e.request_url
    assert_equal [], e.options
  end
end
