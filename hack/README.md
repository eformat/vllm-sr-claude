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
