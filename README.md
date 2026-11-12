# kosa8 (Ruby)

The Ruby SDK for [kosa8](https://kosa8.com): microVM sandboxes for AI agents. No dependencies; Ruby 2.6+.
Method for method it matches [`@kosa8/sdk`](https://github.com/kosa8ai/kosa8-js), the Python `kosa8` package and `kosa8-go`.

## Quickstart: kosa8 Cloud

```sh
gem install kosa8 -v 0.4.0
# or in a Gemfile: gem "kosa8", "~> 0.4.0"
export KOSA8_API_KEY=k8c_live_...   # made in the cloud dashboard
```

```ruby
require "kosa8"

cloud = Kosa8::Cloud.new  # KOSA8_API_KEY from the environment; or Kosa8::Cloud.new(api_key: "k8c_live_...")

box = cloud.sandboxes.create(template: "python", ttl_s: 3600)  # deleted automatically after an hour
r = box.exec(["python3", "-c", "print(6 * 7)"])
puts r.exit_code, r.stdout     # 0, 42

box.exec("echo hello > /workspace/hello.txt")  # only /workspace persists between commands
puts box.exec("cat /workspace/hello.txt").stdout

box.files.write("/workspace/app.py", "print('hi')\n")  # needs the host's data plane (see below)
puts box.files.read_text("/workspace/app.py")

box.sleep                      # costs only snapshot storage while asleep
box.exec("ls /workspace")      # wakes it, files and all
box.delete
```

`cloud.templates` lists the templates your org can start. Without `template:` you get the org's
default, `base` (see below).

### More of the Cloud API

```ruby
box.update(ttl_s: 7200)                 # PATCH: a new lifetime from now
box.update(clear_lifetime: true)        # no automatic delete (sends ttl_s: null)
box.update(sleep_after_s: 0)            # never sleep when idle

cloud.sandboxes.list                    # an Array, as before; list(all: true) includes deleted ones
cloud.sandboxes.each(all: true) { |b| puts "#{b.id} #{b.state} #{b.info["delete_after"]}" }  # every page
page = cloud.sandboxes.list_page(limit: 50)  # one page: page.sandboxes, page.next_cursor (nil at the end)

# These need the host's data plane. On a host without it they raise
# Kosa8::UnsupportedError (501 not_available / not_supported): not every
# kosa8 Cloud host has it yet.
box.files.write("/workspace/data.bin", File.binread("data.bin"))  # bytes or text, at most 8 MiB
bytes = box.files.read("/workspace/data.bin")                     # a binary String
puts box.files.list("/workspace").map { |f| f["name"] }
box.files.mkdir("/workspace/out")
box.files.delete("/workspace/out", recursive: true)

ckpt = box.checkpoint("before the risky bit")   # memory, processes and disk
box.exec("rm -rf /workspace/*")
r = box.rewind(ckpt["id"])                      # back; r.backup is the automatic checkpoint of the state before
box.checkpoints                                 # oldest first
forks = box.fork(4)                             # four live copies, CloudSandbox objects
p box.ports                                     # listening TCP ports

cloud.functions.deploy("hello", {
  "runtime" => "python3.12",
  "code" => "def handler(event):\n    return {\"hello\": event.get(\"name\", \"world\")}\n"
})
out = cloud.functions.invoke("hello", { "name" => "kosa8" })
p out["ok"], out["result"]     # true, {"hello"=>"kosa8"}
```

`cloud.me` and `cloud.usage` show the org and this month's bill estimate. The address is
`KOSA8_CLOUD_URL` (default `https://api.kosa8.com`, https only except localhost).

### The base template

- The `base` template is **Alpine Linux**: `sh` is busybox, and there is no `bash`, `python` or `git`.
  Use `template: "python"` (or another key from `cloud.templates`) for Python, or pass `image:` to `exec`.
- **Each `exec` runs in a fresh container, and only `/workspace` persists.** `cd`, `export` and anything
  installed outside `/workspace` (`apk add`, a system `pip install`) are gone by the next command. Install
  into `/workspace` (for example `pip install --target /workspace/lib ...` with `PYTHONPATH=/workspace/lib`),
  or chain the steps in one `sh -c`.
- **A buffered `exec` is cut off after about 30 seconds** and raises `Kosa8::ExecTimeoutError`. Run long
  work in the background and poll it:
  `box.exec("nohup sh -c 'make test > /workspace/test.log 2>&1; echo $? > /workspace/test.exit' &")`.
- A request body (command and env) is at most 64 KiB; a file read or write is at most 8 MiB.
- Set `ttl_s:` (60 s to 90 days) or `delete_after:` (Unix ms) on create so a crashed script cannot leave a
  sandbox running. Bad values raise `ArgumentError` before any request.
- The Cloud API has no sandbox labels or metadata.

### Cloud errors

| Error | When | What to do |
|---|---|---|
| `Kosa8::PaymentRequiredError` (402) | no payment method (`payment_required`), spending cap reached (`spending_cap_reached`), Store price not accepted (`price_not_accepted`) | show `e.upgrade_url`; an agent should relay `e.agent_message` to its person and stop |
| `Kosa8::OrgFrozenError` (423, `org_frozen`) | the org is frozen in the Security Center | an owner or admin unfreezes it; retrying does not help |
| `Kosa8::RateLimitError` (429) | too many requests, or `quota_exceeded` (active sandbox limit) | wait `e.retry_after` seconds when set, or delete sandboxes |
| `Kosa8::ExecTimeoutError` (504 `exec_timeout`, or today's 502 "timed out" on exec) | a buffered exec ran past about 30 s | run it in the background and poll |
| `Kosa8::UnsupportedError` (501) | the host has no data plane yet (files, checkpoints, rewind, fork, ports) | use `exec`, or try later |

Every Cloud error is a `Kosa8::ApiError` carrying the server's stable `e.code`, its message and `e.body`.

## Local daemon

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
| `worker_file:` | `~/.kosa8/worker.json`; `false` or `""` reads none |

Where requests go, the same as the CLI:

1. `host:`, or a non-blank `KOSA8_HOST`. The token is `token:`, else `KOSA8_TOKEN` (only for a
   host from `KOSA8_HOST`). The saved file is not read.
2. Else, unless `socket_path:` is given, the connection the CLI saved in `~/.kosa8/worker.json`
   (`kosa8 wsl setup` on Windows, `kosa8 worker join` anywhere): its `host`, its `token` unless
   `token:` is given, and plain http to a LAN address only with `"insecure": true`, `insecure: true`
   or `KOSA8_INSECURE=1`. A missing or malformed file, or a blank `host`, is ignored.
3. Else the unix socket.

On Windows the engine runs in WSL2: run `kosa8 wsl setup` once and `Kosa8::Client.new` finds it.
`client.transport.endpoint.target` shows where requests go.

## Errors (local daemon)

All errors inherit `Kosa8::Error` and carry the daemon's message and remediation:
`ConnectionError`, `BadRequestError`, `AuthError`, `PolicyError` › `ApprovalRequiredError` (`#approval`),
`NotFoundError`, `ConflictError`, `UnsupportedError`, `PaymentRequiredError` (402), `OrgFrozenError` (423), `RateLimitError` (429), `ExecTimeoutError`, `StreamError` (`#stdout`/`#stderr` so far),
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

## Development

```sh
ruby -w test/test_client.rb      # mock daemon on a unix socket
ruby -w test/test_toolbox.rb
ruby -w test/test_cloud.rb       # stub transport and a local socket
ruby -w test/test_cloud_parity.rb  # Cloud API parity, stub transport
ruby -w -Ilib -Itest -e 'Dir["test/test_*.rb"].sort.each { |f| require File.expand_path(f) }'  # all, as CI does
ruby examples/smoke.rb           # live, against a running `kosa8 daemon`
```

MIT licensed.
