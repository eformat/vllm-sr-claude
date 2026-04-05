# hack/

Local development and testing utilities.

```bash
python3.12 -m venv venv
source venv/bin/activate
# On CUDA
uv pip install vllm==0.19.0 --torch-backend=auto
uv pip install vllm-sr
```

## vllm-sr-cli-fixes.patch

Patch for local vllm-sr CLI fixes:

- Fixes network attachment for rootless podman
- Fixes config merging for Go router compatibility
- Adds TOKEN to passthrough env vars

Apply with:
```bash
cd $(python3 -c "import vllm_sr; print(vllm_sr.__path__[0])")
patch -p2 < /path/to/hack/vllm-sr-cli-fixes.patch
```

**Note:** These are temporary local fixes. Remove once upstream vllm-sr incorporates them.

## Patched vllm-sr image (Anthropic thinking/reasoning)

The upstream vllm-sr router does not pass `useReasoning` through to Anthropic models.
The `fix-anthropic-thinking` branch of [semantic-router](https://github.com/vllm-project/semantic-router)
(fork: `~/git/semantic-router`) adds thinking/reasoning support for Anthropic models routed via Vertex AI.

See the fork here:

- https://github.com/vllm-project/semantic-router/compare/main...eformat:semantic-router:fix-anthropic-thinking

### Build the patched router binary

Extract the Rust shared libraries from the upstream container (one-time):

```bash
mkdir -p /tmp/vllm-sr-build/lib
podman create --name vllm-sr-extract ghcr.io/vllm-project/semantic-router/vllm-sr:latest
for lib in libcandle_semantic_router.so libml_semantic_router.so libnlp_binding.so; do
  podman cp vllm-sr-extract:/usr/local/lib/$lib /tmp/vllm-sr-build/lib/
done
podman rm vllm-sr-extract
```

Cross-compile the Go binary (must use bullseye for glibc compatibility with bookworm-slim):

```bash
cd ~/git/semantic-router
git checkout fix-anthropic-thinking

podman run --rm \
  -v ~/git/semantic-router:/src:z \
  -v /tmp/vllm-sr-build/lib:/libs:z \
  -v /tmp/vllm-sr-build:/out:z \
  -w /src/src/semantic-router \
  -e CGO_ENABLED=1 \
  -e CGO_LDFLAGS="-L/libs -lcandle_semantic_router -lml_semantic_router -lnlp_binding" \
  -e LD_LIBRARY_PATH=/libs \
  golang:1.24-bullseye \
  go build -buildvcs=false -ldflags="-w -s" -o /out/router ./cmd
```

Copy the binary into this directory:

```bash
cp /tmp/vllm-sr-build/router ~/git/vllm-sr-claude/hack/router
```

### Build and push the container image

```bash
cd ~/git/vllm-sr-claude/hack
podman build -t quay.io/eformat/vllm-sr:latest -f Containerfile .
podman push quay.io/eformat/vllm-sr:latest
```

Then start the stack:

```bash
cd ~/git/vllm-sr-claude
./startup.sh
```
