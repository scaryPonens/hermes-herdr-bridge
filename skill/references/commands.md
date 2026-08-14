# herdr — full command reference

Per-subcommand cheat sheet. Run `herdr <subcommand> --help` for the canonical flag list.

## Top-level

```bash
herdr                            # launch or attach to the persistent session
herdr --session <name>           # use/create a named persistent session
herdr --remote <ssh-target> [--session <name>]   # remote herdr
herdr session attach <name>      # attach to a named session
herdr completion zsh             # shell completions
herdr update [--handoff]         # self-update
herdr channel set <stable|preview>
herdr server stop                # stop the daemon (via socket API)
herdr server reload-config       # reload config.toml
herdr server                     # run as headless server
```

## status

```bash
herdr status [server|client]
```

Returns:
- `client.version`, `client.channel`, `client.protocol`
- `server.status` (running / stopped), `server.version`, `server.protocol`, `server.compatible`, `server.socket`
- `update.restart_needed`

**Always run `herdr status` first** to confirm the daemon is reachable before issuing workspace/agent commands.

## workspace

```bash
herdr workspace list
herdr workspace create [--cwd PATH] [--label TEXT] [--env KEY=VAL] [--focus|--no-focus]
herdr workspace get <WORKSPACE_ID>
herdr workspace focus <WORKSPACE_ID>
herdr workspace rename <WORKSPACE_ID> <NEW_LABEL>
herdr workspace report-metadata <WORKSPACE_ID> <KEY> <VALUE>
herdr workspace close <WORKSPACE_ID>
```

`create` returns a `workspace_created` envelope with `root_pane`, `tab`, and `workspace` objects. The `root_pane.pane_id` (e.g. `wH:p1`) is what you pass to `agent start` next.

> **Focus vs attention.** `--focus` on `create` (or `workspace focus`) raises the workspace to the front, stealing user attention. From a background session, prefer `agent focus <pane_id>` after creation — it routes input without raising the window. `agent read` / `pane read` work without any focus change at all.

## tab

```bash
herdr tab list [--workspace <ID>]
herdr tab create [--workspace <ID>]
herdr tab get <TAB_ID>
herdr tab focus <TAB_ID>
herdr tab rename <TAB_ID> <NEW_LABEL>
herdr tab close <TAB_ID>
```

A workspace has one tab by default; you can split into multiple.

## agent

The most-used subcommand. `<TARGET>` = `<workspace>:<pane>`.

```bash
herdr agent list                              # all agents
herdr agent get <TARGET>                      # single agent details
herdr agent read <TARGET>                     # tail of terminal output
herdr agent prompt <TARGET> <TEXT>            # submit prompt to the agent
herdr agent send-keys <TARGET> <KEY>...       # send key presses
herdr agent rename <TARGET> <NEW_NAME>
herdr agent focus <TARGET>                    # bring agent into focus
herdr agent start <NAME> --kind <K> --pane <P> # start a supported agent in pane
herdr agent attach <TARGET>                   # attach directly to agent terminal
herdr agent wait <TARGET> [--until STATUS]... [--timeout MS]
herdr agent explain <TARGET>                  # explain status detection
```

`--kind` supported: `pi`, `claude`, `codex`, `gemini`, `cursor`, `devin`, `agy`, `cline`, `omp`, `mastracode`, `opencode`, `copilot`, `kimi`, `kiro`, `droid`, `amp`, `hermes`, `kilo`, `qodercli`, `maki`.

### `agent wait` semantics

- Without `--until`, matches `idle`, `done`, or `blocked`.
- Repeat `--until` to specify exact states: `--until idle --until done`.
- Without `--timeout`, waits indefinitely — but in practice the socket times out around 590s, so always pass `--timeout 590000` and cycle in a loop for long tasks.
- When submission starts from a non-working state, `--wait` requires an observed state change within 5000ms; otherwise it returns `agent_prompt_stalled`. A shorter `--timeout` returns `timeout` instead.

### `agent prompt` semantics

- Returns `agent_prompted` on success — but `revision` / `state_change_seq` may not bump if a leftover background shell is busy. Always verify.

## pane

```bash
herdr pane list                                # all panes
herdr pane current                             # current pane
herdr pane get <PANE_ID>
herdr pane layout [--pane <P>]
herdr pane process-info [--pane <P>]           # process tree (foreground + bg)
herdr pane neighbor [--pane <P>] [--direction up|down|left|right]
herdr pane edges [--pane <P>]
herdr pane focus [--pane <P>] [--direction ...]
herdr pane resize [--pane <P>] [--amount N]
herdr pane zoom [--pane <P>] [--on|--off]
herdr pane read [--pane <P>]                   # raw terminal output
herdr pane rename [--pane <P>] <NEW_NAME>
herdr pane split [--pane <P>] [--direction vertical|horizontal]
herdr pane swap [--pane <P>] [--target <P2>]
herdr pane move [--pane <P>] [--direction ...]
herdr pane close [--pane <P>]
herdr pane send-text [--pane <P>] <TEXT>       # send literal text
herdr pane send-keys [--pane <P>] <KEY>...     # send key presses (Esc, ctrl+u, ...)
herdr pane wait-output [--pane <P>] <REGEX>    # wait for matching output
herdr pane run [--pane <P>] <COMMAND>          # run a command in pane
herdr pane report-agent [--pane <P>]
herdr pane report-agent-session [--pane <P>]
herdr pane release-agent [--pane <P>]
herdr pane report-metadata [--pane <P>] <KEY> <VALUE>
```

Use `esc` (not `escape`) as the canonical Escape key name in `send-keys`.

## notification

```bash
herdr notification ...    # OS notification helpers (banner, sound, etc.)
```

Useful when an agent reaches a state you want to alert on without polling.

## api

```bash
herdr api <subcommand> ...
```

Raw socket API access — useful for scripting beyond what the high-level commands expose.

## config

```bash
herdr config <subcommand> ...
herdr config reset-keys    # back up config.toml + remove custom keybindings
```

## integration

```bash
herdr integration <subcommand> ...
```

Manage built-in agent integrations (claude, codex, gemini, etc.).

## worktree, channel

```bash
herdr worktree <subcommand> ...   # Git worktree helpers over the socket API
herdr channel <subcommand> ...    # stable / preview channel management
```

## Common identifier format

```
<workspace_id>   : w1, w8, wD, wH, ...
<tab_id>         : w1:t1
<pane_id>        : w1:p1
<TARGET>         : w1:p1  (used by `herdr agent ...`)
```

All IDs are stable for the lifetime of the workspace.

## Output envelope shape

Every response is a JSON object with a top-level `id` and `result`:

```json
{
  "id": "cli:agent:list",
  "result": {
    "agents": [...],
    "type": "agent_list"
  }
}
```

For `agent_list`, the useful fields per agent are:
- `agent` (claude / codex / hermes / …)
- `agent_status` (idle / working / blocked / done / unknown)
- `agent_session` (kind + source + value, identifies the underlying session)
- `cwd`, `foreground_cwd`
- `pane_id`, `tab_id`, `workspace_id`, `terminal_id`
- `revision` (incremented on agent activity — **use this to detect prompt drops**)
- `state_change_seq` (incremented on status transitions)
- `terminal_title`, `terminal_title_stripped`
- `interactive_ready` (true once the agent is ready for input)