# Changelog

## Unreleased

- `Kosa8::Cloud.new` with no `api_key:` and no `KOSA8_API_KEY` uses the key `kosa8 login` keeps in `~/.kosa8/cloud.json` (and its `api_url` unless `base_url:` or `KOSA8_CLOUD_URL` is set). The no-key error names `kosa8 login`.
- A plan limit answered with HTTP 429 (`starter_limit`) raises the new `Kosa8::PlanLimitError`, a `PaymentRequiredError`, still caught by `rescue Kosa8::RateLimitError`. Fix: it was retried as a rate limit; `starter_limit`, `payment_failed` and `spend_cap` are now quota codes (not retried), as in the other SDKs.

## 0.9.0 - 2026-11-25

- Autopilot: `cloud.bots` with `list` (`bots`, `paused_all`, `pending_approvals`), `templates`, `template(id)`,
  `plan(template: | spec:, name:, replay:)`, `compile(text)` (at most 500 characters, checked before sending),
  `create(template: | spec:, name:, sponsor:, budget_usd:, scope:, notify:)` (a draft; exactly one of template or
  spec), `get`, `update`, `delete`, `enable`, `disable`, `run(id, dry_run: true)` (a dry run by default),
  `runs(id, limit:)`, `get_run`, `cancel_run`, `undo_step(run_id, key)`, `pause_all` and `resume_all`.
  `cloud.approvals` (also `cloud.bots.approvals`): `list(state: "pending", limit:)`, `get`,
  `approve(id, reason:, edited_args:)` and `reject(id, reason:)`.
- Typed error `HumanApprovalRequired` (a `PolicyError`) for 403 `human_required`: enable, resume-all and deciding an
  approval need a person's credential. There is no way around it from code.

## 0.8.0 - 2026-11-24

- GitHub repos: `sandboxes.create(repo: "owner/name@ref")` (or `repo: { name:, ref:, path:, depth: }`) starts a
  sandbox from a repo of the org's connected GitHub, cloned into /workspace/<name>; `info["repo"]` says whether the
  clone is done. `cloud.github.status`, `repos(query, page:)`, `repos_page`, `branches("owner/name")`.
  `box.repo` (with `changes`), `box.push(branch:, message:, path:)` and `box.pull_request(title:, body:, base:,
  branch:, draft:)`. kosa8 uses a GitHub token for one repo, for one operation, that never enters the sandbox.
- Typed errors: `GitHubNotConnectedError` (`connect_url`), `GitHubPermissionsError` (`missing_permissions`,
  `settings_url`) and `NoChangesError` (all `ConflictError`), `RepoNotFoundError` (a `NotFoundError`) and
  `GitHubUnavailableError` (502, `retry_after_s`).

## 0.7.0 - 2026-11-23

- RL rollouts: each flushed chunk carries an Idempotency-Key that stays with those rows until
  kosa8 Cloud answers, so a flush whose answer was lost and is resent later is stored once.
- `build_template` / `tar_dir`: a `.dockerignore` entry with a leading `/` (`/build`) now excludes that path
  (it was sent in the build context); a bare `/` or `.` entry is ignored rather than matching nothing.
- `CloudBrowser#screenshot` says why when the API sent none (`screenshot_note`, e.g. too large).
- Gem metadata: summary and description start "Zero Trust cybersecurity infrastructure for AI agents";
  homepage, changelog, bug tracker and documentation URIs; CHANGELOG.md ships in the gem.
- `sandboxes.create(disk_gb:)` takes up to 500 (was refused past 200, though Team and Scale plans allow 256
  and 500); `kvm: true` (preview). A create from a snapshot also refuses `mem_mb:` and `kvm:`.
  `exec_background(timeout_s:)` (up to a day). `CloudExecResult` has `stdout_truncated`, `stderr_truncated`,
  `stdout_bytes` and `stderr_bytes`. README: the live region is `us-ash1` (`eu` is not offered).
