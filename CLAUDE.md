# CLAUDE.md

## Project overview

vllm-sr-claude is a semantic router that routes LLM requests to the cheapest capable model based on content analysis. It sits between clients (Claude Code, SDKs, curl) and model backends (Kimi K2-6, Claude Sonnet on Vertex AI, Claude Opus on Vertex AI). The core value is cost optimization — coding tasks go to Kimi (cheapest), analysis to Sonnet, architecture to Opus.

Deployable locally via Podman or as a single pod on OpenShift (c2o mode). The c2o MCP server orchestrates remote Claude Code agents running in OpenShift pods.

## Architecture

```
Client → Anthropic Proxy (:8819) → Envoy (:8899) → Model Backend
                                       ↑
                              Semantic Router (ext_proc :50051)
                              GCP Token Server (:8888)
```

Routing flow: Envoy calls the semantic router via ext_proc gRPC. The router inspects the request for keyword signals and returns the selected model + reasoning config. Envoy's Lua filter patches the request body and injects a fresh GCP token, then forwards to the selected upstream cluster.

For Claude models, the Anthropic proxy bypasses Envoy entirely and forwards directly to Vertex AI in native Anthropic format (avoids double-translation of tool definitions).

## Key files

| File | Purpose |
|------|---------|
| `startup.sh` | Local development — launches all services via Podman |
| `vllm-sr-config.yaml` | Routing rules, model definitions, keyword signals |
| `config.yaml` | Centralized config: ports, timeouts, GCP settings |
| `.vllm-sr/envoy/envoy-config.yaml` | Envoy proxy: clusters, routes, Lua filters |
| `.vllm-sr/sidecars/anthropic-proxy/proxy.py` | Anthropic↔OpenAI translator + agent task SSE endpoint |
| `.vllm-sr/sidecars/gcp-token-server/server.py` | Auto-refreshing GCP ADC token server |
| `hack/c2o-mcp-server.py` | MCP server for remote agent orchestration |
| `hack/Containerfile.c2o` | Container build for OpenShift c2o pods |
| `.c2o/entrypoint.sh` | Container entrypoint (starts all services in-pod) |
| `openshift/c2o/` | Kubernetes manifests: deployment, services, routes, configmap |

## Build and deploy

### Local (Podman)

```bash
# Prerequisites: GCP ADC credentials, env vars
export GCP_PROJECT_ID="your-project"
export KIMI_HOST="kimi.example.com"
export TOKEN="kimi-bearer-token"

./startup.sh          # start all services
./startup.sh --test   # start + run smoke tests
./startup.sh --stop   # stop all services
```

### OpenShift (c2o container)

```bash
# Build and push
podman build -f hack/Containerfile.c2o -t quay.io/eformat/c2o:latest .
podman push quay.io/eformat/c2o:latest

# Deploy / rollout
oc apply -k openshift/c2o/
oc rollout restart deployment/c2o-agent1 -n c2o-agents
```

Image: `quay.io/eformat/c2o:latest`

## Testing

```bash
# Tool call tests against a deployed agent (tests claude-sonnet, claude-opus, kimi-k2-6)
./hack/test-tool-calls.sh agent1
./hack/test-tool-calls.sh agent2

# Extended thinking validation
./validate_reasoning.sh

# Local smoke tests (run after startup.sh)
./startup.sh --test
```

## Environment variables

| Variable | Required | Purpose |
|----------|----------|---------|
| `GCP_PROJECT_ID` | Yes | Vertex AI project ID |
| `KIMI_HOST` | Yes | Kimi MaaS hostname |
| `TOKEN` | Yes | Kimi API bearer token |
| `HF_TOKEN` | No | Hugging Face token (faster model downloads) |
| `ANTHROPIC_BASE_URL` | Auto | Set to `http://localhost:8819` for Claude Code |
| `ANTHROPIC_API_KEY` | Auto | Set to `fake` — proxy ignores it |
| `C2O_NAMESPACE` | No | Kubernetes namespace (default: `c2o-{USER}`) |

## Routing rules

Configured in `vllm-sr-config.yaml`. Keyword-based matching, evaluated by priority:

| Priority | Signal | Model | Reasoning |
|----------|--------|-------|-----------|
| 95 | `opus_keywords` (architecture, design, security audit...) | Claude Opus | Enabled |
| 80 | `deep_analysis_keywords` (analyze, investigate, compare...) | Claude Sonnet | Enabled |
| 60 | `coding_keywords` (implement, refactor, debug, test...) | Kimi K2-6 | Disabled |
| 1 | Default (no match) | Kimi K2-6 | Disabled |

## Proxy endpoints

The anthropic proxy (`proxy.py`, port 8819) serves:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v1/messages` | POST | Anthropic Messages API (main proxy path) |
| `/v1/agent/task` | POST | SSE streaming agent task (runs `claude -p` in-pod) |
| `/v1/agent/task/{id}/cancel` | POST | Cancel a running agent task |
| `/v1/agent/tasks` | GET | List active agent tasks |
| `/v1/models` | GET | List available models |
| `/health` | GET | Health check |

## MCP server (c2o-agents)

Configured in `.mcp.json`. Auto-detects local vs in-cluster mode:
- **Local**: discovers pods via `oc get pods`, dispatches tasks via `oc exec`
- **In-cluster**: streams from agent's `/v1/agent/task` SSE endpoint

Tasks to the same agent instance are serialized (per-instance queues). Cancellation uses PID-tracked SIGTERM→SIGKILL.

## Development conventions

- **Zero dependencies**: sidecars use stdlib Python only — no pip packages
- **Commit style**: emoji-wrapped messages, e.g. `🐡 claude to openshift 🐡`
- **Config changes**: update `vllm-sr-config.yaml` or `config.yaml`, no rebuild needed for routing rule changes (ConfigMap in OpenShift)
- **Patched router**: uses fork `eformat:semantic-router:fix-anthropic-thinking` to wire `use_reasoning` through to Anthropic models

## Ports

| Port | Service |
|------|---------|
| 8819 | Anthropic proxy |
| 8899 | Envoy (OpenAI API) |
| 8888 | GCP token server |
| 9090 | Prometheus |
| 3000 | Grafana |
| 9901 | Envoy admin |
| 50051 | Semantic router (ext_proc gRPC) |
