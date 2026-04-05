# vllm-sr with Claude (Vertex AI) + Kimi K2-5

A novel approach to saving tokens using vllm semantic router.

1. Content-aware routing (keyword signals → model selection)
2. Cross-provider support (Kimi + Claude Sonnet + Claude Opus via Vertex AI)
3. Protocol translation (Anthropic API → OpenAI API via the proxy sidecar)
4. Per-route reasoning control with Anthropic extended thinking
5. Full observability stack (Prometheus + Grafana)

Semantic router setup that routes requests between Kimi K2-5 (internal maas hosted), Claude Sonnet 4.6, and Claude Opus 4.6 (via Google Vertex AI), with auto-refreshing GCP tokens and a Grafana dashboard.

- **Semantic routing** -- requests are automatically routed to the best model based on keywords (coding to Kimi, analysis to Sonnet, architecture/design to Opus - totally configurable using vllm-sr config)
- **Claude Code integration** -- use `claude --model=claude-sonnet-4-6` with the Anthropic translation proxy, full streaming support
- **OpenAI-compatible API** -- any OpenAI client works on port 8899 with `model: "auto"`
- **Auto-refreshing GCP tokens** -- sidecar mints fresh Vertex AI tokens from ADC, no container restarts needed
- **Vertex AI body patching** -- Envoy Lua filter injects `anthropic_version`, strips `model`, rewrites auth headers per-request
- **Anthropic extended thinking** -- when `use_reasoning: true` is set for a routing decision, the router enables Anthropic's extended thinking (chain-of-thought) for Claude models via Vertex AI. Thinking content is returned as `reasoning_content` in the OpenAI-compatible response format
- **Cost optimization** -- defaults to Kimi (internal maas hosted) for coding and general tasks, routes to Sonnet for analysis, Opus only for complex architecture/design
- **Grafana dashboard** -- real-time metrics: request count, QPS, success rate, latency percentiles, token usage
- **Zero external dependencies** -- all sidecars are stdlib Python, no pip installs required

## For the impatient

```bash
export GCP_PROJECT_ID=<your-gcp-project-id>
export TOKEN=<your-maas-bearer-token>
export KIMI_HOST=<your-kimi-maas-hostname>
export HF_TOKEN=<your-hf-token optional but faster model first download for vllm-sr>

cd /home/mike/git/vllm-sr-claude
./startup.sh
./startup.sh --test
./startup.sh --stop

unset CLAUDE_CODE_USE_VERTEX
unset CLOUD_ML_REGION
unset ANTHROPIC_VERTEX_PROJECT_ID
export ANTHROPIC_BASE_URL="http://localhost:8819"
export ANTHROPIC_API_KEY="fake"

claude --model=claude-sonnet-4-6
```

## Architecture

```
                          OpenAI-compatible clients (curl, aider, etc.)
                                    |
                                    v
                              Envoy (:8899)
                                    |
Claude Code ──> Anthropic Proxy (:8819) ──> ext_proc (:50051) ──> routing decisions
                (Anthropic ↔ OpenAI                |
                 format translation)               v
                                             Lua filter (claude models):
                                               1. Patch body for Vertex
                                               2. Fetch GCP token from sidecar
                                               3. Set Authorization header
                                                   |
                                                   v
                                             Upstream:
                                               kimi-k2-5     --> MaaS
                                               claude-sonnet --> Vertex AI
                                               claude-opus   --> Vertex AI

Prometheus (:9090) ──> scrapes router metrics (:9190)
Grafana (:3000) ──> visualizes via Prometheus
```

## Files

```
startup.sh                       # Start/stop/test all services (parallel launch)
vllm-sr-config.yaml              # Semantic router config (models, routing decisions)
.vllm-sr/
  envoy-config.yaml              # Envoy sidecar config (clusters, Lua filter)
  gcp-token-server.py            # GCP token sidecar (auto-refreshing access tokens)
  anthropic-proxy.py             # Anthropic-to-OpenAI translation proxy
  grafana/
    grafana.serve.ini            # Grafana config
    grafana-datasource.serve.yaml
    grafana-datasource-jaeger.serve.yaml
    grafana-dashboard.serve.yaml
    llm-router-dashboard.serve.json
    prometheus.serve.yaml        # Prometheus scrape config
```

## Prerequisites

1. **GCP Application Default Credentials** (for Claude via Vertex AI):

    Uses Google Vertex Auth.

   ```bash
   gcloud auth application-default login
   ```

   This creates `~/.config/gcloud/application_default_credentials.json` with a refresh token that doesn't expire.

