# frozen_string_literal: true

require "base64"
require "pathname"
require "rubygems/package"
require "stringio"

module Kosa8
  # A file a code run produced: today, a chart as a PNG. +data+ is a binary String.
  Artifact = Struct.new(:type, :name, :data, keyword_init: true)

  # The outcome of run_code. A non-zero exit_code is not an error.
  CodeResult = Struct.new(:exit_code, :stdout, :stderr, :language, :image, :artifacts, :duration_ms, :timed_out,
                          :truncated, keyword_init: true) do
    def ok?
      exit_code.zero? && !timed_out
    end
  end

  # The outcome of one command in a session. +cwd+ is where the shell is now.
  ShellResult = Struct.new(:exit_code, :stdout, :stderr, :cwd, :duration_ms, :timed_out, :truncated,
                           keyword_init: true) do
    def ok?
      exit_code.zero? && !timed_out
    end
  end

  # The outcome of a git operation; +status+, +log+ or +branches+ are filled for those ops.
  # A git failure is ok == false, not an exception.
  GitResult = Struct.new(:op, :ok, :exit_code, :stdout, :stderr, :path, :status, :log, :branches,
                         keyword_init: true) do
    def ok?
      ok
    end
  end

  # How long the daemon lets a snippet or session command run by default
  # (codeTimeoutDefault), and a git operation (gitTimeout).
  CODE_TIMEOUT_DEFAULT_S = 300
  GIT_TIMEOUT_S = 600

  # The sandbox toolbox: run code, files and git, shell sessions, terminals,
  # previews, lifecycle and templates. Included in Kosa8::Client; every method
  # maps to one daemon route (see https://docs.kosa8.com/guides/native-api/).
  module Toolbox
    # --- code -----------------------------------------------------------------

    # POST …/code: run a Python, JavaScript or TypeScript snippet. It starts in
    # /workspace. Charts a Python snippet draws with matplotlib come back in
    # +artifacts+ as PNG bytes.
    def run_code(sandbox, code, language: "python", image: nil, env: nil, timeout_s: nil, approval: nil)
      body = { language: language, code: code }
      body[:image] = image if image
      body[:env] = env.to_h if env && !env.empty?
      body[:timeout_s] = timeout_s if timeout_s && timeout_s.positive?
      d = @transport.json("POST", sb(sandbox, "code"), body: body, approval: approval,
                                                      timeout: (timeout_s || CODE_TIMEOUT_DEFAULT_S) + 120) || {}
      CodeResult.new(
        exit_code: d["exit"].to_i, stdout: d["stdout"].to_s, stderr: d["stderr"].to_s,
        language: d["language"].to_s, image: d["image"].to_s,
        artifacts: (d["artifacts"] || []).map do |a|
          Artifact.new(type: a["type"].to_s, name: a["name"].to_s, data: Base64.decode64(a["data"].to_s).b)
        end,
        duration_ms: d["duration_ms"].to_i, timed_out: d["timed_out"] == true, truncated: d["truncated"] == true
      )
    end

    # --- files ----------------------------------------------------------------

    # GET …/files: a folder in the workspace (or one entry).
    def list_files(sandbox, path = "/workspace")
      d = @transport.json("GET", sb(sandbox, "files"), query: { path: path })
      (d.is_a?(Hash) ? d["files"] : nil) || []
    end

    # GET …/files/stat: one entry, not following a symlink.
    def stat_file(sandbox, path)
      @transport.json("GET", sb(sandbox, "files", "stat"), query: { path: path })
    end

    # GET …/files/content: a file's bytes, as a binary String.
    def read_file(sandbox, path)
      route = sb(sandbox, "files", "content")
      @transport.raw("GET", route, query: { path: path }) do |resp|
        data = resp.read_body.to_s.b
        code = resp.code.to_i
        if code >= 400
          raise Kosa8.error_from_response(code, decode_body(data), method: "GET", path: route)
        end

        want = resp["Content-Length"]
        if want && want.to_i != data.bytesize
          raise StreamError.new("#{path}: got #{data.bytesize} of #{want} bytes", method: "GET", path: route)
        end

        data
      end
    end

    def read_text(sandbox, path, encoding: Encoding::UTF_8)
      read_file(sandbox, path).force_encoding(encoding)
    end

    # PUT …/files/content: replace a file (a String, binary or text), making its folders.
    def write_file(sandbox, path, data, mode: nil, approval: nil)
      q = { path: path }
      q[:mode] = mode if mode
      @transport.json("PUT", sb(sandbox, "files", "content"), query: q, raw_body: data.to_s.b, approval: approval)
    end

    # DELETE …/files: a file, or with recursive: a folder.
    def delete_file(sandbox, path, recursive: false, approval: nil)
      @transport.json("DELETE", sb(sandbox, "files"), query: { path: path, recursive: recursive }, approval: approval)
    end

    def make_dir(sandbox, path, approval: nil)
      @transport.json("POST", sb(sandbox, "files", "mkdir"), body: { path: path }, approval: approval)
    end

    def move_file(sandbox, from, to, approval: nil)
      @transport.json("POST", sb(sandbox, "files", "move"), body: { from: from, to: to }, approval: approval)
    end

    # --- git ------------------------------------------------------------------

    # POST …/git: +op+ is clone, status, add, commit, push, pull, checkout,
    # branches, log or diff; +fields+ are that op's (url:, path:, branch:,
    # message:, token:…). A git failure returns ok == false.
    def git(sandbox, op, approval: nil, **fields)
      body = { op: op }
      fields.each { |k, v| body[k] = v unless v.nil? }
      d = @transport.json("POST", sb(sandbox, "git"), body: body, approval: approval, timeout: GIT_TIMEOUT_S + 120) || {}
      GitResult.new(op: d["op"] || op.to_s, ok: d["ok"] == true, exit_code: d["exit"].to_i, stdout: d["stdout"].to_s,
                    stderr: d["stderr"].to_s, path: d["path"].to_s, status: d["status"], log: d["log"],
                    branches: d["branches"])
    end

    def git_clone(sandbox, url, path = nil, **kw)
      git(sandbox, "clone", url: url, path: path, **kw)
    end

    def git_status(sandbox, path, **kw)
      git(sandbox, "status", path: path, **kw)
    end

    # Stage everything (unless add_all: false) and commit.
    def git_commit(sandbox, path, message, add_all: true, **kw)
      if add_all
        r = git(sandbox, "add", path: path, approval: kw[:approval])
        return r unless r.ok
      end
      git(sandbox, "commit", path: path, message: message, **kw)
    end

    # --- sessions -------------------------------------------------------------

    # POST …/sessions: a shell that keeps cd and export between commands.
    def create_session(sandbox, name = nil, image: nil, env: nil, approval: nil)
      body = {}
      body[:name] = name if name
      body[:image] = image if image
      body[:env] = env.to_h if env && !env.empty?
      @transport.json("POST", sb(sandbox, "sessions"), body: body, approval: approval)
    end

    def list_sessions(sandbox)
      @transport.json("GET", sb(sandbox, "sessions")) || []
    end

    # POST …/sessions/{name}/exec: run one command line in the session.
    def session_exec(sandbox, session, command, timeout_s: nil, approval: nil)
      body = { command: command }
      body[:timeout_s] = timeout_s if timeout_s && timeout_s.positive?
      d = @transport.json("POST", sb(sandbox, "sessions", Kosa8.enc(session), "exec"), body: body, approval: approval,
                                                                                     timeout: (timeout_s || CODE_TIMEOUT_DEFAULT_S) + 120) || {}
      ShellResult.new(exit_code: d["exit"].to_i, stdout: d["stdout"].to_s, stderr: d["stderr"].to_s, cwd: d["cwd"].to_s,
                      duration_ms: d["duration_ms"].to_i, timed_out: d["timed_out"] == true,
                      truncated: d["truncated"] == true)
    end

    # Run a command in a session, making the session on first use.
    def shell(sandbox, command, session: "main", **kw)
      begin
        return session_exec(sandbox, session, command, **kw)
      rescue NotFoundError => e
        raise unless "#{e.daemon_message} #{e.message}".include?("no such session")
      end
      create_session(sandbox, session, approval: kw[:approval])
      session_exec(sandbox, session, command, **kw)
    end

    def delete_session(sandbox, session, approval: nil)
      @transport.json("DELETE", sb(sandbox, "sessions", Kosa8.enc(session)), approval: approval)
    end

    # --- terminals ------------------------------------------------------------

    # POST …/pty: a container with a terminal; returns its id. Connect to
    # /kosa8/v1/sandboxes/{id}/containers/{cid}/tty with any WebSocket client:
    # binary messages are the terminal, text messages JSON control.
    def start_pty(sandbox, image: nil, command: nil, cols: 0, rows: 0, env: nil, approval: nil)
      body = {}
      body[:image] = image if image
      body[:command] = command.to_a if command && !command.empty?
      if cols.to_i.positive? && rows.to_i.positive?
        body[:cols] = cols
        body[:rows] = rows
      end
      body[:env] = env.to_h if env && !env.empty?
      @transport.json("POST", sb(sandbox, "pty"), body: body, approval: approval)["id"]
    end

    def resize_pty(sandbox, container, cols, rows)
      @transport.json("POST", sb(sandbox, "containers", Kosa8.enc(container), "resize"), body: { cols: cols, rows: rows })
    end

    # --- previews -------------------------------------------------------------

    # POST …/previews: a signed link to a web server in the sandbox that expires.
    def create_preview(sandbox, port, session: nil, container: nil, expires_in_s: nil, approval: nil)
      body = { port: port }
      body[:session] = session if session
      body[:container] = container if container
      body[:expires_in_s] = expires_in_s if expires_in_s && expires_in_s.positive?
      @transport.json("POST", sb(sandbox, "previews"), body: body, approval: approval)
    end

    # POST /kosa8/v1/previews/rotate: end every preview link at once.
    def revoke_previews(approval: nil)
      @transport.json("POST", "/kosa8/v1/previews/rotate", approval: approval)
    end

    # --- lifecycle ------------------------------------------------------------

    # POST …/lifecycle: change auto-stop, auto-delete, TTL or ephemeral.
    # Arguments left nil keep their value; 0 turns one off.
    def set_lifecycle(sandbox, auto_stop_min: nil, auto_delete_min: nil, ttl_min: nil, ephemeral: nil, approval: nil)
      body = { auto_stop_min: auto_stop_min, auto_delete_min: auto_delete_min, ttl_min: ttl_min, ephemeral: ephemeral }
             .reject { |_, v| v.nil? }
      @transport.json("POST", sb(sandbox, "lifecycle"), body: body, approval: approval)
    end

    # --- templates ------------------------------------------------------------

    def list_templates
      @transport.json("GET", "/kosa8/v1/templates") || []
    end

    def delete_template(name, approval: nil)
      @transport.json("DELETE", "/kosa8/v1/templates/#{Kosa8.enc(name)}", approval: approval)
    end

    # POST /kosa8/v1/templates: build context_dir's Dockerfile in a throwaway
    # sandbox and keep the image as a template. Build output goes to on_output
    # (or the block) as it arrives; returns the final frame. A failed build
    # raises Kosa8::StreamError.
    def build_template(name, context_dir = ".", dockerfile: "Dockerfile", build_args: nil, egress: nil, replace: false,
                       on_output: nil, approval: nil, &blk)
      on_output ||= blk
      q = [["name", name], ["dockerfile", dockerfile]]
      (build_args || {}).each { |k, v| q << ["buildarg", "#{k}=#{v}"] }
      q << ["egress", egress] if egress
      q << %w[replace 1] if replace
      ctx = Toolbox.tar_dir(context_dir, dockerfile)
      route = "/kosa8/v1/templates?" + URI.encode_www_form(q)
      last = nil
      @transport.frames("POST", route, raw_body: ctx, approval: approval) do |f|
        next if last

        if f["done"]
          if f["error"].is_a?(String) && !f["error"].empty?
            raise StreamError.new(f["error"], daemon_message: f["error"], method: "POST", path: "/kosa8/v1/templates")
          end

          last = f
          next
        end
        on_output&.call(f["data"]) if f["data"].is_a?(String) && !f["data"].empty?
      end
      last || raise(StreamError.new("template build stream ended unexpectedly (no final frame)",
                                    method: "POST", path: "/kosa8/v1/templates"))
    end

    # Pack a build context the way `kosa8 build` does, honouring .dockerignore
    # prefixes. Returns the tar as a binary String.
    def self.tar_dir(path, dockerfile = "Dockerfile")
      raise Error, "no #{dockerfile} in #{path}" unless File.exist?(File.join(path, dockerfile))

      ignore = []
      di = File.join(path, ".dockerignore")
      if File.exist?(di)
        ignore = File.readlines(di).reject { |l| l.strip.empty? || l.start_with?("#") }
                     .map { |l| Pathname.new(l.strip).cleanpath.to_s }
      end
      skip = ->(rel) { ignore.any? { |p| rel == p || rel.start_with?(p + "/") } }
      io = StringIO.new(+"".b)
      Gem::Package::TarWriter.new(io) do |tar|
        walk = lambda do |dir, rel_dir|
          Dir.children(dir).sort.each do |name|
            full = File.join(dir, name)
            rel = rel_dir.empty? ? name : "#{rel_dir}/#{name}"
            next if skip.call(rel)

            st = File.lstat(full)
            mode = st.mode & 0o7777
            if st.symlink?
              tar.add_symlink(rel, File.readlink(full), mode)
            elsif st.directory?
              tar.mkdir(rel, mode)
              walk.call(full, rel)
            elsif st.file?
              tar.add_file_simple(rel, mode, st.size) { |w| File.open(full, "rb") { |f| IO.copy_stream(f, w) } }
            end
          end
        end
        walk.call(path, "")
      end
      io.string
    end

    private

    def decode_body(data)
      text = data.dup.force_encoding(Encoding::UTF_8).scrub
      return nil if text.strip.empty?

      JSON.parse(text)
    rescue JSON::ParserError
      text
    end
  end
end
