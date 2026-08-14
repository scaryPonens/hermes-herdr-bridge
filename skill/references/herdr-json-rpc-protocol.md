# herdr Raw JSON-RPC Protocol (TCP)

## When to Use

Reference for methods **not** wrapped by `scripts/herdr_client.py`. For the common operations (health, list/get/prompt/wait/read/send-input) use the client's subcommands; for anything else, `from herdr_client import call` and pass the method name and params from this document. Only hand-roll a socket if the client itself is unavailable.

## Connection

```
host.docker.internal:9876
```

Plain TCP (no TLS). Send one JSON object per request, terminated with `\n`. Read one JSON object as the response.

Reached through the host `socat` bridge — see `docker-tcp-bridge.md`.

### Making a call

```python
import sys; sys.path.insert(0, "/root/.hermes/skills/autonomous-ai-agents/herdr/scripts")
from herdr_client import call, HerdrError

call("workspace.create", {"label": "codex lab"})   # returns `result`, raises HerdrError on failure
```

The client handles the framing (responses are newline-delimited and can span multiple `recv`s), timeouts, and error unwrapping. A hand-written `s.recv(65536)` truncates any response over 64KB.

## Message Format

Request:
```json
{"id": "1", "method": "<method>", "params": { ... }}
```

Response (success):
```json
{"id": "1", "result": { "type": "<result_type>", ... }}
```

Response (error):
```json
{"id": "", "error": {"code": "<error_code>", "message": "<details>"}}
```

Note: error responses may return `"id": ""` rather than the request's id.

## Key Method Parameter Shapes

These were reverse-engineered from the server's error messages. The parameter names differ from the CLI flags in some cases.

### `ping`
```json
{"method": "ping", "params": {}}
```
Returns version, protocol, and capabilities (e.g. `live_handoff`, `detached_server_daemon`).

### `workspace.create`
```json
{"method": "workspace.create", "params": {"label": "<name>", "cwd": "<path>"}}
```
Returns `workspace_created` with `workspace`, `tab`, and `root_pane` objects. The `root_pane.pane_id` (e.g. `wJ:p1`) is needed for `agent.start`.

### `workspace.list`
```json
{"method": "workspace.list", "params": {}}
```

### `agent.list`
```json
{"method": "agent.list", "params": {"workspace_id": "<ws_id>"}}
```
Returns all agents. Filter client-side by `workspace_id` if needed.

### `agent.start`
```json
{"method": "agent.start", "params": {"pane_id": "<wX:pY>", "name": "<name>", "kind": "<kind>"}}
```
**Important:** Uses `pane_id` (not `target`). The `kind` field is the bare agent name (e.g. `claude`, `codex`, `omp`), **not** the manifest source prefix (e.g. `herdr:claude` is rejected). Returns `agent_started` with `launch_pending: true`. Wait a few seconds, then verify `interactive_ready: true` via `agent.get`.

### `agent.get`
```json
{"method": "agent.get", "params": {"target": "<wX:pY>"}}
```
Uses `target` (not `pane_id`). Returns full agent info including `agent_status`, `interactive_ready`, `revision`, `state_change_seq`.

### `agent.prompt`
```json
{"method": "agent.prompt", "params": {"target": "<wX:pY>", "text": "<prompt>"}}
```
Uses `target` + `text` (not `pane_id` + `prompt`).

### `agent.read`
```json
{"method": "agent.read", "params": {"source": "recent", "target": "<wX:pY>"}}
```
`source` is one of: `visible`, `recent`, `recent_unwrapped`, `detection`. `target` is the pane ID.

### `agent.wait`
```json
{"method": "agent.wait", "params": {"target": "<wX:pY>", "until": ["idle", "done", "blocked"], "timeout": 590000}}
```

## Full Method List

Discovered from the server's error response on an unknown method:

