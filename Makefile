# Local Claude suite on Strix Halo.
#
# The serving contract runs on BARE METAL, where the GPU and the weights are.
# Everything else — every agent, every test — runs in a rootless podman
# container with no host filesystem mounted. See .necklace/*/cuj.md.

SHELL     := /usr/bin/env bash
CONTRACT  ?= http://127.0.0.1:8080
BATS      ?= bats
TESTS     ?= tests

.PHONY: help setup test test-isolation harness-up harness-down clean

help:                    ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  %-16s %s\n", $$1, $$2}'

setup:                   ## Install the user-level test tooling
	@command -v bats >/dev/null || npm i -g bats
	@command -v jq   >/dev/null || { echo "jq missing; apt install jq (needs root)" >&2; exit 1; }
	@command -v podman >/dev/null || { echo "podman missing" >&2; exit 1; }
	@echo "setup ok: bats $$(bats --version | awk '{print $$2}'), jq $$(jq --version), $$(podman --version)"

harness-up:              ## Start the containerised test harness
	@./harness/suite.sh up

harness-down:            ## Stop the containerised test harness
	@./harness/suite.sh down

test: harness-up         ## Run every test
	@shopt -s nullglob; files=($(TESTS)/*.bats); \
	if [ $${#files[@]} -eq 0 ]; then echo "0 tests"; exit 0; fi; \
	$(BATS) "$${files[@]}"

test-isolation: harness-up ## Run only the isolation boundary tests
	@$(BATS) $(TESTS)/09-isolation.bats

clean:                   ## Remove test volumes left behind by a failed run
	@podman volume ls -q --filter label=suite-test | xargs -r podman volume rm -f
