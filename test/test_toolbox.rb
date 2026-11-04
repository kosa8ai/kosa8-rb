# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift __dir__
require "fileutils"
require "minitest/autorun"
require "rubygems/package"
require "stringio"
require "tmpdir"
require "kosa8"
require "mock_daemon"

class ToolboxTest < Minitest::Test
  J = MockDaemon.method(:json)
  S = "/kosa8/v1/sandboxes/sb1"

  def setup
    MockDaemon.require!(self)
    @d = MockDaemon.new
    @k = Kosa8::Client.new(socket_path: @d.socket_path, checkpoint_store: Kosa8::MemoryCheckpointStore.new, env: {})
  end

  def teardown
    @d&.close
  end

  def body
    JSON.parse(@d.last.body)
  end

  def test_run_code_decodes_artifacts
    png = "\x89PNG fake".b
    @d.on("POST", "#{S}/code") do
      J.call(200, "language" => "python", "image" => "python:3.12-slim", "exit" => 0, "stdout" => "hi\n", "stderr" => "",
                  "artifacts" => [{ "type" => "image/png", "name" => "figure-1.png", "data" => Base64.strict_encode64(png) }],
                  "duration_ms" => 12)
    end
    r = @k.run_code("sb1", "print('hi')", env: { "A" => "1" }, timeout_s: 10)
    assert_kind_of Kosa8::CodeResult, r
    assert r.ok?
    assert_equal "hi\n", r.stdout
    assert_equal png, r.artifacts[0].data
    assert_equal Encoding::BINARY, r.artifacts[0].data.encoding
    assert_equal "figure-1.png", r.artifacts[0].name
    assert_equal({ "language" => "python", "code" => "print('hi')", "env" => { "A" => "1" }, "timeout_s" => 10 }, body)
  end

  def test_timed_out_is_not_ok
    @d.on("POST", "#{S}/code") { J.call(200, "exit" => 124, "stdout" => "", "stderr" => "killed", "timed_out" => true) }
    r = @k.run_code("sb1", "while True: pass")
    refute r.ok?
    assert r.timed_out
    assert_equal({ "language" => "python", "code" => "while True: pass" }, body)
  end

  def test_files
    @d.on("GET", "#{S}/files") { J.call(200, "path" => "/workspace", "files" => [{ "name" => "a.txt", "type" => "file", "size" => 3 }]) }
    @d.on("GET", "#{S}/files/stat") { J.call(200, "name" => "a.txt", "type" => "file", "size" => 3) }
    @d.on("GET", "#{S}/files/content") { MockDaemon.raw(200, "h\xC3\xA9llo".b, "Content-Type" => "application/octet-stream") }
    @d.on("PUT", "#{S}/files/content") { |r| J.call(200, "path" => "/workspace/b.txt", "size" => r.body.bytesize) }
    @d.on("DELETE", "#{S}/files") { J.call(200, "removed" => "/workspace/d") }
    @d.on("POST", "#{S}/files/mkdir") { J.call(200, "path" => "/workspace/n") }
    @d.on("POST", "#{S}/files/move") { J.call(200, "path" => "/workspace/c") }

    assert_equal "a.txt", @k.list_files("sb1")[0]["name"]
    assert_includes @d.last.query, "path=%2Fworkspace"
    assert_equal 3, @k.stat_file("sb1", "a.txt")["size"]
    assert_equal "path=a.txt", @d.last.query
    bin = @k.read_file("sb1", "a.txt")
    assert_equal Encoding::BINARY, bin.encoding
    assert_equal "héllo", @k.read_text("sb1", "a.txt")
    assert_equal Encoding::UTF_8, @k.read_text("sb1", "a.txt").encoding
    assert_equal 6, @k.write_file("sb1", "b.txt", "héllo", mode: "0644")["size"]
    assert_equal "héllo".b, @d.last.body.b
    assert_equal "application/octet-stream", @d.last.headers["content-type"]
    assert_includes @d.last.query, "mode=0644"
    @k.delete_file("sb1", "d", recursive: true)
    assert_includes @d.last.query, "recursive=1"
    @k.delete_file("sb1", "f")
    refute_includes @d.last.query, "recursive"
    @k.make_dir("sb1", "n")
    assert_equal({ "path" => "n" }, body)
    @k.move_file("sb1", "a", "c", approval: "sig")
    assert_equal({ "from" => "a", "to" => "c" }, body)
    assert_equal "sig", @d.last.headers["x-kosa8-approval"]
  end

  def test_read_missing_file_is_typed
    @d.on("GET", "#{S}/files/content") { J.call(404, "error" => "no such file", "remediation" => "") }
    e = assert_raises(Kosa8::NotFoundError) { @k.read_file("sb1", "nope") }
    assert_equal "no such file", e.daemon_message
  end

  def test_short_read_is_an_error
    @d.on("GET", "#{S}/files/content") { MockDaemon.raw(200, "abc", "Content-Length" => "10") }
    assert_raises(Kosa8::Error) { @k.read_file("sb1", "x") }
  end

  def test_git_commit_adds_then_commits
    @d.on("POST", "#{S}/git") { |r| J.call(200, "op" => JSON.parse(r.body)["op"], "ok" => true, "exit" => 0, "stdout" => "", "stderr" => "") }
    r = @k.git_commit("sb1", "repo", "msg")
    assert r.ok?
    assert_equal %w[add commit], @d.requests.map { |q| JSON.parse(q.body)["op"] }
    assert_equal({ "op" => "commit", "path" => "repo", "message" => "msg" }, body)
  end

  def test_git_commit_stops_when_add_fails
    @d.on("POST", "#{S}/git") { J.call(200, "op" => "add", "ok" => false, "exit" => 128, "stdout" => "", "stderr" => "not a repo") }
    r = @k.git_commit("sb1", "repo", "msg")
    refute r.ok?
    assert_equal 128, r.exit_code
    assert_equal 1, @d.requests.length
  end

  def test_git_clone_and_status
    @d.on("POST", "#{S}/git") do |r|
      op = JSON.parse(r.body)["op"]
      J.call(200, "op" => op, "ok" => true, "exit" => 0, "stdout" => "", "stderr" => "", "path" => "/workspace/r",
                  "status" => op == "status" ? { "branch" => "main", "clean" => true, "files" => [] } : nil)
    end
    r = @k.git_clone("sb1", "https://github.com/a/b", "r", depth: 1)
    assert_equal({ "op" => "clone", "url" => "https://github.com/a/b", "path" => "r", "depth" => 1 }, body)
    assert_equal "/workspace/r", r.path
    @k.git_clone("sb1", "https://github.com/a/b")
    assert_equal({ "op" => "clone", "url" => "https://github.com/a/b" }, body)
    s = @k.git_status("sb1", "r")
    assert_equal "main", s.status["branch"]
  end

  def test_shell_makes_the_session_on_first_use
    made = []
    @d.on("POST", "#{S}/sessions/main/exec") do
      if made.empty?
        J.call(404, "error" => "no such session: main", "remediation" => "create it")
      else
        J.call(200, "exit" => 0, "stdout" => "/tmp\n", "stderr" => "", "cwd" => "/tmp", "duration_ms" => 3)
      end
    end
    @d.on("POST", "#{S}/sessions") do |r|
      made << JSON.parse(r.body)
      J.call(200, "name" => "main", "id" => "session-main", "status" => "running")
    end
    r = @k.shell("sb1", "cd /tmp && pwd")
    assert_kind_of Kosa8::ShellResult, r
    assert r.ok?
    assert_equal "/tmp", r.cwd
    assert_equal [{ "name" => "main" }], made
    assert_equal({ "command" => "cd /tmp && pwd" }, body)
  end

  def test_shell_raises_other_not_found
    @d.on("POST", "#{S}/sessions/main/exec") { J.call(404, "error" => "no such sandbox: sb1") }
    assert_raises(Kosa8::NotFoundError) { @k.shell("sb1", "ls") }
    assert_equal 1, @d.requests.length
  end

  def test_sessions
    @d.on("POST", "#{S}/sessions") { J.call(200, "name" => "w", "id" => "session-w", "status" => "running") }
    @d.on("GET", "#{S}/sessions") { J.call(200, [{ "name" => "w" }]) }
    @d.on("POST", "#{S}/sessions/w/exec") { J.call(200, "exit" => 2, "stdout" => "", "stderr" => "x", "timed_out" => false) }
    @d.on("DELETE", "#{S}/sessions/w") { J.call(200, "removed" => "w") }
    @k.create_session("sb1", "w", image: "alpine", env: { "X" => "1" })
    assert_equal({ "name" => "w", "image" => "alpine", "env" => { "X" => "1" } }, body)
    assert_equal "w", @k.list_sessions("sb1")[0]["name"]
    r = @k.session_exec("sb1", "w", "false", timeout_s: 5)
    refute r.ok?
    assert_equal({ "command" => "false", "timeout_s" => 5 }, body)
    assert_equal "w", @k.delete_session("sb1", "w")["removed"]
  end

  def test_pty_preview_lifecycle
    @d.on("POST", "#{S}/pty") { J.call(200, "id" => "c1") }
    @d.on("POST", "#{S}/containers/c1/resize") { J.call(200, "ok" => true) }
    @d.on("POST", "#{S}/previews") { J.call(200, "url" => "http://p", "expires" => 1) }
    @d.on("POST", "/kosa8/v1/previews/rotate") { J.call(200, "rotated" => true) }
    @d.on("POST", "#{S}/lifecycle") { J.call(200, "auto_stop_min" => 0, "ttl_min" => 30) }
    assert_equal "c1", @k.start_pty("sb1", image: "alpine", command: ["sh"], cols: 80, rows: 24)
    assert_equal({ "image" => "alpine", "command" => ["sh"], "cols" => 80, "rows" => 24 }, body)
    @k.start_pty("sb1")
    assert_equal({}, body)
    @k.resize_pty("sb1", "c1", 100, 30)
    assert_equal({ "cols" => 100, "rows" => 30 }, body)
    assert_equal "http://p", @k.create_preview("sb1", 8080, session: "main", expires_in_s: 60)["url"]
    assert_equal({ "port" => 8080, "session" => "main", "expires_in_s" => 60 }, body)
    @k.revoke_previews
    assert_equal "/kosa8/v1/previews/rotate", @d.last.path
    @k.set_lifecycle("sb1", auto_stop_min: 0, ttl_min: 30)
    assert_equal({ "auto_stop_min" => 0, "ttl_min" => 30 }, body)
    @k.set_lifecycle("sb1", ephemeral: false)
    assert_equal({ "ephemeral" => false }, body)
  end

  def test_create_sandbox_lifecycle_and_template
    @d.on("POST", "/kosa8/v1/sandboxes") { J.call(201, "sandbox" => { "id" => "x" }) }
    @k.create_sandbox(name: "x", auto_stop_min: 10, ttl_min: 60, auto_delete_min: 5, ephemeral: true, template: "py")
    assert_equal({ "name" => "x", "auto_stop_min" => 10, "auto_delete_min" => 5, "ttl_min" => 60, "ephemeral" => true,
                   "template" => "py" }, body)
    @k.create_sandbox(name: "y")
    assert_equal({ "name" => "y" }, body)
  end

  def test_sandbox_handle
    @d.on("POST", "#{S}/code") { J.call(200, "exit" => 0, "stdout" => "1\n", "stderr" => "") }
    @d.on("PUT", "#{S}/files/content") { J.call(200, "size" => 2) }
    @d.on("POST", "#{S}/lifecycle") { J.call(200, {}) }
    @d.on("GET", "#{S}/files") { J.call(200, "files" => []) }
    sbx = @k.sandbox("sb1")
    assert_equal "1\n", sbx.run_code("print(1)", language: "python").stdout
    sbx.write_file("a", "hi")
    assert_equal "hi", @d.last.body
    sbx.set_lifecycle(ttl_min: 5)
    assert_equal({ "ttl_min" => 5 }, body)
    assert_equal [], sbx.list_files
  end

  def test_templates
    @d.on("GET", "/kosa8/v1/templates") { J.call(200, [{ "name" => "py" }]) }
    @d.on("DELETE", "/kosa8/v1/templates/py") { J.call(200, "removed" => "py") }
    assert_equal "py", @k.list_templates[0]["name"]
    assert_equal "py", @k.delete_template("py")["removed"]
  end

  def test_build_template_tars_context_and_streams
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Dockerfile"), "FROM alpine\n")
      File.write(File.join(dir, "app.py"), "print(1)\n")
      FileUtils.mkdir_p(File.join(dir, "node_modules", "x"))
      File.write(File.join(dir, "node_modules", "x", "big.js"), "x")
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src", "keep.txt"), "k")
      File.write(File.join(dir, "secret.env"), "S=1")
      File.write(File.join(dir, ".dockerignore"), "# comment\nnode_modules\n./secret.env\n\n")
      @d.on("POST", "/kosa8/v1/templates") do
        MockDaemon.frames(MockDaemon.frame("stdout", "Step 1/1\n"), { "done" => true, "ok" => true, "template" => "t" })
      end
      out = []
      last = @k.build_template("t", dir, build_args: { "A" => "1", "B" => "2" }, egress: "deny", replace: true) { |b| out << b }
      assert_equal true, last["ok"]
      assert_equal ["Step 1/1\n"], out
      q = URI.decode_www_form(@d.last.query)
      assert_equal [%w[name t], %w[dockerfile Dockerfile], %w[buildarg A=1], %w[buildarg B=2], %w[egress deny],
                    %w[replace 1]], q
      assert_equal "application/octet-stream", @d.last.headers["content-type"]
      names = []
      Gem::Package::TarReader.new(StringIO.new(@d.last.body)) { |t| t.each { |e| names << e.full_name } }
      assert_includes names, "Dockerfile"
      assert_includes names, "app.py"
      assert_includes names, "src/keep.txt"
      assert_includes names, ".dockerignore"
      refute(names.any? { |n| n.start_with?("node_modules") })
      refute_includes names, "secret.env"
    end
  end

  def test_build_template_error_frame_raises
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Dockerfile"), "FROM nope\n")
      @d.on("POST", "/kosa8/v1/templates") do
        MockDaemon.frames(MockDaemon.frame("stdout", "pulling"), { "done" => true, "error" => "build failed: no such image" })
      end
      e = assert_raises(Kosa8::StreamError) { @k.build_template("t", dir) }
      assert_equal "build failed: no such image", e.daemon_message
    end
  end

  def test_build_template_needs_dockerfile
    Dir.mktmpdir do |dir|
      e = assert_raises(Kosa8::Error) { @k.build_template("t", dir) }
      assert_includes e.message, "no Dockerfile"
    end
  end
end
