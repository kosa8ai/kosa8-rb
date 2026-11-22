# frozen_string_literal: true

require "json"
require "socket"

# A fake kosa8 Cloud API on a local socket, spoken to over the SDK's own
# Net::HTTP transport. The handler gets each request (a Hash: :method,
# :path (with query), :headers (lower-case names), :body (parsed JSON or
# nil), :raw) and answers [status, payload (Hash, String or nil), headers].
class FakeCloud
  KEY = "k8c_live_fakekey"
  attr_reader :seen, :url

  def initialize(&handler)
    @handler = handler
    @seen = []
    @lock = Mutex.new
    @server = TCPServer.new("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{@server.addr[1]}"
    @thread = Thread.new { serve }
    @thread.report_on_exception = false
  end

  def cloud(**kw)
    Kosa8::Cloud.new(api_key: KEY, base_url: @url, env: {}, timeout: 10, sleeper: ->(_s) {}, **kw)
  end

  # Requests whose method and path (without query) match.
  def calls(method, path)
    @lock.synchronize { @seen.select { |s| s[:method] == method && s[:path].split("?", 2)[0] == path } }
  end

  def close
    @server.close unless @server.closed?
    @thread.kill
  end

  private

  def serve
    loop do
      c = @server.accept
      Thread.new(c) { |conn| handle(conn) }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def handle(conn)
    loop do
      line = conn.gets
      break if line.nil?

      method, target = line.split(" ", 3)
      headers = {}
      while (h = conn.gets) && h != "\r\n"
        k, v = h.split(":", 2)
        headers[k.strip.downcase] = v.to_s.strip
      end
      len = headers["content-length"].to_i
      raw = len.positive? ? conn.read(len) : nil
      body = begin
        raw && headers["content-type"] == "application/json" ? JSON.parse(raw) : nil
      rescue JSON::ParserError
        nil
      end
      req = { method: method, path: target, headers: headers, body: body, raw: raw }
      @lock.synchronize { @seen << req }
      status, payload, extra = begin
        @handler.call(req)
      rescue StandardError => e
        [500, { "error" => "fake_failed", "message" => "#{e.class}: #{e.message}" }]
      end
      out = if payload.nil? then ""
            elsif payload.is_a?(String) then payload
            else JSON.generate(payload)
            end
      ctype = payload.is_a?(String) ? "application/x-ndjson" : "application/json"
      head = +"HTTP/1.1 #{status} X\r\nContent-Type: #{ctype}\r\nContent-Length: #{out.bytesize}\r\n"
      (extra || {}).each { |k, v| head << "#{k}: #{v}\r\n" }
      conn.write(head + "\r\n" + out)
    end
  rescue IOError, SystemCallError
    nil
  ensure
    conn.close unless conn.closed?
  end
end
