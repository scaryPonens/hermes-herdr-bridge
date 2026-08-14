# hermes-herdr-bridge — install/uninstall the socat bridge + Hermes herdr skill.
# Everything here is per-user; nothing needs sudo.
#
# Two installs:
#   make install                              herdr and Hermes on one machine (loopback)
#   make install-tailnet PEER=100.x.y.z/32    herdr and Hermes on two, joined by Tailscale
#
# The tailnet install refuses to leave a bridge running that fails `security-check`.

PORT          ?= 9876
# Loopback is enough for Docker Desktop and OrbStack: both reach a host
# 127.0.0.1 listener through host.docker.internal. Widening BIND hands herdr —
# full control of your local coding agents — to every device that can route
# here. install-tailnet sets it to this node's tailnet address; do not set it
# by hand to anything broader.
BIND          ?= 127.0.0.1
# Source allowlist enforced by socat itself (range=). Required by install-tailnet.
# Independent of your Tailscale ACL on purpose: two locks, different keys.
PEER          ?=
LISTEN_OPTS   ?=
LABEL         ?= local.herdr-socat
SOCKET        ?= $(HOME)/.config/herdr/herdr.sock
PLIST         ?= $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG           ?= $(HOME)/Library/Logs/herdr-socat.log
SKILL_DIR     ?= $(HOME)/.hermes/skills/autonomous-ai-agents/herdr
HERMES_CONFIG ?= $(HOME)/.hermes/config.yaml
CHECK_IMAGE   ?= python:3.11-alpine
# What the Hermes container dials. host.docker.internal on one machine; the
# herdr node's tailnet IP on two.
HERDR_HOST    ?= host.docker.internal
POST_CHECK    ?= check

SOCAT      := $(shell command -v socat)
TS         := $(shell command -v tailscale 2>/dev/null || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)
TAILNET_IP := $(shell $(TS) ip -4 2>/dev/null | head -1)
GUI        := gui/$(shell id -u)
PING       := {"id":"make","method":"ping","params":{}}

.PHONY: help install install-tailnet uninstall reinstall restart \
        check check-server check-client security-check test logs config

help:
	@echo "install          herdr + Hermes on one machine: loopback bridge, skill, verify"
	@echo "install-tailnet  herdr + Hermes on two machines over Tailscale (PEER=... required)"
	@echo "uninstall        unload + remove the LaunchAgent and the installed skill"
	@echo "restart          bounce the bridge (launchctl kickstart -k)"
	@echo "check            check-server + check-client"
	@echo "check-server     LaunchAgent state, bind scope, herdr reachable from this host"
	@echo "check-client     Hermes config + a real container reaching HERDR_HOST"
	@echo "security-check   assert the exposure this bridge creates is contained"
	@echo "test             run the herdr client self-check"
	@echo "logs             tail the socat log"
	@echo "config           print the ~/.hermes/config.yaml snippet this integration needs"
	@echo
	@echo "Vars: PORT BIND PEER HERDR_HOST LABEL SOCKET PLIST LOG SKILL_DIR"
	@echo "      HERMES_CONFIG CHECK_IMAGE"
	@echo "BIND defaults to 127.0.0.1 — read the note in the Makefile before changing it."

install: test
ifeq ($(SOCAT),)
	@echo "socat not found. Run: brew install socat"; exit 1
endif
	@mkdir -p $(dir $(PLIST)) $(dir $(LOG)) $(SKILL_DIR)
	@sed -e 's|@LABEL@|$(LABEL)|g' -e 's|@SOCAT@|$(SOCAT)|g' -e 's|@PORT@|$(PORT)|g' \
	     -e 's|@BIND@|$(BIND)|g' -e 's|@OPTS@|$(LISTEN_OPTS)|g' \
	     -e 's|@SOCKET@|$(SOCKET)|g' -e 's|@LOG@|$(LOG)|g' \
	     launchd/local.herdr-socat.plist.in > $(PLIST)
	@launchctl bootout $(GUI)/$(LABEL) 2>/dev/null || true
	@launchctl bootstrap $(GUI) $(PLIST)
	@echo "installed $(PLIST)"
	@# copy, never symlink: Hermes bind-mounts ~/.hermes/skills into the container,
	@# where a symlink to $(CURDIR) would dangle.
	@rm -rf $(SKILL_DIR) && mkdir -p $(SKILL_DIR) && cp -R skill/. $(SKILL_DIR)/
	@echo "installed $(SKILL_DIR)"
	@sleep 1
	@$(MAKE) --no-print-directory $(POST_CHECK)

