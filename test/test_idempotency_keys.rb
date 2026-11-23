# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "json"
require "minitest/autorun"
require "kosa8"

# The SDK's own Idempotency-Key is renewed after a 5xx (each retry of a
# server-side failure is a new attempt), kept after no answer, a 429 or a
# 409, and a key the caller passed is never changed.
class IdempotencyKeysTest < Minitest::Test
  HOST_FAILED = [502, { "error" => "host_failed", "message" => "boot failed", "failure_class" => "infra",
                        "retryable" => true }].freeze
  RESTARTING = [503, { "error" => "host_restarting", "message" => "restarting" }, { "Retry-After" => "2" }].freeze
  LIMITED = [429, { "error" => "rate_limited", "message" => "slow down" }, { "Retry-After" => "1" }].freeze
  IN_PROGRESS = [409, { "error" => "idempotency_in_progress", "message" => "running", "retry_after_s" => 1 }].freeze
  CREATED = [201, { "sandbox" => { "id" => "sbx_1", "state" => "running" } }].freeze
  DROPPED = :dropped

  # A fake transport that gives its answers in turn (DROPPED raises: no
  # answer) and keeps every Idempotency-Key.
  def script(*answers)
    @keys = []
    @waits = []
    transport = lambda do |_method, _url, headers, _payload, _timeout|
      @keys << headers["Idempotency-Key"]
      a = answers.shift
      raise Errno::ECONNRESET, "connection reset by peer" if a == DROPPED

      [a[0], JSON.generate(a[1]), a[2] || {}]
    end
    Kosa8::Cloud.new(api_key: "k8c_live_testkey", env: {}, transport: transport, sleeper: ->(s) { @waits << s })
  end

  def test_a_502_retry_gets_a_new_key
    script(HOST_FAILED, CREATED).sandboxes.create(wait: false)
    assert_equal 2, @keys.size
    @keys.each { |k| assert_match(/\A[0-9a-f-]{36}\z/, k) }
    refute_equal @keys[0], @keys[1]
  end

  def test_a_503_retry_gets_a_new_key_after_its_retry_after
    script(RESTARTING, CREATED).sandboxes.create(wait: false)
    refute_equal @keys[0], @keys[1]
    assert_operator @waits.first, :>=, 2
  end

  def test_no_answer_keeps_the_key
    script(DROPPED, CREATED).sandboxes.create(wait: false)
    assert_equal 2, @keys.size
    refute_nil @keys[0]
    assert_equal @keys[0], @keys[1]
  end

  def test_429_and_409_in_progress_keep_the_key
    script(LIMITED, IN_PROGRESS, CREATED).sandboxes.create(wait: false)
    assert_equal 3, @keys.size
    assert_equal 1, @keys.uniq.size
  end

  def test_the_callers_key_is_never_changed
    script(HOST_FAILED, RESTARTING, CREATED).sandboxes.create(wait: false, idempotency_key: "caller-key")
    assert_equal ["caller-key"] * 3, @keys
  end

  def test_jobs_and_rollouts_renew_too
    c = script(HOST_FAILED, [202, { "job_id" => "job_1" }])
    c.request("POST", "/v1/jobs", {})
    refute_equal @keys[0], @keys[1]
    c = script(HOST_FAILED, [200, { "recorded" => 1 }])
    c.request("POST", "/v1/rl/runs/run_1/rollouts", { "rollouts" => [] })
    refute_equal @keys[0], @keys[1]
  end

  def test_renews_idempotency_key
    assert Kosa8::Cloud.renews_idempotency_key?(Kosa8::ApiError.new("x", status: 502, code: "host_failed"))
    assert Kosa8::Cloud.renews_idempotency_key?(Kosa8::ApiError.new("x", status: 503, code: "no_capacity"))
    refute Kosa8::Cloud.renews_idempotency_key?(Kosa8::RateLimitError.new("x", status: 429))
    refute Kosa8::Cloud.renews_idempotency_key?(Kosa8::ConflictError.new("x", status: 409, code: "idempotency_in_progress"))
    refute Kosa8::Cloud.renews_idempotency_key?(Kosa8::ConnectionError.new("no answer"))
  end
end
