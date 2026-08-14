---
name: herdr
description: Drive herdr-managed coding agents (list, prompt, wait, read) over the host TCP bridge.
version: 0.2.0
author: Hermes Agent
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [herdr, ai-coding-agents, workspace-manager, monitoring, async]
    related_skills: [claude-code, codex, opencode]
---

# herdr

`herdr` is a terminal workspace manager for AI coding agents (Claude Code, Hermes, Codex, etc.). It runs as a background server with a socket API and exposes a CLI for inspecting and controlling workspaces, tabs, panes, and agent processes. This skill covers the patterns needed to monitor and react to agent activity from a Hermes session.

**Scope:** CLI inspection + wait workflows. Does not cover rich pane interaction, scripted editing, or configuration — just what the user typically needs from a Hermes session.

## When to Use

- User asks to "let me know when agent X finishes" / "watch this workspace" / "check on the coding run"
- Need to enumerate active AI agents across workspaces before replying
- Need to read the recent output of a long-running agent pane
- Need to wait for a specific state change (idle / done / blocked) on a known pane

**Don't use for:** scripted editing or rich pane interaction (use `terminal(pty=true)` or `delegate_task`), file editing inside a workspace (just use `read_file`/`write_file` directly on disk), or managing `herdr` server config (user handles that).

## Prerequisites

- `herdr` server running on the host; check with `herdr_client.py health`. If it fails, tell the user to launch their `herdr` session — do not try to start the server yourself from a Hermes session.
- The host runs a persistent `socat` bridge (LaunchAgent `local.herdr-socat`) exposing the Unix socket on `127.0.0.1:9876`. See `references/docker-tcp-bridge.md` for setup and troubleshooting.

## Interface — use the client, not raw sockets

Hermes runs inside a Docker container with no `herdr` binary, so **every operation goes through the bundled client**:

```bash
CLIENT=/root/.hermes/skills/autonomous-ai-agents/herdr/scripts/herdr_client.py
python3 $CLIENT health
```

It reads `HERDR_HOST` / `HERDR_PORT` from the environment (already set to `host.docker.internal:9876`), prints one JSON object per call, and exits 1 with `{"ok":false,"error":"..."}` when herdr is unreachable, slow, or refuses the request. Do not hand-write socket code.

| Need | Command |
|---|---|
| Is herdr reachable at all | `python3 $CLIENT health` |
| All agents across workspaces | `python3 $CLIENT list-agents [--workspace <ws_id>]` |
| Single agent detail | `python3 $CLIENT get-agent <pane_id>` |
| Submit a prompt | `python3 $CLIENT prompt-agent <pane_id> "<text>"` |
| Block until it settles | `python3 $CLIENT wait-agent <pane_id> [--timeout <ms>] [--until idle,done]` |
| Read recent pane output | `python3 $CLIENT read-pane <pane_id> [--source recent\|visible\|recent_unwrapped\|detection]` |
| Type into a pane (no submit) | `python3 $CLIENT send-input <pane_id> "<text>"` |
| Clear a stuck input buffer | `python3 $CLIENT send-keys <pane_id> ctrl+u ctrl+a ctrl+k` |

Anything not in that table (workspace create, agent start, pane split, …) goes through the generic path — import the module and call the method directly:

```python
import sys; sys.path.insert(0, "/root/.hermes/skills/autonomous-ai-agents/herdr/scripts")
from herdr_client import call
call("workspace.create", {"label": "codex lab"})
```

`references/herdr-json-rpc-protocol.md` has the full method list and parameter shapes.

## Quick Reference — host CLI

Only usable in a shell **on the host**, not from a Hermes container. Included because the user runs these and pastes the output.

