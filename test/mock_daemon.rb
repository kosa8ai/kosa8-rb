# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "socket"
require "tmpdir"

# A tiny HTTP/1.1 server on a unix socket that answers like kosa8d.
class MockDaemon
  Req = Struct.new(:method, :path, :query, :headers, :body, keyword_init: true)
  attr_reader :socket_path, :requests

  # Whether this platform can serve a unix socket (Windows may not); memoized.
  def self.supported?
    return @supported if defined?(@supported)

    @supported = begin
      d = new
      d.close
      true
    rescue NotImplementedError, NameError, SystemCallError, IOError, SocketError
      false
    end
  end

  # Tests that need the mock daemon call this in setup.
  def self.require!(test)
    test.skip("unix-domain sockets are not available on this platform") unless supported?
  end

  def initialize
    # A short base: sun_path is about 104 bytes.
    @dir = File.directory?("/tmp") ? Dir.mktmpdir("k8rb", "/tmp") : Dir.mktmpdir("k8rb")
    @socket_path = File.join(@dir, "k.sock")
    begin
      @server = UNIXServer.new(@socket_path)
    rescue StandardError, NotImplementedError
      FileUtils.rm_rf(@dir)
      raise
    end
    @routes = []
    @requests = []
    @mu = Mutex.new
    @thread = Thread.new { loop { Thread.new(@server.accept) { |c| serve(c) } } }
  end

  def on(method, pattern, &handler)
    @mu.synchronize { @routes.unshift([method, pattern, handler]) }
  end

  def last
    @mu.synchronize { @requests.last }
  end

  def close
    @thread.kill
    @server.close
    FileUtils.rm_rf(@dir)
  end

  def self.json(status, obj)
    [:json, status, obj]
  end

  # A raw answer: status, extra headers, body bytes (Content-Length defaults to the body's).
  def self.raw(status, body, headers = {})
    [:raw, status, headers, body]
  end

  def self.frames(*frames)
    [:frames, frames]
  end

  def self.frame(stream, data)
    { "stream" => stream, "data" => Base64.strict_encode64(data) }
  end

  private

  def serve(c)
    line = c.gets or return
    method, target, = line.split(" ")
    headers = {}
    while (h = c.gets) && h != "\r\n"
      k, v = h.split(":", 2)
      headers[k.strip.downcase] = v.strip
    end
    body = +""
    if headers["transfer-encoding"].to_s.include?("chunked")
      loop do
        size = c.gets.to_s.strip.to_i(16)
        body << c.read(size) if size.positive?
        c.gets
        break if size.zero?
      end
    elsif headers["content-length"]
      body = c.read(headers["content-length"].to_i)
    end
    path, query = target.split("?", 2)
    req = Req.new(method: method, path: path, query: query.to_s, headers: headers, body: body)
    handler = @mu.synchronize do
      @requests << req
      (@routes.find { |m, p, _| m == method && (p.is_a?(Regexp) ? p.match?(path) : p == path) } || [])[2]
    end
    out = handler ? handler.call(req) : MockDaemon.json(404, "error" => "no route #{method} #{path}")
    if out[0] == :raw
      hdrs = { "Content-Length" => out[3].bytesize.to_s }.merge(out[2])
      c.write("HTTP/1.1 #{out[1]} X\r\n" + hdrs.map { |k, v| "#{k}: #{v}\r\n" }.join + "Connection: close\r\n\r\n")
      c.write(out[3])
    elsif out[0] == :json
      text = JSON.generate(out[2])
      c.write("HTTP/1.1 #{out[1]} X\r\nContent-Type: application/json\r\nContent-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}")
    else
      c.write("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
      out[1].each do |f|
        sleep(f.delete("_sleep")) if f["_sleep"]
        l = f.is_a?(String) ? f : JSON.generate(f) + "\n"
        c.write("#{l.bytesize.to_s(16)}\r\n#{l}\r\n")
        c.flush
      end
      c.write("0\r\n\r\n")
    end
  rescue StandardError => e
    warn "mock: #{e.class}: #{e.message}"
  ensure
    c.close
  end
end
