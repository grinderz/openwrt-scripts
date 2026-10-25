MAKEFLAGS += --warn-undefined-variables

.ONESHELL:
.SHELLFLAGS := -o errtrace -o pipefail -o noclobber -o errexit -o nounset -c
SHELL := bash

PRE_COMMIT_VERSION ?= 4.7.0
PRE_COMMIT ?= uvx pre-commit@$(PRE_COMMIT_VERSION)

# every script is POSIX sh (#!/bin/sh), so the dialect is forced
SHELL_SCRIPTS := $(wildcard *.sh tests/*.sh)
# the config examples are shell too; their variables are read by the
# scripts that source them, hence SC2034 (unused) is off for them
CONF_EXAMPLES := $(wildcard *.conf.example)

ARGS ?=


##@ General


.DEFAULT_GOAL := help
.PHONY: help
help: ## Display this help screen
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
		/^[a-zA-Z_0-9\-\\.%]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)


##@ Lint


.PHONY: lint
lint: lint.shellcheck lint.pre-commit ## Run all linters

.PHONY: lint.shellcheck
lint.shellcheck: ## Run shellcheck on every script and config example
	shellcheck --format=gcc -s sh $(SHELL_SCRIPTS)
	shellcheck --format=gcc -s sh -e SC2034 $(CONF_EXAMPLES)

.PHONY: lint.pre-commit
lint.pre-commit: ## Run the pre-commit hooks on every file
	$(PRE_COMMIT) run --all-files $(ARGS)


##@ Test


.PHONY: test
test: ## Dry-run smoke test of the scripts (no ssh, no device)
	tests/smoke.sh
