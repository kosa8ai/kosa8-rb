# kosa8 (Ruby)

**[kosa8](https://kosa8.com): Zero Trust cybersecurity infrastructure for AI agents.**

The Ruby SDK for [kosa8](https://kosa8.com): each agent in its own microVM. No dependencies; Ruby 2.6+.
Method for method it matches [`@kosa8/sdk`](https://github.com/kosa8ai/kosa8-js), the Python `kosa8` package and `kosa8-go`.

## Quickstart: kosa8 Cloud

```sh
gem install kosa8
# or in a Gemfile: gem "kosa8", "~> 0.6"
export KOSA8_API_KEY=k8c_live_...   # made in the cloud dashboard
```

```ruby
require "kosa8"

cloud = Kosa8::Cloud.new  # KOSA8_API_KEY from the environment; or Kosa8::Cloud.new(api_key: "k8c_live_...")

box = cloud.sandboxes.create(template: "python", ttl_s: 3600)  # deleted automatically after an hour
r = box.exec(["python3", "-c", "print(6 * 7)"])
puts r.exit_code, r.stdout     # 0, 42

box.exec("echo hello > /workspace/hello.txt")  # files in /workspace last for the sandbox's life
puts box.exec("cat /workspace/hello.txt").stdout

box.files.write("/workspace/app.py", "print('hi')\n")  # needs the host's data plane (see below)
puts box.files.read_text("/workspace/app.py")

box.sleep                      # costs only snapshot storage while asleep
box.exec("ls /workspace")      # wakes it, files and all
box.delete
```

`cloud.templates` lists the templates your org can start. Without `template:` you get the org's
default, `base` (see below).

The smallest sandbox is a quarter of a vCPU and 512 MB, for fleets of mostly idle sandboxes (RL
rollouts, evals). It reserves 0.25 vCPU and bursts while the host has idle CPU:

```ruby
box = cloud.sandboxes.create(cpus: 0.25, mem_mb: 512, ttl_s: 600)  # or size: "0.25x0.5"
puts box.exec("echo hi").stdout
box.delete
```

The small sizes are `0.25x0.5`, `0.5x1` and `1x2` (`Kosa8::Cloud::SMALL_SIZES`); the standard ones
are `2x4`, `4x8`, `8x16` and `16x32`. A host that does not run small sizes answers 501
`not_available` (`Kosa8::UnsupportedError`).

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

### Sized and Docker sandboxes, env, snapshots

```ruby
box = cloud.sandboxes.create(size: "4x8", image: "kosa8-template/universal-24.04-20261115.2",
                             docker: true, env: { "NODE_ENV" => "production" }, name: "web",
                             labels: { "team" => "a" }, ttl_s: 3600)
# a sized create boots cold; create waits until it runs (wait: false to skip)

snap = box.snapshot("warm")                         # durable: kept until deleted
copy = cloud.sandboxes.create(snapshot: snap["id"])
cloud.snapshots.delete(snap["id"])                  # also list, get
```

Also `cpus:`/`mem_mb:`, `disk_gb:`, `persistent:`, `cpu: "dedicated"`, `region:` (`us`, `eu` or
an id), `secrets:` and `egress:`. `list` takes `name:` and `labels:`.

### Background commands, previews, terminal and more

```ruby
job = box.exec_background("npm run build")          # no 90 s limit
job = box.wait_background(job)                      # or background_exec(id) to poll once
puts job["exit"], job["output"]

puts box.previews.create(3000)["url"]               # private signed URL; public: true for none
box.terminal(cols: 120, rows: 40)["url"]            # a wss:// PTY URL
```

- Files: `files.download(path)` / `files.upload(path, data)` (no 8 MiB cap), `files.link(path,
  method: "PUT")` (presigned URL).
- `egress`, `set_egress(presets: ["pypi"])`, `reset_egress`; `cloud.egress_presets`.
- `run_code("print(6*7)", context: "a")` (stateful Python; persistent sandbox with python3),
  `code_contexts`, `create_code_context`, `reset_code_context`, `delete_code_context`.
- `schedules.create(cron: "0 * * * *", cmd: "date")`, `list`, `run`, `delete`.
- `metrics`, `logs(limit:)`, `set_labels`, `secrets`; `cloud.capabilities`.
- `stop_background(exec_id)`; `previews.delete(port)`, `previews.domains(port)` (custom domains:
  `add`, `list`, `get`, `remove`; also `cloud.preview_domains(preview_id)`).
- `embeds.create(origins: ["https://app.example.com"])` (a signed iframe URL for its terminal or
  desktop), `embeds.list`, `embeds.revoke`; `recordings` (with `create(record: true)`).

### Browsers, AI gateway, jobs and more

```ruby
# A headless browser ($0.12 per browser-hour, billed per second), closed when the block ends.
cloud.browser(ttl_s: 120) do |b|
  File.binwrite("page.png", b.screenshot("https://example.com"))
  puts b.goto("https://example.com")["title"]
  b.cdp_url  # wss://... for any CDP client (valid 10 minutes; b.refresh for a fresh one)
end

# The AI gateway: provider keys stay on kosa8 Cloud; sandboxes made with ai_gateway: true get
# OPENAI_BASE_URL and ANTHROPIC_BASE_URL pointed at it.
cloud.ai.set_key("openai", File.read("openai.key").strip)
cloud.ai.gateway_url("openai")   # https://api.kosa8.com/v1/ai/gw/openai, for an OpenAI client
cloud.ai.call("openai", "chat/completions", { "model" => "gpt-4o-mini", "messages" => [...] })
cloud.ai.usage("2026-11")

# A hosted job: every task in its own sandbox, solver then sealed grader, rollouts recorded.
job = cloud.jobs.submit(name: "eval-1", template: "python", tasks: File.read("tasks.jsonl"),
                        solver: "python /workspace/solve.py", solver_timeout_s: 300,
                        grader: { cmd: %w[python /grader/grade.py], files: { "/grader/grade.py" => File.read("grade.py") } },
                        budget_usd: 5)
cloud.jobs.wait(job["id"]) { |j| puts j["progress"] }   # also estimate, list, get, cancel
```

- `cloud.benchmarks`: `list`, `get`, `instances(name, state:)`, `instance`, `prepare`; create from an
  instance with `template: "<benchmark>/<instance id>"`.
- `cloud.rl_compare("run_a", "run_b")`; `cloud.rl_alerts`: `list`, `create(kind:, threshold:)`,
  `update`, `delete`.
- `cloud.usage`, `usage_insights`, `limits`, `request_limit`, `pricing`, `lineage`, `checkpoints`
  (every sandbox's), `images`, `org_egress` / `set_org_egress`.
- `cloud.audit`: `list`, `each`, `verify`, `export`; `cloud.api_keys`: `list`, `create`, `rotate`,
  `revoke`; `cloud.webhooks`: `list`, `create`, `delete`, `deliveries`, `test`.
- `cloud.recordings` (`list`, `link`, `delete`), `cloud.burst` (`get`, `activate`),
  `cloud.functions.invocations(name)`, `cloud.attack_scorecards`.

### Secrets and Pipelines

```ruby
# Read the value from a file or $stdin, never from argv or code.
cloud.secrets.set("npm-token", value: $stdin.read.strip, upstream: "https://registry.npmjs.org",
                  pipelines: true)                  # also list, delete

run = cloud.pipelines.run(repo_url: "https://github.com/me/app", ref: "main", secrets: ["npm-token"])
run = cloud.pipelines.wait(run["id"])
cloud.pipelines.logs(run["id"])["logs"].each { |l| puts l["text"] }
```

Also `runs`, `get`, `cancel`, `artifacts`, `download_artifact`, `create_hook` (webhook URL and
optional `cron:`), `hooks`, `delete_hook`.

### RL training and fan-out

```ruby
# Many sandboxes at once, leased: deleted 10 minutes after the last heartbeat.
batch = cloud.sandboxes.create_many(64, template: "python", run_id: "exp-1", lease_s: 600, prefix: "roll")
batch.failed                                  # what could not be made, with failure_class
cloud.sandboxes.heartbeat(run_id: "exp-1")    # keep them alive
cloud.sandboxes.drain(run_id: "exp-1")        # delete them all

# Forks of a prepared sandbox, 16 at a time; every fork is deleted, Ctrl-C included.
results = base.fork_map(tasks, concurrency: 16, retries: 2) { |child, task| child.exec(task["cmd"]).stdout }

# Grade in a sealed copy: hidden files, no network; the solver never sees them.
g = box.grade(%w[python /grader/test.py], files: { "/grader/test.py" => File.read("test.py") })
g.reward          # nil when the grader did not finish (failure_class timeout or infra)

# A training run: rollouts recorded on kosa8 Cloud (app.kosa8.com, RL runs).
Kosa8::RL::Run.open(cloud, "grpo-1", lease_s: 600) do |run|
  rollouts = run.map(base, tasks, grade_cmd: %w[python /grader/test.py], group_size: 8) do |sandbox, task|
    sandbox.exec(["python", "agent.py", task["prompt"]])
  end
  rollouts.rewards  # nil where masked (infra, quota or your own exception), never 0
  rollouts.groups   # per task, for group-relative advantages
end
```

Create, batch, fork, grade, job submits and rollout records send an `Idempotency-Key` (a UUID, or
`idempotency_key:`). The SDK's own key is reused after no answer (a timeout or a dropped connection:
the first try may still be running), a 429 and a 409 `idempotency_in_progress` / `template_building`,
so such a retry never doubles the fleet; after a 5xx (502 `host_failed`, 503 `no_capacity`, ...) the
retry gets a new key, so it is a new attempt. A key you pass is never changed.
Retries (`Kosa8::RetryPolicy`: 3 tries, backoff with full jitter, at least the server's Retry-After or
`retry_after`) apply only where safe: reads, PUTs and deletes, keyed POSTs, and any request the server
refused before running it (429, 503 `database_busy`, 409 `template_building`). An answer marked
`retryable: false` is never retried. Every error has `failure_class` (`ok`, `exit_nonzero`, `timeout`,
`oom`, `infra`, `quota`, `client`, `error`) and `retryable?`.

```ruby
cloud.org_templates.build("swe-task-1", image: "ghcr.io/org/task@sha256:...")  # kept as a snapshot
cloud.org_templates.wait_ready("swe-task-1")
cloud.sandboxes.create(template: "swe-task-1")                                    # a restore, ~1 s

tok = cloud.tokens.create(["sandboxes:read", "sandboxes:write"], sandbox_ids: [box.id], ttl_s: 3600)
Kosa8::Cloud.new(api_key: tok["secret"])  # hand this to your end user, not your API key
```

### The base template

- The `base` template is **Alpine Linux**: `sh` is busybox, and there is no `bash`, `python` or `git`.
  Use `template: "python"` (or another key from `cloud.templates`) for Python, or pass `image:` to `exec`.
- **Each exec is a fresh process; files in `/workspace` persist for the sandbox's life; installed
  packages need `persistent: true`.** `cd` and `export` do not carry over, and a command may run in a
  fresh container that shares only `/workspace`, so processes it leaves running and anything installed
  outside `/workspace` (`apk add`, a system `pip install`) may be gone by the next command. Install into `/workspace` (for example
  `pip install --target /workspace/lib ...` with `PYTHONPATH=/workspace/lib`), chain the steps in one
  `sh -c`, or create with `persistent: true` (one long-lived container) to keep the whole filesystem and
  background processes; the code interpreter (`run_code`) needs it, and it counts against your plan's
  persistent-sandbox limit.
- **A buffered `exec` runs at most 90 seconds** and raises `Kosa8::ExecTimeoutError`.
  `box.exec(cmd, timeout_s: 30)` stops a command sooner, in the sandbox (1 to 90 whole seconds). Run long
  work in the background and poll it:
  `box.exec("nohup sh -c 'make test > /workspace/test.log 2>&1; echo $? > /workspace/test.exit' &")`.
- A request body (command and env) is at most 64 KiB; a file read or write is at most 8 MiB.
- Set `ttl_s:` (60 s to 90 days) or `delete_after:` (Unix ms) on create so a crashed script cannot leave a
  sandbox running. Bad values raise `ArgumentError` before any request.
- Sandboxes take `name:` and `labels:` on create (`set_labels` later); `list(labels: {...})` filters by them.

### Cloud errors

| Error | When | What to do |
|---|---|---|
| `Kosa8::PaymentRequiredError` (402) | no payment method (`payment_required`), spending cap reached (`spending_cap_reached`), Store price not accepted (`price_not_accepted`) | show `e.upgrade_url`; an agent should relay `e.agent_message` to its person and stop |
| `Kosa8::OrgFrozenError` (423, `org_frozen`) | the org is frozen in the Security Center | an owner or admin unfreezes it; retrying does not help |
| `Kosa8::RateLimitError` (429) | too many requests, or `quota_exceeded` (active sandbox limit) | wait `e.retry_after` seconds when set, or delete sandboxes |
| `Kosa8::ExecTimeoutError` (504 `exec_timeout`, or today's 502 "timed out" on exec) | a buffered exec ran past its 90 s limit | run it in the background and poll |
| `Kosa8::UnsupportedError` (501) | the host has no data plane yet (files, checkpoints, rewind, fork, ports), or the sandbox runs on overflow capacity (Cloudflare), which has no fork, checkpoint or sleep | use `exec`, or create it on a kosa8 host (a template, or a size such as `2x4`) |
| `Kosa8::ApiError` (503 `database_busy`, 409 `template_building`) | the API's database was overloaded, or a benchmark environment is still building | retried for you (Retry-After); if it still fails, try again later |

Every Cloud error is a `Kosa8::ApiError` carrying the server's stable `e.code`, its message and `e.body`.

## The same thing in each language

The five kosa8 SDKs (Python `kosa8`, JS `@kosa8/sdk`, Go `kosa8-go`, Ruby `kosa8`, Java
`com.kosa8:kosa8`) call the same kosa8 Cloud API, but some names differ by language. The ones
that catch people switching:

| | Python | JS / TS | Go | Ruby | Java |
|---|---|---|---|---|---|
| client | `Kosa8Cloud()` | `new Kosa8Cloud()` | `kosa8.NewCloud(kosa8.CloudOptions{})`, returns `(cloud, err)` | `Kosa8::Cloud.new` | `Kosa8Cloud.builder().build()` |
| lifetime on create | `ttl_s=3600` | `{ ttlS: 3600 }` | `CloudCreateOptions{TTLSeconds: 3600}` | `ttl_s: 3600` | `new CloudOptions.Create().ttlSeconds(3600)` |
| persistent sandbox | `persistent=True` | `{ persistent: true }` | `CloudCreateOptions{Persistent: true}` | `persistent: true` | `.persistent(true)` |
| sandbox id | `box.id` | `box.id` | `box.ID()`, a method (`fmt.Println(box.ID)` prints a func value; `go vet` reports it) | `box.id` | `box.id()` |
| shell command | `box.exec("ls /")` | `box.exec('ls /')` | `box.ExecShell(ctx, "ls /", nil)` | `box.exec("ls /")` | `box.exec("ls /")` |
| argv command | `box.exec(["ls", "/"])` | `box.exec(['ls', '/'])` | `box.Exec(ctx, []string{"ls", "/"}, nil)` | `box.exec(["ls", "/"])` | `box.exec(List.of("ls", "/"))` |
| per-exec timeout | `exec(cmd, timeout_s=30)` | `exec(cmd, { timeoutS: 30 })` | `&kosa8.CloudExecOptions{TimeoutS: 30}` | `exec(cmd, timeout_s: 30)` | `exec(cmd, null, null, 30)` |
| exit code | `r.exit_code` | `r.exitCode` | `r.ExitCode`, an `*int` (nil when the cloud sent none; `r.OK()` checks for 0) | `r.exit_code` | `r.exitCode()`, an `Integer` (may be null) |
| files | `box.files.write` / `read_text` / `list` | `box.files.write` / `readText` / `list` | `box.Files().WriteString` / `ReadText` / `List(ctx, "")` | `box.files.write` / `read_text` / `list` | `box.files().write` / `readText` / `list()` |
| no such sandbox | `Kosa8NotFoundError` | `Kosa8NotFoundError` | `*kosa8.Error` with `Kind` `KindNotFound` (`errors.Is(err, kosa8.ErrNotFound)`) | `Kosa8::NotFoundError` | `Kosa8Exception.NotFoundException` |

In every SDK a non-zero exit is returned in the result, not raised. Each exec is a fresh process;
files in `/workspace` persist for the sandbox's life; installed packages need `persistent: true`.

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
ruby -w test/test_cloud_rl.rb      # RL and fan-out, a fake Cloud API on a local socket
ruby -w -Ilib -Itest -e 'Dir["test/test_*.rb"].sort.each { |f| require File.expand_path(f) }'  # all, as CI does
ruby examples/smoke.rb           # live, against a running `kosa8 daemon`
```

MIT licensed.
