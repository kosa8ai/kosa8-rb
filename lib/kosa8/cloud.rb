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

  # One page of CloudSandboxes#list_page. +next_cursor+ is nil on the last page,
  # and always on a server that does not page yet (it then answers every
  # sandbox in one page).
  CloudSandboxPage = Struct.new(:sandboxes, :next_cursor, keyword_init: true)

  # What CloudSandbox#rewind answers: the +checkpoint+ it went back to, the
  # automatic +backup+ checkpoint of the sandbox as it was just before, and +ms+.
  CloudRewindResult = Struct.new(:checkpoint, :backup, :ms, keyword_init: true)

  # kosa8 Cloud: the same sandboxes, run on kosa8's hosts (or your own, with
  # bring-your-own-cloud) instead of the local daemon.
  #
  #   cloud = Kosa8::Cloud.new            # KOSA8_API_KEY from the environment
  #   box = cloud.sandboxes.create(template: "python", ttl_s: 3600)
  #   box.exec(["python3", "-c", "print(6 * 7)"]).stdout  # => "42\n"
  #   box.delete
  #
  # Authentication is an API key (k8c_live_...) made in the cloud dashboard.
  # Errors are the SDK's usual typed errors; each carries the cloud's stable
  # +code+ (for example payment_required, quota_exceeded). Standard library only.
  #
  # Each exec runs in a fresh container and only /workspace persists; a
  # buffered exec is cut off after about 30 s (ExecTimeoutError), and a request
  # body is at most 64 KiB.
  class Cloud
    DEFAULT_URL = "https://api.kosa8.com"
    KEY_PREFIX = "k8c_live_"
    LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
    # A ttl_s is from 60 seconds to 90 days.
    MIN_TTL_S = 60
    MAX_TTL_S = 7_776_000
    # sleep_after_s is from 0 (never) to 7 days.
    MAX_SLEEP_AFTER_S = 604_800
    # A fork makes from 1 to 100 copies.
    MAX_FORK = 100
    # The limit kosa8 Cloud puts on a buffered exec today, in seconds.
    EXEC_LIMIT_S = 30
    EXEC_HINT = "a buffered exec is limited to about #{EXEC_LIMIT_S} s; run long work in the background, " \
                "writing to /workspace, and poll it"

    attr_reader :base_url, :timeout, :sandboxes, :functions

    # transport: an optional callable (method, url, headers, body_or_nil, timeout) -> [status, body_string]
    # or [status, body_string, response_headers], used instead of Net::HTTP (tests, proxies).
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

    # The templates the org can start: "key", "cpus", "mem_mb", "image", "regions", "warm".
    def templates
      r = request("GET", "/v1/templates")
      r.is_a?(Hash) ? (r["templates"] || []) : []
    end

    # One JSON request; raises the typed error for an error answer.
    def request(method, path, body = nil)
      perform(method, path, body, nil, false)
    end

    # One request whose body is +data+ (raw bytes, application/octet-stream)
    # when given; with +raw+ a successful answer's bytes come back as a binary
    # String instead of parsed JSON. Raises the typed error for an error answer.
    def request_bytes(method, path, data: nil, raw: false)
      perform(method, path, nil, data, raw)
    end

    private def perform(method, path, body, data, raw)
      headers = { "Authorization" => "Bearer #{@key}",
                  "Accept" => raw ? "application/octet-stream" : "application/json" }
      payload = nil
      if !data.nil?
        headers["Content-Type"] = "application/octet-stream"
        payload = data.to_s.b
      elsif !body.nil?
        headers["Content-Type"] = "application/json"
        payload = JSON.generate(body)
      end
      begin
        status, content, resp_headers = @transport.call(method, @base_url + path, headers, payload, @timeout)
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => e
        if Cloud.exec_path?(path)
          raise ExecTimeoutError.new("kosa8 Cloud did not answer within #{@timeout} s (#{EXEC_HINT})",
                                     method: method, path: path, code: "exec_timeout")
        end
        raise TimeoutError.new("kosa8 Cloud did not answer within #{@timeout} s (#{e.message})",
                               method: method, path: path)
      rescue SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError => e
        raise ConnectionError.new("could not reach kosa8 Cloud at #{@base_url}: #{e.message}",
                                  method: method, path: path)
      end
      return content.to_s.b if raw && status.to_i < 400

      text = content.to_s.dup.force_encoding(Encoding::UTF_8)
      text = text.scrub unless text.valid_encoding?
      parsed = begin
        text.strip.empty? ? nil : JSON.parse(text)
      rescue JSON::ParserError
        text
      end
      raise Cloud.error(status.to_i, parsed, method, path, resp_headers) if status.to_i >= 400

      parsed
    end

    # The cloud answers {"error": code, "message": sentence}: the sentence is
    # the message, and the code is kept.
    def self.error(status, body, method, path, headers = nil)
      code = nil
      msg_body = body
      if body.is_a?(Hash)
        code = body["error"] if body["error"].is_a?(String)
        m = body["message"]
        msg_body = { "error" => m.is_a?(String) && !m.empty? ? m : body["error"] }
      end
      message = (msg_body.is_a?(Hash) ? msg_body["error"] : msg_body).to_s
      e = if exec_timeout?(status, code, message, path)
            said = message.empty? ? nil : message
            ExecTimeoutError.new("#{said || "request failed with HTTP #{status}"} (#{EXEC_HINT})",
                                 status: status, daemon_message: said, method: method, path: path,
                                 code: code || "exec_timeout")
          else
            Kosa8.error_from_response(status, msg_body, method: method, path: path, code: code)
          end
      e.instance_variable_set(:@body, body)
      e.retry_after = retry_after(headers) if e.is_a?(RateLimitError)
      e
    end

    def self.exec_path?(path)
      path.to_s.split("?", 2)[0].end_with?("/exec")
    end

    # 504, code exec_timeout, or today's 502 host_failed "... timed out" on /exec.
    def self.exec_timeout?(status, code, message, path)
      return true if status == 504 || code == "exec_timeout"

      status == 502 && exec_path?(path) && message.downcase.include?("timed out")
    end

    # Retry-After in seconds (a number), or nil.
    def self.retry_after(headers)
      return nil unless headers.respond_to?(:each)

      v = nil
      headers.each { |k, val| v = val if k.to_s.casecmp("retry-after").zero? }
      v = v.first if v.is_a?(Array)
      Float(v.to_s.strip)
    rescue ArgumentError, TypeError
      nil
    end

    # Argument checks shared by create and update; raise ArgumentError before any request.
    def self.check_lifetime(ttl_s, delete_after)
      raise ArgumentError, "give ttl_s or delete_after, not both" if !ttl_s.nil? && !delete_after.nil?
      if !ttl_s.nil? && !(ttl_s.is_a?(Integer) && ttl_s.between?(MIN_TTL_S, MAX_TTL_S))
        raise ArgumentError, "ttl_s must be a whole number of seconds from #{MIN_TTL_S} to #{MAX_TTL_S}"
      end
      return if delete_after.nil? || delete_after.is_a?(Integer)

      raise ArgumentError, "delete_after must be a Unix time in milliseconds"
    end

    def self.check_sleep_after(sleep_after_s)
      return if sleep_after_s.nil? || (sleep_after_s.is_a?(Integer) && sleep_after_s.between?(0, MAX_SLEEP_AFTER_S))

      raise ArgumentError, "sleep_after_s must be a whole number of seconds from 0 (never) to #{MAX_SLEEP_AFTER_S}"
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
        [resp.code.to_i, resp.body.to_s, resp.to_hash]
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
    #
    # +template+ is a key from Cloud#templates (default the org's default,
    # "base": Alpine, busybox sh, no bash or python) or a kosa8 Store item,
    # "creator/name" or "creator/name@1.2.3". +ttl_s+ (60 s to 90 days) or
    # +delete_after+ (Unix ms) deletes it automatically: set one so a crashed
    # script cannot leave it running. +sleep_after_s+ is the idle time before it
    # sleeps (0 never; default 300). +accept_price+ is a paid Store item's
    # current price in USD, which the person agreed to. Bad arguments raise
    # ArgumentError before any request.
    def create(template: nil, region: nil, sleep_after_s: nil, ttl_s: nil, delete_after: nil, accept_price: nil)
      Cloud.check_lifetime(ttl_s, delete_after)
      Cloud.check_sleep_after(sleep_after_s)
      if !accept_price.nil? && !accept_price.is_a?(Numeric)
        raise ArgumentError, "accept_price must be a number (USD)"
      end

      body = {}
      body["template"] = template unless template.nil?
      body["region"] = region unless region.nil?
      body["sleep_after_s"] = sleep_after_s unless sleep_after_s.nil?
      body["ttl_s"] = ttl_s unless ttl_s.nil?
      body["delete_after"] = delete_after unless delete_after.nil?
      body["accept_price"] = accept_price unless accept_price.nil?
      CloudSandbox.new(@cloud, @cloud.request("POST", "/v1/sandboxes", body)["sandbox"])
    end

    # The org's sandboxes, newest first, as an Array; with all: true, deleted
    # ones too. With +limit:+ or +cursor:+ this is one page: #list_page also
    # gives the next cursor, and #each walks every page.
    def list(all: false, limit: nil, cursor: nil)
      list_page(all: all, limit: limit, cursor: cursor).sandboxes
    end

    # One page of sandboxes (a CloudSandboxPage) and the cursor of the next
    # (nil at the end).
    def list_page(all: false, limit: nil, cursor: nil)
      q = []
      q << %w[all 1] if all
      unless limit.nil?
        raise ArgumentError, "limit must be a positive whole number" unless limit.is_a?(Integer) && limit.positive?

        q << ["limit", limit.to_s]
      end
      q << ["cursor", cursor.to_s] if cursor && !cursor.to_s.empty?
      r = @cloud.request("GET", "/v1/sandboxes" + (q.empty? ? "" : "?#{URI.encode_www_form(q)}"))
      r = {} unless r.is_a?(Hash)
      nxt = r["next_cursor"]
      CloudSandboxPage.new(sandboxes: (r["sandboxes"] || []).map { |s| CloudSandbox.new(@cloud, s) },
                           next_cursor: nxt.is_a?(String) && !nxt.empty? ? nxt : nil)
    end

    # Every sandbox, following next_cursor page by page; stops if the server
    # sends a cursor it already sent. Without a block, an Enumerator. A server
    # that does not page answers everything at once, which is then the only page.
    def each(all: false, page_size: nil)
      return enum_for(:each, all: all, page_size: page_size) unless block_given?

      cursor = nil
      seen = {}
      loop do
        page = list_page(all: all, limit: page_size, cursor: cursor)
        page.sandboxes.each { |s| yield s }
        break if page.next_cursor.nil? || seen[page.next_cursor]

        seen[page.next_cursor] = true
        cursor = page.next_cursor
      end
      self
    end

    def get(id)
      CloudSandbox.new(@cloud, @cloud.request("GET", "/v1/sandboxes/#{Kosa8.enc(id)}")["sandbox"])
    end
  end

  # One cloud sandbox. +info+ is its state as of the last call (a Hash with
  # "id", "state", "template", "parent_id", "delete_after", "sleep_after_s",
  # "source", "region", "cost_usd", ... as the Cloud API's Sandbox schema).
  #
  # #checkpoint, #checkpoints, #rewind, #fork, #ports and #files need the host's
  # data plane. On hosts without it the API answers 501 (not_available /
  # not_supported), raised as Kosa8::UnsupportedError; not every kosa8 Cloud
  # host has it yet.
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
    #
    # Each exec runs in a fresh container: only /workspace persists, so cd,
    # export and packages installed elsewhere are gone by the next one. kosa8
    # Cloud cuts a buffered exec off after about 30 s, raised as
    # Kosa8::ExecTimeoutError; run long work in the background
    # (nohup sh -c '...' > /workspace/job.log 2>&1 &) and poll it. The request
    # (command and env) is at most 64 KiB (413 too_large).
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

    # Change its lifetime or sleep timer (PATCH). +ttl_s+ counts from now;
    # +clear_lifetime: true+ removes the automatic delete (sends ttl_s: null).
    # A new +sleep_after_s+ is recorded; the host keeps the idle time the
    # sandbox started with until it can change it in place. +notes+ holds the
    # server's notes, if any. Raises ArgumentError when nothing is given.
    def update(ttl_s: nil, delete_after: nil, sleep_after_s: nil, clear_lifetime: false)
      if clear_lifetime && !(ttl_s.nil? && delete_after.nil?)
        raise ArgumentError, "clear_lifetime cannot be combined with ttl_s or delete_after"
      end

      Cloud.check_lifetime(ttl_s, delete_after)
      Cloud.check_sleep_after(sleep_after_s)
      body = {}
      body["ttl_s"] = nil if clear_lifetime
      body["ttl_s"] = ttl_s unless ttl_s.nil?
      body["delete_after"] = delete_after unless delete_after.nil?
      body["sleep_after_s"] = sleep_after_s unless sleep_after_s.nil?
      raise ArgumentError, "give ttl_s:, delete_after:, sleep_after_s: or clear_lifetime: true" if body.empty?

      r = @cloud.request("PATCH", path, body)
      @info = r["sandbox"]
      @notes = r["notes"].is_a?(Array) ? r["notes"] : []
      self
    end

    # The server's notes from the last #update (an Array of sentences).
    def notes
      @notes || []
    end

    # Files in the sandbox: a CloudFiles. Needs the host's data plane; on hosts
    # without it the API answers 501 (not_available/not_supported), raised as
    # Kosa8::UnsupportedError. Not every kosa8 Cloud host has it yet.
    def files
      CloudFiles.new(@cloud, self)
    end

    # Save memory, processes and disk as a checkpoint and return it (a Hash:
    # "id", "label", "auto", "created_at", "bytes"). The newest 10 are kept.
    #
    # Needs the host's data plane; on hosts without it the API answers 501
    # (not_available/not_supported), raised as Kosa8::UnsupportedError. Not
    # every kosa8 Cloud host has it yet.
    def checkpoint(label = nil)
      body = {}
      unless label.nil?
        raise ArgumentError, "a checkpoint label is at most 200 characters" if label.to_s.length > 200

        body["label"] = label.to_s
      end
      @cloud.request("POST", path("/checkpoints"), body)["checkpoint"]
    end

    # Its checkpoints, oldest first. Does not wake a sleeping sandbox.
    #
    # Needs the host's data plane; on hosts without it the API answers 501
    # (not_available/not_supported), raised as Kosa8::UnsupportedError. Not
    # every kosa8 Cloud host has it yet.
    def checkpoints
      r = @cloud.request("GET", path("/checkpoints"))
      r.is_a?(Hash) ? (r["checkpoints"] || []) : []
    end

    # Go back to a checkpoint (its id, or the Hash #checkpoint returned). The
    # sandbox as it was is first saved as an automatic checkpoint, returned as
    # +backup+ in a CloudRewindResult.
    #
    # Needs the host's data plane; on hosts without it the API answers 501
    # (not_available/not_supported), raised as Kosa8::UnsupportedError. Not
    # every kosa8 Cloud host has it yet.
    def rewind(checkpoint_id)
      checkpoint_id = checkpoint_id["id"] if checkpoint_id.is_a?(Hash)
      raise ArgumentError, "rewind needs a checkpoint id" if checkpoint_id.nil? || checkpoint_id.to_s.empty?

      r = @cloud.request("POST", path("/rewind"), { "checkpoint_id" => checkpoint_id.to_s })
      r = {} unless r.is_a?(Hash)
      @info = r["sandbox"] if r["sandbox"].is_a?(Hash)
      CloudRewindResult.new(checkpoint: r["checkpoint"] || {}, backup: r["backup"], ms: r["ms"])
    end

    # +n+ (1 to 100) live copies of the sandbox as it is now, on its host, as
    # an Array of CloudSandbox. Each is held to the rules of a create
    # (payment, quotas); all or nothing.
    #
    # Needs the host's data plane; on hosts without it the API answers 501
    # (not_available/not_supported), raised as Kosa8::UnsupportedError. Not
    # every kosa8 Cloud host has it yet.
    def fork(n = 1)
      unless n.is_a?(Integer) && n.between?(1, Cloud::MAX_FORK)
        raise ArgumentError, "n must be a whole number from 1 to #{Cloud::MAX_FORK}"
      end

      r = @cloud.request("POST", path("/fork"), { "n" => n })
      r = {} unless r.is_a?(Hash)
      (r["sandboxes"] || []).map { |s| CloudSandbox.new(@cloud, s) }
    end

    # TCP ports listening in its running containers (Hashes: "port",
    # "address", "container", "loopback").
    #
    # Needs the host's data plane; on hosts without it the API answers 501
    # (not_available/not_supported), raised as Kosa8::UnsupportedError. Not
    # every kosa8 Cloud host has it yet.
    def ports
      r = @cloud.request("GET", path("/ports"))
      r.is_a?(Hash) ? (r["ports"] || []) : []
    end

    # "/v1/sandboxes/{id}" plus +suffix+.
    def path(suffix = "")
      "/v1/sandboxes/#{Kosa8.enc(id)}#{suffix}"
    end
  end

  # sandbox.files: files in a cloud sandbox, at most 8 MiB each. Paths are
  # absolute, such as /workspace/app.py; only /workspace outlives an exec. A
  # sleeping sandbox wakes first. File info Hashes have "name", "path",
  # "type" ("file" or "dir"), "size", "mode" and "mod_time".
  #
  # Needs the host's data plane; on hosts without it the API answers 501
  # (not_available/not_supported), raised as Kosa8::UnsupportedError. Not every
  # kosa8 Cloud host has it yet.
  class CloudFiles
    def initialize(cloud, sandbox)
      @cloud = cloud
      @sandbox = sandbox
    end

    def inspect
      "#<Kosa8::CloudFiles sandbox=#{@sandbox.id.inspect}>"
    end

    # The file's bytes, as a binary (ASCII-8BIT) String.
    def read(path)
      @cloud.request_bytes("GET", query("/files", path), raw: true)
    end

    # The file as text (UTF-8 by default).
    def read_text(path, encoding: Encoding::UTF_8)
      read(path).force_encoding(encoding)
    end

    # Create or replace a file with +content+ (a String; sent as raw bytes).
    # Returns its info Hash.
    def write(path, content)
      r = @cloud.request_bytes("PUT", query("/files", path), data: content.to_s)
      r.is_a?(Hash) ? (r["file"] || {}) : {}
    end

    # A folder's entries (default /workspace), as info Hashes.
    def list(path = "/workspace")
      r = @cloud.request("GET", query("/files/list", path))
      r.is_a?(Hash) ? (r["files"] || []) : []
    end

    # Make a folder and its parents; returns its info Hash.
    def mkdir(path)
      raise ArgumentError, "a path is required, e.g. /workspace/data" if path.nil? || path.to_s.empty?

      r = @cloud.request("POST", @sandbox.path("/files/mkdir"), { "path" => path.to_s })
      r.is_a?(Hash) ? (r["file"] || {}) : {}
    end

    # Remove a file, or a folder and everything in it with +recursive: true+.
    def delete(path, recursive: false)
      @cloud.request("DELETE", query("/files", path, recursive ? [%w[recursive 1]] : []))
      nil
    end

    private

    def query(suffix, path, extra = [])
      raise ArgumentError, "a path is required, e.g. /workspace/app.py" if path.nil? || path.to_s.empty?

      "#{@sandbox.path(suffix)}?#{URI.encode_www_form([["path", path.to_s]] + extra).gsub('+', '%20')}"
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
