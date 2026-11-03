# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift __dir__
require "fileutils"
require "minitest/autorun"
require "kosa8"
require "mock_daemon"

class ClientTest < Minitest::Test
  J = MockDaemon.method(:json)
  F = MockDaemon.method(:frame)

  def setup
    MockDaemon.require!(self)
    @d = MockDaemon.new
    @k = Kosa8::Client.new(socket_path: @d.socket_path, checkpoint_store: Kosa8::MemoryCheckpointStore.new, env: {})
  end

  def teardown
    @d&.close
  end

  def test_health_and_headers
    @d.on("GET", "/kosa8/v1/health") { J.call(200, "status" => "ok", "version" => "0.12.0") }
    k = Kosa8::Client.new(socket_path: @d.socket_path, actor: "agent", agent_token: "at-1",
                          checkpoint_store: Kosa8::MemoryCheckpointStore.new, env: {})
    assert_equal "0.12.0", k.version
    h = @d.last.headers
    assert_equal "agent", h["x-kosa8-actor"]
    assert_equal "at-1", h["x-kosa8-agent-token"]
    assert_nil h["authorization"], "no bearer token over the local socket"
    assert_raises(Kosa8::Error) { Kosa8::Client.new(socket_path: @d.socket_path, actor: "root", env: {}) }
  end

  def test_create_sandbox_body
    @d.on("POST", "/kosa8/v1/sandboxes") { J.call(201, "sandbox" => { "id" => "demo" }) }
    @k.create_sandbox(name: "demo", cpus: 2, egress: { allow: [" pypi.org", "github.com"] }, labels: { team: "a" }, approval: "sig")
    b = JSON.parse(@d.last.body)
    assert_equal "allow:pypi.org,github.com", b["egress"]
    assert_equal 2, b["cpus"]
    refute b.key?("mem_mb")
    assert_equal "sig", @d.last.headers["x-kosa8-approval"]
    @k.create_sandbox(egress_allow: ["x.io"])
    assert_equal "allow:x.io", JSON.parse(@d.last.body)["egress"]
    assert_raises(Kosa8::Error) { @k.create_sandbox(egress: "any", egress_allow: ["x"]) }
  end

  def test_typed_errors
    @d.on("POST", "/kosa8/v1/sandboxes/x/up") do
      J.call(403, "error" => "policy needs approval", "remediation" => "sign it", "approval" => { "why" => "egress any" })
    end
    @d.on("POST", "/kosa8/v1/sandboxes/x/down") { J.call(409, "error" => "already stopped") }
    e = assert_raises(Kosa8::ApprovalRequiredError) { @k.start_sandbox("x") }
    assert_kind_of Kosa8::PolicyError, e
    assert_equal "policy needs approval (sign it)", e.message
    assert_equal "egress any", e.approval["why"]
    assert_equal 403, e.status
    assert_raises(Kosa8::ConflictError) { @k.stop_sandbox("x") }
    assert_raises(Kosa8::NotFoundError) { @k.sandbox_egress("missing") }
  end

  def test_connection_error
    k = Kosa8::Client.new(socket_path: "/tmp/k8rb-nope.sock", env: {}, checkpoint_store: Kosa8::MemoryCheckpointStore.new)
    e = assert_raises(Kosa8::ConnectionError) { k.health }
    assert_includes e.message, "kosa8 daemon start"
  end

  def test_run_streams
    @d.on("POST", "/kosa8/v1/sandboxes/sb/run") do
      MockDaemon.frames(F.call("status", "pulling"), F.call("stdout", "hel"), F.call("stderr", "warn"),
                        F.call("stdout", "lo\n"), { "done" => true, "ok" => true, "exit" => 3 })
    end
    live = []
    r = @k.run("sb", "alpine", ["echo"], env: { "A" => "1" }, on_stdout: ->(b) { live << b })
    assert_equal "hello\n", r.stdout
    assert_equal "warn", r.stderr
    assert_equal 3, r.exit_code
    refute r.ok?
    assert_equal ["hel", "lo\n"], live
    assert_equal ["A=1"], JSON.parse(@d.last.body)["env"]
  end

  def test_stream_error_and_truncation
    @d.on("POST", "/kosa8/v1/sandboxes/sb/exec") do
      MockDaemon.frames(F.call("stdout", "partial"), { "done" => true, "error" => "container gone" })
    end
    @d.on("POST", %r{/containers/c1/attach\z}) { MockDaemon.frames(F.call("stdout", "cut")) }
    e = assert_raises(Kosa8::StreamError) { @k.exec("sb", "c1", ["ls"]) }
    assert_equal "partial", e.stdout
    assert_equal "container gone", e.message
    e = assert_raises(Kosa8::StreamError) { @k.attach("sb", "c1") }
    assert_includes e.message, "no final frame"
    assert_equal "cut", e.stdout
  end

  def test_stdin_chunked_and_escaped
    @d.on("POST", %r{/stdin\z}) { |r| J.call(200, "bytes" => r.body.bytesize) }
    out = @k.write_stdin("sb", "c/1", %w[abc de])
    assert_equal 5, out["bytes"]
    assert_equal "chunked", @d.last.headers["transfer-encoding"]
    assert_equal "application/octet-stream", @d.last.headers["content-type"]
    assert_includes @d.last.path, "c%2F1"
    assert_equal 3, @k.write_stdin("sb", "c1", "xyz")["bytes"]
  end

  def test_fork_and_explore
    @d.on("POST", "/kosa8/v1/sandboxes/p/pull") { J.call(200, {}) }
    @d.on("POST", "/kosa8/v1/sandboxes/p/fork") do
      J.call(200, "forks" => [{ "id" => "e-1" }, { "id" => "e-2" }, { "id" => "e-3" }], "fork_ms" => 412, "count" => 3)
    end
    tries = Queue.new
    @d.on("POST", "/kosa8/v1/sandboxes/e-1/run") do
      MockDaemon.frames(F.call("stdout", "slow").merge("_sleep" => 1.5), { "done" => true, "exit" => 0 })
    end
    @d.on("POST", "/kosa8/v1/sandboxes/e-2/run") do
      tries << 1
      if tries.size == 1 # engine still settling
        MockDaemon.frames({ "done" => true, "error" => "connection refused" })
      else
        MockDaemon.frames(F.call("stdout", "fast"), { "done" => true, "exit" => 0 })
      end
    end
    @d.on("POST", "/kosa8/v1/sandboxes/e-3/run") { MockDaemon.frames(F.call("stdout", "fail"), { "done" => true, "exit" => 1 }) }
    deleted = Queue.new
    @d.on("DELETE", %r{\A/kosa8/v1/sandboxes/e-\d\z}) { |r| deleted << r.path; J.call(200, {}) }
    f = @k.fork("p", 3, prefix: "e")
    assert_equal 3, f["count"]
    res = @k.explore("p", %w[a b c], prefix: "e")
    assert_equal "e-2", res.winner
    assert_equal 2, res.removed
    assert_equal "fast", res.branches[1].output
    assert_equal 1, res.branches[2].exit
    assert_equal 2, tries.size, "transient failure retried"
    assert_raises(Kosa8::Error) { @k.explore("p", ["only"]) }
  end

  def checkpoint_routes(log)
    @d.on("POST", "/kosa8/v1/sandboxes/sb/snapshot") do |r|
      id = JSON.parse(r.body)["id"]
      log << "snap #{id}"
      J.call(200, "id" => id)
    end
    @d.on("DELETE", "/kosa8/v1/sandboxes/sb") { log << "del sb"; J.call(200, "deleted" => "sb") }
    @d.on("DELETE", %r{\A/kosa8/v1/snapshots/}) { |r| log << "dsnap #{r.path.split('/').last}"; J.call(200, {}) }
    @d.on("POST", %r{/restore\z}) do |r|
      log << "restore #{r.path.split('/')[-2]}"
      J.call(200, "sandbox" => { "id" => "sb" }, "restore_ms" => 897)
    end
  end

  def test_checkpoint_rewind
    log = []
    checkpoint_routes(log)
    %w[base deps broken].each { |l| @k.checkpoint("sb", label: l) }
    rw = @k.rewind("sb", to: "DEPS")
    assert_equal "sb-ckpt-2", rw["checkpoint"]["id"]
    assert_equal ["sb-ckpt-3"], rw["dropped"]
    assert_equal 897, rw["restore_ms"]
    assert_includes log.join(","), "del sb,restore sb-ckpt-2,dsnap sb-ckpt-3"
    assert_equal 2, @k.list_checkpoints("sb").length
    assert_equal "sb-ckpt-3", @k.checkpoint("sb")["checkpoint"]["id"]
    assert_raises(Kosa8::CheckpointError) { @k.rewind("sb", to: "nope") }
    assert_raises(Kosa8::CheckpointError) { @k.checkpoint("../etc") }
  end

  def test_eviction_and_delete
    log = []
    checkpoint_routes(log)
    11.times { @k.checkpoint("sb") }
    l = @k.list_checkpoints("sb")
    assert_equal 10, l.length
    assert_equal "sb-ckpt-2", l.first["id"]
    assert_includes log.join(","), "snap sb-ckpt-11,dsnap sb-ckpt-1"
    out = @k.sandbox("sb").delete(wipe: true)
    assert_equal 10, out["checkpoints_dropped"]
    assert_equal "sb", out["deleted"]
    assert_includes @d.last.query, "wipe=1"
    assert_empty @k.list_checkpoints("sb")
  end

  def test_file_store_shared_with_cli
    dir = Dir.mktmpdir
    path = File.join(dir, "checkpoints.json")
    File.write(path, '{"sb":[{"id":"sb-ckpt-4","sandbox":"sb","label":"cli","created":"2026-11-01T10:00:00.123456789Z"}]}')
    book = Kosa8::CheckpointBook.new(Kosa8::FileCheckpointStore.new(path))
    assert_equal "sb-ckpt-5", book.next_id("sb")[0]
    8.times.map { |i| Thread.new { book.record("other-ckpt-#{i}", "other", "") } }.each(&:join)
    d = JSON.parse(File.read(path))
    assert_equal 8, d["other"].length
    assert_equal "cli", d["sb"][0]["label"]
    assert_equal 0o600, File.stat(path).mode & 0o777 unless Kosa8.windows?
    assert File.exist?("#{path}.lock")
    refute_includes File.read(path), '"auto"'
    assert_match(/\.\d{9}Z\z/, d["other"][0]["created"])
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_error_keeps_object_method
    @d.on("GET", "/kosa8/v1/sandboxes") { J.call(500, "error" => "boom") }
    e = assert_raises(Kosa8::ApiError) { @k.list_sandboxes }
    assert_equal "GET", e.http_method
    assert_kind_of Method, e.method(:message), "Object#method must not be shadowed"
  end

  def test_second_write_stdin_raises
    @d.on("POST", "/kosa8/v1/sandboxes/s/containers/c/stdin") { J.call(200, "ok" => true) }
    assert_equal({ "ok" => true }, @k.write_stdin("s", "c", "hi\n"))
    assert_raises(Kosa8::Error) { @k.write_stdin("s", "c", "again\n") }
  end

  def test_callback_error_is_not_relabelled
    @d.on("POST", "/kosa8/v1/sandboxes/s/run") { MockDaemon.frames(F.call("stdout", "x"), { "done" => true, "exit" => 0 }) }
    assert_raises(IOError) { @k.run("s", "alpine", ["true"], on_stdout: ->(_) { raise IOError, "mine" }) }
  end

  def test_bad_frame_is_protocol_error
    @d.on("POST", "/kosa8/v1/sandboxes/s/run") { MockDaemon.frames("not json\n") }
    assert_raises(Kosa8::ProtocolError) { @k.run("s", "alpine", ["true"]) }
  end

  def test_checkpoint_retries_on_id_collision
    calls = 0
    @d.on("POST", "/kosa8/v1/sandboxes/s/snapshot") do
      calls += 1
      calls == 1 ? J.call(409, "error" => "snapshot already exists: s-ckpt-1") : J.call(201, "id" => "s-ckpt-2")
    end
    r = @k.checkpoint("s", label: "a")
    assert_equal 2, calls
    assert_equal "s-ckpt-2", r["checkpoint"]["id"]
    @d.on("POST", "/kosa8/v1/sandboxes/t/snapshot") { J.call(409, "error" => "sandbox busy") }
    assert_raises(Kosa8::ConflictError) { @k.checkpoint("t") }
  end
