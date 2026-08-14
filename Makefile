# hermes-herdr-bridge — install/uninstall the socat bridge + Hermes herdr skill.
# Everything here is per-user; nothing needs sudo.

PORT          ?= 9876
# Loopback is enough for Docker Desktop and OrbStack: both reach a host
# 127.0.0.1 listener through host.docker.internal. Widening BIND hands herdr —
# full control of your local coding agents — to every device that can route
# here. Change it only for a runtime that provably cannot reach loopback.
BIND          ?= 127.0.0.1
LABEL         ?= local.herdr-socat
SOCKET        ?= $(HOME)/.config/herdr/herdr.sock
PLIST         ?= $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG           ?= $(HOME)/Library/Logs/herdr-socat.log
SKILL_DIR     ?= $(HOME)/.hermes/skills/autonomous-ai-agents/herdr
HERMES_CONFIG ?= $(HOME)/.hermes/config.yaml
CHECK_IMAGE   ?= python:3.11-alpine

SOCAT := $(shell command -v socat)
GUI   := gui/$(shell id -u)
PING  := {"id":"make","method":"ping","params":{}}

.PHONY: help install uninstall reinstall restart check test logs config

help:
	@echo "install    render + load the LaunchAgent, install the Hermes skill, verify"
	@echo "uninstall  unload + remove the LaunchAgent and the installed skill"
	@echo "restart    bounce the bridge (launchctl kickstart -k)"
	@echo "check      bridge state, bind scope, host + container reachability, Hermes config"
	@echo "test       run the herdr client self-check"
	@echo "logs       tail the socat log"
	@echo "config     print the ~/.hermes/config.yaml snippet this integration needs"
	@echo
	@echo "Vars: PORT BIND LABEL SOCKET PLIST LOG SKILL_DIR HERMES_CONFIG CHECK_IMAGE"
	@echo "BIND defaults to 127.0.0.1 — read the note in the Makefile before changing it."

install: test
ifeq ($(SOCAT),)
	@echo "socat not found. Run: brew install socat"; exit 1
endif
	@mkdir -p $(dir $(PLIST)) $(dir $(LOG)) $(SKILL_DIR)
	@sed -e 's|@LABEL@|$(LABEL)|g' -e 's|@SOCAT@|$(SOCAT)|g' -e 's|@PORT@|$(PORT)|g' \
	     -e 's|@BIND@|$(BIND)|g' -e 's|@SOCKET@|$(SOCKET)|g' -e 's|@LOG@|$(LOG)|g' \
	     launchd/local.herdr-socat.plist.in > $(PLIST)
	@launchctl bootout $(GUI)/$(LABEL) 2>/dev/null || true
	@launchctl bootstrap $(GUI) $(PLIST)
	@echo "installed $(PLIST)"
	@# copy, never symlink: Hermes bind-mounts ~/.hermes/skills into the container,
	@# where a symlink to $(CURDIR) would dangle.
	@rm -rf $(SKILL_DIR) && mkdir -p $(SKILL_DIR) && cp -R skill/. $(SKILL_DIR)/
	@echo "installed $(SKILL_DIR)"
	@sleep 1
	@$(MAKE) --no-print-directory check

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

check:
	@echo "== LaunchAgent"
	@launchctl print $(GUI)/$(LABEL) 2>/dev/null | grep -E '^\t(state|pid) =' \
	  || { echo "  NOT LOADED — run: make install"; exit 1; }
	@echo "== bind scope"
	@lsof -nP -iTCP:$(PORT) -sTCP:LISTEN | awk 'NR>1 {print "  " $$9}' \
	  || { echo "  nothing listening on $(PORT)"; exit 1; }
	@if ! lsof -nP -iTCP:$(PORT) -sTCP:LISTEN | grep -q '127.0.0.1:$(PORT)'; then \
	  echo "  !! NOT loopback-only (BIND=$(BIND))."; \
	  echo "  !! The bridge has no auth and herdr controls your local coding agents,"; \
	  echo "  !! so anything that can route here can drive them."; \
	fi
	@echo "== herdr, from the host"
	@printf '$(PING)\n' | nc 127.0.0.1 $(PORT) | head -c 120 | sed 's/^/  /'; echo
	@echo "== herdr, from a container (real client, real skills mount)"
	@if ! command -v docker >/dev/null; then echo "  skipped (no docker)"; \
	elif out=$$(docker run --rm -e HERDR_HOST=host.docker.internal -e HERDR_PORT=$(PORT) \
	    -v $(HOME)/.hermes/skills:/root/.hermes/skills:ro $(CHECK_IMAGE) \
	    python3 /root/.hermes/skills/autonomous-ai-agents/herdr/scripts/herdr_client.py health 2>&1); then \
	  echo "$$out" | cut -c1-120 | sed 's/^/  /'; \
	else \
	  echo "$$out" | cut -c1-160 | sed 's/^/  /'; \
	  echo "  This runtime cannot reach the bridge. Two knobs, in order:"; \
	  echo "    1. host.docker.internal missing? run containers with"; \
	  echo "       --add-host=host.docker.internal:host-gateway, or set HERDR_HOST to a reachable IP."; \
	  echo "    2. resolves but refuses? the VM cannot see host loopback — make install BIND=<addr>"; \
	  echo "       with the narrowest address that runtime can reach. Never 0.0.0.0 on an untrusted network."; \
	  exit 1; \
	fi
	@echo "== Hermes config"
	@grep -q 'HERDR_HOST=host.docker.internal' $(HERMES_CONFIG) \
	  && echo "  HERDR_HOST/HERDR_PORT present" \
	  || { echo "  MISSING — add the snippet from 'make config'"; exit 1; }
	@grep -q 'HERDR_SOCKET_PATH\|/run/herdr' $(HERMES_CONFIG) \
	  && { echo "  STALE socket bind-mount still present — remove it (see 'make config')"; exit 1; } \
	  || echo "  no stale socket mount"

logs:
	@tail -f $(LOG)

config:
	@echo "In $(HERMES_CONFIG), under terminal:, the container needs the endpoint"
	@echo "and must NOT bind-mount the herdr socket:"
	@echo
	@echo "  docker_extra_args:"
	@echo "    - \"-e\""
	@echo "    - \"HERDR_HOST=host.docker.internal\""
	@echo "    - \"-e\""
	@echo "    - \"HERDR_PORT=$(PORT)\""
	@echo
	@echo "Remove any '-v .../.config/herdr:/run/herdr' and HERDR_SOCKET_PATH entries:"
	@echo "a macOS Unix socket is unusable inside the Linux VM (Errno 111)."