# Exposes the bridge on this node's tailnet address, with socat's own source
# allowlist in front of it. Installs nothing that security-check won't pass:
# on failure the bridge comes back out rather than sitting there exposed.
install-tailnet:
	@[ -n "$(PEER)" ] || { \
	  echo "PEER is required — the tailnet address allowed to reach this bridge:"; \
	  echo "    make install-tailnet PEER=100.101.102.103/32"; \
	  echo "Find it with 'tailscale status' on this machine."; exit 1; }
	@[ -n "$(TAILNET_IP)" ] || { \
	  echo "This machine has no tailnet address. Is tailscaled running and logged in?"; \
	  echo "    $(TS) status"; exit 1; }
	@echo "Binding to $(TAILNET_IP), allowing $(PEER) only."
	@$(MAKE) --no-print-directory install \
	    BIND=$(TAILNET_IP) LISTEN_OPTS=',keepalive,range=$(PEER)' POST_CHECK=check-server
	@$(MAKE) --no-print-directory security-check BIND=$(TAILNET_IP) PEER=$(PEER) || { \
	  echo; \
	  echo "SECURITY CHECK FAILED — removing the bridge rather than leaving it exposed."; \
	  $(MAKE) --no-print-directory uninstall; exit 1; }
	@echo
	@echo "Now, on the Hermes machine:  make check-client HERDR_HOST=$(TAILNET_IP)"
	@echo "Note: this replaces the loopback listener. A Hermes container on THIS machine"
	@echo "no longer reaches the bridge — see 'serving both at once' in the README."

uninstall:
	@launchctl bootout $(GUI)/$(LABEL) 2>/dev/null || true
	@rm -f $(PLIST) && echo "removed $(PLIST)"
	@rm -rf $(SKILL_DIR) && echo "removed $(SKILL_DIR)"
	@echo
	@echo "Left alone: $(HERMES_CONFIG) (hand-edited, see 'make config') and $(LOG)."

reinstall: uninstall install

restart:
	@launchctl kickstart -k $(GUI)/$(LABEL) && echo "bounced $(LABEL)"

test:
	@cd skill/scripts && python3 test_herdr_client.py

check: check-server check-client

check-server:
	@echo "== LaunchAgent"
	@launchctl print $(GUI)/$(LABEL) 2>/dev/null | grep -E '^\t(state|pid) =' \
	  || { echo "  NOT LOADED — run: make install"; exit 1; }
	@echo "== bind scope"
	@lsof -nP -iTCP:$(PORT) -sTCP:LISTEN | awk 'NR>1 {print "  " $$9}' \
	  || { echo "  nothing listening on $(PORT)"; exit 1; }
	@if ! lsof -nP -iTCP:$(PORT) -sTCP:LISTEN | grep -q '127.0.0.1:$(PORT)'; then \
	  echo "  not loopback-only — run 'make security-check' to confirm it is contained"; \
	fi
	@echo "== herdr, from this host"
	@printf '$(PING)\n' | nc $(BIND) $(PORT) | head -c 120 | sed 's/^/  /'; echo

check-client:
	@echo "== Hermes config"
	@grep -q 'HERDR_HOST=$(HERDR_HOST)' $(HERMES_CONFIG) \
	  && echo "  HERDR_HOST=$(HERDR_HOST) present" \
	  || { echo "  MISSING — add the snippet from 'make config'"; exit 1; }
	@grep -q 'HERDR_SOCKET_PATH\|/run/herdr' $(HERMES_CONFIG) \
	  && { echo "  STALE socket bind-mount still present — remove it (see 'make config')"; exit 1; } \
	  || echo "  no stale socket mount"
	@echo "== herdr, from a container (real client, real skills mount)"
	@if ! command -v docker >/dev/null; then echo "  skipped (no docker)"; \
	elif out=$$(docker run --rm -e HERDR_HOST=$(HERDR_HOST) -e HERDR_PORT=$(PORT) \
	    -v $(HOME)/.hermes/skills:/root/.hermes/skills:ro $(CHECK_IMAGE) \
	    python3 /root/.hermes/skills/autonomous-ai-agents/herdr/scripts/herdr_client.py health 2>&1); then \
	  echo "$$out" | cut -c1-120 | sed 's/^/  /'; \
	else \
	  echo "$$out" | cut -c1-160 | sed 's/^/  /'; \
	  echo "  This runtime cannot reach the bridge. Knobs, in order:"; \
	  echo "    1. host.docker.internal missing? run containers with"; \
	  echo "       --add-host=host.docker.internal:host-gateway, or set HERDR_HOST to a reachable IP."; \
	  echo "    2. resolves but refuses? the VM cannot see host loopback — make install BIND=<addr>"; \
	  echo "       with the narrowest address that runtime can reach. Never 0.0.0.0."; \
	  echo "    3. across a tailnet? confirm PEER on the herdr machine allows this node,"; \
	  echo "       and that your Tailscale ACL permits tcp:$(PORT)."; \
	  exit 1; \
	fi

security-check:
	@PORT=$(PORT) BIND=$(BIND) PEER=$(PEER) PLIST=$(PLIST) TS=$(TS) \
	  sh bin/security-check.sh

logs:
	@tail -f $(LOG)

config:
	@echo "In $(HERMES_CONFIG), under terminal:, the container needs the endpoint"
	@echo "and must NOT bind-mount the herdr socket:"
	@echo
	@echo "  docker_extra_args:"
	@echo "    - \"-e\""
	@echo "    - \"HERDR_HOST=$(HERDR_HOST)\""
	@echo "    - \"-e\""
	@echo "    - \"HERDR_PORT=$(PORT)\""
	@echo
	@echo "Remove any '-v .../.config/herdr:/run/herdr' and HERDR_SOCKET_PATH entries:"
	@echo "a macOS Unix socket is unusable inside the Linux VM (Errno 111)."
