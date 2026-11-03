# kosa8 (Ruby)

The Ruby SDK for [kosa8](https://kosa8.com): microVM sandboxes for AI agents. No dependencies; Ruby 2.6+.
Method for method it matches [`@kosa8/sdk`](https://github.com/kosa8ai/kosa8-js), the Python `kosa8` package and `kosa8-go`.

```ruby
require "kosa8"

k = Kosa8::Client.new                     # local daemon at ~/.kosa8/run/kosa8.sock
k.create_sandbox(name: "demo", egress_allow: ["pypi.org"])
sb = k.sandbox("demo")
sb.pull("python:3.12-alpine")
puts sb.run("python:3.12-alpine", ["python", "-c", "print(6*7)"]).stdout  # 42

sb.checkpoint(label: "clean")             # restore point, shared with `kosa8 rewind`
sb.rewind(to: "clean")                    # back to it, processes resumed
best = sb.explore(["make test", "make test-fast"])  # best-of-N on forks
sb.delete
```

## Connecting

| Option | Default |
|---|---|
| `socket_path:` | `~/.kosa8/run/kosa8.sock` |
| `host:` / `KOSA8_HOST` | a remote worker: `https://`, `http://` (loopback only unless `insecure: true` / `KOSA8_INSECURE=1`), `tcp://`, `unix://` |
| `token:` / `KOSA8_TOKEN` | sent as `Authorization: Bearer` to a remote worker |
| `actor:` | `"tool"` (`human`, `agent`, `tool`), sent as `X-Kosa8-Actor` |
| `agent_token:` / `KOSA8_AGENT_TOKEN` | sent as `X-Kosa8-Agent-Token` |

## Errors

All errors inherit `Kosa8::Error` and carry the daemon's message and remediation:
`ConnectionError`, `BadRequestError`, `AuthError`, `PolicyError` › `ApprovalRequiredError` (`#approval`),
`NotFoundError`, `ConflictError`, `UnsupportedError`, `PaymentRequiredError` (402), `RateLimitError` (429), `StreamError` (`#stdout`/`#stderr` so far),
`CheckpointError`, `TimeoutError`. Methods that a policy may gate take `approval:`.

## API

Daemon: `health`, `version`, `pull`.
Sandboxes: `list_sandboxes`, `get_sandbox`, `create_sandbox`, `start_sandbox`, `stop_sandbox`, `delete_sandbox`,
`pull_into_sandbox`, `sandbox_images`, `sandbox_containers`, `sandbox_egress`.
Processes: `run`, `start_container`, `exec`, `exec_frames`, `start_interactive`, `write_stdin`, `attach`.

Streaming calls (`run`, `exec`, `exec_frames`, `attach`) wait as long as the command runs unless you pass `timeout:`; a timeout stops the client waiting, not the command. `write_stdin` sends the container's whole stdin in one call (the daemon closes stdin at the end of the body), so pass an IO or an Enumerable to stream input; a second call raises.
Snapshots: `snapshot`, `list_snapshots`, `restore_snapshot`, `delete_snapshot`, `fork`, `explore`.
Checkpoints: `checkpoint`, `list_checkpoints`, `rewind` (store: `~/.kosa8/checkpoints.json`, flock-shared with the CLI).
`client.sandbox(id)` binds them to one sandbox.

## Toolbox

Run code, files, git, shell sessions, terminals, previews, lifecycle and templates, each one daemon
route (see the [native API](https://docs.kosa8.com/guides/native-api/)). All of them except the
template calls are also on `client.sandbox(id)`.

```ruby
k.create_sandbox(name: "work", egress_allow: ["github.com"], auto_stop_min: 30, ttl_min: 120)
sb = k.sandbox("work")

r = sb.run_code("print(6*7)")                  # Kosa8::CodeResult; also language: "javascript" / "typescript"
r.stdout                                       # "42\n"; r.ok?, r.exit_code, r.timed_out
r.artifacts.each { |a| File.binwrite(a.name, a.data) }  # matplotlib charts as PNG bytes

sb.write_file("/workspace/app.py", "print(1)") # make_dir, move_file, delete_file(recursive: true)
sb.read_text("/workspace/app.py")              # read_file gives binary bytes; list_files, stat_file

sb.git_clone("https://github.com/octocat/Hello-World.git", "hw", depth: 1)
sb.git_commit("hw", "change", author_name: "me", author_email: "me@example.com")  # stages everything first
sb.git("log", path: "hw", n: 5).log            # any op: status, add, push, pull, checkout, branches, diff

sb.shell("cd /tmp && export X=1")              # session "main", made on first use; cd/export persist
sb.shell("echo $X; pwd").cwd                   # "/tmp"; create_session / session_exec / delete_session

cid = sb.start_pty(cols: 80, rows: 24)         # then WebSocket …/containers/{cid}/tty; resize_pty
sb.create_preview(8000, session: "main", expires_in_s: 600)  # signed link; k.revoke_previews ends them all
sb.set_lifecycle(auto_stop_min: 0)             # nil keeps a setting, 0 turns it off

k.build_template("py-data", "./ctx", build_args: { "V" => "1" }) { |out| print out }  # tars ./ctx, honours .dockerignore
k.create_sandbox(name: "fast", template: "py-data")
k.list_templates; k.delete_template("py-data")
```

A non-zero exit or a failed git op is a result (`ok?` false), not an exception; a failed template build
raises `Kosa8::StreamError`.

## kosa8 Cloud

The same sandboxes on kosa8 Cloud instead of the local daemon. Make an API
key in the cloud dashboard and set `KOSA8_API_KEY`.

```ruby
require "kosa8"

cloud = Kosa8::Cloud.new  # or Kosa8::Cloud.new(api_key: "k8c_live_...")

box = cloud.sandboxes.create(template: "python", sleep_after_s: 600)
r = box.exec(["python3", "-c", "print(6 * 7)"])
puts r.exit_code, r.stdout     # 0, 42
box.sleep                      # costs only snapshot storage while asleep
box.exec("ls /workspace")      # wakes it, files and all
box.delete

cloud.functions.deploy("hello", {
  "runtime" => "python3.12",
  "code" => "def handler(event):\n    return {\"hello\": event.get(\"name\", \"world\")}\n"
})
out = cloud.functions.invoke("hello", { "name" => "kosa8" })
p out["ok"], out["result"]     # true, {"hello"=>"kosa8"}
```

A new organization runs nothing until a payment method is on file; until
then creating a sandbox raises `Kosa8::PaymentRequiredError` (`code`
`payment_required`), whose message says what to do. Every error from the
cloud carries its stable `code`. The address is `KOSA8_CLOUD_URL` (default
`https://api.kosa8.cloud`, https only except localhost); `cloud.me` and
`cloud.usage` show the org and this month's bill estimate.

## Development

```sh
ruby -w test/test_client.rb      # mock daemon on a unix socket
ruby -w test/test_toolbox.rb
ruby -w test/test_cloud.rb       # stub transport and a local socket
ruby examples/smoke.rb           # live, against a running `kosa8 daemon`
```

MIT licensed.
