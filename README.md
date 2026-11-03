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
`NotFoundError`, `ConflictError`, `UnsupportedError`, `StreamError` (`#stdout`/`#stderr` so far),
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

## Development

```sh
ruby -w test/test_client.rb      # mock daemon on a unix socket
ruby examples/smoke.rb           # live, against a running `kosa8 daemon`
```

MIT licensed.
