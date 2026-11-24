# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift __dir__
require "minitest/autorun"
require "kosa8"
require "fake_cloud"

# Autopilot: cloud.bots, cloud.approvals and HumanApprovalRequired, against a fake API.
class CloudBotsTest < Minitest::Test
  BOT = { "id" => "bot_1", "name" => "Spend guard", "state" => "draft" }.freeze
  RUN = { "id" => "brun_1", "bot_id" => "bot_1", "dry_run" => true, "state" => "succeeded", "steps" => [] }.freeze
  APPR = { "id" => "appr_1", "run_id" => "brun_1", "state" => "pending", "tier" => "T3" }.freeze
  SPEC = { "triggers" => [{ "event" => "sandbox.idle", "for_s" => 1200 }],
           "actions" => [{ "action" => "sandbox.sleep" }] }.freeze

  def teardown
    @fake&.close
  end

  def cloud(&handler)
    @fake = FakeCloud.new(&handler)
    @fake.cloud(retry_policy: Kosa8::RetryPolicy::NONE)
  end

  def default_cloud
    cloud do |req|
      p = req[:path].split("?", 2)[0]
      m = req[:method]
      if p == "/v1/bots" && m == "GET"
        [200, { "bots" => [BOT], "paused_all" => false, "paused_all_at" => nil, "pending_approvals" => 2 }]
      elsif p == "/v1/bot-templates" then [200, { "templates" => [{ "id" => "spend-guard", "rank" => 1 }] }]
      elsif p.start_with?("/v1/bot-templates/") then [200, { "template" => { "id" => "spend-guard" } }]
      elsif ["/v1/bots/plan", "/v1/bots/compile"].include?(p) then [200, { "plan" => { "summary" => "s" }, "spec" => {} }]
      elsif p.end_with?("pause-all") then [200, { "paused_all" => true, "at" => 1 }]
      elsif p.end_with?("resume-all") then [200, { "paused_all" => false, "at" => 1 }]
      elsif p.end_with?("/runs") && m == "GET" then [200, { "runs" => [RUN] }]
      elsif p.end_with?("/runs") || p.start_with?("/v1/bot-runs/") then [200, { "run" => RUN }]
      elsif p.start_with?("/v1/bots") && m == "DELETE" then [200, { "deleted" => true }]
      elsif p.start_with?("/v1/bots") then [p == "/v1/bots" ? 201 : 200, { "bot" => BOT }]
      elsif p == "/v1/approvals" then [200, { "approvals" => [APPR] }]
      elsif p.end_with?("/decide") then [200, { "approval" => APPR.merge("state" => "approved"), "run" => RUN }]
      else [200, { "approval" => APPR }]
      end
    end
  end

  def calls
    @fake.seen.map { |s| [s[:method], s[:path], s[:body]] }
  end

  def test_every_bot_call_uses_the_contract
    c = default_cloud
    b = c.bots
    assert_equal 2, b.list["pending_approvals"]
    assert_equal "spend-guard", b.templates[0]["id"]
    assert_equal "spend-guard", b.template("spend-guard")["id"]
    assert b.plan(template: "spend-guard", replay: true).key?("plan")
    b.plan(spec: SPEC, name: "n")
    assert b.compile("sleep idle dev sandboxes after 20 minutes").key?("spec")
    assert_equal "bot_1", b.create(template: "spend-guard", name: "g", budget_usd: 5)["id"]
    b.create(spec: SPEC, sponsor: "a@b.co", scope: { "labels" => { "env" => "dev" } }, notify: { "mode" => "digest" })
    assert_equal "draft", b.get("bot_1")["state"]
    b.update("bot_1", name: "x", spec: SPEC)
    assert b.delete("bot_1")["deleted"]
    b.enable("bot_1")
    b.disable("bot_1")
    assert b.run("bot_1")["dry_run"]
    b.run("bot_1", dry_run: false)
    assert_equal "brun_1", b.runs("bot_1", limit: 5)[0]["id"]
    b.get_run("brun_1")
    b.cancel_run("brun_1")
    b.undo_step("brun_1", "s1")
    assert b.pause_all["paused_all"]
    refute b.resume_all["paused_all"]
    assert_equal [
      ["GET", "/v1/bots", nil],
      ["GET", "/v1/bot-templates", nil],
      ["GET", "/v1/bot-templates/spend-guard", nil],
      ["POST", "/v1/bots/plan", { "template" => "spend-guard", "replay" => true }],
      ["POST", "/v1/bots/plan", { "spec" => SPEC, "name" => "n" }],
      ["POST", "/v1/bots/compile", { "text" => "sleep idle dev sandboxes after 20 minutes" }],
      ["POST", "/v1/bots", { "template" => "spend-guard", "name" => "g", "budget_usd" => 5 }],
      ["POST", "/v1/bots", { "spec" => SPEC, "sponsor" => "a@b.co", "scope" => { "labels" => { "env" => "dev" } },
                             "notify" => { "mode" => "digest" } }],
      ["GET", "/v1/bots/bot_1", nil],
      ["PATCH", "/v1/bots/bot_1", { "name" => "x", "spec" => SPEC }],
      ["DELETE", "/v1/bots/bot_1", nil],
      ["POST", "/v1/bots/bot_1/enable", {}],
      ["POST", "/v1/bots/bot_1/disable", {}],
      ["POST", "/v1/bots/bot_1/runs", { "dry_run" => true }],
      ["POST", "/v1/bots/bot_1/runs", { "dry_run" => false }],
      ["GET", "/v1/bots/bot_1/runs?limit=5", nil],
      ["GET", "/v1/bot-runs/brun_1", nil],
      ["POST", "/v1/bot-runs/brun_1/cancel", {}],
      ["POST", "/v1/bot-runs/brun_1/steps/s1/undo", {}],
      ["POST", "/v1/bots/pause-all", {}],
      ["POST", "/v1/bots/resume-all", {}]
    ], calls
  end

  def test_approvals
    c = default_cloud
    a = c.approvals
    assert_same a, c.bots.approvals
    assert_equal "appr_1", a.list[0]["id"]
    a.list(state: "all", limit: 10)
    a.get("appr_1")
    assert_equal "approved", a.approve("appr_1")["approval"]["state"]
    a.approve("appr_1", reason: "ok", edited_args: { "spending_cap_usd" => 50 })
    a.reject("appr_1", reason: "no")
    assert_equal [
      ["GET", "/v1/approvals?state=pending", nil],
      ["GET", "/v1/approvals?state=all&limit=10", nil],
      ["GET", "/v1/approvals/appr_1", nil],
      ["POST", "/v1/approvals/appr_1/decide", { "decision" => "approve" }],
      ["POST", "/v1/approvals/appr_1/decide", { "decision" => "approve", "reason" => "ok",
                                                "edited_args" => { "spending_cap_usd" => 50 } }],
      ["POST", "/v1/approvals/appr_1/decide", { "decision" => "reject", "reason" => "no" }]
    ], calls
  end

  def test_arguments_are_checked_before_any_request
    c = default_cloud
    b = c.bots
    assert_raises(ArgumentError) { b.create }
    assert_raises(ArgumentError) { b.create(template: "spend-guard", spec: SPEC) }
    assert_raises(ArgumentError) { b.plan }
    e = assert_raises(ArgumentError) { b.compile("x" * 501) }
    assert_match(/500/, e.message)
    assert_raises(ArgumentError) { b.compile("") }
    assert_raises(ArgumentError) { b.update("bot_1") }
    assert_raises(ArgumentError) { b.runs("bot_1", limit: 0) }
    assert_raises(ArgumentError) { b.get("") }
    assert_raises(ArgumentError) { c.approvals.list(state: "open") }
    assert_empty @fake.seen
    b.compile("x" * 500) # the limit itself is fine
    assert_equal 1, @fake.seen.size
  end

  def test_ids_are_escaped
    c = default_cloud
    c.bots.get("bot 1/../x")
    c.bots.undo_step("brun_1", "a/b")
    c.approvals.approve("appr?1")
    assert_equal ["/v1/bots/bot%201%2F..%2Fx", "/v1/bot-runs/brun_1/steps/a%2Fb/undo", "/v1/approvals/appr%3F1/decide"],
                 @fake.seen.map { |s| s[:path] }
  end

  def test_human_required_is_a_typed_error_with_no_bypass
    c = cloud do
      [403, { "error" => "human_required",
              "message" => "a person must approve this: open app.kosa8.com/app#autopilot or Slack" }]
    end
    [-> { c.approvals.approve("appr_1") }, -> { c.approvals.reject("appr_1") },
     -> { c.bots.enable("bot_1") }, -> { c.bots.resume_all }].each do |call|
      e = assert_raises(Kosa8::HumanApprovalRequired) { call.call }
      assert_kind_of Kosa8::PolicyError, e
      assert_kind_of Kosa8::ApiError, e
      assert_equal 403, e.status
      assert_equal "human_required", e.code
    end
    assert_equal 4, @fake.seen.size
  end

  def test_other_403_stays_a_policy_error
    c = cloud { [403, { "error" => "forbidden", "message" => "scope" }] }
    e = assert_raises(Kosa8::PolicyError) { c.bots.enable("bot_1") }
    refute_kind_of Kosa8::HumanApprovalRequired, e
  end
end
