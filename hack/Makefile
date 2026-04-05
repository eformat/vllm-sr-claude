# Image URL for building/pushing
REGISTRY ?= quay.io
REPOSITORY ?= $(REGISTRY)/eformat/vllm-sr
IMG := $(REPOSITORY):latest

PODMAN_ARGS ?=

# --- Build ---

podman-build:
	podman build $(PODMAN_ARGS) . -t $(IMG) -f Containerfile

# --- Push ---

podman-login:
	@podman login -u $(DOCKER_USER) -p $(DOCKER_PASSWORD) $(REGISTRY)

podman-push:
	podman push $(IMG)

# --- All-in-one ---

all: podman-build podman-push

.PHONY: podman-build podman-login podman-push all