- Files: `read` / `download` take `range:` (`0..1023`, `1024..`, `-500` or `"bytes=a-b"`; one Range header);
  `write` takes `offset:`, `append: true` and `mode:`; `upload` takes an IO (a File is read a part at a time)
  and sends anything past `part_size:` (64 MiB) in parts with `offset=`, so files over the API's 100 MB request
  limit upload. An `append` write is never retried after a 5xx or no answer, so it cannot land twice. The docs no
  longer say a file is at most 8 MiB (that is only hosts without streamed files).
- Streamed exec: `CloudSandbox#exec_stream(cmd, timeout_s:, on_stdout:, on_stderr:) { |stream, text| ... }`
  reads the output as the command prints it (NDJSON frames, heartbeats skipped, UTF-8 decoded across chunks)
  and is not held to the 90 s of a buffered exec; `timeout_s` up to a day. `exec` streams when given
  `stream: true`, `on_stdout:` / `on_stderr:` or a `timeout_s` over 90 (as the Python SDK). A command
  stopped at its `timeout_s` raises `ExecTimeoutError` with the output so far; a broken stream raises
  `StreamError`. `Cloud.new(stream_transport:)` replaces Net::HTTP for streamed answers (tests).
- Every Cloud error (`Kosa8::ApiError`) now reads the API's contract fields: `agent_message` and
  `request_url` on a 429 `quota_exceeded` (before, only a 402 had `agent_message`), and for a 402
  `plan_limit` / `plan_feature` `limit_name`, `limit`, `used`, `plan`, `next_plan`, `feature`, `options` and
  `pack_url`. `ExecTimeoutError#stdout` / `#stderr` / `#limit_s` give the output a command stopped at its
  `timeout_s` had printed.
- Retries of creates, batches, forks, grades, job submits and rollout records use a new SDK-made
  `Idempotency-Key` after a 5xx (502 `host_failed`, 503 `no_capacity` / `host_restarting` /
  `host_unavailable`, 504), so each retry of a server-side failure is a new attempt. The key is still
  kept after no answer (the first try may have created the sandbox), a 429 and a 409
  `idempotency_in_progress` / `template_building`. A key you pass as `idempotency_key:` is never
  changed. Retry-After is honoured as before. `Kosa8::Cloud.renews_idempotency_key?(e)` says which
  failures renew it.

## 0.6.0 - 2026-11-22

The Ruby SDK now covers what the Python and JS SDKs do (no longer "core tier" only):

- **Browsers:** `cloud.browsers` (`create`, `list`, `info`, `get`, `delete`), `cloud.browser { |b| ... }`
  (closed when the block ends), `CloudBrowser#page`, `goto`, `screenshot`, `close`, `refresh`, `cdp_url`
  (never shown by `inspect`) and `cdp_path` (GET /v1/browsers/{id}/cdp).
