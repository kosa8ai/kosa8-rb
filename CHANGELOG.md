# Changelog

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
