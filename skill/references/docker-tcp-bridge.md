# Reaching herdr from the Hermes container (socat TCP bridge)

## Why a bridge

herdr listens on a macOS Unix domain socket (`~/.config/herdr/herdr.sock`). Hermes runs in a Linux container — under Docker Desktop or OrbStack, that means a Linux VM. Bind-mounting the socket **does not work**: the file appears inside the container, but `socket.AF_UNIX` connects fail with `ConnectionRefusedError: [Errno 111]` — a macOS Unix socket has no meaning inside the VM. Only TCP crosses that boundary. (On native Linux there is no VM and no need for any of this — mount the socket.)

```
Hermes container → host.docker.internal:9876 → socat (macOS) → herdr.sock → herdr
```

## Host setup

Managed by the repo at `~/Workspace/hermes-herdr-bridge` — `make install` / `make uninstall` / `make check`. The installed plist and the installed copy of this skill are both generated; edit the repo, not them.

`socat` from Homebrew runs as a LaunchAgent so it starts at login and restarts on crash. `~/Library/LaunchAgents/local.herdr-socat.plist` runs:

```bash
/opt/homebrew/bin/socat \
  TCP-LISTEN:9876,bind=127.0.0.1,reuseaddr,fork \
  UNIX-CONNECT:/Users/<user>/.config/herdr/herdr.sock
```

with `RunAtLoad`, `KeepAlive`, and logs at `~/Library/Logs/herdr-socat.log`.

Install / reinstall:

```bash
brew install socat
cd ~/Workspace/hermes-herdr-bridge && make install
```

Restart after a change: `make restart`. Verify anytime: `make check`.

## Security

- **`bind=127.0.0.1`, not `0.0.0.0`.** Containers under Docker Desktop and OrbStack reach a host loopback listener through `host.docker.internal` (verified on OrbStack), so binding to all interfaces buys nothing and would expose herdr — full control of the user's local coding agents — to every device on the LAN. Do not "fix" a connection problem by widening the bind: try `--add-host=host.docker.internal:host-gateway` or a different `HERDR_HOST` first. The repo's `BIND` var exists for runtimes that provably cannot reach loopback, and `make check` warns whenever the listener is not loopback-only.
- Confirm the scope any time the bridge is touched: `lsof -nP -iTCP:9876 -sTCP:LISTEN` must show `127.0.0.1:9876`, never `*:9876`.
- The bridge has no auth. Anything that can open a loopback TCP connection on the host — including any other container — can drive herdr. That is the same trust boundary as the Unix socket's file permissions, minus the file mode; acceptable on a single-user laptop, not on a shared or exposed machine.

## Container config

`~/.hermes/config.yaml` passes the endpoint in as env vars:

```yaml
terminal:
  docker_extra_args:
    - "-e"
    - "HERDR_HOST=host.docker.internal"
    - "-e"
    - "HERDR_PORT=9876"
```

There is deliberately **no** `-v .../herdr.sock` mount and no `HERDR_SOCKET_PATH`. Both were removed; re-adding them brings back the Errno 111 dead end. `make check` fails if either reappears. This file is the one piece `make install` does not write — Hermes owns it, so it is hand-edited; `make config` prints the snippet.

Container config changes take effect on the next container, and `container_persistent: false` with `lifetime_seconds: 300` means that happens within ~5 minutes. To force it: `docker rm -f $(docker ps -q --filter label=hermes-agent=1)`.

## Verify end to end

From the host:

```bash
printf '{"id":"t","method":"ping","params":{}}\n' | nc 127.0.0.1 9876
```

From inside the container:

```bash
python3 /root/.hermes/skills/autonomous-ai-agents/herdr/scripts/herdr_client.py health
```

Both should return a `pong` with the herdr version and protocol number.

## Failure modes

| Symptom | Meaning | Fix |
|---|---|---|
| `cannot reach herdr at host.docker.internal:9876` | Bridge not listening | `make restart` in `~/Workspace/hermes-herdr-bridge` on the host |
| Connects, then `herdr closed the connection` immediately | Bridge is up, herdr server is down — socat accepts TCP before it tries the Unix socket | User starts their herdr session; check `herdr status` on the host |
| `no response within Ns` | herdr is wedged or the call genuinely takes longer | Raise `HERDR_TIMEOUT`, or use `wait-agent`, which sizes its own socket timeout |
| Works from host `nc`, fails from container | Container has no host connectivity, or the runtime lacks `host.docker.internal` | `docker inspect <container>` for network/labels; add `--add-host=host.docker.internal:host-gateway`, or set `HERDR_HOST`. If it resolves but refuses, that runtime cannot see host loopback — `make install BIND=<addr>` |
| `ConnectionRefusedError: [Errno 111]` on `/run/herdr/herdr.sock` | Someone reintroduced the bind-mount | Remove it; use TCP |