| Category | Methods |
|----------|---------|
| Server | `ping`, `server.stop`, `server.live_handoff`, `server.reload_config`, `server.agent_manifests`, `server.reload_agent_manifests` |
| Notifications | `notification.show` |
| Client | `client.window_title.set`, `client.window_title.clear` |
| Session | `session.snapshot` |
| Workspace | `workspace.create`, `workspace.list`, `workspace.get`, `workspace.focus`, `workspace.rename`, `workspace.move`, `workspace.report_metadata`, `workspace.close` |
| Worktree | `worktree.list`, `worktree.create`, `worktree.open`, `worktree.remove` |
| Tab | `tab.create`, `tab.list`, `tab.get`, `tab.focus`, `tab.rename`, `tab.move`, `tab.close` |
| Agent | `agent.list`, `agent.get`, `agent.read`, `agent.explain`, `agent.send_keys`, `agent.rename`, `agent.view.set`, `agent.view.clear`, `agent.focus`, `agent.start`, `agent.prompt`, `agent.wait` |
| Pane | `pane.split`, `pane.swap`, `pane.move`, `pane.zoom`, `pane.layout`, `pane.process_info`, `pane.neighbor`, `pane.edges`, `pane.focus_direction`, `pane.resize`, `pane.list`, `pane.current`, `pane.get`, `pane.focus`, `pane.rename`, `pane.send_text`, `pane.send_keys`, `pane.send_input`, `pane.read`, `pane.graphics.set`, `pane.graphics.clear`, `pane.graphics.info`, `pane.graphics.stream`, `pane.report_agent`, `pane.report_agent_session`, `pane.report_metadata`, `pane.clear_agent_authority`, `pane.release_agent`, `pane.close` |
| Layout | `layout.export`, `layout.apply`, `layout.set_split_ratio` |
| Popup | `popup.close` |
| Events | `events.subscribe`, `events.wait`, `pane.wait_for_output` |
| Integration | `integration.install`, `integration.uninstall` |
| Plugin | `plugin.link`, `plugin.list`, `plugin.unlink`, `plugin.enable`, `plugin.disable`, `plugin.action.list`, `plugin.action.invoke`, `plugin.log.list`, `plugin.pane.open`, `plugin.pane.focus`, `plugin.pane.close` |

## Parameter Name Gotchas

The raw protocol uses different parameter names than the CLI flags. Common mismatches:

| CLI flag | JSON-RPC param | Notes |
|----------|---------------|-------|
| `--pane <P>` | `pane_id` | `agent.start` uses `pane_id` |
| positional `<TARGET>` | `target` | `agent.get`, `agent.prompt`, `agent.wait`, `agent.read` use `target` |
| `--kind <K>` | `kind` | Bare agent name (`claude`), not manifest source (`herdr:claude`) |
| `--name <N>` | `name` | Human label for the agent instance |
| `<TEXT>` (prompt body) | `text` | `agent.prompt` uses `text`, not `prompt` |
| `--workspace <ID>` | `workspace_id` | `agent.list` uses `workspace_id` |

## Error Codes

| Code | Meaning |
|------|---------|
| `invalid_request` | Missing or wrong field name. The `message` tells you exactly which field is missing or wrong. |
| `agent_not_found` | The target pane doesn't have an agent attached yet, or the ID format is wrong. |
| `unsupported_agent_kind` | The `kind` value isn't recognized. Use the bare agent name (e.g. `claude`), not a qualified source. |

## Discovery Trick

Send a deliberately invalid method name to get the full method list in the error response:

```python
herdr_call("agent.spawn", {"target": "wX:p1"})
# Error: unknown variant `agent.spawn`, expected one of `ping`, `server.stop`, ...
```

### `pane.send_text` / `pane.send_keys`

```json
{"method": "pane.send_text", "params": {"pane_id": "<wX:pY>", "text": "<text>"}}
{"method": "pane.send_keys", "params": {"pane_id": "<wX:pY>", "keys": ["ctrl+u", "ctrl+a", "ctrl+k"]}}
```

Pane methods use `pane_id`; agent methods use `target`. `send_text` types without submitting — use `agent.prompt` to submit.