end

# Endpoint resolution and remote workers: no unix socket needed.
class EndpointTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("k8rb-w")
    @wf = File.join(@dir, "worker.json")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def save(obj)
    File.write(@wf, obj.is_a?(String) ? obj : JSON.generate(obj))
  end

  def resolve(**kw)
    Kosa8.resolve_endpoint(worker_file: @wf, env: {}, **kw)
  end

  def test_resolve_endpoint
    r = ->(host, env) { Kosa8.resolve_endpoint(host: host, socket_path: "/s.sock", env: env, worker_file: false) }
    assert_equal "unix:///s.sock", r.call(nil, {}).target
    e = r.call(nil, "KOSA8_HOST" => "https://w.example.com/", "KOSA8_TOKEN" => "t")
    assert_equal ["https://w.example.com:443", "t"], [e.target, e.token]
    assert_equal "http://127.0.0.1:7070", r.call("tcp://127.0.0.1:7070", {}).target
    assert_equal "http://localhost:7070", r.call("localhost:7070", {}).target
    assert_equal "unix:///o.sock", r.call("unix:///o.sock", {}).target
    assert_raises(Kosa8::Error) { r.call("http://10.0.0.5:7070", {}) }
    assert_equal "http://10.0.0.5:7070", r.call(nil, "KOSA8_HOST" => "http://10.0.0.5:7070", "KOSA8_INSECURE" => "1").target
    assert_raises(Kosa8::Error) { r.call("ftp://x", {}) }
    assert_nil r.call("https://w.example.com", "KOSA8_TOKEN" => "t").token, "env token only for an env host"
  end

  def test_remote_bearer
    srv = TCPServer.new("127.0.0.1", 0)
    auth = nil
    t = Thread.new do
      c = srv.accept
      while (h = c.gets) && h != "\r\n"
        auth = h.split(":", 2)[1].strip if h.downcase.start_with?("authorization:")
      end
      c.write("HTTP/1.1 200 OK\r\nContent-Length: 15\r\nConnection: close\r\n\r\n{\"version\":\"x\"}")
      c.close
    end
    k = Kosa8::Client.new(host: "http://127.0.0.1:#{srv.addr[1]}", token: "tok", env: {},
                          checkpoint_store: Kosa8::MemoryCheckpointStore.new)
    assert_equal "x", k.version
    t.join
    assert_equal "Bearer tok", auth
  ensure
    srv&.close
  end

  def test_saved_worker_used_when_no_host
    save("host" => "http://127.0.0.1:7428", "token" => "wt", "via" => "wsl", "distro" => "Ubuntu", "extra" => [1])
    e = resolve
    assert_equal ["http://127.0.0.1:7428", "wt"], [e.target, e.token]
    assert_equal :tcp, e.kind
    e = resolve(env: { "KOSA8_HOST" => "  ", "KOSA8_TOKEN" => "envt" })
    assert_equal ["http://127.0.0.1:7428", "wt"], [e.target, e.token], "blank KOSA8_HOST is unset"
    save("host" => "127.0.0.1:7428")
    assert_equal ["http://127.0.0.1:7428", nil], [resolve.target, resolve.token]
    save("host" => "unix:///x/k.sock", "token" => "wt")
    assert_equal "unix:///x/k.sock", resolve.target
  end

  def test_env_host_wins_over_saved_token
    save("host" => "http://127.0.0.1:7428", "token" => "wt")
    e = resolve(env: { "KOSA8_HOST" => "https://w.example.com" })
    assert_equal ["https://w.example.com:443", nil], [e.target, e.token]
    e = resolve(env: { "KOSA8_HOST" => "https://w.example.com", "KOSA8_TOKEN" => "et" })
    assert_equal "et", e.token
    e = resolve(host: "https://h.example.com")
    assert_equal ["https://h.example.com:443", nil], [e.target, e.token]
  end

  def test_socket_path_skips_saved_file
    save("host" => "http://127.0.0.1:7428", "token" => "wt")
    e = resolve(socket_path: "/s.sock")
    assert_equal ["unix:///s.sock", false], [e.target, e.default_socket]
  end

  def test_bad_saved_file_means_socket
    ['{"host": ', "[]", '{"host": "  "}', '{"host": 5}', '{"token": "t"}', ""].each do |text|
      save(text)
      e = resolve
      assert_equal "unix://#{Kosa8.default_socket_path}", e.target, text
      assert e.default_socket
    end
    assert_equal :unix, Kosa8.resolve_endpoint(worker_file: File.join(@dir, "missing.json"), env: {}).kind
    save("host" => "http://127.0.0.1:7428")
    assert_equal :unix, resolve(worker_file: false).kind
    assert_equal :unix, resolve(worker_file: "").kind
  end

  def test_saved_insecure
    save("host" => "http://192.168.1.20:7428", "token" => "wt", "insecure" => true)
    assert_equal "http://192.168.1.20:7428", resolve.target
    save("host" => "http://192.168.1.20:7428", "token" => "wt")
    e = assert_raises(Kosa8::Error) { resolve }
    assert_includes e.message, "plain http"
    assert_equal "http://192.168.1.20:7428", resolve(insecure: true).target
    assert_equal "http://192.168.1.20:7428", resolve(env: { "KOSA8_INSECURE" => "1" }).target
    save("host" => "http://192.168.1.20:7428", "insecure" => "yes")
    assert_raises(Kosa8::Error) { resolve }
  end

  def test_token_option_overrides_saved
    save("host" => "https://w.example.com", "token" => "wt")
    assert_equal "mine", resolve(token: "mine").token
    assert_equal "wt", resolve(token: "").token
  end

  def test_client_uses_saved_worker
    srv = TCPServer.new("127.0.0.1", 0)
    save("host" => "http://127.0.0.1:#{srv.addr[1]}", "token" => "wt")
    auth = nil
    t = Thread.new do
      c = srv.accept
      while (h = c.gets) && h != "\r\n"
        auth = h.split(":", 2)[1].strip if h.downcase.start_with?("authorization:")
      end
      c.write("HTTP/1.1 200 OK\r\nContent-Length: 15\r\nConnection: close\r\n\r\n{\"version\":\"x\"}")
      c.close
    end
    k = Kosa8::Client.new(env: {}, worker_file: @wf, checkpoint_store: Kosa8::MemoryCheckpointStore.new)
    assert_equal "http://127.0.0.1:#{srv.addr[1]}", k.transport.endpoint.target
    assert_equal "x", k.version
    t.join
    assert_equal "Bearer wt", auth
  ensure
    srv&.close
  end

  def test_windows_hint_on_default_socket
    k = Kosa8::Client.new(env: {}, worker_file: false, checkpoint_store: Kosa8::MemoryCheckpointStore.new)
    ep = k.transport.endpoint
    ep.socket_path = File.join(@dir, "nope.sock")
    e = assert_raises(Kosa8::ConnectionError) { k.health }
    if Kosa8.windows?
      assert_includes e.message, "kosa8 wsl setup"
    else
      refute_includes e.message, "kosa8 wsl setup"
    end
    k2 = Kosa8::Client.new(socket_path: File.join(@dir, "nope.sock"), env: {}, checkpoint_store: Kosa8::MemoryCheckpointStore.new)
    e = assert_raises(Kosa8::ConnectionError) { k2.health }
    refute_includes e.message, "kosa8 wsl setup", "only for the default socket"
  end
end
