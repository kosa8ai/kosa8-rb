# frozen_string_literal: true

module Kosa8
  # Every error this gem raises. The daemon's own words are kept in
  # +daemon_message+ and +remediation+, as @kosa8/sdk does.
  class Error < StandardError
    attr_reader :status, :daemon_message, :remediation, :method, :path, :body

    def initialize(message = nil, status: nil, daemon_message: nil, remediation: nil, method: nil, path: nil, body: nil)
      super(message)
      @status = status
      @daemon_message = daemon_message
      @remediation = remediation
      @method = method
      @path = path
      @body = body
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

  BY_STATUS = {
    400 => BadRequestError, 401 => AuthError, 403 => PolicyError,
    404 => NotFoundError, 409 => ConflictError, 501 => UnsupportedError
  }.freeze

  # The typed error for an HTTP error answer: the daemon's message with its
  # remediation in parentheses, as the CLI and MCP server print it.
  def self.error_from_response(status, body, method:, path:)
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
    kw = { status: status, daemon_message: msg, remediation: rem, method: method, path: path, body: body }
    return ApprovalRequiredError.new(text, approval: approval, **kw) if approval

    (BY_STATUS[status] || ApiError).new(text, **kw)
  end
end
