#!/usr/bin/env python3
"""Self-check for herdr_client framing + error handling. Run: python3 test_herdr_client.py"""
import socket
import threading

import herdr_client as hc


def serve(reply_chunks):
    """One-shot fake herdr on a loopback port; sends reply_chunks then closes."""
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)

    def run():
        conn, _ = srv.accept()
        conn.recv(65536)
        for chunk in reply_chunks:
            conn.sendall(chunk)
        conn.close()
        srv.close()

    threading.Thread(target=run, daemon=True).start()
    hc.HOST, hc.PORT = srv.getsockname()


def expect_error(fragment, chunks=None):
    if chunks is not None:
        serve(chunks)
    try:
        hc.call("ping")
    except hc.HerdrError as e:
        assert fragment in str(e), f"expected {fragment!r} in {e!r}"
        return
    raise AssertionError(f"expected HerdrError containing {fragment!r}")


# response split across reads must still parse (framing, not one recv)
serve([b'{"id":"1","result":{"type":', b'"pong","version":"0.7.5"}}\n'])
assert hc.call("ping") == {"type": "pong", "version": "0.7.5"}

# trailing bytes after the newline belong to nobody; first line wins
serve([b'{"id":"1","result":{"ok":true}}\nGARBAGE'])
assert hc.call("ping") == {"ok": True}

expect_error("agent_not_found", [b'{"id":"","error":{"code":"agent_not_found","message":"nope"}}\n'])
expect_error("malformed", [b'not json at all\n'])
expect_error("closed the connection", [b'{"id":"1","result":{}'])  # no newline, then EOF

hc.HOST, hc.PORT = "127.0.0.1", 1  # nothing listening
expect_error("cannot reach herdr")

# long waits must survive an idle cross-machine path
s = socket.socket()
hc._keepalive(s)
assert s.getsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE)  # macOS reports the flag bit, not 1
if hasattr(socket, "TCP_KEEPIDLE"):  # Linux; absent on macOS, must not raise
    assert s.getsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE) == 60
s.close()

print("ok")