- **AI gateway:** `cloud.ai` (`keys`, `set_key`, `delete_key`, `settings`, `update_settings`, `usage`),
  `gateway_url(provider)` (`.../v1/ai/gw/{provider}` for a provider's own client) and `call(provider,
  path, body)`. `sandboxes.create(ai_gateway: true)` and `record: true`.
- **Hosted jobs:** `cloud.jobs` (`submit` with an Idempotency-Key, `estimate`, `get`, `list`, `cancel`,
  `wait`); tasks as an Array or JSONL, files base64-encoded for you.
- **Benchmarks:** `cloud.benchmarks` (`list`, `get`, `instances`, `instance`, `prepare`).
- **RL:** `cloud.rl_compare(*ids)` and `cloud.rl_alerts` (`list`, `create`, `update`, `delete`).
- **Org:** `usage_insights`, `pricing`, `limits`, `request_limit`, `lineage`, `checkpoints`, `images`,
  `org_egress`, `set_org_egress`, `preview_domains`, `attack_scorecards`; `cloud.audit` (`list`, `each`,
  `verify`, `export`), `cloud.api_keys` (`list`, `create`, `rotate`, `revoke`), `cloud.webhooks` (`list`,
  `create`, `delete`, `deliveries`, `test`), `cloud.recordings` (`list`, `link`, `delete`), `cloud.burst`
  (`get`, `activate`), `cloud.functions.invocations(name)`.
- **Per sandbox:** `stop_background(exec_id)`, `embeds` (`create`, `list`, `revoke`), `recordings`,
  `previews.domains(port)` (`add`, `list`, `get`, `remove`).
- **Small sizes:** `create(size: "0.25x0.5" | "0.5x1" | "1x2")` or `cpus: 0.25, mem_mb: 512`
  (`Kosa8::Cloud::SMALL_SIZES`); `cpus:` takes fractions (it was `Integer(cpus)`).
- **Retries:** every request is retried (backoff with full jitter, bounded by the policy's attempts,
  at least the Retry-After header or the body's `retry_after` / `retry_after_s`) on 503
  `database_busy`, 409 `template_building` and 429, POSTs included, since the server refused them before
  running anything. POST /v1/jobs and rollout records now carry an Idempotency-Key, so they are retried
  on infra failures too. `retryable: false` is never retried. `Kosa8.failure_of` follows the server's
  rules for `database_busy`, `template_building`, `idempotency_in_progress` and `invalid_*` codes.
- Overflow capacity (Cloudflare) sandboxes answer fork, checkpoint, rewind and sleep with 501
  `not_available`; documented, raised as `Kosa8::UnsupportedError`, never retried.
- README: `gem "kosa8", "~> 0.6"`; one persistence sentence for all SDKs (each exec is a fresh process;
  files in /workspace persist for the sandbox's life; installed packages need `persistent: true`); the
  stale "no sandbox labels" line removed.

## 0.5.3

- `CloudSandbox#exec(cmd, timeout_s:)`: the API's exec `timeout_s` (1 to 90 whole seconds) stops the command in the sandbox when it runs that long and raises `Kosa8::ExecTimeoutError` (without the hint about the 90 s buffered limit). Python, JS, Go and Java have the same option. Any other value is an `ArgumentError` before the call.
- README: `gem install kosa8` (it said `-v 0.4.0`) and `gem "kosa8", "~> 0.5"`; what persists between commands (only `/workspace`, unless the sandbox is persistent) matches the server; a "same thing in each language" table for the five SDKs.

## 0.5.2

- **Actionable API errors:** an error from kosa8 Cloud now reads as the server's sentence followed by its
  context, e.g. `no capacity: fork fewer or retry in 2 s [HTTP 503 no_capacity; retry in 10 s; request a5e7…-BOS]`.
  A 402 adds its `upgrade_url` (when the sentence does not already have it) and a 401 says to check
  `KOSA8_API_KEY` and where to make a key. The bare sentence stays in `daemon_message`.
- `Kosa8::Error#request_id`: the failed request's `X-Request-Id`, else Cloudflare's `cf-ray` (quote it to
  support). `#retry_after_s` is `#retry_after` under the API's name.
- Client-side errors say what to do next: a missing or malformed key points at `KOSA8_API_KEY` and
  https://app.kosa8.com/app#keys; a timeout names the call and suggests a longer `timeout:`; a connection
  failure says to check the network and `KOSA8_CLOUD_URL`.

## 0.5.1

- Failure class `oom`: exit 137 with the guest kernel's OOM count raised (kosa8 Cloud reports it on exec and grade; a grade killed for memory has no reward). It can be added to a rollout mask.

## 0.5.0 — unreleased

