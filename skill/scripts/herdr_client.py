#!/usr/bin/env python3
"""Minimal herdr Socket API client.

Talks newline-delimited JSON to the herdr daemon over the host socat bridge
(container -> host.docker.internal:9876 -> ~/.config/herdr/herdr.sock).

Usable as a library (`from herdr_client import call, list_agents`) or a CLI:

    python3 herdr_client.py health
    python3 herdr_client.py list-agents
    python3 herdr_client.py prompt-agent wD:p1 "run the tests"
    python3 herdr_client.py wait-agent wD:p1 --timeout 590000

Every command prints one JSON object. Exit 0 = herdr answered, 1 = it did not
(unreachable, timed out, malformed reply, or returned a protocol error).

Config via env: HERDR_HOST (default host.docker.internal), HERDR_PORT (9876),
HERDR_TIMEOUT (seconds, default 15).
"""
import argparse
import json
import os
import socket
import sys

HOST = os.environ.get("HERDR_HOST", "host.docker.internal")
PORT = int(os.environ.get("HERDR_PORT", "9876"))
TIMEOUT = float(os.environ.get("HERDR_TIMEOUT", "15"))
DONE_STATES = ["idle", "done", "blocked"]


class HerdrError(RuntimeError):
    """herdr was unreachable, slow, incoherent, or refused the request."""


def _keepalive(conn):
    """Keep a long wait alive across a NAT or tailnet relay.

    wait-agent holds one connection for up to 10 minutes with no bytes flowing,
    which idle timeouts on a cross-machine path will happily reap. macOS socat
    can't set the interval (no keepidle option there), so the client does it —
    and the client runs on Linux, where these sockopts exist. Absent ones are
    skipped rather than raising, so this is a no-op on platforms without them.
    """
    conn.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    for name, value in (("TCP_KEEPIDLE", 60), ("TCP_KEEPINTVL", 10), ("TCP_KEEPCNT", 5)):
        opt = getattr(socket, name, None)
        if opt is not None:
            conn.setsockopt(socket.IPPROTO_TCP, opt, value)


def call(method, params=None, timeout=None):
    """Send one request, return its `result`. Raises HerdrError on any failure."""
    timeout = TIMEOUT if timeout is None else timeout
    try:
        conn = socket.create_connection((HOST, PORT), timeout=timeout)
    except OSError as e:
        raise HerdrError(
            f"cannot reach herdr at {HOST}:{PORT} ({e}) - is the socat bridge "
            f"running on the host? (launchctl list local.herdr-socat)"
        )
    try:
        conn.settimeout(timeout)
        _keepalive(conn)
        req = {"id": "1", "method": method, "params": params or {}}
        conn.sendall((json.dumps(req) + "\n").encode())
        buf = bytearray()
        while b"\n" not in buf:  # responses are newline-delimited, one per request
            try:
                chunk = conn.recv(65536)
            except socket.timeout:
                raise HerdrError(f"{method}: no response within {timeout}s")
            if not chunk:
                raise HerdrError(
                    f"{method}: herdr closed the connection"
                    + (f" after {len(buf)} partial bytes" if buf else "")
                )
            buf += chunk
    finally:
        conn.close()

    line = bytes(buf).split(b"\n", 1)[0]
    try:
        resp = json.loads(line)
    except ValueError:
        raise HerdrError(f"{method}: malformed response {line[:200]!r}")
    if "error" in resp:
        err = resp["error"] or {}
        raise HerdrError(f"{err.get('code', 'error')}: {err.get('message', '')}")
    return resp.get("result", {})


def health():
    """Is herdr reachable? Cheap, side-effect free."""
    return call("ping", timeout=5)


def list_agents(workspace_id=None):
    return call("agent.list", {"workspace_id": workspace_id} if workspace_id else {})


def get_agent(target):
    return call("agent.get", {"target": target})


def prompt_agent(target, text):
    return call("agent.prompt", {"target": target, "text": text})


def wait_agent(target, until=None, timeout_ms=590000):
    return call(
        "agent.wait",
        {"target": target, "until": until or DONE_STATES, "timeout": timeout_ms},
        timeout=timeout_ms / 1000.0 + 10,  # socket must outlive herdr's own wait
    )


def read_pane(target, source="recent"):
    return call("agent.read", {"target": target, "source": source})


def send_input(pane_id, text):
    """Type text into a pane without submitting. Use prompt_agent to submit."""
    return call("pane.send_text", {"pane_id": pane_id, "text": text})


def send_keys(pane_id, keys):
    """Named keys, e.g. ['ctrl+u', 'ctrl+a', 'ctrl+k'] to clear a stuck input buffer."""
    return call("pane.send_keys", {"pane_id": pane_id, "keys": keys})


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("health")
    s = sub.add_parser("list-agents"); s.add_argument("--workspace")
    s = sub.add_parser("get-agent"); s.add_argument("target")
    s = sub.add_parser("prompt-agent"); s.add_argument("target"); s.add_argument("text")
    s = sub.add_parser("wait-agent")
    s.add_argument("target")
    s.add_argument("--timeout", type=int, default=590000, help="milliseconds")
    s.add_argument("--until", help="comma-separated states (default idle,done,blocked)")
    s = sub.add_parser("read-pane")
    s.add_argument("target")
    s.add_argument("--source", default="recent",
                   choices=["visible", "recent", "recent_unwrapped", "detection"])
    s = sub.add_parser("send-input"); s.add_argument("pane_id"); s.add_argument("text")
    s = sub.add_parser("send-keys"); s.add_argument("pane_id"); s.add_argument("keys", nargs="+")

    a = p.parse_args(argv)
    try:
        if a.cmd == "health":
            out = health()
        elif a.cmd == "list-agents":
            out = list_agents(a.workspace)
        elif a.cmd == "get-agent":
            out = get_agent(a.target)
        elif a.cmd == "prompt-agent":
            out = prompt_agent(a.target, a.text)
        elif a.cmd == "wait-agent":
            out = wait_agent(a.target, a.until.split(",") if a.until else None, a.timeout)
        elif a.cmd == "read-pane":
            out = read_pane(a.target, a.source)
        elif a.cmd == "send-input":
            out = send_input(a.pane_id, a.text)
        elif a.cmd == "send-keys":
            out = send_keys(a.pane_id, a.keys)
    except HerdrError as e:
        json.dump({"ok": False, "error": str(e)}, sys.stdout)
        print()
        return 1
    json.dump({"ok": True, "result": out}, sys.stdout)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
