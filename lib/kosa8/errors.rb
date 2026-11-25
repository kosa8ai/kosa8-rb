# frozen_string_literal: true

require "timeout"

module Kosa8
  # Every error this gem raises. The daemon's own words are kept in
  # +daemon_message+ and +remediation+, as @kosa8/sdk does.
  class Error < StandardError
    # +code+ is kosa8 Cloud's stable error code (payment_required, quota_exceeded, ...).
    attr_reader :status, :daemon_message, :remediation, :http_method, :path, :body, :code
    # Seconds the server asked to wait before trying again (Retry-After, or
    # the body's retry_after_s), when it said.
    attr_accessor :retry_after
    # The id of the request that failed (the X-Request-Id header, else
    # Cloudflare's cf-ray): quote it when you ask kosa8 support. nil when the
    # answer had neither, and for errors with no answer.
    attr_accessor :request_id
    # Context added after the server's sentence in #message (kosa8 Cloud
    # answers: "[HTTP 503 no_capacity; retry in 10 s; request ...]").
    attr_accessor :detail # :nodoc:

    def initialize(message = nil, status: nil, daemon_message: nil, remediation: nil, method: nil, path: nil, body: nil,
                   code: nil)
      super(message)
      @status = status
      @daemon_message = daemon_message
      @remediation = remediation
      @http_method = method
      @path = path
      @body = body
      @code = code
      @detail = nil
      @retry_after = nil
      @request_id = nil
    end

    # The message: the server's own sentence (or the SDK's), followed for a
    # kosa8 Cloud answer by its status, code, wait and request id, so a log
    # line alone says what happened and what to do. The bare sentence is
    # daemon_message.
    def to_s
      d = @detail
      d.nil? || d.empty? ? super : "#{super} #{d}"
    end

    # retry_after under the API's own name: seconds to wait before trying
    # again, or nil.
    def retry_after_s
      retry_after
    end

    # Whose fault it was: "ok", "exit_nonzero", "timeout", "infra", "quota",
    # "client", or "error" (not an API answer). See Kosa8.classify_failure.
    def failure_class
      Kosa8.classify_failure(self)[0]
    end

    # Whether the same call may work if sent again.
    def retryable?
      Kosa8.classify_failure(self)[1]
    end
    alias retryable retryable?
  end

  class ConnectionError < Error; end # daemon unreachable

  # Any HTTP error answer. A kosa8 Cloud answer's contract fields (see the
  # API's Error schema) are read from +body+; each is nil when the answer
  # did not carry it.
  class ApiError < Error
    # 402: where the person adds a payment method or credit, or raises the cap.
    def upgrade_url
      Kosa8.body_str(body, "upgrade_url")
    end

    # 402 and 429 quota_exceeded: a sentence an AI agent should relay to its
    # person word for word.
    def agent_message
      Kosa8.body_str(body, "agent_message")
    end

    # 429 quota_exceeded: where to ask for a higher limit.
    def request_url
      Kosa8.body_str(body, "request_url")
    end

    # 402 plan_limit: which limit (sandbox_hours, running, size, persistent or snapshots).
    def limit_name
      Kosa8.body_str(body, "limit_name")
    end

    # 402 plan_limit: the plan's limit (a Number).
    def limit
      Kosa8.body_num(body, "limit")
    end

    # 402 plan_limit: what the organization has used.
    def used
      Kosa8.body_num(body, "used")
    end

    # 402 plan_limit and plan_feature: the organization's plan.
    def plan
      Kosa8.body_str(body, "plan")
    end

    # 402 plan_limit and plan_feature: the first plan that includes more (nil: contact sales).
    def next_plan
      Kosa8.body_str(body, "next_plan")
    end

    # 402 plan_feature: the feature the plan lacks.
    def feature
      Kosa8.body_str(body, "feature")
    end

    # 402 plan_limit: the ways past the limit, cheaper first (Hashes: "kind"
    # pack or upgrade, "addon", "plan", "label", "monthly_usd", "url").
    def options
      v = body.is_a?(Hash) ? body["options"] : nil
      v.is_a?(Array) ? v.select { |o| o.is_a?(Hash) } : []
    end

    # 402 plan_limit: where to add the pack for this limit, when one is sold.
    def pack_url
      Kosa8.body_str(body, "pack_url")
    end

    # 409 github_not_connected: where an admin connects GitHub.
    def connect_url
      Kosa8.body_str(body, "connect_url")
    end

    # 409 github_permissions: where on GitHub to approve the permissions
    # kosa8 lacks.
    def settings_url
      Kosa8.body_str(body, "settings_url")
    end

    # 409 github_permissions: the GitHub App permissions missing
    # (contents:write, pull_requests:write, ...); [] otherwise.
    def missing_permissions
      v = body.is_a?(Hash) ? body["missing"] : nil
      v.is_a?(Array) ? v.select { |x| x.is_a?(String) } : []
    end
  end

  class BadRequestError < ApiError; end   # 400
  class AuthError < ApiError; end         # 401
  class PolicyError < ApiError; end       # 403
  class NotFoundError < ApiError; end     # 404
  class ConflictError < ApiError; end     # 409
  class UnsupportedError < ApiError; end  # 501

  # 409 github_not_connected: the org has not connected GitHub yet; an admin
  # connects it at #connect_url.
  class GitHubNotConnectedError < ConflictError; end
  # 409 github_permissions: the kosa8 GitHub App lacks #missing_permissions;
  # approve them at #settings_url.
  class GitHubPermissionsError < ConflictError; end
  # 409 no_changes: nothing changed in the sandbox's repo, so nothing to push.
  class NoChangesError < ConflictError; end
  # 404 repo_not_found: the repo is not visible to the org's GitHub
  # installations (or does not exist).
  class RepoNotFoundError < NotFoundError; end
  # 502 github_unavailable: GitHub did not answer or rate-limited kosa8; try
  # again after #retry_after_s.
  class GitHubUnavailableError < ApiError; end

  # 403 human_required: only a person can do this (turn a bot on, resume every
  # bot, decide an approval). Capability tokens, MCP and org keys bound to no
  # member are never a person. An agent never approves its own action; a
  # person approves in the web app (app.kosa8.com/app#autopilot), desktop, CLI
  # or Slack. There is no way around it from code.
  class HumanApprovalRequired < PolicyError; end

  # Typed errors by kosa8 Cloud code, before the status fallback.
  BY_CODE = {
    "github_not_connected" => GitHubNotConnectedError, "github_permissions" => GitHubPermissionsError,
    "no_changes" => NoChangesError, "repo_not_found" => RepoNotFoundError,
    "github_unavailable" => GitHubUnavailableError, "human_required" => HumanApprovalRequired
  }.freeze

  # 402: kosa8 Cloud wants a payment method, credit or an accepted price first
  # (+code+ payment_required, spending_cap_reached, price_not_accepted, ...).
  # #upgrade_url, #agent_message and the plan_limit fields (#limit_name,
  # #limit, #used, #plan, #next_plan, #options, #pack_url) are on ApiError.
  class PaymentRequiredError < ApiError; end

  # 429: too many requests, or a quota reached (+code+ quota_exceeded, with
  # #agent_message and #request_url). +retry_after+ is the server's
  # Retry-After in seconds, when it sent one.
  class RateLimitError < ApiError
    # A plan limit answered 429 (PlanLimitError) still matches +rescue
    # RateLimitError+, for code written before it existed.
    def self.===(other)
      super || (equal?(RateLimitError) && other.is_a?(PlanLimitError) && other.status == 429)
    end
  end

  # 423 (+code+ org_frozen): the org is frozen in the Security Center. New
  # sandboxes, commands, wakes and function calls are refused until an owner or
  # admin unfreezes it; retrying does not help.
  class OrgFrozenError < ApiError; end

  # A kosa8 Cloud exec ran past the API's limit for a buffered command. A
  # buffered exec runs at most 90 s, then the API stops it and answers 504
  # exec_timeout (older servers: HTTP 502 host_failed "timed out"). Run long work in the background,
  # writing to /workspace, and poll it:
  #
  #   box.exec("nohup sh -c 'make test > /workspace/test.log 2>&1' &")
  class ExecTimeoutError < ApiError
    attr_writer :stdout, :stderr

    # The output so far: a streamed exec's, or what a buffered exec stopped
    # at its own timeout_s sent back ("" when the answer had none).
    def stdout
      @stdout || Kosa8.body_str(body, "stdout") || ""
    end

    def stderr
      @stderr || Kosa8.body_str(body, "stderr") || ""
    end

    # The limit the command ran past, in seconds, when the answer said.
    def limit_s
      Kosa8.body_num(body, "limit_s")
    end
  end

  # 403 that a signed approval would lift; +approval+ is the daemon's refusal.
  class ApprovalRequiredError < PolicyError
    attr_reader :approval

    def initialize(message = nil, approval: {}, **kw)
      super(message, **kw)
      @approval = approval
    end
  end

  # A stream ended with an error frame (or none); output so far is kept.
  class StreamError < Error
    attr_reader :stdout, :stderr

    def initialize(message = nil, stdout: "", stderr: "", **kw)
      super(message, **kw)
      @stdout = stdout
      @stderr = stderr
    end
  end

  class CheckpointError < Error; end
  class TimeoutError < Error; end

  # Raised when a frame stream carries something that is not NDJSON.
  class ProtocolError < Error; end

  # A plan limit answered with HTTP 429 (Starter's running limit,
  # +starter_limit+): a PaymentRequiredError like every other plan limit
  # (pick a plan or stop a sandbox; retrying does not help).
  class PlanLimitError < PaymentRequiredError; end

  # Codes that mean "pick or pay for a plan", whatever the HTTP status.
  PLAN_LIMIT_CODES = %w[starter_limit plan_limit plan_feature plan_required].freeze

  BY_STATUS = {
    400 => BadRequestError, 401 => AuthError, 402 => PaymentRequiredError, 403 => PolicyError,
    404 => NotFoundError, 409 => ConflictError, 423 => OrgFrozenError, 429 => RateLimitError,
    501 => UnsupportedError
  }.freeze

  # body[key] when it is a non-empty String, else nil.
  def self.body_str(body, key)
    v = body.is_a?(Hash) ? body[key] : nil
    v.is_a?(String) && !v.empty? ? v : nil
  end

  # body[key] when it is a Number, else nil.
  def self.body_num(body, key)
    v = body.is_a?(Hash) ? body[key] : nil
    v.is_a?(Numeric) ? v : nil
  end

  # The typed error for an HTTP error answer: the daemon's message with its
  # remediation in parentheses, as the CLI and MCP server print it.
  def self.error_from_response(status, body, method:, path:, code: nil)
    msg = nil
    rem = nil
    approval = nil
    if body.is_a?(Hash)
      msg = body["error"].is_a?(String) && !body["error"].empty? ? body["error"] : body["message"]
      rem = body["remediation"] if body["remediation"].is_a?(String) && !body["remediation"].empty?
      approval = body["approval"] if status == 403 && body["approval"].is_a?(Hash) && body["approval"]["why"].is_a?(String)
    elsif body.is_a?(String) && !body.strip.empty?
      msg = body.strip
    end
    base = msg.is_a?(String) && !msg.empty? ? msg : "request failed with HTTP #{status}"
    text = rem ? "#{base} (#{rem})" : base
    kw = { status: status, daemon_message: msg, remediation: rem, method: method, path: path, body: body,
           code: code }
    return ApprovalRequiredError.new(text, approval: approval, **kw) if approval

    if !BY_CODE[code] && PLAN_LIMIT_CODES.include?(code)
      return (status == 429 ? PlanLimitError : PaymentRequiredError).new(text, **kw)
    end

    (BY_CODE[code] || BY_STATUS[status] || ApiError).new(text, **kw)
  end

  # The failure classes kosa8 Cloud puts on every answer under /v1/sandboxes.
  FAILURE_CLASSES = %w[ok exit_nonzero timeout oom infra quota client].freeze
  INFRA_CODES = %w[host_failed not_ready no_capacity host_unreachable host_unavailable host_busy host_restarting
                   wake_failed try_again internal kernel_failed egress_failed dns_unreachable host_lost host_removed
                   insufficient_storage starting database_busy].freeze
  RATE_CODES = %w[rate_limited slow_down too_soon].freeze
  QUOTA_CODES = %w[quota_exceeded running_limit plan_required plan_limit plan_feature payment_required payment_declined
                   payment_failed spend_cap starter_limit
                   spending_cap_reached snapshot_limit org_frozen org_suspended too_many_runs].freeze
  IDEMPOTENCY_IN_PROGRESS = "idempotency_in_progress"

  # [failure_class, retryable] for an HTTP status and error code, by the
  # server's own rules (workers/cloud-api failures.js), for answers that came
  # without failure_class (an older server, a proxy).
  def self.failure_of(status, code = nil)
    c = code.is_a?(String) ? code : ""
    return ["ok", false] if status < 400
    return ["timeout", false] if c == "exec_timeout"
    return ["infra", true] if c == IDEMPOTENCY_IN_PROGRESS || c == "template_building"
    # A bad parameter is the caller's to fix, whatever it names (invalid_timeout).
    return ["client", false] if status < 500 && /\A(invalid|bad|missing|unknown)_/.match?(c)
    return ["timeout", true] if c.include?("timeout")
    return ["quota", true] if RATE_CODES.include?(c)
    return ["quota", false] if QUOTA_CODES.include?(c) || status == 402 || status == 423
    return ["quota", c != "quota_exceeded"] if status == 429
    return ["infra", false] if c == "not_available" || c == "not_supported" || status == 501
    return ["infra", true] if INFRA_CODES.include?(c) || status >= 500

    ["client", false]
  end

  # [failure_class, retryable] of an exec that ran: ok on exit 0,
  # exit_nonzero on any other exit, infra when there was no exit code.
  def self.exec_failure(exit_code)
    return ["infra", true] unless exit_code.is_a?(Integer)

    [exit_code.zero? ? "ok" : "exit_nonzero", false]
  end

  # [failure_class, retryable] for any exception. A kosa8 Cloud error body's
  # failure_class and retryable are used as sent; 409 idempotency_in_progress
  # is retryable (the first request with that key is still running); no
  # answer at all is infra (retryable); an exec past its limit is timeout;
  # else the server's rules (Kosa8.failure_of). An exception that is not a
  # Kosa8::Error is "error" (not retryable): a bug in your code.
  def self.classify_failure(exc)
    return ["client", true] if exc.is_a?(Error) && exc.code == IDEMPOTENCY_IN_PROGRESS

    body = exc.respond_to?(:body) ? exc.body : nil
    if body.is_a?(Hash) && body["failure_class"].is_a?(String)
      fc = body["failure_class"]
      rt = body["retryable"]
      return [fc, rt == true || rt == false ? rt : fc == "infra"]
    end
    unless exc.is_a?(Error)
      return ["infra", true] if exc.is_a?(SystemCallError) || exc.is_a?(IOError) || exc.is_a?(SocketError) ||
                                exc.is_a?(::Timeout::Error)

      return ["error", false]
    end
    return ["timeout", false] if exc.is_a?(ExecTimeoutError)
    return ["infra", true] if exc.is_a?(ConnectionError) || exc.is_a?(TimeoutError)
    return ["error", false] if exc.status.nil?

    failure_of(exc.status, exc.code)
  end
end
