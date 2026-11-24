# frozen_string_literal: true

# Autopilot: bots that watch the org's sandboxes, spend and agents and act
# (cloud.bots), and the approvals their T3 actions wait on (cloud.approvals,
# also cloud.bots.approvals). Answers are the API's own Hashes.
#
# A bot starts as a draft. Turning it on (CloudBots#enable), resuming every
# bot (CloudBots#resume_all) and deciding an approval need a person's
# credential (a dashboard session or a member's API key, such as the one
# `kosa8 login` makes); anything else (a capability token, MCP, an org key
# bound to no member) raises Kosa8::HumanApprovalRequired (403
# human_required). An agent never approves its own action; a person approves
# in the web app, desktop, CLI or Slack.
module Kosa8
  class Cloud
    # Autopilot bots (a CloudBots).
    attr_reader :bots
    # Approvals T3 bot actions wait on (a CloudApprovals).
    attr_reader :approvals

    alias initialize_without_bots initialize
    def initialize(**kw)
      initialize_without_bots(**kw)
      @approvals = CloudApprovals.new(self)
      @bots = CloudBots.new(self, @approvals)
    end
  end

  # Shared argument checks for CloudBots and CloudApprovals.
  module BotArgs
    module_function

    def need(name, v)
      raise ArgumentError, "#{name} is required" if v.nil? || v.to_s.empty?

      v.to_s
    end

    def limit(v, hi = 100)
      return if v.nil?
      raise ArgumentError, "limit must be a whole number from 1 to #{hi}, got #{v.inspect}" unless v.is_a?(Integer) && v.between?(1, hi)
    end

    def one_of(template, spec)
      raise ArgumentError, "give exactly one of template: or spec:" if template.nil? == spec.nil?
      return { "template" => need("template", template) } unless template.nil?
      raise ArgumentError, "spec must be a Hash (triggers, actions, scope, ...)" unless spec.is_a?(Hash)

      { "spec" => spec }
    end

    def put(body, fields)
      fields.each { |k, v| body[k.to_s] = v unless v.nil? }
      body
    end
  end

  # cloud.bots: start from a ranked template or a spec, see the plan and a dry
  # run over the last 7 days of real events, then a person turns the bot on.
  # Bots never touch sandboxes labelled protected or env=prod.
  #
  # #enable and #resume_all need a person's credential and raise
  # Kosa8::HumanApprovalRequired otherwise; an agent can create drafts,
  # dry-run, disable and #pause_all, never switch a bot on.
  class CloudBots
    # The longest sentence #compile takes.
    COMPILE_MAX_CHARS = 500

    # The same as cloud.approvals.
    attr_reader :approvals

    def initialize(cloud, approvals = nil)
      @cloud = cloud
      @approvals = approvals || CloudApprovals.new(cloud)
    end

    def inspect
      "#<Kosa8::CloudBots>"
    end

    # {"bots" => [...], "paused_all", "paused_all_at", "pending_approvals"}.
    def list
      @cloud.request("GET", "/v1/bots")
    end

    # Ready-made bots ranked for this org ("rank"; "why" when an org signal moved one up).
    def templates
      r = @cloud.request("GET", "/v1/bot-templates")
      (r.is_a?(Hash) && r["templates"]) || []
    end

    # One template, with its "spec" and "plan".
    def template(template_id)
      pick(@cloud.request("GET", "/v1/bot-templates/#{Kosa8.enc(BotArgs.need("template_id", template_id))}"), "template")
    end

    # What a bot from +template+ or +spec+ would do: {"plan", "spec", "replay"?}.
    # replay: true adds what it would have done over the last 7 days. Saves nothing.
    def plan(template: nil, spec: nil, name: nil, replay: nil)
      body = BotArgs.put(BotArgs.one_of(template, spec), name: name, replay: replay)
      @cloud.request("POST", "/v1/bots/plan", body)
    end

    # A sentence (at most 500 characters) to {"spec", "plan", "source", "notes"}.
    # Never saves and never turns anything on.
    def compile(text)
      BotArgs.need("text", text)
      if text.to_s.length > COMPILE_MAX_CHARS
        raise ArgumentError, "text must be at most #{COMPILE_MAX_CHARS} characters, got #{text.to_s.length}"
      end

      @cloud.request("POST", "/v1/bots/compile", { "text" => text.to_s })
    end

    # A new bot in state draft from exactly one of +template+ (an id such as
    # "spend-guard") or +spec+. +sponsor+ (a member's email) defaults to the
    # person calling; a non-human caller must give one.
    def create(template: nil, spec: nil, name: nil, sponsor: nil, budget_usd: nil, scope: nil, notify: nil)
      body = BotArgs.put(BotArgs.one_of(template, spec),
                         name: name, sponsor: sponsor, budget_usd: budget_usd, scope: scope, notify: notify)
      pick(@cloud.request("POST", "/v1/bots", body), "bot")
    end

    # One bot, with "spec", "plan" and "versions".
    def get(bot_id)
      pick(@cloud.request("GET", bot_path(bot_id)), "bot")
    end

    # Change a bot. A new spec is a new version; a non-human changing an on
    # bot's spec sends it back to draft.
    def update(bot_id, name: nil, spec: nil, sponsor: nil, budget_usd: nil, scope: nil, notify: nil)
      path = bot_path(bot_id)
      body = BotArgs.put({}, name: name, spec: spec, sponsor: sponsor, budget_usd: budget_usd, scope: scope, notify: notify)
      raise ArgumentError, "nothing to update: give name, spec, sponsor, budget_usd, scope or notify" if body.empty?

      pick(@cloud.request("PATCH", path, body), "bot")
    end

    # Delete a bot (its runs are kept; its pending approvals are rejected).
    def delete(bot_id)
      @cloud.request("DELETE", bot_path(bot_id))
    end

    # Turn a bot on. Needs a person's credential: Kosa8::HumanApprovalRequired otherwise.
    def enable(bot_id)
      pick(@cloud.request("POST", "#{bot_path(bot_id)}/enable", {}), "bot")
    end

    # Turn a bot off (state paused). Any credential with sandboxes:write.
    def disable(bot_id)
      pick(@cloud.request("POST", "#{bot_path(bot_id)}/disable", {}), "bot")
    end

    # Run a bot now. A dry run (the default) says what it would do now plus a
    # "replay" over the last 7 days; it changes nothing and is never billed.
    # dry_run: false evaluates the bot's triggers for real (the bot must be on).
    def run(bot_id, dry_run: true)
      pick(@cloud.request("POST", "#{bot_path(bot_id)}/runs", { "dry_run" => dry_run ? true : false }), "run")
    end

    # A bot's runs, newest first.
    def runs(bot_id, limit: nil)
      path = "#{bot_path(bot_id)}/runs"
      BotArgs.limit(limit)
      r = @cloud.request("GET", limit.nil? ? path : "#{path}?limit=#{limit}")
      (r.is_a?(Hash) && r["runs"]) || []
    end

    # One run (brun_...) with its steps.
    def get_run(run_id)
      pick(@cloud.request("GET", run_path(run_id)), "run")
    end

    # Cancel a run; its pending approvals are rejected.
    def cancel_run(run_id)
      pick(@cloud.request("POST", "#{run_path(run_id)}/cancel", {}), "run")
    end

    # Undo one step that has an undo (wake the sandbox, remove the bot's own
    # threat block, lift a label block).
    def undo_step(run_id, step_key)
      path = "#{run_path(run_id)}/steps/#{Kosa8.enc(BotArgs.need("step_key", step_key))}/undo"
      pick(@cloud.request("POST", path, {}), "run")
    end

    # Stop every bot in the org (admin; any credential, so an agent can stop
    # everything). {"paused_all", "at"}.
    def pause_all
      @cloud.request("POST", "/v1/bots/pause-all", {})
    end

    # Undo #pause_all (admin and a person's credential:
    # Kosa8::HumanApprovalRequired otherwise).
    def resume_all
      @cloud.request("POST", "/v1/bots/resume-all", {})
    end

    private

    def bot_path(bot_id)
      "/v1/bots/#{Kosa8.enc(BotArgs.need("bot_id", bot_id))}"
    end

    def run_path(run_id)
      "/v1/bot-runs/#{Kosa8.enc(BotArgs.need("run_id", run_id))}"
    end

    def pick(r, key)
      r.is_a?(Hash) && r[key].is_a?(Hash) ? r[key] : r
    end
  end

  # cloud.approvals (also cloud.bots.approvals): T3 bot actions waiting on a
  # person. Approvals expire after 24 hours (as rejected).
  #
  # Deciding needs a person's credential whose role covers the action; a
  # capability token, MCP or an org key bound to no member raises
  # Kosa8::HumanApprovalRequired. An agent never approves its own action; a
  # person approves in the web app, desktop, CLI or Slack.
  class CloudApprovals
    STATES = %w[pending decided all].freeze

    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudApprovals>"
    end

    # Approvals in +state+ ("pending", "decided" or "all").
    def list(state: "pending", limit: nil)
      s = state.to_s
      raise ArgumentError, "state must be one of #{STATES.join(", ")}, got #{state.inspect}" unless STATES.include?(s)

      BotArgs.limit(limit, 1000)
      q = "state=#{Kosa8.enc(s)}#{limit.nil? ? "" : "&limit=#{limit}"}"
      r = @cloud.request("GET", "/v1/approvals?#{q}")
      (r.is_a?(Hash) && r["approvals"]) || []
    end

    # One approval (appr_...).
    def get(approval_id)
      r = @cloud.request("GET", path(approval_id))
      r.is_a?(Hash) && r["approval"].is_a?(Hash) ? r["approval"] : r
    end

    # Approve ({"approval", "run"}), optionally with +edited_args+ (checked
    # against the action's schema). A person's credential only; 409 expired or
    # decided when it is too late.
    def approve(approval_id, reason: nil, edited_args: nil)
      decide(approval_id, "approve", reason, edited_args)
    end

    # Reject ({"approval", "run"}). A person's credential only.
    def reject(approval_id, reason: nil)
      decide(approval_id, "reject", reason, nil)
    end

    private

    def path(approval_id)
      "/v1/approvals/#{Kosa8.enc(BotArgs.need("approval_id", approval_id))}"
    end

    def decide(approval_id, decision, reason, edited_args)
      p = "#{path(approval_id)}/decide"
      @cloud.request("POST", p, BotArgs.put({ "decision" => decision }, reason: reason, edited_args: edited_args))
    end
  end
end
