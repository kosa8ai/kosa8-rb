# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "json"
require "minitest/autorun"
require "kosa8"
require_relative "fake_cloud"

# A flush whose answer was lost resends the same rows with the same
# Idempotency-Key on the next flush, so kosa8 Cloud stores them once.
class RolloutKeysTest < Minitest::Test
  def test_a_failed_chunk_keeps_its_key_until_answered
    fail_now = true
    f = FakeCloud.new do |r|
      if r[:method] == "POST" && r[:path] == "/v1/rl/runs"
        [201, { "run" => { "id" => "run_1", "name" => "n" } }]
      elsif r[:path] == "/v1/rl/runs/run_1/rollouts"
        if fail_now
          [400, { "error" => "invalid_rollout", "message" => "lost" }]
        else
          [200, { "recorded" => r[:body]["rollouts"].size }]
        end
      else
        [200, { "run" => { "id" => "run_1" }, "extended" => 0, "deleted" => 0, "ids" => [], "failed" => [], "more" => false }]
      end
    end
    run = Kosa8::RL::Run.new(f.cloud, "n", flush_every: 100, heartbeat_s: 3600)
    run.start
    run.record([{ step: 0, index: 1 }, { step: 0, index: 2 }], flush: false)
    assert_raises(Kosa8::ApiError) { run.flush }
    assert_equal 2, run.pending
    run.record({ step: 0, index: 3 }, flush: false)
    fail_now = false
    assert_equal 3, run.flush
    assert_equal 0, run.pending
    keys = f.calls("POST", "/v1/rl/runs/run_1/rollouts").map { |r| r[:headers]["idempotency-key"] }
    sizes = f.calls("POST", "/v1/rl/runs/run_1/rollouts").map { |r| r[:body]["rollouts"].size }
    assert_equal [2, 2, 1], sizes
    assert_equal keys[0], keys[1], "the failed chunk's key is reused"
    refute_equal keys[1], keys[2]
    keys.each { |k| assert_match(/\A[0-9a-f-]{36}\z/, k) }
  ensure
    run&.finish rescue nil # rubocop:disable Style/RescueModifier
    f&.close
  end
end
