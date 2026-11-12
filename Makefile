# Makefile: local developer shortcuts.
# Release and CI automation (certs, TestFlight, App Store) live in fastlane/Fastfile.

# The pipefail wiring below relies on .SHELLFLAGS, which GNU Make honors only at 3.82+. Stock
# macOS /usr/bin/make is 3.81 and ignores .SHELLFLAGS silently, which would let a failed
# xcodebuild exit through xcsift's 0 status undetected. Refuse to run on such a make rather than
# build without the guard; install a newer make (Homebrew `make`) and put it ahead on PATH.
MIN_MAKE_VERSION := 3.82
ifneq ($(MIN_MAKE_VERSION),$(firstword $(sort $(MAKE_VERSION) $(MIN_MAKE_VERSION))))
$(error GNU Make $(MIN_MAKE_VERSION)+ required for pipefail support; found $(MAKE_VERSION). Install a newer make, e.g. Homebrew make)
endif

# `pipefail` makes a `cmd | xcsift` recipe exit with xcodebuild's status, not xcsift's, so a
# failed build/test isn't masked when xcsift's summary exits 0. Requires bash, not /bin/sh.
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

SCHEME  := Cairn
PROJECT := Cairn.xcodeproj

# The full app suite runs on the project-standard iOS 27 simulator. Override SIM to retarget.
SIM ?= platform=iOS Simulator,name=iPhone 17e,OS=27.0

# Concurrent `xcodebuild test` runs against the same simulator fight over its single
# test-manager connection and hang ("test runner hung before establishing connection"), the
# usual cause of a stuck run when several agent/worktree sessions share one Mac. SIM_LOCK takes
# a per-simulator host lock so same-sim runs serialize while runs on different sims still
# proceed in parallel. The lock is an atomic O_EXCL create (shell noclobber); if the holding
# process is gone (killed run) the stale lock is reclaimed after `ps -p` confirms it is dead,
# and it is released on exit. Skipped under $CI; runners are single-tenant. macOS `shlock` is
# deliberately avoided here: it does not reclaim a dead-owner lock, so a SIGKILLed run would
# wedge every later run. The calling recipe sets `dest` first.
SIM_LOCK = if [ -z "$$CI" ]; then \
		lock="/tmp/cairn-xcodebuild-$$(printf '%s' "$$dest" | tr -c 'A-Za-z0-9' '-').lock"; \
		waited=0; \
		while :; do \
			if ( set -C; echo $$$$ > "$$lock" ) 2>/dev/null; then break; fi; \
			owner=$$(cat "$$lock" 2>/dev/null); \
			if [ -z "$$owner" ] || ! ps -p "$$owner" >/dev/null 2>&1; then rm -f "$$lock"; continue; fi; \
			echo "==> waiting for simulator lock ($$dest), held by pid $$owner, $${waited}s elapsed"; sleep 2; \
			waited=$$((waited + 2)); \
		done; \
		trap 'rm -f "$$lock"' EXIT INT TERM HUP; \
	fi

# Heartbeat runs in the pipe consumer so its trap cannot replace SIM_LOCK's
# lock-release trap. Kill it after xcsift; macOS bash skips pipeline exit traps.
XCODEBUILD_HEARTBEAT_SEC ?= 30
XCSIFT_WITH_HEARTBEAT = { \
		echo "==> xcodebuild test ($$dest); xcsift summary at EOF" >&2; \
		SECONDS=0; \
		( while sleep $(XCODEBUILD_HEARTBEAT_SEC); do echo "==> still running $${SECONDS}s" >&2; done ) & \
		hb=$$!; \
		trap 'kill $$hb 2>/dev/null || true' EXIT; \
		xcsift -f toon; \
		sift=$$?; \
		kill $$hb 2>/dev/null || true; \
		wait $$hb 2>/dev/null || true; \
		exit $$sift; \
	}

.DEFAULT_GOAL := help
.PHONY: help generate generate-mac test test-app

help: ## List available targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

define DEV_YML_STUB
settings:
  base:
    DEVELOPMENT_TEAM: ""
endef
export DEV_YML_STUB

dev.yml:
	@echo "dev.yml not found, creating empty stub (set DEVELOPMENT_TEAM for local signing)"
	@echo "$$DEV_YML_STUB" > dev.yml

generate: dev.yml ## Regenerate Cairn.xcodeproj from project.yml (xcodegen)
	xcodegen generate

generate-mac: ## Regenerate CairnMac.xcodeproj (the Designed-for-iPad Mac build) from mac.local.yml
	xcodegen generate --spec mac.local.yml

test: test-app ## Run everything: the full app suite (iOS 27)

# Skip sysdiagnose collection. xcodebuild can spawn simctl diagnose after the
# suite and block the recipe for minutes even when every test passed.
test-app: generate ## Run the full app suite on iOS 27
	@dest='$(SIM)'; $(SIM_LOCK); \
		xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-destination "$$dest" \
		-collect-test-diagnostics never \
		2>&1 | $(XCSIFT_WITH_HEARTBEAT)
