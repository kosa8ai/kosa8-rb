# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift __dir__
require "minitest/autorun"
require "tmpdir"
require "json"
require "kosa8"
require "fake_cloud"

# A signed-in CLI (`kosa8 login`) is enough: with no KOSA8_API_KEY the key and
# address come from ~/.kosa8/cloud.json. A 429 starter_limit is a payment error.
class LoginFallbackTest < Minitest::Test
  def home_with(creds)
    d = Dir.mktmpdir
    Dir.mkdir(File.join(d, ".kosa8"))
    File.write(File.join(d, ".kosa8", "cloud.json"), creds.is_a?(String) ? creds : JSON.dump(creds)) if creds
    d
  end

  def test_uses_cloud_json
    home = home_with("key" => "k8c_live_fromlogin", "api_url" => "http://localhost:8787")
    c = Kosa8::Cloud.new(env: { "HOME" => home })
    assert_equal "http://localhost:8787", c.base_url
    assert_equal "k8c_live_fromlogin", c.instance_variable_get(:@key)
  end

  def test_env_key_wins_and_skips_saved_url
    home = home_with("key" => "k8c_live_fromlogin", "api_url" => "http://localhost:8787")
    c = Kosa8::Cloud.new(env: { "HOME" => home, "KOSA8_API_KEY" => "k8c_live_env" })
    assert_equal "k8c_live_env", c.instance_variable_get(:@key)
    assert_equal "https://api.kosa8.com", c.base_url
  end

  def test_no_login_names_kosa8_login
    [nil, "not json", { "org_id" => "x" }].each do |creds|
      e = assert_raises(Kosa8::Error) { Kosa8::Cloud.new(env: { "HOME" => home_with(creds) }) }
      assert_match(/kosa8 login/, e.message)
    end
  end

  def test_starter_limit_429_is_payment_required
    fake = FakeCloud.new { |_req| [429, { "error" => "starter_limit", "message" => "Starter runs 2 sandboxes at once" }, {}] }
    cloud = fake.cloud(retry_policy: Kosa8::RetryPolicy::NONE)
    e = assert_raises(Kosa8::PaymentRequiredError) { cloud.sandboxes.create }
    assert_kind_of Kosa8::PlanLimitError, e
    assert(Kosa8::RateLimitError === e, "still rescued as RateLimitError")
    refute e.retryable? if e.respond_to?(:retryable?)
  ensure
    fake&.close
  end

  def test_plain_429_is_rate_limit_only
    fake = FakeCloud.new { |_req| [429, { "error" => "rate_limited", "message" => "slow down" }, {}] }
    cloud = fake.cloud(retry_policy: Kosa8::RetryPolicy::NONE)
    e = assert_raises(Kosa8::RateLimitError) { cloud.sandboxes.create }
    refute_kind_of Kosa8::PaymentRequiredError, e
  ensure
    fake&.close
  end
end
