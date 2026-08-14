#!/bin/sh
# Gate on the exposure this bridge creates. Exit 0 only if every mitigation this
# machine can actually verify is in place. Run by `make security-check`, and by
# `make install-tailnet`, which tears the bridge back down if this fails.
#
# What it cannot verify is stated as a NOTE rather than passed over in silence:
# a Tailscale ACL lives on the coordination server, not here. That is exactly why
# the enforced allowlist is socat's own range= — it does not depend on the ACL
# being right, and this script asserts it is present in the loaded LaunchAgent.
set -u

: "${PORT:?}" "${BIND:?}" "${PLIST:?}"
PEER="${PEER:-}"
TS="${TS:-tailscale}"

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
note() { printf '  note  %s\n' "$1"; }

listener=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}')
[ -n "$listener" ] || bad "nothing is listening on port $PORT"

case "$listener" in
  *"*:$PORT"*)
    bad "listening on ALL interfaces ($listener) — every network this machine"
    printf '        touches can drive your coding agents. Reinstall with a narrower BIND.\n'
    ;;
esac

if [ "$BIND" = "127.0.0.1" ]; then
  echo "mode: loopback (herdr and Hermes on one machine)"
  case "$listener" in
    *"127.0.0.1:$PORT"*) ok "listener is loopback-only: $listener" ;;
    *) bad "BIND=127.0.0.1 but the listener is $listener — stale install? run: make install" ;;
  esac
  [ -z "$PEER" ] || note "PEER=$PEER is ignored in loopback mode"
  echo
  [ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL"
  exit $fail
fi

echo "mode: tailnet (herdr and Hermes on different machines)"

# 1. Tailscale must actually be up. Without it, BIND is just a routable address.
if ! command -v "$TS" >/dev/null 2>&1 && [ ! -x "$TS" ]; then
  bad "tailscale CLI not found at '$TS' — cannot verify any of this. Set TS=<path>."
else
  state=$("$TS" status --json 2>/dev/null | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null)
  case "$state" in
    Running) ok "tailscaled is running" ;;
    "")      bad "cannot read tailscale status — is the daemon running?" ;;
    *)       bad "tailscaled state is '$state', not Running" ;;
  esac

  # 2. BIND must be an address Tailscale itself assigned to this node. This is
  #    what makes the listener reachable only over WireGuard.
  if "$TS" ip -4 2>/dev/null | grep -qx "$BIND"; then
    ok "BIND=$BIND is this node's tailnet address"
  else
    bad "BIND=$BIND is not a tailnet address of this node ($("$TS" ip -4 2>/dev/null | tr '\n' ' '))"
  fi

  # 3. Funnel publishes to the public internet. Never for this.
  if fs=$("$TS" funnel status 2>&1); then
    if printf '%s' "$fs" | grep -q "$PORT"; then
      bad "Tailscale Funnel config mentions port $PORT — this may be published"
      printf '        to the public internet. Run: %s funnel reset\n' "$TS"
    else
      ok "no Funnel configuration on port $PORT"
    fi
  else
    bad "cannot read funnel status ('$TS funnel status' failed) — verify by hand before trusting this"
  fi
fi

case "$BIND" in
  0.0.0.0|::|"*") bad "BIND=$BIND exposes the bridge on every interface" ;;
esac

# 4. Source allowlist, enforced by socat regardless of what the ACL says.
if [ -z "$PEER" ]; then
  bad "PEER is empty — the bridge accepts any source that can route to $BIND"
else
  peer_status=$(python3 - "$PEER" <<'PY' 2>/dev/null
import ipaddress, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    print("MALFORMED"); raise SystemExit(0)
if not net.subnet_of(ipaddress.ip_network("100.64.0.0/10")):
    print("OUTSIDE"); raise SystemExit(0)
print("OK" if net.prefixlen == 32 else "WIDE %d" % net.prefixlen)
PY
)
  case "$peer_status" in
    OK)        ok "PEER=$PEER is a single tailnet host" ;;
    WIDE*)     ok "PEER=$PEER is a tailnet range"
               note "a /32 is one machine; ${PEER#*/} lets any tailnet host in that range in" ;;
    OUTSIDE)   bad "PEER=$PEER is outside the tailnet range 100.64.0.0/10" ;;
    MALFORMED) bad "PEER=$PEER is not a valid address or CIDR" ;;
    *)         bad "could not validate PEER=$PEER" ;;
  esac
fi

# 5. The mitigations must be in the LaunchAgent that is actually loaded, not just
#    in the variables passed to this script.
if [ -f "$PLIST" ]; then
  grep -q "bind=$BIND," "$PLIST" && ok "loaded LaunchAgent binds $BIND" \
    || bad "$PLIST does not bind $BIND — reinstall"
  if [ -n "$PEER" ]; then
    grep -q "range=$PEER" "$PLIST" && ok "loaded LaunchAgent enforces range=$PEER" \
      || bad "$PLIST has no range= allowlist — reinstall with make install-tailnet"
  fi
else
  bad "$PLIST is missing"
fi

case "$listener" in
  *"$BIND:$PORT"*) ok "live listener matches: $listener" ;;
  *)               bad "live listener is $listener, expected $BIND:$PORT — run: make restart" ;;
esac

note "not verifiable from this machine: your Tailscale ACL. Restrict tcp:$PORT to the"
printf '        Hermes node, e.g.\n'
printf '          {"grants": [{"src": ["tag:hermes"], "dst": ["tag:herdr"], "ip": ["tcp:%s"]}]}\n' "$PORT"
note "the bridge has no auth of its own: reaching it means running prompts in your"
printf '        coding agents, which is code execution on this machine.\n'

echo
if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAIL"; fi
exit $fail
