# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift __dir__
require "json"
require "minitest/autorun"
require "tmpdir"
require "kosa8"
require "fake_cloud"

# The RL / fan-out API against a fake kosa8 Cloud on a local socket.
class CloudRLTest < Minitest::Test
  def setup
    @fakes = []
  end

  def teardown
    @fakes.each(&:close)
  end

  def fake(&handler)
    f = FakeCloud.new(&handler)
    @fakes << f
    f
  end

  def sbx(id = "sbx_1", over = {})
    { "id" => id, "state" => "running" }.merge(over)
  end

  # --- failures -------------------------------------------------------------

  def test_failure_of_follows_the_server
    {
      [200, nil] => ["ok", false], [504, "exec_timeout"] => ["timeout", false], [502, "host_timeout"] => ["timeout", true],
      [429, "rate_limited"] => ["quota", true], [429, "quota_exceeded"] => ["quota", false], [429, nil] => ["quota", true],
      [402, "payment_required"] => ["quota", false], [423, "org_frozen"] => ["quota", false],
      [400, "running_limit"] => ["quota", false], [501, "not_available"] => ["infra", false], [501, nil] => ["infra", false],
      [503, "no_capacity"] => ["infra", true], [500, nil] => ["infra", true], [409, "starting"] => ["infra", true],
      [404, "not_found"] => ["client", false], [422, nil] => ["client", false]
    }.each { |(st, code), want| assert_equal want, Kosa8.failure_of(st, code), [st, code].inspect }
    assert_equal ["ok", false], Kosa8.exec_failure(0)
    assert_equal ["exit_nonzero", false], Kosa8.exec_failure(2)
    assert_equal ["infra", true], Kosa8.exec_failure(nil)
  end

  def test_classify_failure
    assert_equal ["error", false], Kosa8.classify_failure(RuntimeError.new("bug"))
    assert_equal ["infra", true], Kosa8.classify_failure(Errno::ECONNRESET.new)
    assert_equal ["infra", true], Kosa8.classify_failure(Kosa8::ConnectionError.new("x"))
    assert_equal ["infra", true], Kosa8.classify_failure(Kosa8::TimeoutError.new("x"))
    assert_equal ["timeout", false], Kosa8.classify_failure(Kosa8::ExecTimeoutError.new("x", status: 504))
    assert_equal ["error", false], Kosa8.classify_failure(Kosa8::Error.new("x"))
    assert_equal ["client", true], Kosa8.classify_failure(Kosa8::ConflictError.new("x", status: 409, code: "idempotency_in_progress"))
    e = Kosa8::ApiError.new("x", status: 400, body: { "failure_class" => "quota", "retryable" => true })
    assert_equal ["quota", true], Kosa8.classify_failure(e)
    assert_equal "quota", e.failure_class
    assert e.retryable?
    e = Kosa8::ApiError.new("x", status: 500, body: { "failure_class" => "infra" })
    assert_equal ["infra", true], Kosa8.classify_failure(e)
  end

  def test_errors_carry_class_and_retry_after
    answers = [
      [503, { "error" => "no_capacity", "message" => "no room", "failure_class" => "infra", "retryable" => true, "retry_after_s" => 4 }],
      [409, { "error" => "idempotency_in_progress", "message" => "still running", "retry_after_s" => 2 }],
      [429, { "error" => "rate_limited", "message" => "slow" }, { "Retry-After" => (Time.now + 30).httpdate }]
    ]
    f = fake { answers.shift }
    c = f.cloud(retry_policy: Kosa8::RetryPolicy::NONE)
    e = assert_raises(Kosa8::ApiError) { c.me }
    assert_equal ["infra", true, 4.0, "no_capacity"], [e.failure_class, e.retryable?, e.retry_after, e.code]
    e = assert_raises(Kosa8::ConflictError) { c.me }
    assert_equal [true, 2.0], [e.retryable?, e.retry_after]
    e = assert_raises(Kosa8::RateLimitError) { c.me }
    assert_in_delta 30, e.retry_after, 2
    assert_equal ["quota", true], Kosa8.classify_failure(e)
  end

  def test_exec_result_has_failure_class
    answers = [[200, { "exit" => 0, "stdout" => "", "stderr" => "" }], [200, { "exit" => 3, "stdout" => "", "stderr" => "" }],
               [200, { "exit" => nil, "stdout" => "", "stderr" => "", "failure_class" => "infra", "retryable" => true }]]
    f = fake { answers.shift }
    box = Kosa8::CloudSandbox.new(f.cloud, sbx)
    r = box.exec("true")
    assert_equal ["ok", false], [r.failure_class, r.retryable?]
    r = box.exec("false")
    assert_equal ["exit_nonzero", false], [r.failure_class, r.retryable]
    r = box.exec("x")
    assert_equal ["infra", true], [r.failure_class, r.retryable?]
  end

  # --- retries and Idempotency-Key -------------------------------------------

  def test_retry_policy_delay
    p = Kosa8::RetryPolicy.new(attempts: 5, base_s: 1, max_s: 4, rng: Random.new(1))
    20.times do
      assert_operator p.delay(nil, 1), :<=, 1
      assert_operator p.delay(nil, 4), :<=, 4
    end
    e = Kosa8::RateLimitError.new("x", status: 429)
    e.retry_after = 9
    assert_operator p.delay(e, 1), :>=, 9
    e.retry_after = 600
    assert_equal 60, p.delay(e, 1)
    refute p.retry?(Kosa8::ApiError.new("x", status: 500), 5)
    assert p.retry?(Kosa8::ApiError.new("x", status: 500), 4)
    refute p.retry?(Kosa8::BadRequestError.new("x", status: 400), 1)
    assert_raises(ArgumentError) { Kosa8::RetryPolicy.new(attempts: 0) }
    assert_equal 1, Kosa8::RetryPolicy::NONE.attempts
    n = 0
    assert_equal :ok, Kosa8.with_retry(p, sleeper: ->(_) {}) { (n += 1) < 3 ? raise(Kosa8::ConnectionError, "x") : :ok }
    assert_equal 3, n
  end

  def test_retries_where_safe_and_waits_retry_after
    waits = []
    answers = Hash.new { |h, k| h[k] = [] }
    answers["GET /v1/me"] = [[503, { "error" => "host_busy" }], [200, { "ok" => true }]]
    answers["POST /v1/sandboxes/sbx_1/exec"] = [[503, { "error" => "host_failed" }], [200, { "exit" => 0 }]]
    answers["GET /v1/usage"] = [[429, { "error" => "rate_limited" }, { "Retry-After" => "7" }], [200, { "u" => 1 }]]
    answers["GET /v1/templates"] = [[400, { "error" => "bad" }], [200, {}]]
    answers["POST /v1/sandboxes/heartbeat"] = [[502, { "error" => "internal" }], [200, { "extended" => 3 }]]
    f = fake { |r| answers["#{r[:method]} #{r[:path]}"].shift || [500, nil] }
    c = Kosa8::Cloud.new(api_key: FakeCloud::KEY, base_url: f.url, env: {}, sleeper: ->(s) { waits << s })
    assert_equal({ "ok" => true }, c.me)
    assert_equal 2, f.calls("GET", "/v1/me").size
    e = assert_raises(Kosa8::ApiError) { Kosa8::CloudSandbox.new(c, sbx).exec("x") }
    assert_equal "host_failed", e.code
    assert_equal 1, f.calls("POST", "/v1/sandboxes/sbx_1/exec").size, "an exec is not sent twice"
    assert_equal({ "u" => 1 }, c.usage)
    assert_operator waits.last, :>=, 7
    assert_raises(Kosa8::BadRequestError) { c.templates }
    assert_equal 1, f.calls("GET", "/v1/templates").size
    assert_equal 3, c.sandboxes.heartbeat(run_id: "r1")
    assert_equal 2, f.calls("POST", "/v1/sandboxes/heartbeat").size
  end

  def test_post_retried_on_429_only
    answers = [[429, { "error" => "slow_down" }], [200, { "ok" => true }]]
    f = fake { answers.shift }
    c = f.cloud
    assert_equal({ "ok" => true }, c.request("POST", "/v1/functions/x/invoke", {}))
    assert_equal 2, f.seen.size
  end

  def test_create_retries_with_the_same_idempotency_key
    answers = [[503, { "error" => "no_capacity" }], [201, { "sandbox" => sbx }]]
    f = fake { answers.shift }
    c = f.cloud
    box = c.sandboxes.create(template: "python", lease_s: 600)
    assert_equal "sbx_1", box.id
    keys = f.seen.map { |s| s[:headers]["idempotency-key"] }
    assert_equal 2, keys.size
    assert_match(/\A[0-9a-f-]{36}\z/, keys[0])
    assert_equal keys[0], keys[1]
    assert_equal({ "template" => "python", "lease_s" => 600 }, f.seen[0][:body])

    answers.replace([[201, { "sandbox" => sbx }]])
    c.sandboxes.create(idempotency_key: "my-key-1", run_id: "run_a", labels: { "t" => "1" })
    assert_equal "my-key-1", f.seen.last[:headers]["idempotency-key"]
    assert_equal({ "labels" => { "t" => "1", "kosa8.run" => "run_a" } }, f.seen.last[:body])

    n = f.seen.size
    assert_raises(ArgumentError) { c.sandboxes.create(idempotency_key: "has space") }
    assert_raises(ArgumentError) { c.sandboxes.create(idempotency_key: "x" * 256) }
    assert_raises(ArgumentError) { c.sandboxes.create(lease_s: 30) }
    assert_raises(ArgumentError) { c.sandboxes.create(lease_s: 600, ttl_s: 600) }
    assert_raises(ArgumentError) { c.sandboxes.create(run_id: "-bad") }
    assert_equal n, f.seen.size
    assert Kosa8::Cloud.keyed?("POST", "/v1/sandboxes/sbx_9/grade")
    refute Kosa8::Cloud.keyed?("POST", "/v1/sandboxes/sbx_9/exec")
    refute Kosa8::Cloud.keyed?("GET", "/v1/sandboxes")
  end

  def test_unkeyed_post_is_not_given_a_key
    f = fake { [200, {}] }
    f.cloud.request("POST", "/v1/sandboxes/sbx_1/exec", { "cmd" => ["true"] })
    assert_nil f.seen[0][:headers]["idempotency-key"]
  end

  # --- batch, fork, heartbeat, drain ------------------------------------------

  def test_create_many
    f = fake do
      [200, { "sandboxes" => [sbx("sbx_a"), sbx("sbx_b")], "requested" => 3, "created" => 2, "run_id" => "r1",
              "failed" => [{ "index" => 2, "code" => "running_limit", "message" => "past it", "failure_class" => "quota",
                             "retryable" => false }] }]
    end
    c = f.cloud
    b = c.sandboxes.create_many(3, template: "python", size: "2x4", env: { "A" => "1" }, labels: { "x" => "y" },
                                   run_id: "r1", lease_s: 900, prefix: "roll", partial_ok: true, idempotency_key: "b-1")
    assert_kind_of Kosa8::SandboxBatch, b
    assert_kind_of Array, b
    assert_equal %w[sbx_a sbx_b], b.map(&:id)
    assert_equal [2, 3, "r1"], [b.created, b.requested, b.run_id]
    refute b.complete?
    assert_equal "running_limit", b.failed[0]["code"]
    req = f.seen[0]
    assert_equal "/v1/sandboxes/batch", req[:path]
    assert_equal "b-1", req[:headers]["idempotency-key"]
    assert_equal({ "count" => 3, "template" => "python", "size" => "2x4", "env" => { "A" => "1" }, "labels" => { "x" => "y" },
                   "run_id" => "r1", "lease_s" => 900, "prefix" => "roll", "partial_ok" => true }, req[:body])
    c.sandboxes.create_many(1)
    assert_equal({ "count" => 1 }, f.seen.last[:body])
    refute_nil f.seen.last[:headers]["idempotency-key"]

    n = f.seen.size
    assert_raises(ArgumentError) { c.sandboxes.create_many(0) }
    assert_raises(ArgumentError) { c.sandboxes.create_many(1001) }
    assert_raises(ArgumentError) { c.sandboxes.create_many(2, name: "x") }
    assert_raises(ArgumentError) { c.sandboxes.create_many(2, prefix: "-x") }
    assert_raises(ArgumentError) { c.sandboxes.create_many(2, partial_ok: "yes") }
    assert_raises(ArgumentError) { c.sandboxes.create_many(2, bogus: 1) }
    assert_raises(ArgumentError) { c.sandboxes.create_many(2, lease_s: 600, ttl_s: 600) }
    assert_equal n, f.seen.size
  end

  def test_batch_that_made_none_raises_the_refusal
    f = fake do
      [429, { "error" => "quota_exceeded", "message" => "over", "requested" => 5, "created" => 0, "failed" => [] }]
    end
    e = assert_raises(Kosa8::RateLimitError) { f.cloud.sandboxes.create_many(5) }
    assert_equal ["quota", false], [e.failure_class, e.retryable?]
    assert_equal 0, e.body["created"]
    assert_equal 1, f.seen.size, "a used-up quota is not retried"
  end

  def test_fork_options
    f = fake do |r|
      n = r[:body]["n"]
      [201, { "parent" => "sbx_1", "sandboxes" => (1..[n, 2].min).map { |i| sbx("sbx_f#{i}") }, "requested" => n,
              "created" => [n, 2].min, "failed" => n > 2 ? [{ "index" => 2, "code" => "no_capacity", "failure_class" => "infra", "retryable" => true }] : [] }]
    end
    box = Kosa8::CloudSandbox.new(f.cloud, sbx)
    kids = box.fork(1000, labels: { "k" => "v" }, run_id: "r2", lease_s: 120, prefix: "p", partial_ok: true,
                          idempotency_key: "fk-1")
    assert_equal %w[sbx_f1 sbx_f2], kids.map(&:id)
    assert_equal "no_capacity", kids.failed[0]["code"]
    assert_equal({ "n" => 1000, "labels" => { "k" => "v" }, "run_id" => "r2", "lease_s" => 120, "prefix" => "p",
                   "partial_ok" => true }, f.seen[0][:body])
    assert_equal "fk-1", f.seen[0][:headers]["idempotency-key"]
    box.fork
    assert_equal({ "n" => 1 }, f.seen.last[:body])
    refute_nil f.seen.last[:headers]["idempotency-key"]
    assert_raises(ArgumentError) { box.fork(1001) }
    assert_raises(ArgumentError) { box.fork(2, lease_s: 59) }
    assert_raises(ArgumentError) { box.fork(2, labels: (1..16).map { |i| ["l#{i}", "v"] }.to_h, run_id: "r") }
  end

  def test_heartbeat_and_drain
    drains = [{ "deleted" => 1000, "ids" => ["a"], "failed" => [], "more" => true },
              { "deleted" => 3, "ids" => ["b"], "failed" => [{ "id" => "c", "code" => "host_failed" }], "more" => false }]
    f = fake do |r|
      case r[:path]
      when "/v1/sandboxes/heartbeat" then [200, { "extended" => 4, "at" => 1 }]
      when "/v1/sandboxes/drain" then [200, drains.shift || { "deleted" => 0, "more" => true }]
      end
    end
    c = f.cloud
    assert_equal 4, c.sandboxes.heartbeat(run_id: "r1", extend_s: 300)
    assert_equal({ "run_id" => "r1", "extend_s" => 300 }, f.seen.last[:body])
    box = Kosa8::CloudSandbox.new(c, sbx)
    assert_equal 4, box.heartbeat
    assert_equal({ "ids" => ["sbx_1"] }, f.seen.last[:body])
    c.sandboxes.heartbeat(labels: { "a" => "b" }, ids: [box, "sbx_2"])
    assert_equal({ "labels" => { "a" => "b" }, "ids" => %w[sbx_1 sbx_2] }, f.seen.last[:body])

    out = c.sandboxes.drain(run_id: "r1")
    assert_equal 1003, out["deleted"]
    assert_equal %w[a b], out["ids"]
    assert_equal "c", out["failed"][0]["id"]
    assert_equal 2, f.calls("POST", "/v1/sandboxes/drain").size
    out = c.sandboxes.drain(ids: ["x"])
    assert_equal 0, out["deleted"]
    assert_equal 3, f.calls("POST", "/v1/sandboxes/drain").size, "stops when a call deleted none"

    n = f.seen.size
    assert_raises(ArgumentError) { c.sandboxes.drain }
    assert_raises(ArgumentError) { c.sandboxes.heartbeat }
    assert_raises(ArgumentError) { c.sandboxes.heartbeat(run_id: "r", extend_s: 10) }
    assert_raises(ArgumentError) { c.sandboxes.drain(ids: []) }
    assert_equal n, f.seen.size
  end

  # --- grade ------------------------------------------------------------------

  def test_grade
    answer = { "reward" => 0.5, "metrics" => { "pass" => 3 }, "reward_from" => "json", "exit" => 0, "stdout" => "{\"reward\":0.5}\n",
               "stderr" => "", "failure_class" => "ok", "retryable" => false, "ms" => 900, "grader_id" => "sbx_g",
               "kept" => false, "sandbox_id" => "sbx_1", "run_id" => "r1", "recorded" => true }
    answers = [[502, { "error" => "host_failed" }], [200, answer]]
    f = fake { answers.shift || [200, answer] }
    c = f.cloud
    g = Kosa8::CloudSandbox.new(c, sbx).grade(["pytest", "-q"], files: { "/grader/t.py" => "assert 1\n" }, timeout_s: 30,
                                                                env: { "B" => "2", "A" => "1" }, run_id: "r1",
                                                                rollout: { step: 3, group: 1, index: 0, meta: { "t" => "x" } })
    assert_kind_of Kosa8::GradeResult, g
    assert_equal [0.5, { "pass" => 3 }, "json", 0, "ok", "sbx_g", true, 900], [g.reward, g.metrics, g.reward_from, g.exit_code,
                                                                               g.failure_class, g.grader_id, g.recorded, g.ms]
    assert g.ok?
    assert_equal({ "cmd" => %w[pytest -q], "files" => { "/grader/t.py" => ["assert 1\n"].pack("m0") }, "timeout_s" => 30,
                   "env" => %w[A=1 B=2], "run_id" => "r1",
                   "rollout" => { "step" => 3, "group" => "1", "index" => 0, "meta" => { "t" => "x" } } }, f.seen[0][:body])
    assert_equal "/v1/sandboxes/sbx_1/grade", f.seen[0][:path]
    k = f.seen.map { |s| s[:headers]["idempotency-key"] }
    assert_equal 2, k.size
    assert_equal k[0], k[1], "the retry reuses the key"
    c.sandboxes.grade("sbx_9", "make test", keep: true, idempotency_key: "g1")
    assert_equal({ "cmd" => ["sh", "-c", "make test"], "keep" => true }, f.seen.last[:body])
    assert_equal "/v1/sandboxes/sbx_9/grade", f.seen.last[:path]
    assert_equal "g1", f.seen.last[:headers]["idempotency-key"]

    box = Kosa8::CloudSandbox.new(c, sbx)
    n = f.seen.size
    assert_raises(ArgumentError) { box.grade([]) }
    assert_raises(ArgumentError) { box.grade("x", timeout_s: 91) }
    assert_raises(ArgumentError) { box.grade("x", files: (0..64).map { |i| ["/f#{i}", "x"] }.to_h) }
    assert_raises(ArgumentError) { box.grade("x", files: { "/big" => "x" * (8 * 1024 * 1024 + 1) }) }
    assert_raises(ArgumentError) { box.grade("x", files: { "rel/path" => "x" }) }
    assert_raises(ArgumentError) { box.grade("x", files: { "/a/../b" => "x" }) }
    assert_equal n, f.seen.size
  end

  def test_grade_that_did_not_finish
    f = fake do
      [200, { "reward" => nil, "exit" => nil, "failure_class" => "timeout", "retryable" => false, "grader_id" => "g",
              "error" => "exec_timeout", "message" => "ran past 90 s" }]
    end
    g = f.cloud.sandboxes.grade("sbx_1", "sleep 100")
    assert_nil g.reward
    assert_equal ["timeout", "exec_timeout"], [g.failure_class, g.error]
    refute g.ok?
  end

  # --- fork_map -----------------------------------------------------------------

  # A fake that forks children and records deletes.
  def forking_fake(fail_forks: 0)
    seq = 0
    lock = Mutex.new
    deleted = []
    fails = fail_forks
    f = fake do |r|
      if r[:method] == "POST" && r[:path] == "/v1/sandboxes/sbx_base/fork"
        if fails.positive?
          fails -= 1
          next [409, { "error" => "secrets", "message" => "has secrets", "failure_class" => "client", "retryable" => false }]
        end
        n = r[:body]["n"]
        ids = lock.synchronize { (1..n).map { seq += 1; "sbx_k#{seq}" } }
        [201, { "sandboxes" => ids.map { |i| sbx(i) }, "requested" => n, "created" => n, "failed" => [] }]
      elsif r[:method] == "DELETE"
        lock.synchronize { deleted << r[:path].split("/").last }
        [200, { "ok" => true }]
      elsif r[:path] == "/v1/sandboxes/drain"
        lock.synchronize { deleted.concat(r[:body]["ids"] || []) }
        [200, { "deleted" => (r[:body]["ids"] || []).size, "ids" => r[:body]["ids"], "failed" => [], "more" => false }]
      else
        [404, { "error" => "not_found" }]
      end
    end
    [f, deleted]
  end

  def test_fork_map_runs_retries_and_cleans_up
    f, deleted = forking_fake
    c = f.cloud
    base = Kosa8::CloudSandbox.new(c, sbx("sbx_base"))
    tries = Hash.new(0)
    lock = Mutex.new
    results = base.fork_map([1, 2, 3, 4, 5], concurrency: 2, retries: 2, labels: { "job" => "j" }, run_id: "r", lease_s: 300) do |child, item|
      t = lock.synchronize { tries[item] += 1 }
      raise "bug in item 2" if item == 2
      raise Kosa8::ConnectionError, "host went away" if item == 3 && t == 1

      [child.id, item * 10]
    end
    assert_equal 5, results.size
    assert_equal [1, 2, 3, 4, 5], results.map(&:item)
    assert_equal [10, nil, 30, 40, 50], results.map { |r| r.value && r.value[1] }
    r2 = results[1]
    assert_equal ["error", 1], [r2.failure_class, r2.attempts]
    assert_match(/bug in item 2/, r2.error.message)
    refute r2.ok?
    assert_equal ["ok", 2], [results[2].failure_class, results[2].attempts]
    assert results[0].ok?
    assert_kind_of Integer, results[0].ms
    forked = f.calls("POST", "/v1/sandboxes/sbx_base/fork")
    assert_equal({ "n" => 2, "labels" => { "job" => "j" }, "run_id" => "r", "lease_s" => 300, "partial_ok" => true }, forked[0][:body])
    made = forked.sum { |r| r[:body]["n"] }
    assert_equal made, deleted.uniq.size, "every child deleted"
    assert_equal deleted.size, deleted.uniq.size, "none deleted twice"
  end

  def test_fork_map_cleans_up_on_interrupt
    f, deleted = forking_fake
    c = f.cloud
    base = Kosa8::CloudSandbox.new(c, sbx("sbx_base"))
    started = Queue.new
    assert_raises(Interrupt) do
      base.fork_map((1..6).to_a, concurrency: 3) do |_child, item|
        started << item
        raise Interrupt if item == 1

        sleep 0.3
        :done
      end
    end
    forked = f.calls("POST", "/v1/sandboxes/sbx_base/fork").sum { |r| r[:body]["n"] }
    assert_equal forked, deleted.uniq.size, "every child deleted after Ctrl-C"
  end

  def test_fork_map_timeout_and_a_failing_fork
    f, deleted = forking_fake(fail_forks: 2)
    c = f.cloud
    base = Kosa8::CloudSandbox.new(c, sbx("sbx_base"))
    results = base.fork_map(%w[slow], concurrency: 1, retries: 0, timeout_s: 0.2) { |_c, _i| sleep 3 }
    # The prefork was refused (409 secrets), so the worker forked its own and saw it.
    assert_equal "client", results[0].failure_class
    assert_kind_of Kosa8::ApiError, results[0].error
    results = base.fork_map(%w[slow], concurrency: 1, retries: 0, timeout_s: 0.2) { |_c, _i| sleep 3 }
    assert_equal "timeout", results[0].failure_class
    assert_kind_of Kosa8::ItemTimeoutError, results[0].error
    assert_includes deleted, results[0].sandbox_id
    assert_raises(ArgumentError) { base.fork_map([1]) }
    assert_raises(ArgumentError) { base.fork_map([1], retries: -1) { nil } }
    assert_raises(ArgumentError) { base.fork_map([1], concurrency: 0) { nil } }
    assert_equal [], c.fork_map(base, []) { nil }
  end

  # --- RL runs ---------------------------------------------------------------------

  def rl_fake(grades: nil)
    rows = []
    lock = Mutex.new
    seq = 0
    grades ||= []
    f = fake do |r|
      m = r[:method]
      p = r[:path]
      if m == "POST" && p == "/v1/rl/runs"
        [201, { "run" => { "id" => "run_1", "name" => r[:body]["name"], "status" => "running" } }]
      elsif m == "POST" && p == "/v1/rl/runs/run_1/rollouts"
        lock.synchronize { rows.concat(r[:body]["rollouts"]) }
        [200, { "recorded" => r[:body]["rollouts"].size, "ids" => [] }]
      elsif m == "PATCH" && p == "/v1/rl/runs/run_1"
        [200, { "run" => { "id" => "run_1", "status" => r[:body]["status"] } }]
      elsif m == "GET" && p == "/v1/rl/runs/run_1"
        [200, { "run" => { "id" => "run_1", "name" => "n" }, "summary" => { "rollouts" => 3 }, "recommendations" => [] }]
      elsif m == "GET" && p.start_with?("/v1/rl/runs/run_1/rollouts")
        [200, { "rollouts" => [{ "id" => "ro_1" }], "next_cursor" => nil, "q" => p }]
      elsif m == "GET" && p == "/v1/rl/runs/run_1/export?format=jsonl"
        [200, "{\"id\":\"ro_1\"}\n{\"id\":\"ro_2\"}\n"]
      elsif m == "GET" && p.start_with?("/v1/rl/runs")
        [200, { "runs" => [{ "id" => "run_1" }], "q" => p }]
      elsif p == "/v1/sandboxes/heartbeat"
        [200, { "extended" => 2 }]
      elsif p == "/v1/sandboxes/drain"
        [200, { "deleted" => 2, "ids" => %w[a b], "failed" => [], "more" => false }]
      elsif m == "POST" && p == "/v1/sandboxes/sbx_base/fork"
        n = r[:body]["n"]
        ids = lock.synchronize { (1..n).map { seq += 1; "sbx_k#{seq}" } }
        [201, { "sandboxes" => ids.map { |i| sbx(i) }, "requested" => n, "created" => n, "failed" => [] }]
      elsif m == "POST" && p == "/v1/sandboxes"
        id = lock.synchronize { seq += 1; "sbx_c#{seq}" }
        [201, { "sandbox" => sbx(id) }]
      elsif m == "POST" && p.end_with?("/grade")
        g = lock.synchronize { grades.shift }
        g ||= { "reward" => 1.0, "exit" => 0, "failure_class" => "ok", "grader_id" => "sbx_g", "recorded" => true, "run_id" => "run_1" }
        [200, g]
      elsif m == "DELETE"
        [200, { "ok" => true }]
      else
        [404, { "error" => "not_found", "message" => p }]
      end
    end
    [f, rows]
  end

  def test_run_lifecycle_and_batching
    f, rows = rl_fake
    c = f.cloud
    run = Kosa8::RL::Run.new(c, "grpo", project: "p", config: { "lr" => 1e-6 }, lease_s: 120, flush_every: 500, heartbeat_s: 0.05)
    run.start
    assert_equal "run_1", run.id
    assert run.open?
    assert_equal({ "name" => "grpo", "project" => "p", "config" => { "lr" => 1e-6 } }, f.seen[0][:body])
    assert_equal({ "run_id" => "run_1", "lease_s" => 120 }, c.run_defaults)
    run.record((1..1200).map { |i| { step: 0, index: i, reward: 1.0 } }, flush: false)
    assert_equal 1200, run.pending
    assert_equal 1200, run.flush
    sizes = f.calls("POST", "/v1/rl/runs/run_1/rollouts").map { |r| r[:body]["rollouts"].size }
    assert_equal [500, 500, 200], sizes
    assert_equal 1200, run.recorded
    assert_equal({ "step" => 0, "index" => 1, "reward" => 1.0 }, rows[0])
    # A create inside the run is labelled and leased.
    c.sandboxes.create
    assert_equal({ "lease_s" => 120, "labels" => { "kosa8.run" => "run_1" } }, f.calls("POST", "/v1/sandboxes").last[:body])
    sleep 0.25
    refute_empty f.calls("POST", "/v1/sandboxes/heartbeat"), "the lease heartbeats"
    assert_equal({ "run_id" => "run_1" }, f.calls("POST", "/v1/sandboxes/heartbeat")[0][:body])

    assert_equal 3, run.summary["summary"]["rollouts"]
    q = run.rollouts(step: 2, failure_class: "infra", limit: 10)
    assert_equal "/v1/rl/runs/run_1/rollouts?step=2&failure_class=infra&limit=10", q["q"]
    Dir.mktmpdir do |d|
      out = File.join(d, "r.jsonl")
      data = run.export(out)
      assert_equal 2, data.lines.size
      assert_equal data, File.binread(out)
    end
    assert_equal "/v1/rl/runs?project=p&status=running&limit=5", Kosa8::RL::Run.list(c, project: "p", status: "running", limit: 5) && f.seen.last[:path]
    assert_equal 2, run.drain["deleted"]

    run.record({ "step" => 1, "reward" => 0 })
    assert_equal 1, run.pending
    run.finish
    assert_equal 0, run.pending
    assert_equal "finished", run.status
    assert_equal({ "status" => "finished" }, f.calls("PATCH", "/v1/rl/runs/run_1").last[:body])
    assert_operator f.calls("POST", "/v1/sandboxes/drain").size, :>=, 2, "finish drains"
    assert_nil c.run_defaults
    run.finish # twice is fine
    assert_raises(ArgumentError) { run.finish("bogus") }
  end

  def test_run_flush_keeps_rows_on_error_and_open_block_fails_the_run
    answers = [[500, { "error" => "internal" }]]
    f = fake do |r|
      if r[:path] == "/v1/rl/runs" then [201, { "run" => { "id" => "run_9" } }]
      elsif r[:path].end_with?("/rollouts") then answers.shift || [200, { "recorded" => r[:body]["rollouts"].size }]
      elsif r[:method] == "PATCH" then [200, { "run" => { "id" => "run_9", "status" => r[:body]["status"] } }]
      else [200, { "extended" => 0, "deleted" => 0, "more" => false }]
      end
    end
    c = f.cloud
    run = nil
    assert_raises(RuntimeError) do
      Kosa8::RL::Run.open(c, "x", heartbeat_s: 60) do |r|
        run = r
        r.record([{ "reward" => 1 }, { "reward" => 0 }], flush: false)
        assert_raises(Kosa8::ApiError) { r.flush } # a POST of rollouts is not retried on a 5xx
        assert_equal 2, r.pending
        raise "trainer crashed"
      end
    end
    assert_equal "failed", run.status
    assert_equal 0, run.pending, "finish recorded the rest"
    assert_equal({ "status" => "failed" }, f.calls("PATCH", "/v1/rl/runs/run_9").last[:body])
    assert_equal 1, f.calls("POST", "/v1/sandboxes/drain").size
    assert_equal :v, Kosa8::RL::Run.open(c, "y", heartbeat_s: 60) { :v }
    assert_raises(ArgumentError) { Kosa8::RL::Run.new(c) }
    assert_raises(ArgumentError) { Kosa8::RL::Run.new(c, "x", flush_every: 501) }
    assert_raises(ArgumentError) { Kosa8::RL::Run.new(c, "x", lease_s: 10) }
    drains = f.calls("POST", "/v1/sandboxes/drain").size
    attached = Kosa8::RL::Run.attach(c, "run_old", drain_on_exit: false, heartbeat_s: 60).start
    assert_equal "run_old", attached.id
    attached.finish
    assert_equal drains, f.calls("POST", "/v1/sandboxes/drain").size, "drain_on_exit: false keeps the sandboxes"
  end

  def test_run_map_with_sealed_grading
    grades = [
      # The first grade did not finish on a host failure: graded again, with a new key.
      { "reward" => nil, "exit" => nil, "failure_class" => "infra", "retryable" => true, "grader_id" => "g0", "error" => "host_failed" }
    ]
    f, rows = rl_fake(grades: grades)
    c = f.cloud
    tasks = [{ "id" => "t1", "files" => { "/grader/a.py" => "x" } }, { "id" => "t2" }, { "id" => "t3" }]
    out = nil
    Kosa8::RL::Run.open(c, "m", heartbeat_s: 60) do |run|
      base = Kosa8::CloudSandbox.new(c, sbx("sbx_base"))
      lock = Mutex.new
      seen = Hash.new(0)
      out = run.map(base, tasks, grade_cmd: %w[python /grader/a.py], group_size: 2, concurrency: 2, retries: 1) do |_box, task|
        k = lock.synchronize { seen[task["id"]] += 1 }
        raise Kosa8::ApiError.new("host went", status: 503, code: "host_failed") if task["id"] == "t3"
        raise ArgumentError, "harness bug" if task["id"] == "t2" && k == 1

        "patch"
      end
    end
    assert_kind_of Kosa8::RL::Rollouts, out
    assert_equal 6, out.size
    assert_equal [0, 0, 1, 1, 2, 2], out.map(&:group)
    assert_equal [0, 1, 0, 1, 0, 1], out.map(&:index)
    t3 = out.select { |r| r.group == 2 }
    assert(t3.all? { |r| r.masked && r.reward.nil? && r.failure_class == "infra" && r.attempts == 2 })
    t2 = out.select { |r| r.group == 1 }
    assert_equal 1, t2.count { |r| r.failure_class == "error" && r.masked }
    t1 = out.select { |r| r.group.zero? }
    assert(t1.all? { |r| r.reward == 1.0 && !r.masked && r.recorded })
    assert_equal [1.0, 1.0], out.groups[0].map(&:reward)
    assert_in_delta 1.0, out.mean_reward
    assert_equal 3, out.mask.count(true)
    assert_equal 3, out.by_class["infra"] + out.by_class["error"]
    grade_calls = f.seen.select { |r| r[:path].end_with?("/grade") }
    assert_equal 4, grade_calls.size, "3 good grades plus the one that did not finish"
    assert_equal grade_calls.size, grade_calls.map { |r| r[:headers]["idempotency-key"] }.uniq.size
    gb = grade_calls[0][:body]
    assert_equal %w[python /grader/a.py], gb["cmd"]
    assert_equal "run_1", gb["run_id"]
    assert_equal "t1", gb["rollout"]["meta"]["task"]
    assert_equal 0, gb["rollout"]["step"]
    # Graded rollouts were recorded by kosa8; the failed ones by the SDK.
    assert_equal 3, rows.size
    assert(rows.all? { |r| r["meta"]["masked"] })
    err = rows.find { |r| r["meta"]["sdk_failure_class"] == "error" }
    assert_equal "client", err["failure_class"]
    # Every child deleted (forks made == deletes).
    made = f.calls("POST", "/v1/sandboxes/sbx_base/fork").sum { |r| r[:body]["n"] }
    deleted = f.seen.count { |r| r[:method] == "DELETE" }
    drained = f.calls("POST", "/v1/sandboxes/drain").size
    assert_operator deleted, :>=, made - 2 * drained
    fork_body = f.calls("POST", "/v1/sandboxes/sbx_base/fork")[0][:body]
    assert_equal "run_1", fork_body["run_id"]
    assert_equal 600, fork_body["lease_s"]
  end

  def test_run_map_rewards_from_solve_and_created_sandboxes
    f, rows = rl_fake
    c = f.cloud
    out = nil
    Kosa8::RL::Run.open(c, "m2", heartbeat_s: 60, lease_s: 300) do |run|
      out = run.map({ template: "python" }, [1, 2], concurrency: 2,
                                                    meta: ->(task, _o) { { "n" => task } }) do |_box, task|
        { "reward" => task / 2.0, "tokens" => 10, "metrics" => { "len" => 1 } }
      end
      assert_raises(ArgumentError) { run.map(nil, [1]) { 1 } }
      r = run.map(->(_t) { c.sandboxes.create }, [1], step: 7) { |_b, _t| "no reward" }
      assert_equal "error", r[0].failure_class
      assert_match(/no reward/, r[0].error)
      assert_equal 7, r[0].step
      r = run.map(Kosa8::CloudSandbox.new(c, sbx("sbx_base")), [1], reward: ->(_b, _t, o) { o.size }) { |_b, _t| "abc" }
      assert_equal 3.0, r[0].reward
      assert_raises(ArgumentError) { run.map(nil, [1], mask: ["nope"]) { 1 } }
      assert_raises(ArgumentError) { run.map(nil, [1]) }
    end
    assert_equal [0.5, 1.0], out.rewards
    assert_equal [0, 0], out.map(&:step)
    created = f.calls("POST", "/v1/sandboxes")
    assert_equal({ "template" => "python", "lease_s" => 300, "labels" => { "kosa8.run" => "run_1" } }, created[0][:body])
    row = rows.find { |r| r["reward"] == 0.5 }
    assert_equal [10, { "len" => 1 }, 1], [row["tokens"], row["meta"]["metrics"], row["meta"]["n"]]
    assert_raises(ArgumentError) { Kosa8::RL::Run.new(c, "z").map(nil, []) { 1 } }
  end

  def test_rollout_result_row_and_fit_meta
    r = Kosa8::RL::RolloutResult.new(group: 2, index: 1, step: 4, reward: nil, failure_class: "error", masked: true,
                                     metrics: {}, stdout: "x" * 5000, error: "boom", attempts: 3, meta: { "a" => 1 },
                                     duration_ms: 12)
    row = r.to_row
    assert_equal "2", row["group"]
    assert_equal "client", row["failure_class"]
    assert_equal 4096, row["stdout_tail"].size
    assert_equal({ "a" => 1, "masked" => true, "error" => "boom", "attempts" => 3, "sdk_failure_class" => "error" }, row["meta"])
    refute row.key?("reward")
    m = Kosa8::RL.fit_meta({ "big" => "x" * 9000, "small" => 1 })
    assert_equal({ "small" => 1, "truncated" => true }, m)
  end

  def test_lease
    f = fake { |r| r[:path].end_with?("heartbeat") ? [200, { "extended" => 1 }] : [200, { "deleted" => 1, "more" => false }] }
    c = f.cloud
    ticks = 0
    lease = Kosa8::RL::Lease.new(c, labels: { "a" => "b" }, lease_s: 60, interval_s: 0.05, on_tick: -> { ticks += 1 }).start
    sleep 0.2
    lease.close
    lease.close
    assert_operator lease.beats, :>=, 1
    assert_operator ticks, :>=, 2
    assert_equal({ "deleted" => 1, "ids" => [], "failed" => [] }, lease.drained)
    assert_equal({ "labels" => { "a" => "b" } }, f.calls("POST", "/v1/sandboxes/drain")[0][:body])
    assert_raises(ArgumentError) { Kosa8::RL::Lease.new(c) }
    assert_equal 200.0, Kosa8::RL::Lease.new(c, run_id: "r").interval_s
  end

  # --- org templates and tokens -----------------------------------------------------------

  def test_org_templates
    states = %w[queued building ready]
    f = fake do |r|
      case [r[:method], r[:path]]
      when ["POST", "/v1/templates"] then [202, { "template" => { "id" => "tpl_12345678", "name" => r[:body]["name"], "state" => "queued" } }]
      when ["POST", "/v1/templates/import"] then [202, { "queued" => 2, "templates" => [], "failed" => [] }]
      when ["GET", "/v1/templates"] then [200, { "templates" => [{ "key" => "base" }], "org_templates" => [{ "id" => "tpl_12345678" }] }]
      when ["GET", "/v1/templates/swe-1"] then [200, { "template" => { "id" => "tpl_12345678", "state" => states.shift || "ready" } }]
      when ["GET", "/v1/templates/bad"] then [200, { "template" => { "state" => "failed", "last_error" => "pull failed" } }]
      when ["DELETE", "/v1/templates/tpl_12345678"] then [200, { "ok" => true, "id" => "tpl_12345678" }]
      else [404, { "error" => "not_found" }]
      end
    end
    c = f.cloud
    t = c.org_templates.build("swe-1", image: "ghcr.io/x/y@sha256:#{'a' * 64}", setup_cmd: "pip install -e .", size: "4x8")
    assert_equal "queued", t["state"]
    assert_equal({ "name" => "swe-1", "image" => "ghcr.io/x/y@sha256:#{'a' * 64}", "setup_cmd" => "pip install -e .", "size" => "4x8" }, f.seen.last[:body])
    c.org_templates.build("df", dockerfile: "FROM alpine\n", build_args: { "V" => 1 }, cpus: 2, mem_mb: 4096, region: "eu", setup_cmd: %w[make])
    assert_equal({ "name" => "df", "dockerfile" => "FROM alpine\n", "build_args" => { "V" => "1" }, "setup_cmd" => ["make"],
                   "cpus" => 2, "mem_mb" => 4096, "region" => "eu" }, f.seen.last[:body])
    r = c.org_templates.import([{ name: "a", image: "i:1" }, { "name" => "b", "image" => "i:2" }], partial_ok: true, size: "2x4")
    assert_equal 2, r["queued"]
    assert_equal({ "images" => [{ "name" => "a", "image" => "i:1" }, { "name" => "b", "image" => "i:2" }], "size" => "2x4", "partial_ok" => true }, f.seen.last[:body])
    assert_equal ["tpl_12345678"], c.org_templates.list.map { |x| x["id"] }
    assert_equal ["base"], c.templates.map { |x| x["key"] }, "Cloud#templates is unchanged"
    assert_equal "ready", c.org_templates.wait_ready("swe-1", poll_interval: 0)["state"]
    e = assert_raises(Kosa8::Error) { c.org_templates.wait_ready("bad") }
    assert_match(/pull failed/, e.message)
    assert_nil c.org_templates.delete("tpl_12345678")
    n = f.seen.size
    assert_raises(ArgumentError) { c.org_templates.build("Bad Name", image: "x") }
    assert_raises(ArgumentError) { c.org_templates.build("ok") }
    assert_raises(ArgumentError) { c.org_templates.build("ok", image: "x", dockerfile: "y") }
    assert_raises(ArgumentError) { c.org_templates.build("ok", image: "x", size: "3x3") }
    assert_raises(ArgumentError) { c.org_templates.build("ok", image: "x", cpus: 2) }
    assert_raises(ArgumentError) { c.org_templates.import([]) }
    assert_raises(ArgumentError) { c.org_templates.import([{ name: "a" }]) }
    assert_equal n, f.seen.size
  end

  def test_template_wait_times_out
    f = fake { [200, { "template" => { "state" => "building" } }] }
    assert_raises(Kosa8::TimeoutError) { f.cloud.org_templates.wait_ready("x", timeout: 0, poll_interval: 0) }
  end

  def test_tokens
    tok = { "id" => "tok_1", "prefix" => "k8c_tok_abcd", "scopes" => ["sandboxes:read"], "state" => "active" }
    f = fake do |r|
      case [r[:method], r[:path]]
      when ["POST", "/v1/tokens"] then [201, { "token" => tok.merge("secret" => "k8c_tok_secret"), "note" => "shown once" }]
      when ["GET", "/v1/tokens"], ["GET", "/v1/tokens?all=1"] then [200, { "tokens" => [tok] }]
      when ["DELETE", "/v1/tokens/tok_1"] then [200, { "token" => tok.merge("state" => "revoked") }]
      when ["GET", "/v1/me"] then [200, { "auth" => r[:headers]["authorization"] }]
      else [404, { "error" => "not_found" }]
      end
    end
    c = f.cloud
    t = c.tokens.create(%w[sandboxes:read sandboxes:write], sandbox_ids: [Kosa8::CloudSandbox.new(c, sbx), "sbx_2"],
                                                         labels: { "user" => "u1" }, ttl_s: 600, name: "student")
    assert_equal "k8c_tok_secret", t["secret"]
    assert_equal({ "scopes" => %w[sandboxes:read sandboxes:write], "sandbox_ids" => %w[sbx_1 sbx_2], "labels" => { "user" => "u1" },
                   "ttl_s" => 600, "name" => "student" }, f.seen.last[:body])
    assert_equal ["tok_1"], c.tokens.list.map { |x| x["id"] }
    c.tokens.list(all: true)
    assert_equal "/v1/tokens?all=1", f.seen.last[:path]
    assert_equal "revoked", c.tokens.revoke("tok_1")["state"]
    n = f.seen.size
    assert_raises(ArgumentError) { c.tokens.create([]) }
    assert_raises(ArgumentError) { c.tokens.create(["admin"]) }
    assert_raises(ArgumentError) { c.tokens.create(%w[sandboxes:read sandboxes:read]) }
    assert_raises(ArgumentError) { c.tokens.create(["sandboxes:read"], ttl_s: 30) }
    assert_raises(ArgumentError) { c.tokens.create(["sandboxes:read"], sandbox_ids: []) }
    assert_equal n, f.seen.size
    # A capability token is a key the client takes.
    tc = Kosa8::Cloud.new(api_key: "k8c_tok_secret", base_url: f.url, env: {})
    assert_equal "Bearer k8c_tok_secret", tc.me["auth"]
    e = assert_raises(Kosa8::Error) { Kosa8::Cloud.new(api_key: "sk-x", env: {}) }
    assert_match(/k8c_tok_/, e.message)
  end
end