| Need | Command |
|---|---|
| Server + client health | `herdr status` |
| All workspaces | `herdr workspace list` |
| Create workspace | `herdr workspace create --label "<name>" [--cwd <path>] [--focus]` |
| All agents across workspaces | `herdr agent list` |
| Single workspace detail | `herdr workspace get <ws_id>` |
| Single agent detail | `herdr agent get <pane_id>` |
| Start agent in pane | `herdr agent start <name> --kind <kind> --pane <pane_id> --timeout 60000` |
| Submit prompt to agent | `herdr agent prompt <pane_id> "<text>"` |
| Read recent pane output | `herdr agent read <pane_id>` |
| Wait for completion | `herdr agent wait <pane_id> [--until <state>] [--timeout <ms>]` |
| Find agent target | `herdr agent list` → look at `pane_id` (format `wX:pY`) |
| Explain agent detection | `herdr agent explain <pane_id>` |

Agent states: `idle`, `working`, `blocked`, `done`, `unknown`. `blocked` means the agent is waiting on the user (permission prompt, input request) — that counts as "done for now" for monitoring purposes.

## References

- `scripts/herdr_client.py` — The client. Library + CLI, stdlib only.
- `references/docker-tcp-bridge.md` — How the container reaches herdr: the host `socat` LaunchAgent, install/verify commands, security notes, and what each failure mode means.
- `references/herdr-json-rpc-protocol.md` — Full protocol reference: method list, parameter shapes, parameter-name gotchas vs CLI flags, error codes, discovery trick.
- `references/commands.md` — Host CLI subcommand cheat sheet with flags, output shapes, and identifier formats.
- `references/diagnostics.md` — "Does this agent have GitHub access?" prompt, terminal-title glyphs, how to tell a real completion from a wait timeout, and how to detect a silently-dropped prompt.

## Procedure — "Tell me when the agent finishes"

This is the canonical async-watch pattern. The `terminal` tool's foreground timeout is capped at 600s, so long waits MUST go through `background=true` with `notify_on_complete=true`.

0. **Confirm the bridge is up** — one call, before anything else: `python3 $CLIENT health`. A failure here means the host bridge or the herdr server is down; say so instead of retrying other commands.

1. **Discover the target pane.**
   ```bash
   python3 $CLIENT list-agents
   ```
   Identify the workspace and pane from `workspace_id` and `pane_id`. The `terminal_title` and `cwd` help confirm it's the right one.

2. **Sanity-check it's the right task.**
   ```bash
   python3 $CLIENT read-pane <pane_id> | tail -40
   ```
   Confirms the title bar matches what the user asked about. Skipping this leads to watching the wrong pane for hours.

3. **Start the wait in the background.**
   ```bash
   python3 $CLIENT wait-agent <pane_id> --timeout 590000
   ```
   Default `--until` matches `idle`, `done`, or `blocked` — exactly what "finished" means. Pass explicit `--until` only when you need a non-default state (rare). `--timeout` is in milliseconds; subtract a small margin from your budget so the wait exits cleanly before any outer timeout.

4. **Wrap it in the `terminal` tool with `background=true` and `notify_on_complete=true`.** The runtime delivers one notification when the wait process exits, and that notification becomes the trigger for your follow-up reply.
   ```python
   terminal(command="python3 $CLIENT wait-agent <pane_id> --timeout 590000",
            background=True,
            notify_on_complete=True,
            timeout=600)
   ```
   Setting `timeout` ≥ the wait's `--timeout` is required or the runtime kills the process mid-wait.

5. **Tell the user what you're watching** — workspace, pane, agent, task title, current state, and elapsed time. They will not have visibility into the wait otherwise.

6. **When the notification arrives, re-read state and reply with the new status + a short summary of what the agent actually did.** Don't reply with just "it finished" — confirm what finished.

7. **For long-running agents, plan on multiple cycles.** A skill eval / large refactor that takes 30-60 minutes will hit the 10-minute wait ceiling 3-6 times. Each cycle notification should produce a tight 3-5 line reply ("still working, now on batch N of M, restarting watcher") rather than a full transcript dump. The user's first reaction will be "Update?" — make those replies cheap to skim.

## Pitfalls

