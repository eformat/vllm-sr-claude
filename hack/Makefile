# Image URL for building/pushing
REGISTRY ?= quay.io
REPOSITORY ?= $(REGISTRY)/eformat/vllm-sr
IMG := $(REPOSITORY):latest

C2O_REPOSITORY ?= $(REGISTRY)/eformat/c2o
C2O_IMG := $(C2O_REPOSITORY):latest

PODMAN_ARGS ?=

# --- vllm-sr Build ---

podman-build:
	podman build $(PODMAN_ARGS) . -t $(IMG) -f Containerfile

# --- c2o Build ---

c2o-build:
	podman build $(PODMAN_ARGS) -t $(C2O_IMG) -f Containerfile.c2o ..

c2o-push:
	podman push $(C2O_IMG)

c2o: c2o-build c2o-push

# --- Push ---

podman-login:
	@podman login -u $(DOCKER_USER) -p $(DOCKER_PASSWORD) $(REGISTRY)

podman-push:
	podman push $(IMG)

# --- All-in-one ---

all: podman-build podman-push

.PHONY: podman-build podman-login podman-push all c2o-build c2o-push c2o
