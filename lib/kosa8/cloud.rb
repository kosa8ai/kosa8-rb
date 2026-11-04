# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "socket"
require "uri"

module Kosa8
  # The outcome of a cloud exec. +woke_ms+ is set when the sandbox was asleep
  # and woke for this command.
  CloudExecResult = Struct.new(:exit_code, :stdout, :stderr, :woke_ms, keyword_init: true) do
    def ok?
      exit_code == 0 # exit_code is nil when the command never ran
    end
  end

  # kosa8 Cloud: the same sandboxes, run on kosa8's hosts (or your own, with
  # bring-your-own-cloud) instead of the local daemon.
  #
  #   cloud = Kosa8::Cloud.new            # KOSA8_API_KEY from the environment
  #   box = cloud.sandboxes.create(template: "python")
  #   box.exec(["python3", "-c", "print(6 * 7)"]).stdout  # => "42\n"
  #   box.delete
  #
  # Authentication is an API key (k8c_live_...) made in the cloud dashboard.
  # Errors are the SDK's usual typed errors; each carries the cloud's stable
  # +code+ (for example payment_required, quota_exceeded). Standard library only.
  class Cloud
    DEFAULT_URL = "https://api.kosa8.com"
    KEY_PREFIX = "k8c_live_"
    LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

    attr_reader :base_url, :timeout, :sandboxes, :functions

    # transport: an optional callable (method, url, headers, body_or_nil, timeout) -> [status, body_string],
    # used instead of Net::HTTP (tests, proxies).
    def initialize(api_key: nil, base_url: nil, env: ENV, timeout: 120, transport: nil)
      key = (api_key.nil? ? env["KOSA8_API_KEY"].to_s : api_key.to_s).strip
      raise Error, "no kosa8 Cloud API key: pass api_key: or set KOSA8_API_KEY" if key.empty?
      raise Error, "a kosa8 Cloud API key starts with #{KEY_PREFIX}" unless key.start_with?(KEY_PREFIX)

      @key = key
      base = [base_url, env["KOSA8_CLOUD_URL"]].find { |v| v && !v.to_s.empty? } || DEFAULT_URL
      @base_url = Cloud.check_base(base.to_s)
      @timeout = timeout
      @transport = transport || method(:net_http)
      @sandboxes = CloudSandboxes.new(self)
      @functions = CloudFunctions.new(self)
    end

    # Never the key.
    def inspect
      "#<Kosa8::Cloud base_url=#{@base_url.inspect}>"
    end
    alias to_s inspect

    # The org, the key in use and, for a member's key, the member.
    def me
      request("GET", "/v1/me")
    end

    # This month's usage, bill estimate and whether work is paused for payment.
    def usage
      request("GET", "/v1/usage")
    end

    # One JSON request; raises the typed error for an error answer.
    def request(method, path, body = nil)
      headers = { "Authorization" => "Bearer #{@key}", "Accept" => "application/json" }
      data = nil
      unless body.nil?
        headers["Content-Type"] = "application/json"
        data = JSON.generate(body)
      end
      begin
        status, raw = @transport.call(method, @base_url + path, headers, data, @timeout)
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => e
        raise TimeoutError.new("kosa8 Cloud did not answer within #{@timeout} s (#{e.message})",
                               method: method, path: path)
      rescue SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError => e
        raise ConnectionError.new("could not reach kosa8 Cloud at #{@base_url}: #{e.message}",
                                  method: method, path: path)
      end
      text = raw.to_s.dup.force_encoding(Encoding::UTF_8)
      text = text.scrub unless text.valid_encoding?
      parsed = begin
        text.strip.empty? ? nil : JSON.parse(text)
      rescue JSON::ParserError
        text
      end
      raise Cloud.error(status.to_i, parsed, method, path) if status.to_i >= 400

      parsed
    end

    # The cloud answers {"error": code, "message": sentence}: the sentence is
    # the message, and the code is kept.
    def self.error(status, body, method, path)
      code = nil
      msg_body = body
      if body.is_a?(Hash)
        code = body["error"] if body["error"].is_a?(String)
        m = body["message"]
        msg_body = { "error" => m.is_a?(String) && !m.empty? ? m : body["error"] }
      end
      e = Kosa8.error_from_response(status, msg_body, method: method, path: path, code: code)
      e.instance_variable_set(:@body, body)
      e
    end

    def self.check_base(url)
      u = begin
        URI.parse(url)
      rescue URI::InvalidURIError
        nil
      end
      raise Error, "kosa8 Cloud address is not a URL: #{url}" if u.nil? || u.scheme.nil? || u.host.nil? || u.host.empty?

      local = LOCAL_HOSTS.include?(u.hostname)
      # The API key travels in every request.
      unless u.scheme == "https" || (u.scheme == "http" && local)
        raise Error, "kosa8 Cloud address must use https: #{url}"
      end

      url.sub(%r{/+\z}, "")
    end

    private

    def net_http(method, url, headers, body, timeout)
      u = URI.parse(url)
      http = Net::HTTP.new(u.hostname, u.port)
      http.use_ssl = u.scheme == "https"
      if timeout
        http.open_timeout = [timeout, 30].min
        http.read_timeout = timeout
        http.write_timeout = timeout if http.respond_to?(:write_timeout=)
      end
      req = Net::HTTPGenericRequest.new(method, !body.nil?, true, u.request_uri)
      headers.each { |k, v| req[k] = v }
      req.body = body unless body.nil?
      http.start do |h|
        resp = h.request(req)
        [resp.code.to_i, resp.body.to_s]
      end
    end
  end

  # cloud.sandboxes
  class CloudSandboxes
    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudSandboxes>"
    end

    # Start a sandbox; returns once it is running. Unset options take the org's settings.
    def create(template: nil, region: nil, sleep_after_s: nil)
      body = {}
      body["template"] = template unless template.nil?
      body["region"] = region unless region.nil?
      body["sleep_after_s"] = sleep_after_s unless sleep_after_s.nil?
      CloudSandbox.new(@cloud, @cloud.request("POST", "/v1/sandboxes", body)["sandbox"])
    end

    # The org's sandboxes; with all: true, deleted ones too.
    def list(all: false)
      r = @cloud.request("GET", "/v1/sandboxes" + (all ? "?all=1" : ""))
      r["sandboxes"].map { |s| CloudSandbox.new(@cloud, s) }
    end

    def get(id)
      CloudSandbox.new(@cloud, @cloud.request("GET", "/v1/sandboxes/#{Kosa8.enc(id)}")["sandbox"])
    end
  end

  # One cloud sandbox. +info+ is its state as of the last call.
  class CloudSandbox
    attr_reader :info

    def initialize(cloud, info)
      @cloud = cloud
      @info = info
    end

    def id
      @info["id"]
    end

    def state
      @info["state"].to_s
    end

    def inspect
      "#<Kosa8::CloudSandbox id=#{id.inspect} state=#{state.inspect}>"
    end

    # Run a command and wait for it. A String runs through sh -c, an Array is
    # the argv. A sleeping sandbox wakes for it.
    def exec(cmd, image: nil, env: nil)
      argv = cmd.is_a?(String) ? ["sh", "-c", cmd] : cmd.to_a
      body = { "cmd" => argv }
      body["image"] = image unless image.nil?
      body["env"] = env.map { |k, v| "#{k}=#{v}" } if env && !env.empty?
      r = @cloud.request("POST", path("/exec"), body)
      CloudExecResult.new(exit_code: r["exit"], stdout: r["stdout"] || "", stderr: r["stderr"] || "",
                          woke_ms: r["woke_ms"])
    end

    # Snapshot it and free its VM; it then costs only snapshot storage.
    def sleep
      @info = @cloud.request("POST", path("/sleep"))["sandbox"]
      self
    end

    # Restore a sleeping sandbox, files and all.
    def wake
      @info = @cloud.request("POST", path("/wake"))["sandbox"]
      self
    end

    def refresh
      @info = @cloud.request("GET", path)["sandbox"]
      self
    end

    def delete
      @cloud.request("DELETE", path)
      nil
    end

    private

    def path(suffix = "")
      "/v1/sandboxes/#{Kosa8.enc(id)}#{suffix}"
    end
  end

  # cloud.functions
  class CloudFunctions
    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudFunctions>"
    end

    # Deploy (create or replace) a function; every deploy bumps its version.
    def deploy(name, spec)
      @cloud.request("PUT", path(name), spec.to_h)
    end

    def list
      @cloud.request("GET", "/v1/functions")["functions"]
    end

    def get(name)
      @cloud.request("GET", path(name))
    end

    def delete(name)
      @cloud.request("DELETE", path(name))
      nil
    end

    # Call it once. A handler that raises answers "ok" => false, not an exception.
    def invoke(name, event = nil)
      @cloud.request("POST", path(name, "/invoke"), { "event" => event })
    end

    # One call per event, results in input order.
    def map(name, events, concurrency: nil)
      body = { "events" => events.to_a }
      body["concurrency"] = concurrency unless concurrency.nil?
      @cloud.request("POST", path(name, "/map"), body)
    end

    private

    def path(name, suffix = "")
      "/v1/functions/#{Kosa8.enc(name)}#{suffix}"
    end
  end
end