- **Foreground timeout cap.** The `terminal` tool refuses `timeout > 600` in foreground mode. Long `wait-agent` calls must use `background=true`.
- **`--timeout` is milliseconds, not seconds.** `wait-agent wD:p1 --timeout 590000` ≈ 9m50s. Easy off-by-1000 mistake.
- **Default wait states are right.** `wait-agent` without `--until` matches `idle`/`done`/`blocked`. Don't add `--until done` thinking it's more specific — `done` is rare; `idle` is the common completion state.
- **`blocked` is not an error.** A blocked agent is waiting on user input (permission prompt, question). Surface it as "needs your input" rather than "failed."
- **Pane IDs are not stable across restarts.** Always re-run `python3 $CLIENT list-agents` before issuing a `wait` — a pane from yesterday's session won't exist today.
- **Multiple agents per workspace.** `call("workspace.list")` shows one `active_tab_id` per workspace but agents can exist in non-active tabs. Use `python3 $CLIENT list-agents` for the full picture.
- **Don't try to start the server.** If `health` fails while the bridge is up (host `herdr status` reports server stopped), ask the user to launch their session. Starting `herdr server` from a Hermes shell will fight the user's interactive session.
- **Wait timeout ≠ agent finished.** `wait-agent --timeout 590000` exits 1 with `{"ok":false,"error":"timeout: ..."}` after ~10 minutes. That is **the wait hitting its ceiling**, not the agent settling. On a timeout notification: re-run `python3 $CLIENT list-agents` to confirm the agent's current state, then start a fresh `background=true` wait if it is still `working`. Do not tell the user "the agent finished" because the wait process exited.
- **(host CLI only) `herdr agent prompt --wait` does not take a positional prompt with the wait flags.** The CLI parses the prompt text as another flag and errors (`unknown option: ...`). The `--until <STATE>` flag requires `--wait` first. Cleanest pattern: call `python3 $CLIENT prompt-agent <pane> "<text>"` (no wait flags), then use `python3 $CLIENT wait-agent <pane> --timeout N` separately to block on completion.
- **`prompt-agent` can silently drop the prompt.** If the pane has a leftover background shell (a `until [...] do sleep N` tail watcher, a `caffeinate` foreground process, or any still-running subprocess from a prior turn), herdr returns `{"type":"agent_prompted"}` as if success, but `revision` and `state_change_seq` never bump and the agent never processes the text. Observed in practice: a long, detailed prompt dropped silently while a terse one-liner submitted immediately afterwards landed. **A fresh `caffeinate -i -t 300` foreground process does not block input** (it expires on its own in 5 min) — the usual culprit is the leftover `until/do/sleep` shell from a prior turn's tail-watcher. Diagnostics and recovery:
  1. Capture `revision` and `state_change_seq` from `python3 $CLIENT get-agent <pane>` BEFORE submitting.
  2. Submit the prompt.
  3. Wait ~3s, then `python3 $CLIENT get-agent <pane>` again — if `revision`/`state_change_seq` are unchanged and `agent_status` is still `idle`, the prompt was dropped.
  4. Recovery order: (a) send a **shorter, simpler** version of the same prompt (most reliable), (b) cycle another `wait-agent` to drain the leftover shell and retry, (c) clear the input buffer with `python3 $CLIENT send-keys <p> ctrl+u ctrl+a ctrl+k` and resubmit. Bare `Escape` and `ctrl+u` may not visibly clear the buffer — that's a UI artifact of Claude/Codex, not a sign of failure; trust the revision/state_change_seq, not the display.
