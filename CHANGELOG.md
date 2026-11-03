# Changelog

## Unreleased

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
