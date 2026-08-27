# vdownloader orchestration — task runner across the three service repos.
# CI in each service repo should call `go`/`golangci-lint` directly; this
# Makefile is for local, all-at-once checks and for driving docker compose.
#
# Assumes the three service repos are checked out as subdirectories of this
# one (same layout docker-compose.yml expects: build: ./vdownloader_worker).

MODULES := vdownloader_worker vdownloader_telegram vdownloader_web

.PHONY: all fmt-check vet lint test build tidy-check docker smoke clean help

## help: list targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'

## all: fmt-check + vet + test + build
all: fmt-check vet test build

## fmt-check: fail if any Go file is not gofmt-formatted
fmt-check:
	@for m in $(MODULES); do \
		out=$$(cd $$m && gofmt -l .); \
		if [ -n "$$out" ]; then echo "gofmt needed in $$m:"; echo "$$out"; exit 1; fi; \
	done
	@echo "gofmt: clean"

## vet: go vet all modules
vet:
	@for m in $(MODULES); do echo "== vet $$m =="; (cd $$m && go vet ./...) || exit 1; done

## lint: golangci-lint all modules (install: https://golangci-lint.run)
lint:
	@for m in $(MODULES); do echo "== lint $$m =="; (cd $$m && golangci-lint run ./...) || exit 1; done

## test: go test all modules
test:
	@for m in $(MODULES); do echo "== test $$m =="; (cd $$m && go test ./...) || exit 1; done

## build: compile all modules
build:
	@for m in $(MODULES); do echo "== build $$m =="; (cd $$m && go build ./...) || exit 1; done

## tidy-check: fail if any go.mod / go.sum is not tidy
tidy-check:
	@for m in $(MODULES); do \
		echo "== tidy-check $$m =="; \
		(cd $$m && go mod tidy && git diff --exit-code -- go.mod go.sum) \
			|| { echo "go.mod/go.sum not tidy in $$m"; exit 1; }; \
	done

## docker: build all three service images via compose
docker:
	docker compose build

## smoke: run the end-to-end smoke test against an already-running stack
smoke:
	./scripts/smoke-test.sh

## clean: remove built binaries from each module
clean:
	rm -f vdownloader_worker/downloader vdownloader_telegram/telegram_service vdownloader_web/webui