RL training and fan-out on kosa8 Cloud (the API of kosa8 Cloud's RL release):

- **Fan-out:** `cloud.sandboxes.create_many(count, ...)` (POST /v1/sandboxes/batch, up to 1000, a
  `Kosa8::SandboxBatch` with `failed`, `requested`, `created`, `run_id`). `box.fork(n)` now takes
  up to 1000 and `labels:`, `run_id:`, `lease_s:`, `prefix:`, `partial_ok:`, `idempotency_key:`,
  and returns a `SandboxBatch` (still an Array). `create` takes `lease_s:`, `run_id:` and
  `idempotency_key:`.
- **Leases:** `cloud.sandboxes.heartbeat(run_id:/labels:/ids:, extend_s:)`, `box.heartbeat`,
  `cloud.sandboxes.drain(...)` (calls again while the server says there are more), and
  `Kosa8::RL::Lease`.
- **Sealed grader:** `box.grade(cmd, files:, timeout_s:, env:, keep:, run_id:, rollout:)` and
  `cloud.sandboxes.grade(id, ...)`, a `Kosa8::GradeResult`.
- **Idempotency-Key** on create, batch, fork and grade (a UUID by default), the same on every retry.
- **Retries:** `Kosa8::RetryPolicy` (3 tries, exponential backoff with full jitter, at least the
  server's Retry-After), on by default where safe (reads, PUTs, deletes, heartbeats, drains, keyed
  POSTs, and any 429); `Cloud.new(retry_policy: Kosa8::RetryPolicy::NONE)` turns it off,
  `sleeper:` replaces the waits. `Kosa8.with_retry`.
- **Failure classes:** every `Kosa8::Error` has `failure_class` and `retryable?`
  (`Kosa8.classify_failure`, `Kosa8.failure_of`) and `retry_after` (Retry-After seconds or HTTP
  date, or the body's `retry_after_s`); `CloudExecResult` has `failure_class` and `retryable`.
- **fork_map:** `box.fork_map(items, concurrency:, retries:, timeout_s:, ...) { |child, item| }`
  and `cloud.fork_map(base, items, ...)`, `Kosa8::ForkResult`s in order; every fork deleted, Ctrl-C
  included.
- **RL runs:** `Kosa8::RL::Run` (`open`, `start`, `record`, `flush` in batches of at most 500,
  `finish`, `summary`, `update`, `rollouts`, `export`, `drain`, `Run.list`, `Run.attach`) and
  `Run#map` (one training step: fork, solve, sealed grade, record, with masking of infra, quota
  and harness failures), `Kosa8::RL::Rollouts`, `RolloutResult`.
- **Org templates:** `cloud.org_templates` (`build`, `import`, `list`, `get`, `delete`, `wait_ready`).
- **Capability tokens:** `cloud.tokens` (`create`, `list`, `revoke`); `Cloud.new` takes a
  `k8c_tok_` token as its key.
- `Cloud::MAX_FORK` is now 1000. Requests that used to fail at once on a 5xx (reads, deletes) are
  now retried; pass `retry_policy: Kosa8::RetryPolicy::NONE` for the old behaviour.

## 0.4.0 — 2026-11-15

The rest of the kosa8 Cloud API:

- **Sized and Docker creates**: `create` takes `size:`, `cpus:`/`mem_mb:`, `image:`, `disk_gb:`,
  `persistent:`, `docker:`, `cpu:`, `name:`, `labels:`, `env:`, `secrets:`, `egress:`,
  `snapshot:` and `wait:`; a cold boot is waited for with the new `wait_running`. `list` takes
  `name:` and `labels:`.
- **Background commands** (`exec_background`, `background_exec`, `wait_background`), **durable
  snapshots** (`snapshot`, `cloud.snapshots`), **previews**, **terminal**, raw `files.download` /
  `files.upload` and `files.link`, **egress**, **secrets** (`cloud.secrets`), **schedules**,
  **code interpreter**, `metrics`, `logs`, `set_labels`, `cloud.capabilities`.
- **Pipelines** (`cloud.pipelines`): `run`, `runs`, `get`, `wait`, `logs`, `cancel`,
  `artifacts`, `download_artifact`, `create_hook`, `hooks`, `delete_hook`.
- Every Cloud request sends `User-Agent: kosa8-ruby/<version>` (api.kosa8.com's edge refuses some
  default library user agents).

kosa8 Cloud parity with the Python SDK. The default address stays `https://api.kosa8.com` (0.3.0 defaulted to `api.kosa8.cloud`; do not use 0.3.0).

- **Lifetime:** `cloud.sandboxes.create` takes `ttl_s:` (60 s to 90 days), `delete_after:` (Unix ms) and `accept_price:` (paid Store items); bad values raise `ArgumentError` before any request. New `CloudSandbox#update(ttl_s:, delete_after:, sleep_after_s:, clear_lifetime:)` (PATCH; `clear_lifetime: true` sends `ttl_s: null`) and `#notes`.
- **Paging:** `cloud.sandboxes.list` still returns an Array and now takes `limit:` and `cursor:`. New `list_page` (a `Kosa8::CloudSandboxPage` with `sandboxes` and `next_cursor`) and `each(all:, page_size:)`, which follows `next_cursor` (an Enumerator without a block) and stops on a repeated cursor.
- **Data plane** (needs the host's data plane; 501 `Kosa8::UnsupportedError` on hosts without it): `box.files` (`read` binary, `read_text`, `write`, `list`, `mkdir`, `delete(recursive:)`, raw `application/octet-stream` bodies), `box.checkpoint(label)`, `box.checkpoints`, `box.rewind(id)` (a `Kosa8::CloudRewindResult`), `box.fork(n)` and `box.ports`.
- `cloud.templates`. New `cloud.request_bytes` for raw bodies.
- **Errors:** `PaymentRequiredError#upgrade_url` and `#agent_message`. New `Kosa8::OrgFrozenError` (423 `org_frozen`) and `Kosa8::ExecTimeoutError` (504 `exec_timeout`, or today's 502 "timed out" on exec after about 30 s; also a client-side timeout on exec). `RateLimitError#retry_after` from Retry-After. A `transport:` may now return `[status, body, headers]`.
- README: Cloud quickstart first; the base template (Alpine, busybox sh, fresh container per exec, only `/workspace` persists, 30 s exec limit, 64 KiB bodies, 8 MiB files); Cloud errors.

## 0.3.1 — 2026-11-03

- The default kosa8 Cloud address is now `https://api.kosa8.com` (0.3.0 defaulted to `api.kosa8.cloud`, which kosa8 Cloud does not use). `KOSA8_CLOUD_URL` still overrides it.

## 0.3.0 — 2026-11-03

kosa8 Cloud's API (api.kosa8.cloud) is not open yet; the `Kosa8Cloud` client is ready for when it is.

kosa8 Cloud, the same as the Python SDK's `Kosa8Cloud` and `@kosa8/sdk`'s.

- `Kosa8::Cloud`: a client for the kosa8 Cloud control plane, authenticated with a `k8c_live_` API key
  (`KOSA8_API_KEY`; address `KOSA8_CLOUD_URL`, default `https://api.kosa8.cloud`, https only except
  localhost). Standard library only; `inspect` never shows the key; `transport:` swaps Net::HTTP out.
- `cloud.sandboxes.create`, `list` and `get` return a `Kosa8::CloudSandbox` with `exec` (returns
  `Kosa8::CloudExecResult`: `exit_code`, `stdout`, `stderr`, `woke_ms`), `sleep`, `wake`, `refresh` and `delete`.
- `cloud.functions`: `deploy`, `list`, `get`, `delete`, `invoke` and `map`.
- `cloud.me` and `cloud.usage`.
- Errors: every error has `code`, the cloud's stable error code. New `Kosa8::PaymentRequiredError` (402)
  and `Kosa8::RateLimitError` (429).

The saved worker connection, as the CLI uses it (Windows especially).

- With no `host:` and no `KOSA8_HOST`, and no `socket_path:`, the client uses the connection
  `kosa8 wsl setup` or `kosa8 worker join` saved in `~/.kosa8/worker.json`: its host, its token
  (unless `token:` is given) and its `"insecure": true`. A saved token is never sent to a host from
  `KOSA8_HOST` or `host:`. New `worker_file:` option (`false` reads none).
- On Windows, a failed connection to the default socket says to run `kosa8 wsl setup` or set `KOSA8_HOST`.
- CI on ubuntu, macOS and Windows; mock-daemon tests skip where unix sockets are unavailable.

## 0.2.0 — 2026-11-03

The sandbox toolbox, matching the Python SDK and the v0.13.0 daemon.

- **Run code**: `run_code` (Python, JavaScript, TypeScript) returns `Kosa8::CodeResult`; matplotlib
  charts come back in `artifacts` as `Kosa8::Artifact` with binary `data`.
- **Files**: `list_files`, `stat_file`, `read_file` (binary String; a short body raises),
  `read_text`, `write_file` (with `mode:`), `delete_file` (with `recursive:`), `make_dir`, `move_file`.
- **Git**: `git(op, **fields)` returns `Kosa8::GitResult`, plus `git_clone`, `git_status` and
  `git_commit`, which stages everything first (`add_all: false` to skip).
- **Sessions**: `create_session`, `list_sessions`, `session_exec` (`Kosa8::ShellResult` with `cwd`),
  `delete_session`, and `shell`, which makes the session the first time it is used.
- **Terminals and previews**: `start_pty`, `resize_pty`, `create_preview`, `revoke_previews`.
- **Lifecycle**: `set_lifecycle`, and `create_sandbox` takes `auto_stop_min:`, `ttl_min:`,
  `auto_delete_min:`, `ephemeral:` and `template:`.
- **Templates**: `list_templates`, `delete_template`, and `build_template`, which tars the context
  folder (honouring `.dockerignore`) with the standard library, streams build output to a block or
  `on_output:`, and raises `Kosa8::StreamError` when the build fails.
- `Kosa8::Sandbox` gains every toolbox method that takes a sandbox.
- `run_code` and `session_exec` wait for the daemon's own limit (5 min, or `timeout_s` when given)
  plus 2 min, and git for 12 min, rather than Net::HTTP's 60 s default.

## 0.1.2 — 2026-11-03

- **Concurrent checkpoints really no longer collide.** 0.1.1 retried by re-reading the
  store, which still returned the taken id (the winner records it only after its snapshot
  completes). The loser now steps to the next id; a 409 for any other reason is raised.
  Verified live with two threads checkpointing one sandbox.

## 0.1.1 — 2026-11-03

Fixes found while writing and testing the docs at https://docs.kosa8.com/guides/rb-guide/.

- **`run`, `exec`, `exec_frames` and `attach` no longer time out after 60 s of silence.**
  With no `timeout:`, streaming calls now wait as long as the command runs. Net::HTTP's
  60 s read timeout used to raise `Kosa8::TimeoutError` on any command quiet for a minute.
  JSON calls keep Net::HTTP's defaults.
- **A second `write_stdin` to the same container now raises `Kosa8::Error`** instead of
  answering `{"ok"=>true}` for input the process never sees. The daemon treats one request
  body as the whole of stdin and closes it at the end; stream with an IO or Enumerable.
- **`Kosa8::Error#method` is renamed `#http_method`**, so `Object#method` works on errors
  again (`e.method(:message)` used to raise ArgumentError).
- **An exception raised in your own `on_stdout` / `on_stderr` / `on_status` callback comes
  out unchanged.** An `IOError` there used to be relabelled `Kosa8::ConnectionError`.
- **A frame that is not valid NDJSON raises `Kosa8::ProtocolError`** (a `Kosa8::Error`),
  not `JSON::ParserError`.
- **Concurrent checkpoints of one sandbox no longer collide.** When two pick the same id,
  the one refused with 409 picks the next id and retries.
- **The checkpoint file lock waits at most 10 s** (`FileCheckpointStore.new(lock_timeout:)`),
  as `@kosa8/sdk` does, then raises `Kosa8::CheckpointError` instead of hanging.
- **A failed `rewind` says what happened**: the sandbox was deleted (not stopped) and the
  checkpoint is intact, with the `restore_snapshot` call that recovers it.
- **`explore` no longer sleeps after its last retry.**
- **`Kosa8::Sandbox` gains `exec_frames`, `start_interactive`, `write_stdin` and `attach`.**

Not changed: a client-side `timeout:` stops waiting but does not stop the command in the
sandbox; the daemon has no cancel for a run in progress.

## 0.1.0 — 2026-11-03

First release.
