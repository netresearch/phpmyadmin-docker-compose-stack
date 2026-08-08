# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH

IMAGE      ?= ghcr.io/netresearch/phpmyadmin-php-fpm
TAG        ?= local
PMA_VERSION ?= $(shell cat .phpmyadmin-version)
PHP_VERSION ?= 8.4
COMPOSE    := docker compose

.PHONY: help build build-rolling up up-standalone down logs shell lint test scan clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Build the pinned image
	docker build -t $(IMAGE):$(TAG) \
		--build-arg PHP_VERSION=$(PHP_VERSION) \
		--build-arg PMA_VERSION=$(PMA_VERSION) .

build-rolling: ## Build with refreshed PHP libraries
	docker build -t $(IMAGE):$(TAG)-rolling \
		--build-arg PHP_VERSION=$(PHP_VERSION) \
		--build-arg PMA_VERSION=$(PMA_VERSION) \
		--build-arg ROLLING_DEPS=true .

up: ## Start app + web against an existing database (set PMA_HOST)
	$(COMPOSE) up -d app-assets app web

up-standalone: ## Start everything including a demo MariaDB
	$(COMPOSE) --profile standalone up -d --wait

down: ## Stop the stack
	$(COMPOSE) --profile standalone down

logs: ## Follow the logs
	$(COMPOSE) logs -f

shell: ## Shell in the app container
	$(COMPOSE) exec app bash

lint: ## hadolint + compose validation + shellcheck
	docker run --rm -i hadolint/hadolint hadolint --config - - < .hadolint.yaml < Dockerfile || \
		docker run --rm -v $(PWD):/w -w /w hadolint/hadolint hadolint Dockerfile
	$(COMPOSE) config -q
	docker run --rm -v $(PWD):/w -w /w koalaman/shellcheck:stable rootfs/usr/local/bin/entrypoint.sh

test: build ## Build, then run the container-structure tests
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
		-v $(PWD)/tests:/tests \
		gcr.io/gcp-runtimes/container-structure-test:latest \
		test --image $(IMAGE):$(TAG) --config /tests/container-structure-test.yaml

scan: build ## Scan the built image for known vulnerabilities
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
		aquasec/trivy:latest image --scanners vuln --ignore-unfixed $(IMAGE):$(TAG)

clean: ## Remove the stack including its volumes
	$(COMPOSE) --profile standalone down -v
