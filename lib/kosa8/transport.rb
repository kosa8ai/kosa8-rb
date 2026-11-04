# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "rbconfig"
require "socket"
require "uri"

module Kosa8
  APPROVAL_HEADER = "X-Kosa8-Approval"
  ACTOR_HEADER = "X-Kosa8-Actor"
  AGENT_TOKEN_HEADER = "X-Kosa8-Agent-Token"

  # $HOME/.kosa8/run/kosa8.sock (pkg/paths).
  def self.default_socket_path
    File.join(Dir.home, ".kosa8", "run", "kosa8.sock")
  end

  # $HOME/.kosa8/worker.json: the connection `kosa8 wsl setup` (Windows) and
  # `kosa8 worker join` save, which the CLI uses whenever KOSA8_HOST is unset.
  def self.default_worker_file
    File.join(Dir.home, ".kosa8", "worker.json")
  end

  # Where requests go: a unix socket or a remote worker. default_socket is true
  # when nothing chose the socket: no host, no saved worker, no socket_path.
  Endpoint = Struct.new(:kind, :socket_path, :scheme, :host, :port, :base_path, :token, :default_socket,
                        keyword_init: true) do
    def target
      kind == :unix ? "unix://#{socket_path}" : "#{scheme}://#{host}:#{port}"
    end
  end

  def self.loopback?(host)
    h = host.to_s.delete("[]")
    h == "localhost" || h == "::1" || h.start_with?("127.")
  end

  # The saved worker connection as {"host", "token", "insecure"}, or nil when
  # the file is missing, unreadable, not a JSON object or names no host.
  def self.load_saved_worker(path)
    return nil if path.nil? || path == false || path.to_s.empty?

    w = JSON.parse(File.read(path.to_s))
    return nil unless w.is_a?(Hash) && w["host"].is_a?(String) && !w["host"].strip.empty?

    { "host" => w["host"], "token" => w["token"].is_a?(String) ? w["token"] : nil, "insecure" => w["insecure"] == true }
  rescue SystemCallError, IOError, JSON::ParserError, EncodingError
    nil
  end

  # The CLI's rules (internal/cli/worker.go targetHost/targetToken/targetInsecure):
  # 1. an explicit host:, or a non-blank KOSA8_HOST: https://, http://, tcp://,
  #    unix:// or a bare host:port; KOSA8_TOKEN goes only to a KOSA8_HOST host;
  # 2. else, unless socket_path: was given, the saved worker in worker_file
  #    (nil = ~/.kosa8/worker.json, false or "" = none), with its token unless
  #    token: is given, and its "insecure": true;
  # 3. else the unix socket.
  # Plain http to a non-loopback host is refused unless insecure (or KOSA8_INSECURE=1).
  def self.resolve_endpoint(host: nil, socket_path: nil, token: nil, insecure: false, env: ENV, worker_file: nil)
    explicit = !host.nil? && !host.empty?
    raw = (explicit ? host : env["KOSA8_HOST"].to_s).strip
    if raw.empty?
      saved = socket_path.nil? ? load_saved_worker(worker_file.nil? ? default_worker_file : worker_file) : nil
      if saved.nil?
        return Endpoint.new(kind: :unix, socket_path: socket_path || default_socket_path,
                            default_socket: socket_path.nil?)
      end

      tok = token.nil? || token.empty? ? saved["token"] : token
      return parse_host(saved["host"].strip, token: tok, insecure: insecure || saved["insecure"], env: env,
                                             source: "the saved worker host (#{worker_file || default_worker_file})")
    end
    token = env["KOSA8_TOKEN"] if (token.nil? || token.empty?) && !explicit
    parse_host(raw, token: token, insecure: insecure, env: env, source: explicit ? "host" : "KOSA8_HOST")
  end

  def self.parse_host(raw, token:, insecure:, env:, source:)
    raw = raw.sub(%r{/+\z}, "")
    h = raw.sub(%r{\A([A-Za-z][A-Za-z0-9+.-]*)://}) { "#{Regexp.last_match(1).downcase}://" }
    if h.start_with?("unix://")
      return Endpoint.new(kind: :unix, socket_path: h.sub("unix://", ""), default_socket: false)
    elsif h.start_with?("tcp://")
      h = "http://" + h.sub("tcp://", "")
    elsif h =~ %r{\A([a-z][a-z0-9+.-]*)://} && !%w[http https].include?(Regexp.last_match(1))
      raise Error, "#{source} scheme \"#{Regexp.last_match(1)}\" is not supported; use http://, https://, tcp:// or unix://"
    elsif h !~ %r{\Ahttps?://}
      h = "http://" + h
    end
    u = begin
      URI.parse(h)
    rescue URI::InvalidURIError
      nil
    end
    raise Error, "#{source} #{raw.inspect} names no host" if u.nil? || u.host.nil? || u.host.empty?

    if u.scheme == "http" && !insecure && env["KOSA8_INSECURE"] != "1" && !loopback?(u.host)
      raise Error, "refusing to talk to #{u.host}:#{u.port} over plain http: the token and every request would cross " \
                   "the network unencrypted. Use https://#{u.host}:#{u.port} (a worker behind a TLS-terminating tunnel " \
                   "or proxy), or pass insecure: true / KOSA8_INSECURE=1 if this link is already private and trusted"
    end
    Endpoint.new(kind: :tcp, scheme: u.scheme, host: u.host, port: u.port, base_path: u.path.to_s.sub(%r{/+\z}, ""),
                 token: token && !token.empty? ? token : nil, default_socket: false)
  end
  private_class_method :parse_host

  def self.windows?
    RbConfig::CONFIG["host_os"] =~ /mswin|mingw|cygwin/ ? true : false
  end

  def self.enc(s)
    URI.encode_www_form_component(s.to_s).gsub("+", "%20")
  end

  # Net::HTTP over a unix socket.
  class UnixHTTP < Net::HTTP
    attr_accessor :socket_path

    def connect
      raise Errno::EAFNOSUPPORT, "unix sockets are not available in this Ruby" unless defined?(UNIXSocket)

      io = UNIXSocket.new(@socket_path)
      @socket = Net::BufferedIO.new(io, read_timeout: @read_timeout, continue_timeout: @continue_timeout,
                                        debug_output: @debug_output)
      on_connect
    end
  end

  # An IO-like over an Enumerable of string chunks, for a chunked request body.
  class ChunkReader
    def initialize(chunks)
      @enum = chunks.each
      @buf = +""
      @eof = false
    end

    def read(len = nil, outbuf = nil)
      until @eof || (len && @buf.bytesize >= len)
        begin
          @buf << @enum.next.to_s.b
        rescue StopIteration
          @eof = true
        end
      end
      return nil if @buf.empty? && len

      out = len ? @buf.byteslice(0, len) : @buf
      @buf = len ? (@buf.byteslice(len..-1) || +"") : +""
      outbuf ? outbuf.replace(out) : out
    end
  end

  # Carries an exception raised by a caller's callback past raw's network
  # rescue; raw re-raises the original.
  class CallbackFailure < Exception # rubocop:disable Lint/InheritException
    attr_reader :cause_error

    def initialize(err)
      super(err.message)
      @cause_error = err
    end
  end

  # Sends requests to the daemon; the client builds on it.
  class Transport
    attr_reader :endpoint

    def initialize(socket_path: nil, host: nil, token: nil, insecure: false, actor: "tool", agent_token: nil,
                   headers: {}, timeout: nil, env: ENV, worker_file: nil)
      @endpoint = Kosa8.resolve_endpoint(host: host, socket_path: socket_path, token: token, insecure: insecure, env: env,
                                         worker_file: worker_file)
      raise Error, "actor must be human, agent or tool, not #{actor.inspect}" unless %w[human agent tool].include?(actor)

      @actor = actor
      @agent_token = agent_token || env["KOSA8_AGENT_TOKEN"]
      @headers = headers || {}
      @timeout = timeout
    end

    # One request; yields the Net::HTTPResponse (body unread) and returns the block's value.
    def raw(method, path, query: nil, body: nil, raw_body: nil, approval: nil, timeout: nil, stream: false)
      full = (@endpoint.kind == :tcp ? @endpoint.base_path.to_s : "") + path
      q = (query || {}).each_with_object([]) do |(k, v), a|
        next if v.nil? || v == false

        a << [k.to_s, v == true ? "1" : v.to_s]
      end
      full += "?" + URI.encode_www_form(q) unless q.empty?
      req = Net::HTTPGenericRequest.new(method, !raw_body.nil? || !body.nil?, true, full)
      req["Accept"] = "application/json"
      req[ACTOR_HEADER] = @actor
      @headers.each { |k, v| req[k] = v }
      if !raw_body.nil?
        req["Content-Type"] = "application/octet-stream"
        if raw_body.is_a?(String)
          req.body = raw_body
        else
          req["Transfer-Encoding"] = "chunked"
          req.body_stream = raw_body.respond_to?(:read) ? raw_body : ChunkReader.new(raw_body)
        end
      elsif !body.nil?
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end
      req[APPROVAL_HEADER] = approval.strip if approval && !approval.strip.empty?
      req[AGENT_TOKEN_HEADER] = @agent_token if @agent_token && !@agent_token.empty?
      req["Authorization"] = "Bearer #{@endpoint.token}" if @endpoint.kind == :tcp && @endpoint.token
      http = connection
      t = timeout || @timeout
      if t
        http.open_timeout = [t, 30].min
        http.read_timeout = t
      elsif stream
        # A run, exec or attach can be silent for as long as the command
        # likes; Net::HTTP's 60 s default would cut it off. Wait for it.
        http.read_timeout = nil
      end
      begin
        http.start { |h| h.request(req) { |resp| return yield(resp) } }
      rescue CallbackFailure => e
        raise e.cause_error
      rescue Net::ReadTimeout, Net::OpenTimeout => e
        raise TimeoutError.new("#{method} #{path} timed out talking to #{@endpoint.target}: #{e.message}",
                               method: method, path: path)
      rescue SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError => e
        # Windows reports a missing unix socket path as ENETDOWN.
        absent = e.is_a?(Errno::ENOENT) || e.is_a?(Errno::ECONNREFUSED) ||
                 (Kosa8.windows? && @endpoint.kind == :unix && e.is_a?(Errno::ENETDOWN))
        hint = absent ? " (is kosa8 installed and its daemon running? start it with `kosa8 daemon start`)" : ""
        if @endpoint.kind == :unix && @endpoint.default_socket && Kosa8.windows?
          hint += "; on Windows the engine runs in WSL2: run `kosa8 wsl setup`, or set KOSA8_HOST"
        end
        raise ConnectionError.new("kosa8 daemon unreachable at #{@endpoint.target}: #{e.message}#{hint}",
                                  method: method, path: path)
      end
    end

    # A request whose answer is JSON.
    def json(method, path, **kw)
      raw(method, path, **kw) do |resp|
        text = resp.read_body.to_s
        parsed = decode(text)
        raise Kosa8.error_from_response(resp.code.to_i, parsed, method: method, path: path) if resp.code.to_i >= 400

        parsed
      end
    end

    # A request whose answer is NDJSON frames; yields each, data decoded from base64.
    def frames(method, path, **kw)
      raw(method, path, stream: true, **kw) do |resp|
        if resp.code.to_i >= 400
          raise Kosa8.error_from_response(resp.code.to_i, decode(resp.read_body.to_s), method: method, path: path)
        end

        buf = +""
        emit = lambda do |line|
          next if line.empty?

          frame = begin
            Kosa8.decode_frame(JSON.parse(line))
          rescue JSON::ParserError, ArgumentError => e
            raise ProtocolError.new("#{method} #{path}: the daemon sent a frame that is not valid NDJSON " \
                                    "(#{e.message}): #{line[0, 200].inspect}", method: method, path: path)
          end
          # Errors from the caller's own callbacks must come out as they are,
          # not relabelled as a lost connection by the rescue in raw.
          begin
            yield frame
          rescue Kosa8::Error
            raise
          rescue StandardError => e
            raise CallbackFailure.new(e)
          end
        end
        resp.read_body do |chunk|
          buf << chunk
          while (i = buf.index("\n"))
            emit.call(buf.slice!(0..i).strip)
          end
        end
        emit.call(buf.strip)
        nil
      end
    end

    private

    def connection
      if @endpoint.kind == :unix
        h = UnixHTTP.new("kosa8", 80)
        h.socket_path = @endpoint.socket_path
        h
      else
        h = Net::HTTP.new(@endpoint.host, @endpoint.port)
        h.use_ssl = @endpoint.scheme == "https"
        h
      end
    end

    def decode(text)
      return nil if text.strip.empty?

      JSON.parse(text)
    rescue JSON::ParserError
      text
    end
  end

  def self.decode_frame(f)
    f["data"] = Base64.strict_decode64(f["data"]) if f["data"].is_a?(String) && !f["data"].empty?
    f
  end
end
