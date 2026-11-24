# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "socket"
require "uri"

# Streamed exec on kosa8 Cloud: POST /v1/sandboxes/{id}/exec {stream: true}
# answers NDJSON frames while the command prints ({stream, data: base64},
# an empty stdout frame with heartbeat: true every 15 s of silence, then
# {done: true, exit} or {done: true, error, code}). Not held to the 90 s of
# a buffered exec.
module Kosa8
  class Cloud
    # The longest timeout_s a streamed or background command takes (a day).
    STREAM_MAX_TIMEOUT_S = 86_400
    # A read that waits longer than this without a byte is a dead
    # connection, not a quiet command (heartbeats come every 15 s).
    STREAM_MIN_READ_TIMEOUT_S = 30

    alias initialize_without_stream initialize
    # stream_transport: an optional callable (method, url, headers, body,
    # read_timeout) { |chunk| ... } -> [status, error_body_or_nil, headers]
    # used for streamed answers instead of Net::HTTP (tests, proxies): it
    # yields each chunk of a 2xx answer as it arrives and returns the
    # body of an error answer.
    def initialize(stream_transport: nil, **kw)
      initialize_without_stream(**kw)
      @stream_transport = stream_transport || method(:net_http_stream)
    end

    # One streamed request: yields the answer's bytes as they arrive. A
    # refusal before the stream starts raises the usual typed error (a
    # refusal made before anything ran, such as a 429, is retried as
    # retry_policy allows); nothing is retried once bytes flow. A broken or
    # stalled stream raises Kosa8::StreamError.
    def stream(method, path, body)
      headers = { "Authorization" => "Bearer #{@key}", "User-Agent" => "kosa8-ruby/#{VERSION}",
                  "Accept" => "application/x-ndjson, application/json", "Content-Type" => "application/json" }
      payload = JSON.generate(body)
      read_timeout = [@timeout.to_f, STREAM_MIN_READ_TIMEOUT_S].max
      attempt = 1
      loop do
        started = false
        begin
          status, content, resp_headers = @stream_transport.call(method, @base_url + path, headers, payload,
                                                                 read_timeout) do |chunk|
            started = true
            begin
              yield chunk
            rescue Exception => e # rubocop:disable Lint/RescueException
              raise CallbackFailure.new(e)
            end
          end
        rescue CallbackFailure => e
          raise e.cause_error
        rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => e
          if started
            raise StreamError.new("kosa8 Cloud stopped sending the exec stream (no data or heartbeat in #{read_timeout.round} s)",
                                  method: method, path: path, code: "stream_stalled")
          end
          raise TimeoutError.new("kosa8 Cloud did not answer #{method} #{path} within #{read_timeout.round} s (#{e.message})",
                                 method: method, path: path)
        rescue SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError => e
          raise StreamError.new("the exec stream broke: #{e.message}", method: method, path: path, code: "stream_broken") if started

          raise ConnectionError.new("could not reach kosa8 Cloud at #{@base_url}: #{e.message}; " \
                                    "check the network connection and KOSA8_CLOUD_URL (or base_url:), then try again",
                                    method: method, path: path)
        end
        return nil if status.to_i < 400

        text = content.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        parsed = begin
          text.strip.empty? ? nil : JSON.parse(text)
        rescue JSON::ParserError
          text
        end
        e = Cloud.error(status.to_i, parsed, method, path, resp_headers)
        raise e unless !started && Cloud.pre_execution?(e) && @retry_policy.retry?(e, attempt)

        @sleeper.call(@retry_policy.delay(e, attempt))
        attempt += 1
      end
    end

    def self.check_stream_timeout(timeout_s)
      return if timeout_s.nil? || (timeout_s.is_a?(Integer) && timeout_s.between?(1, STREAM_MAX_TIMEOUT_S))

      raise ArgumentError, "timeout_s must be a whole number of seconds from 1 to #{STREAM_MAX_TIMEOUT_S}"
    end

    private

    def net_http_stream(method, url, headers, body, timeout)
      u = URI.parse(url)
      http = Net::HTTP.new(u.hostname, u.port)
      http.use_ssl = u.scheme == "https"
      http.open_timeout = [timeout, 30].min
      http.read_timeout = timeout
      http.write_timeout = timeout if http.respond_to?(:write_timeout=)
      req = Net::HTTPGenericRequest.new(method, !body.nil?, true, u.request_uri)
      headers.each { |k, v| req[k] = v }
      req.body = body unless body.nil?
      http.start do |h|
        h.request(req) do |resp|
          code = resp.code.to_i
          return [code, resp.read_body.to_s, resp.to_hash] if code >= 400

          resp.read_body { |chunk| yield chunk }
          return [code, nil, resp.to_hash]
        end
      end
    end
  end

  # Reads a streamed exec's NDJSON frames from chunks that split lines and
  # UTF-8 characters anywhere.
  class CloudExecStream # :nodoc:
    STREAMS = %w[stdout stderr].freeze
    attr_reader :exit_code, :done

    def initialize(path, on_text)
      @path = path
      @on_text = on_text
      @line = +"".b
      @pending = { "stdout" => +"".b, "stderr" => +"".b }
      @out = { "stdout" => +"", "stderr" => +"" }
      @exit_code = nil
      @done = false
      @whole = nil
    end

    def stdout
      @out["stdout"]
    end

    def stderr
      @out["stderr"]
    end

    # A buffered answer (an ExecResult) when the server sent one instead of frames.
    attr_reader :whole

    def feed(chunk)
      return if @done

      @line << chunk.to_s.b
      while (i = @line.index("\n".b))
        line = @line.slice!(0..i)
        frame(line)
        return if @done
      end
    end

    # The stream ended: the last line, then any bytes held for a split character.
    def finish
      frame(@line) unless @done || @line.strip.empty?
      flush
      return if @done || @whole

      raise StreamError.new("the exec stream ended before the command finished (no final frame)",
                            stdout: stdout, stderr: stderr, method: "POST", path: @path, code: "stream_broken")
    end

    private

    def frame(line)
      text = line.strip
      return if text.empty?

      f = begin
        JSON.parse(text.force_encoding(Encoding::UTF_8))
      rescue JSON::ParserError
        raise StreamError.new("kosa8 Cloud sent a stream line that is not JSON: #{text[0, 200].inspect}",
                              stdout: stdout, stderr: stderr, method: "POST", path: @path, code: "stream_broken")
      end
      return unless f.is_a?(Hash)

      if f["done"]
        flush
        @done = true
        fail_with(f) unless f["error"].nil?
        @exit_code = f["exit"].is_a?(Integer) ? f["exit"] : nil
        return
      end
      if f.key?("exit") && f.key?("stdout") && !f.key?("stream")
        @whole = f # a server that ignored stream: true answered the whole result
        @done = true
        return
      end
      name = f["stream"]
      data = f["data"]
      return unless STREAMS.include?(name) && data.is_a?(String) && !data.empty? # a heartbeat, or unknown

      bytes = begin
        data.unpack1("m0")
      rescue ArgumentError
        data.b
      end
      emit(name, decode(name, bytes))
    end

    def emit(name, text)
      return if text.empty?

      @out[name] << text
      @on_text&.call(name, text)
    end

    def flush
      STREAMS.each do |name|
        rest = @pending[name]
        @pending[name] = +"".b
        emit(name, rest.force_encoding(Encoding::UTF_8).scrub) unless rest.empty?
      end
    end

    # The text of +bytes+ after what was held back, holding back a
    # trailing incomplete UTF-8 character for the next chunk.
    def decode(name, bytes)
      buf = @pending[name] + bytes.b
      cut = buf.bytesize
      1.upto([3, buf.bytesize].min) do |k|
        b = buf.getbyte(buf.bytesize - k)
        break if b < 0x80 # ASCII: nothing is split
        next unless b >= 0xC0 # a lead byte

        need = if b >= 0xF0 then 4
               elsif b >= 0xE0 then 3
               else 2
               end
        cut = buf.bytesize - k if need > k
        break
      end
      @pending[name] = buf.byteslice(cut..-1) || +"".b
      buf.byteslice(0, cut).force_encoding(Encoding::UTF_8).scrub
    end

    def fail_with(f)
      msg = f["error"].to_s
      msg = "the command failed" if msg.empty?
      code = f["code"].is_a?(String) ? f["code"] : nil
      if code == "exec_timeout" || msg.include?("timeout_s")
        e = ExecTimeoutError.new(msg, status: 504, daemon_message: msg, method: "POST", path: @path,
                                      code: "exec_timeout")
        e.stdout = stdout
        e.stderr = stderr
        raise e
      end
      raise StreamError.new(msg, stdout: stdout, stderr: stderr, method: "POST", path: @path, code: code)
    end
  end

  class CloudSandbox
    alias exec_buffered exec

    # Run a command and wait for it. A String runs through sh -c, an Array is
    # the argv. A sleeping sandbox wakes for it.
    #
    # With +on_stdout+ / +on_stderr+ (callables taking the text), +stream:
    # true+ or a +timeout_s+ over 90, it runs as a streamed exec
    # (#exec_stream): the callbacks get the output as the command prints it
    # and the command is not held to the 90 s of a buffered exec. The result
    # is a CloudExecResult either way. +stream: false+ always buffers.
    def exec(cmd, image: nil, env: nil, timeout_s: nil, stream: nil, on_stdout: nil, on_stderr: nil)
      long = timeout_s.is_a?(Numeric) && timeout_s > Cloud::EXEC_LIMIT_S
      if stream == true || (stream.nil? && (on_stdout || on_stderr || long))
        return exec_stream(cmd, image: image, env: env, timeout_s: timeout_s, on_stdout: on_stdout,
                                on_stderr: on_stderr)
      end

      r = exec_buffered(cmd, image: image, env: env, timeout_s: timeout_s)
      on_stdout&.call(r.stdout) unless r.stdout.empty?
      on_stderr&.call(r.stderr) unless r.stderr.empty?
      r
    end

    # Run a command and read its output as it prints (a streamed exec); not
    # held to the 90 s of a buffered exec. +timeout_s+ (1 s to a day) stops
    # it in the sandbox. Yields (stream, text) with stream "stdout" or
    # "stderr" (UTF-8, decoded across chunk edges; heartbeats skipped), and
    # calls +on_stdout+ / +on_stderr+ likewise; returns a CloudExecResult
    # with everything it printed.
    #
    #   box.exec_stream("make test") { |_stream, text| print text }
    #
    # A refusal (bad request, sandbox not running) raises before any output.
    # A command stopped at +timeout_s+ raises Kosa8::ExecTimeoutError (its
    # #stdout / #stderr hold the output so far); a stream that breaks or
    # ends early raises Kosa8::StreamError, with the output so far.
    def exec_stream(cmd, image: nil, env: nil, timeout_s: nil, on_stdout: nil, on_stderr: nil, &block)
      argv = cmd.is_a?(String) ? ["sh", "-c", cmd] : cmd.to_a
      raise ArgumentError, "exec_stream needs a command" if argv.empty?

      Cloud.check_stream_timeout(timeout_s)
      body = { "cmd" => argv, "stream" => true }
      body["image"] = image unless image.nil?
      body["env"] = Cloud.env_list(env) if env && !env.empty?
      body["timeout_s"] = timeout_s unless timeout_s.nil?
      cbs = { "stdout" => on_stdout, "stderr" => on_stderr }
      reader = CloudExecStream.new(path("/exec"), lambda { |name, text|
        cbs[name]&.call(text)
        block&.call(name, text)
      })
      @cloud.stream("POST", path("/exec"), body) { |chunk| reader.feed(chunk) }
      reader.finish
      if (w = reader.whole)
        res = CloudExecResult.new(exit_code: w["exit"], stdout: w["stdout"].to_s, stderr: w["stderr"].to_s,
                                  woke_ms: w["woke_ms"], failure_class: nil, retryable: nil)
        fc, rt = Kosa8.exec_failure(w["exit"])
        res.failure_class = w["failure_class"].is_a?(String) ? w["failure_class"] : fc
        res.retryable = [true, false].include?(w["retryable"]) ? w["retryable"] : rt
        { "stdout" => res.stdout, "stderr" => res.stderr }.each do |n, t|
          next if t.empty?

          cbs[n]&.call(t)
          block&.call(n, t)
        end
        return res
      end
      fc, rt = Kosa8.exec_failure(reader.exit_code)
      CloudExecResult.new(exit_code: reader.exit_code, stdout: reader.stdout, stderr: reader.stderr, woke_ms: nil,
                          failure_class: fc, retryable: rt, stdout_truncated: false, stderr_truncated: false,
                          stdout_bytes: reader.stdout.bytesize, stderr_bytes: reader.stderr.bytesize)
    end
  end
end