2. **Environment variables**:

    Set these before startup.

   ```bash
   export GCP_PROJECT_ID=<your-gcp-project-id>
   export TOKEN=<your-maas-bearer-token>
   export KIMI_HOST=<your-kimi-maas-hostname>
   ```

## Startup

Start pods using podman.

```bash
# Start all services (parallel container launch)
./startup.sh

# Run smoke tests (health checks, routing, proxy translation)
./startup.sh --test

# Stop all services
./startup.sh --stop
```

Services started: vllm-sr (semantic router), gcp-token-server, envoy, anthropic-proxy, prometheus, grafana. All sidecar containers launch in parallel after the router creates the network.

On first run, the router downloads ~7G of classifier models (intent, PII, jailbreak, embedding) to `~/.cache/vllm-sr/models`. These are cached outside the project so they persist across cleanups and are not re-downloaded on subsequent starts. To reclaim disk space: `rm -rf ~/.cache/vllm-sr/models` (they will re-download on next startup).

## Using with Claude Code

Route Claude Code to vllm-sr locally.

```bash
unset CLAUDE_CODE_USE_VERTEX
unset CLOUD_ML_REGION
unset ANTHROPIC_VERTEX_PROJECT_ID
export ANTHROPIC_BASE_URL="http://localhost:8819"
export ANTHROPIC_API_KEY="fake"

claude --model=claude-sonnet-4-6
```

Use any valid Claude model name (e.g. `claude-sonnet-4-6`). The proxy remaps it to `auto` for vllm-sr, which then routes semantically: analysis/reasoning tasks go to Claude, coding and general tasks go to Kimi.

## Using with OpenAI-compatible clients

```bash
# Coding tasks --> Kimi (internal maas hosted)
curl -s http://localhost:8899/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"implement a fibonacci function in python"}],"max_tokens":100}'

# Analysis tasks --> Claude Sonnet
curl -s http://localhost:8899/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"analyze the pros and cons of microservices vs monoliths"}],"max_tokens":100}'

# Architecture/design tasks --> Claude Opus
curl -s http://localhost:8899/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"architect a distributed event-driven system design for a trading platform"}],"max_tokens":100}'

# General chat --> Kimi (default)
curl -s http://localhost:8899/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"what is the capital of France?"}],"max_tokens":50}'

# Force specific model with reasoning
# Sonnet with reasoning enabled (analysis response will include thinking)
curl -s http://localhost:8899/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet","messages":[{"role":"user","content":"explain why recursion is useful"}],"max_tokens":200}'
```

Check which model handled it with `| jq .model`.

## Routing rules

| Priority | Signal | Keywords | Routes to | Reasoning |
|----------|--------|----------|-----------|-----------|
| 95 | opus_keywords | architect, design pattern, system design, algorithm design, complex, performance optimization, refactor entire, rewrite... | claude-opus | enabled |
| 90 | deep_analysis_keywords | analyze, explain why, compare, evaluate, critique, pros and cons, trade-offs, implications, nuance... | claude-sonnet | enabled |
| 80 | coding_keywords | implement, refactor, debug, function, class, code, fix, bug, test, deploy, script... | kimi-k2-5 | disabled |
| 1 | (default) | everything else | kimi-k2-5 | disabled |

Reasoning enables Anthropic's extended thinking for complex tasks at higher latency/cost. When enabled, the router injects a `thinking` block with a 10,000-token budget into the Anthropic API request. The thinking output is returned as `reasoning_content` in the OpenAI-compatible response, with token usage reported in `completion_tokens_details.reasoning_tokens`. Disabled for fast coding responses.

## Dashboard

Grafana dashboard at **http://localhost:3000** (no login required, anonymous access enabled).

Shows: Total Requests, Average QPS, Success Rate, Request Latency (P50/P95/P99), Token Usage, and trends over time.

## Token refresh

The `gcp-token-server` sidecar reads the ADC refresh token (which doesn't expire) and serves fresh access tokens on `GET /token`. Envoy's Lua filter calls this on every Claude request. No container restarts needed for token expiry.

## Patched router image

This project uses a patched vllm-sr image (`quay.io/eformat/vllm-sr:latest`) that adds Anthropic extended thinking support. The upstream router does not pass `use_reasoning` through to Anthropic models — the patched binary enables the `thinking` parameter for Claude models routed via Vertex AI.

See [hack/README.md](hack/README.md) for build instructions and the source diff:
- https://github.com/vllm-project/semantic-router/compare/main...eformat:semantic-router:fix-anthropic-thinking

## Teardown

```bash
./startup.sh --stop
```
