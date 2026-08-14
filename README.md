# hermes-herdr-bridge

Lets a Hermes agent running in a container drive [herdr](https://herdr.dev)-managed coding agents on the macOS host.

herdr listens on a Unix domain socket. Hermes runs in a Linux container under OrbStack. Bind-mounting the socket does not work — the file shows up inside the container but connecting fails with `ConnectionRefusedError: [Errno 111]`, because a macOS Unix socket means nothing inside the Linux VM. Only TCP crosses that boundary.

```
Hermes container → host.docker.internal:9876 → socat (macOS) → ~/.config/herdr/herdr.sock → herdr
```

This repo is the source of truth for both halves: the host `socat` LaunchAgent and the Hermes skill that talks to it.

## Use

```bash
brew install socat
make install      # render + load the LaunchAgent, install the skill, verify
make check        # bridge state, bind scope, host + container reachability, config
make uninstall    # remove both
```

`make help` lists the rest (`restart`, `test`, `logs`, `config`).

`make install` writes two generated things — edit the repo, never them:

| Generated | From |
|---|---|
| `~/Library/LaunchAgents/local.herdr-socat.plist` | `launchd/local.herdr-socat.plist.in` |
| `~/.hermes/skills/autonomous-ai-agents/herdr/` | `skill/` |

The skill is **copied, not symlinked** — Hermes bind-mounts `~/.hermes/skills` into the container, where a symlink pointing back into `~/Workspace` would dangle.

## The one manual step

`~/.hermes/config.yaml` is Hermes's own file, hand-edited rather than generated. It needs:

```yaml
terminal:
  docker_extra_args:
    - "-e"
    - "HERDR_HOST=host.docker.internal"
    - "-e"
    - "HERDR_PORT=9876"
```

and must not bind-mount the herdr socket. `make config` prints this; `make check` fails if the env vars are missing or a stale `/run/herdr` mount reappears.

## Security

- The listener binds **127.0.0.1**, never `0.0.0.0`. OrbStack containers reach a host loopback listener through `host.docker.internal` — verified — so binding wider buys nothing and would expose herdr, i.e. full control of your local coding agents, to the LAN. Do not widen the bind to fix a connection problem. `make check` prints the bind scope for exactly this reason.
- The bridge has no auth. Anything that can open a loopback TCP connection on the host, including any other container, can drive herdr. Same trust boundary as the socket's file permissions, minus the file mode — fine on a single-user laptop, not on a shared or exposed machine.

## Layout

```
Makefile
launchd/local.herdr-socat.plist.in    # KeepAlive + RunAtLoad, loopback bind
skill/SKILL.md                        # how Hermes should drive herdr
skill/scripts/herdr_client.py         # stdlib client: library + CLI
skill/scripts/test_herdr_client.py    # framing / timeout / error self-check
skill/references/docker-tcp-bridge.md # setup, failure modes
skill/references/*.md                 # protocol, CLI cheat sheet, diagnostics
```

The client speaks herdr's newline-delimited JSON and exposes `health`, `list-agents`, `get-agent`, `prompt-agent`, `wait-agent`, `read-pane`, `send-input`, `send-keys`; anything else goes through `call(method, params)`.

```bash
CLIENT=/root/.hermes/skills/autonomous-ai-agents/herdr/scripts/herdr_client.py
python3 $CLIENT health
python3 $CLIENT prompt-agent w8:p1 "run the tests"
python3 $CLIENT wait-agent w8:p1 --timeout 590000
```
