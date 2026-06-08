BINARY ?= flux-snapshot
IMG    ?= flux-snapshot:latest

.PHONY: all build test lint fmt vet docker-build

all: build

build:
	go build -o bin/$(BINARY) ./cmd/manager

test:
	go test ./... -count=1

test-e2e:
	bash test/e2e/run_all.sh

cover:
	go test ./... -count=1 -coverprofile=coverage.out && go tool cover -func=coverage.out

lint:
	golangci-lint run ./...

fmt:
	go fmt ./...

vet:
	go vet ./...

docker-build:
	docker build -t $(IMG) .
