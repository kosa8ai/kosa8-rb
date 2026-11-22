# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift __dir__
require "minitest/autorun"
require "kosa8"
require "fake_cloud"

# What an API error says and exposes: the server's sentence first, then its
# status, code, wait and request id; the fields to act on in code.
class CloudErrorsTest < Minitest::Test
  def fake(status, body, headers = {})
    @fake = FakeCloud.new { |_req| [status, body, headers] }
    @fake.cloud(retry_policy: Kosa8::RetryPolicy::NONE)
  end

  def teardown
    @fake&.close
  end

  def test_no_capacity_shows_message_wait_and_request_id
    cloud = fake(503, { "error" => "no_capacity", "message" => "no capacity: fork fewer or retry in 2 s",
                        "retryable" => true, "retry_after_s" => 10, "failure_class" => "infra" },
                 "Retry-After" => "7", "cf-ray" => "a5e77ddee9ef8120-BOS")
    e = assert_raises(Kosa8::ApiError) { cloud.sandboxes.create }
    assert_equal "no capacity: fork fewer or retry in 2 s [HTTP 503 no_capacity; retry in 7 s; request a5e77ddee9ef8120-BOS]",
                 e.message
    assert_equal "no capacity: fork fewer or retry in 2 s", e.daemon_message
    assert_equal "no_capacity", e.code
    assert_equal 503, e.status
    assert_equal 7.0, e.retry_after, "the Retry-After header wins over the body"
    assert_equal 7.0, e.retry_after_s
    assert e.retryable?
    assert_equal "a5e77ddee9ef8120-BOS", e.request_id
  end

  def test_x_request_id_wins_over_cf_ray
    cloud = fake(500, { "error" => "internal", "message" => "boom" }, "X-Request-Id" => "req_1", "cf-ray" => "ray_1")
    e = assert_raises(Kosa8::ApiError) { cloud.me }
    assert_equal "req_1", e.request_id
  end

  def test_template_building_reads_retry_after_s_from_the_body
    cloud = fake(409, { "error" => "template_building", "message" => "the environment is being built; ready in about 40 s",
                        "eta_s" => 40, "retry_after_s" => 10, "failure_class" => "quota", "retryable" => true })
    e = assert_raises(Kosa8::ConflictError) { cloud.sandboxes.create(template: "swe/x") }
    assert_equal "template_building", e.code
    assert_equal 409, e.status
    assert_equal 10.0, e.retry_after_s
    assert e.retryable?
    assert_equal 40, e.body["eta_s"]
    assert_includes e.message, "ready in about 40 s [HTTP 409 template_building; retry in 10 s]"
    assert_nil e.request_id
  end

  def test_payment_required_names_the_upgrade_url
    cloud = fake(402, { "error" => "payment_required", "message" => "add a payment method to start running work",
                        "upgrade_url" => "https://app.kosa8.com/app#billing", "agent_message" => "stop and tell the person" })
    e = assert_raises(Kosa8::PaymentRequiredError) { cloud.sandboxes.create }
    assert_equal "add a payment method to start running work " \
                 "[HTTP 402 payment_required; upgrade: https://app.kosa8.com/app#billing]", e.message
    assert_equal "https://app.kosa8.com/app#billing", e.upgrade_url
    assert_equal "stop and tell the person", e.agent_message
    refute e.retryable?
  end

  def test_upgrade_url_not_repeated_when_the_sentence_has_it
    cloud = fake(402, { "error" => "plan_required", "message" => "pick a plan at https://app.kosa8.com/p",
                        "upgrade_url" => "https://app.kosa8.com/p" })
    e = assert_raises(Kosa8::PaymentRequiredError) { cloud.sandboxes.create }
    assert_equal "pick a plan at https://app.kosa8.com/p [HTTP 402 plan_required]", e.message
  end

  def test_unauthorized_says_where_to_get_a_key
    cloud = fake(401, { "error" => "unauthorized", "message" => "API key is unknown, revoked or expired",
                        "failure_class" => "client", "retryable" => false })
    e = assert_raises(Kosa8::AuthError) { cloud.me }
    assert e.message.start_with?("API key is unknown, revoked or expired [HTTP 401 unauthorized; check KOSA8_API_KEY")
    assert_includes e.message, "https://app.kosa8.com/app#keys"
    refute_includes e.message, FakeCloud::KEY
  end

  def test_not_available_is_not_retryable
    cloud = fake(501, { "error" => "not_available", "message" => "background commands are not available on this sandbox's host yet" })
    e = assert_raises(Kosa8::UnsupportedError) { cloud.me }
    assert_equal "not_available", e.code
    refute e.retryable?
    assert_equal "infra", e.failure_class
    assert_equal "background commands are not available on this sandbox's host yet [HTTP 501 not_available]", e.message
  end

  def test_missing_or_wrong_key_says_what_to_do
    e = assert_raises(Kosa8::Error) { Kosa8::Cloud.new(env: {}) }
    assert_includes e.message, "set KOSA8_API_KEY or pass api_key:"
    assert_includes e.message, "https://app.kosa8.com/app#keys"
    e = assert_raises(Kosa8::Error) { Kosa8::Cloud.new(api_key: "sk-other", env: {}) }
    assert_includes e.message, "https://app.kosa8.com/app#keys"
    assert_nil e.status
    assert_nil e.request_id
  end

  def test_timeout_and_connection_failures_say_what_to_do
    slow = ->(*) { raise Net::ReadTimeout }
    e = assert_raises(Kosa8::TimeoutError) do
      Kosa8::Cloud.new(api_key: FakeCloud::KEY, env: {}, transport: slow, retry_policy: Kosa8::RetryPolicy::NONE).me
    end
    assert_includes e.message, "GET /v1/me"
    assert_includes e.message, "longer timeout:"
    assert e.retryable?

    boom = ->(*) { raise Errno::ECONNREFUSED, "connect(2)" }
    e = assert_raises(Kosa8::ConnectionError) do
      Kosa8::Cloud.new(api_key: FakeCloud::KEY, env: {}, transport: boom, retry_policy: Kosa8::RetryPolicy::NONE).me
    end
    assert_includes e.message, "check the network connection and KOSA8_CLOUD_URL"
  end
end
