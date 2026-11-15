# frozen_string_literal: true

module Kosa8
  # Every error this gem raises. The daemon's own words are kept in
  # +daemon_message+ and +remediation+, as @kosa8/sdk does.
  class Error < StandardError
    # +code+ is kosa8 Cloud's stable error code (payment_required, quota_exceeded, ...).
    attr_reader :status, :daemon_message, :remediation, :http_method, :path, :body, :code

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
    end
  end

  class ConnectionError < Error; end # daemon unreachable
  class ApiError < Error; end        # any HTTP error answer
  class BadRequestError < ApiError; end   # 400
  class AuthError < ApiError; end         # 401
  class PolicyError < ApiError; end       # 403
  class NotFoundError < ApiError; end     # 404
  class ConflictError < ApiError; end     # 409
  class UnsupportedError < ApiError; end  # 501

  # 402: kosa8 Cloud wants a payment method, credit or an accepted price first
  # (+code+ payment_required, spending_cap_reached, price_not_accepted, ...).
  class PaymentRequiredError < ApiError
    # Where the person adds a payment method or credit; nil when the answer has none.
    def upgrade_url
      Kosa8.body_str(body, "upgrade_url")
    end

    # A sentence an AI agent should relay to its person word for word; nil when absent.
    def agent_message
      Kosa8.body_str(body, "agent_message")
    end
  end

  # 429: too many requests, or a quota reached (+code+ quota_exceeded).
  # +retry_after+ is the server's Retry-After in seconds, when it sent one.
  class RateLimitError < ApiError
    attr_accessor :retry_after
  end

  # 423 (+code+ org_frozen): the org is frozen in the Security Center. New
  # sandboxes, commands, wakes and function calls are refused until an owner or
  # admin unfreezes it; retrying does not help.
  class OrgFrozenError < ApiError; end

  # A kosa8 Cloud exec ran past the API's limit for a buffered command. Today a
  # buffered exec is cut off after about 30 s (HTTP 502 host_failed "timed out";
  # later servers answer 504 exec_timeout). Run long work in the background,
  # writing to /workspace, and poll it:
  #
  #   box.exec("nohup sh -c 'make test > /workspace/test.log 2>&1' &")
  class ExecTimeoutError < ApiError; end

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

    (BY_STATUS[status] || ApiError).new(text, **kw)
  end
end