- **`--focus` on `workspace create` steals user attention.** It brings the new workspace to the front. Use `call("agent.focus", {"target": "<pane_id>"})` after creation if you want to drive input to the agent without raising the window. `python3 $CLIENT read-pane` and `call("pane.read", ...)` work regardless of focus, so background monitoring never needs to raise anything.
- **Never bind-mount the Unix socket into the container.** A macOS Unix domain socket does not work across the OrbStack VM boundary: the socket file shows up inside the container but connecting to it fails with `ConnectionRefusedError: [Errno 111]`. The bridge exists because of this; the old `-v ~/.config/herdr:/run/herdr` mount and `HERDR_SOCKET_PATH` env var have been removed from `~/.hermes/config.yaml`. Don't reintroduce them.
- **`cannot reach herdr at host.docker.internal:9876` means the host side is down, not your call.** The bridge is a LaunchAgent; ask the user to run `make restart` in `~/Workspace/hermes-herdr-bridge` on the host. See `references/docker-tcp-bridge.md`.
- **Workspace create + agent start sequencing.** `call("workspace.create", {"label": "<name>"})` returns a `root_pane_id` (e.g. `wH:p1`). The pane's shell needs a moment to initialize before `agent start` will detect a prompt — sleep ~2s first. Then `call("agent.start", {"pane_id": "<pane_id>", "name": "<name>", "kind": "<kind>"})`. Verify success via `interactive_ready: true` in the result.
- **JSON-RPC parameter names differ from CLI flags.** When using the raw TCP protocol (Docker container without CLI), `agent.start` takes `pane_id` (not `target`), `agent.get`/`agent.prompt`/`agent.wait`/`agent.read` take `target` (not `pane_id`), `agent.prompt` takes `text` (not `prompt`), and `kind` is the bare agent name (`claude`) not the manifest source prefix (`herdr:claude`). See `references/herdr-json-rpc-protocol.md` for the full mapping.
- **`agent.start` kind must be bare name, not qualified source.** The `agent_session.source` field shows `"herdr:claude"` but the `kind` param in `agent.start` must be `"claude"` — the qualified form is rejected with `unsupported_agent_kind`.
- **New workspace pane has no agent until `agent.start`.** `workspace.create` gives you a bare shell pane. It won't appear in `agent.list` until you call `agent.start` with the pane_id. After `agent.start`, wait for `interactive_ready: true` before sending a prompt.

## Procedure — "Create a new workspace and start an agent"

When the user asks to spin up a fresh agent in its own workspace (e.g. "open a new workspace called codex lab and start codex"):

1. Create the workspace:
   ```bash
   call("workspace.create", {"label": "<name>"})
   ```
   Capture the returned `root_pane.pane_id` (it is the only pane initially).

2. Brief settle delay so the shell prompt is live:
   ```bash
   sleep 2
   ```

3. Start the agent into that pane:
   ```bash
   call("agent.start", {"pane_id": "<pane_id>", "name": "<human-name>", "kind": "<codex|claude|hermes>"})
   ```
   A success response has `interactive_ready: true`.

4. Confirm with `call("workspace.list")` — the new workspace should appear with the agent kind as `agent_status: blocked` if it is awaiting login/auth (Codex with no token, Claude needing OAuth, etc.), or `idle` once it has a session.

5. Submit a prompt and read the reply:
   ```bash
   python3 $CLIENT prompt-agent <pane_id> "<text>"     # submission
   python3 $CLIENT wait-agent <pane_id> --timeout N    # block on completion
   python3 $CLIENT read-pane <pane_id> | tail -60     # surface the answer
   ```

## Procedure — "Cycle a long wait past the 10-minute ceiling"

For agents expected to run longer than ~10 minutes (skill evaluations, large refactors, multi-batch PR reviews):

1. First wait cycle: `python3 $CLIENT wait-agent <pane_id> --timeout 590000` in `terminal(background=true, notify_on_complete=true, timeout=600)`.

2. On notification, the wait will have exited 1 with `{"ok":false,"error":"timeout: ..."}`. Do NOT interpret this as completion.

3. Re-check the agent's state:
   ```bash
   python3 $CLIENT list-agents | jq '.result.agents[] | select(.pane_id=="<pane_id>") | .agent_status'
   ```
   - If `working`: restart the wait (next step).
   - If `idle` / `done` / `blocked`: report to the user with a fresh `read-pane` summary.

4. Restart the wait for another 10-minute cycle:
   ```bash
   terminal(command="python3 $CLIENT wait-agent <pane_id> --timeout 590000",
            background=True, notify_on_complete=True, timeout=600)
   ```

5. Repeat until the agent settles. Multiple in-flight wait processes (each on a different pane, or chained on the same pane) are fine — they show up in `process action='list'` with distinct session IDs.

## Verification

- `python3 $CLIENT health` returns a `pong` before any other command.
- After starting a `wait`, the process appears in `process action='list'` as a background session.
- On notification, `python3 $CLIENT get-agent <pane_id>` shows the pane's `agent_status` matching the state you waited for (idle/done/blocked).
