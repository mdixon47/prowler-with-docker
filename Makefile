.DEFAULT_GOAL := help
SHELL := /bin/bash

VERSION := $(shell cat .prowler-version 2>/dev/null || echo unpinned)

TF := terraform -chdir=terraform

.PHONY: help setup preflight secrets up down logs ps status open purge upgrade \
        tf-init tf-plan tf-apply tf-creds tf-secret tf-destroy tf-check \
        docs-check lint ci

help: ## Show this help
	@echo "Prowler local server — pinned to $(VERSION)"
	@echo
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-11s\033[0m %s\n", $$1, $$2}'

setup: ## Download docker-compose.yml + .env for the pinned release
	@./scripts/setup.sh

preflight: ## Check docker, ports, RAM and secrets before starting
	@./scripts/preflight.sh

secrets: ## Rotate the default AUTH_SECRET / encryption key in .env
	@./scripts/rotate-secrets.sh

up: preflight ## Start the stack in the background
	docker compose up -d
	@echo
	@echo "Starting. First run pulls ~several GB of images and the API runs"
	@echo "migrations — give it a few minutes, then: make status"

down: ## Stop the stack, keep all data
	@./scripts/teardown.sh

purge: ## Stop and DELETE all local data (irreversible)
	@./scripts/teardown.sh --purge

ps: ## Show container state
	docker compose ps

status: ## Check whether the UI and API are answering (single check, not a wait)
	@echo "API  http://localhost:8080/health/live"
	@curl -fsS -o /dev/null http://localhost:8080/api/v1/docs && echo "  API up" || echo "  API not ready yet"
	@curl -fsS -o /dev/null http://localhost:3000 && echo "  UI  up -> http://localhost:3000" || echo "  UI  not ready yet"

logs: ## Tail logs (make logs S=api to filter one service)
	docker compose logs -f --tail=100 $(S)

open: ## Open the Prowler UI in a browser
	@open http://localhost:3000

upgrade: ## Pin and download the latest Prowler release
	@./scripts/setup.sh latest
	@echo "Review .env.bak vs .env for any settings you had customized, then: make up"

# --- Terraform: the AWS-side IAM identity Prowler scans with ---------------

tf-init: ## Initialize the terraform working directory
	$(TF) init

tf-plan: ## Preview the IAM changes
	$(TF) plan

tf-apply: ## Create the IAM user/role in AWS
	$(TF) apply
	@echo
	@$(TF) output -raw next_steps; echo

tf-creds: ## Print the credentials to paste into the Prowler UI
	@echo "Account ID:    $$($(TF) output -raw aws_account_id)"
	@echo "Access key ID: $$($(TF) output -raw access_key_id 2>/dev/null || echo '(role mode — use the role ARN)')"
	@echo "Role ARN:      $$($(TF) output -raw role_arn 2>/dev/null || echo '(credentials mode)')"
	@echo
	@echo "Secret (not echoed above by design):"
	@echo "  make -s tf-secret"

tf-secret: ## Print ONLY the secret access key (careful — goes to your terminal)
	@$(TF) output -raw secret_access_key; echo

tf-destroy: ## Delete the IAM user/role and any access key
	$(TF) destroy
	@echo
	@echo "IAM side removed. The encrypted copy in Prowler's database survives"
	@echo "until 'make purge' — see docs/issue.md (SEC-3)."

tf-check: ## Validate and format-check the terraform config
	$(TF) fmt -check -recursive
	$(TF) validate

# --- Checks that mirror CI ------------------------------------------------

docs-check: ## Check markdown layout, links and anchors
	@python3 scripts/check-docs.py

lint: ## Syntax-check and shellcheck the shell scripts
	@for f in scripts/*.sh; do bash -n "$$f" || exit 1; done
	@echo "bash -n: ok"
	@command -v shellcheck >/dev/null \
		&& shellcheck --severity=warning scripts/*.sh && echo "shellcheck: ok" \
		|| echo "shellcheck: not installed, skipped (brew install shellcheck)"

ci: lint docs-check tf-check ## Run every check CI runs that works offline
	@command -v checkov >/dev/null \
		&& checkov -d terraform --compact --quiet \
		|| echo "checkov: not installed, skipped (pip install checkov)"
	@echo
	@echo "All local checks passed. CI additionally fetches the pinned release"
	@echo "and validates the compose file — see docs/ci.md."
