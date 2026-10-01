# Companion repository for "Hooking into the Go Toolchain".
# Every target that builds anything uses a fresh, repo-local GOCACHE under
# .cache/ (see scripts/lib.sh), never the user's cache.

SHELL := /bin/bash

GO ?= go
GO126 ?= $(HOME)/sdk/go1.26.8/bin/go
OTELC_VERSION := v1.1.0
SHELLCHECK ?= shellcheck
SHFMT ?= shfmt

GOFILES_DIRS := app cmd greet hooks other hello

CAPTURES ?= $(CURDIR)/captures
TOOLBIN ?= $(CURDIR)/.bin
CACHE_SUFFIX ?=
export GO CAPTURES TOOLBIN CACHE_SUFFIX

.DEFAULT_GOAL := help

# Several targets share .bin/ and captures/; never run them in parallel.
.NOTPARALLEL:

.PHONY: help tools otelc-install versions step0 step0-replay step1 step2 step3 step4-broken step4 \
	step5 step6-poison step6-fixed step7 stats check captures check-go126 clean

help: ## Show this help
	@awk -F':.*## ' -v go='$(GO)' -v ver='$(OTELC_VERSION)' \
		'/^[a-zA-Z0-9_-]+:.*## /{d=$$2; gsub(/\$$\(GO\)/, go, d); gsub(/\$$\(OTELC_VERSION\)/, ver, d); printf "  %-14s %s\n", $$1, d}' $(MAKEFILE_LIST)

tools: ## Build cmd/stopwatch and cmd/toyhook into .bin/
	@scripts/build-tools.sh

otelc-install: ## Install otelc $(OTELC_VERSION) into .bin/ (not into ~/go/bin)
	rm -rf .cache/otelc-install
	mkdir -p .cache/otelc-install
	GOBIN=$(CURDIR)/.bin GOCACHE=$(CURDIR)/.cache/otelc-install GOFLAGS= GOTOOLCHAIN=local \
		$(GO) install go.opentelemetry.io/otelc/tool/cmd/otelc@$(OTELC_VERSION)
	.bin/otelc version --verbose

versions: ## Record Go, otelc, uname and date in captures/versions.txt
	@scripts/versions.sh

step0: ## go build -a -toolexec=/usr/bin/time ./app
	@scripts/step0.sh

step0-replay: ## golang/go#27628: a plain build replays cached -toolexec stderr
	@scripts/step0-replay.sh

step1: ## go build -a -x -work ./app (log, importcfg, "# internal" lines)
	@scripts/step1.sh

step2: ## cmd/stopwatch: counts, slowest, -V=full, warm build, stdout bugs
	@scripts/step2.sh

step3: ## cmd/toyhook rewrites //demo:log functions
	@scripts/step3.sh

step4-broken: ## injected log/slog is missing from the importcfg: compile error
	@scripts/step4.sh broken

step4: ## toyhook patches the compile and link importcfg
	@scripts/step4.sh fixed

step5: ## //go:linkname from os.ReadFile to hooks.OnReadFile
	@scripts/step5.sh

step6-poison: ## build-cache poisoning: plain ./other picks up the rewritten greet
	@scripts/step6.sh poison

step6-fixed: ## toyhook marks the -V=full answer: ./other stays clean
	@scripts/step6.sh fixed

step7: ## otelc $(OTELC_VERSION) builds ./hello (needs make otelc-install)
	@scripts/step7.sh

stats: ## stopwatch vs otelc --stats on go build -a ./hello
	@scripts/stats.sh

check: ## gofmt, go vet, go test, go build, shellcheck, shfmt
	@command -v $(SHELLCHECK) >/dev/null || { echo "shellcheck not found: install it or set SHELLCHECK=/path"; exit 1; }
	@command -v $(SHFMT) >/dev/null || { echo "shfmt not found: install it or set SHFMT=/path"; exit 1; }
	@rm -rf .cache/check
	@test -z "$$(gofmt -l $(GOFILES_DIRS))" || { echo "gofmt needed:"; gofmt -l $(GOFILES_DIRS); exit 1; }
	GOCACHE=$(CURDIR)/.cache/check GOFLAGS= $(GO) vet ./...
	GOCACHE=$(CURDIR)/.cache/check GOFLAGS= $(GO) test ./...
	GOCACHE=$(CURDIR)/.cache/check GOFLAGS= $(GO) build ./...
	cd hello && GOCACHE=$(CURDIR)/.cache/check GOFLAGS= $(GO) vet ./...
	$(SHELLCHECK) -x -P SCRIPTDIR scripts/*.sh
	$(SHFMT) -i 2 -d scripts/*.sh

captures: tools otelc-install versions step0 step0-replay step1 step2 step3 step4-broken step4 step5 step6-poison step6-fixed step7 stats ## Regenerate captures/ with $(GO)

check-go126: ## step0-replay and steps 2-6 with Go 1.26.8; captures go to captures/go1.26/
	$(MAKE) GO=$(GO126) CAPTURES=$(CURDIR)/captures/go1.26 TOOLBIN=$(CURDIR)/.bin/go1.26 CACHE_SUFFIX=-go126 \
		versions step0-replay step2 step3 step4-broken step4 step5 step6-poison step6-fixed

clean: ## Remove .cache/ and .otelc-build/ (keeps .bin/ and captures/)
	rm -rf .cache hello/.otelc-build
