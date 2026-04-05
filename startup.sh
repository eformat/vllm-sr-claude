#!/bin/bash
# -*- coding: UTF-8 -*-

# vllm-sr Claude + Kimi Semantic Router Startup
# Starts all containers in the correct order

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ALL_CONTAINERS="vllm-sr-grafana vllm-sr-prometheus anthropic-proxy vllm-sr-envoy gcp-token-server vllm-sr-container"

# --- Stop mode ---

if [ "${1:-}" == "--stop" ]; then
    echo -e "${BLUE}"
    echo "🌴 vllm-sr Semantic Router — Stopping"
    echo -e "${NC}"

    echo -e "🌴 ${ORANGE}Stopping containers...${NC}"
    for c in $ALL_CONTAINERS; do
        if podman stop "$c" &>/dev/null && podman rm -f "$c" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} ${c} stopped"
        else
            echo -e "  ${ORANGE}—${NC} ${c} (not running)"
        fi
    done

    echo ""
    echo -e "${GREEN}🌴 All services stopped.${NC}"
    exit 0
fi

# --- Test mode ---

if [ "${1:-}" == "--test" ]; then
    echo -e "${BLUE}"
    echo "🌴 vllm-sr Semantic Router — Smoke Tests"
    echo -e "${NC}"

    PASS=0
    FAIL=0

    run_test() {
        local desc="$1"
        shift
        local result
        result=$("$@" 2>&1)
        local rc=$?
        if [ $rc -eq 0 ] && [ -n "$result" ]; then
            echo -e "  ${GREEN}✓${NC} ${desc}"
            PASS=$((PASS + 1))
        else
            echo -e "  ${RED}✗${NC} ${desc}"
            echo "    ${result:0:200}"
            FAIL=$((FAIL + 1))
        fi
    }

    # Health checks
    echo -e "🌴 ${ORANGE}Health checks...${NC}"
    run_test "Anthropic proxy health" curl -sf http://localhost:8819/health
    run_test "Envoy admin ready" curl -sf http://localhost:9901/ready
    run_test "Prometheus targets" curl -sf http://localhost:9090/-/ready
    run_test "Grafana health" curl -sf http://localhost:3000/api/health

    # OpenAI API — coding request → should route to kimi-k2-5
    echo -e "\n🌴 ${ORANGE}Routing tests (OpenAI API :8899)...${NC}"
    CODING_RESP=$(curl -s --max-time 60 http://localhost:8899/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d '{"model":"auto","messages":[{"role":"user","content":"implement a hello world function in python"}],"max_tokens":50}' 2>&1)
    CODING_MODEL=$(echo "$CODING_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('model',''))" 2>/dev/null || true)
    if [ "$CODING_MODEL" = "kimi-k2-5" ]; then
        echo -e "  ${GREEN}✓${NC} Coding request → kimi-k2-5"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} Coding request → expected kimi-k2-5, got: ${CODING_MODEL:-no response}"
        FAIL=$((FAIL + 1))
    fi

    # OpenAI API — analysis request → should route to claude-sonnet (with reasoning)
    ANALYSIS_RESP=$(curl -s --max-time 90 http://localhost:8899/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d '{"model":"auto","messages":[{"role":"user","content":"analyze the pros and cons of monoliths vs microservices"}],"max_tokens":50}' 2>&1)
    ANALYSIS_MODEL=$(echo "$ANALYSIS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('model',''))" 2>/dev/null || true)
    if [ "$ANALYSIS_MODEL" = "claude-sonnet" ]; then
        echo -e "  ${GREEN}✓${NC} Analysis request → claude-sonnet"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} Analysis request → expected claude-sonnet, got: ${ANALYSIS_MODEL:-no response}"
        FAIL=$((FAIL + 1))
    fi

    # OpenAI API — architecture request → should route to claude-opus
    OPUS_RESP=$(curl -s --max-time 90 http://localhost:8899/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d '{"model":"auto","messages":[{"role":"user","content":"architect a distributed event-driven system design"}],"max_tokens":50}' 2>&1)
    OPUS_MODEL=$(echo "$OPUS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('model',''))" 2>/dev/null || true)
    if [ "$OPUS_MODEL" = "claude-opus" ]; then
        echo -e "  ${GREEN}✓${NC} Architecture request → claude-opus"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} Architecture request → expected claude-opus, got: ${OPUS_MODEL:-no response}"
        FAIL=$((FAIL + 1))
    fi

    # Anthropic API — proxy translation
    echo -e "\n🌴 ${ORANGE}Anthropic proxy test (:8819)...${NC}"
    ANTHRO_RESP=$(curl -s --max-time 60 http://localhost:8819/v1/messages \
        -H "Content-Type: application/json" \
        -H "x-api-key: fake" \
        -H "anthropic-version: 2023-06-01" \
        -d '{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"say hello"}],"max_tokens":50}' 2>&1)
    ANTHRO_TYPE=$(echo "$ANTHRO_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type',''))" 2>/dev/null || true)
    if [ "$ANTHRO_TYPE" = "message" ]; then
        echo -e "  ${GREEN}✓${NC} Anthropic proxy → valid message response"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} Anthropic proxy → expected type=message, got: ${ANTHRO_TYPE:-no response}"
        FAIL=$((FAIL + 1))
    fi

    # Summary
    echo ""
    if [ "$FAIL" -eq 0 ]; then
        echo -e "${GREEN}🌴 All ${PASS} tests passed!${NC}"
    else
        echo -e "${RED}🌴 ${PASS} passed, ${FAIL} failed${NC}"
        exit 1
    fi
    exit 0
fi

echo -e "${BLUE}"
echo "🌴 vllm-sr Semantic Router — Claude + Kimi"
echo -e "${NC}"

# --- Preflight checks ---

command -v podman &> /dev/null || { echo -e "🕱${RED} podman not installed. Aborting${NC}"; exit 1; }

if [ -z "${TOKEN:-}" ]; then
    echo -e "🕱${RED} TOKEN env var not set (Kimi MaaS auth). Aborting${NC}"
    exit 1
fi

ADC_PATH="${HOME}/.config/gcloud/application_default_credentials.json"
if [ ! -f "$ADC_PATH" ]; then
    echo -e "🕱${RED} GCP ADC not found at ${ADC_PATH}${NC}"
    echo -e "${ORANGE}  Run: gcloud auth application-default login${NC}"
    exit 1
fi

# --- Check for EnvVars ---

[ -z "${GCP_PROJECT_ID:-}" ] && echo -e "🕱${RED} Error: must supply GCP_PROJECT_ID in env${NC}" && exit 1
[ -z "${KIMI_HOST:-}" ] && echo -e "🕱${RED} Error: must supply KIMI_HOST in env${NC}" && exit 1

echo -e "🌴 Preflight checks passed"
echo -e "  ${GREEN}✓${NC} GCP_PROJECT_ID: ${GCP_PROJECT_ID}"
echo -e "  ${GREEN}✓${NC} KIMI_HOST: ${KIMI_HOST}"
if [ -n "${HF_TOKEN:-}" ]; then
    echo -e "  ${GREEN}✓${NC} HF_TOKEN: set (faster model downloads)"
else
    echo -e "  ${ORANGE}—${NC} HF_TOKEN: not set (model downloads will be slower)"
fi
echo ""

# --- Configuration ---

CONFIG_FILE="${SCRIPT_DIR}/config.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "🕱${RED} Config file not found: ${CONFIG_FILE}${NC}"
    exit 1
fi

# Load container versions from config for documentation
ENVOY_VERSION="$(grep -A1 'envoy:' "$CONFIG_FILE" | grep 'version:' | cut -d'"' -f2 || echo 'v1.32-latest')"
GRAFANA_VERSION="$(grep -A1 'grafana:' "$CONFIG_FILE" | grep 'version:' | cut -d'"' -f2 || echo '11.5.1')"
PROMETHEUS_VERSION="$(grep -A1 'prometheus:' "$CONFIG_FILE" | grep 'version:' | cut -d'"' -f2 || echo 'v3.4.1')"

# --- Helper ---

start_container() {
    local name="$1"
    shift
    # Remove existing container if present
    podman rm -f "$name" &>/dev/null || true
    # Run container and capture output
    local output rc=0
    output=$(podman run "$@" 2>&1) || rc=$?
    # Filter out BoltDB spam but preserve real errors
    output=$(echo "$output" | grep -v "BoltDB" || true)
    if [ "$rc" -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} ${name}"
    else
        echo -e "  ${RED}✗${NC} ${name} — failed to start"
        echo "$output" | tail -5
        return 1
    fi
}

# --- 1. Semantic Router ---

# --- Process config templates with envsubst ---

LOG_DIR="/tmp/vllm-sr-startup-logs"
mkdir -p "$LOG_DIR"
export KIMI_HOST GCP_PROJECT_ID

ROUTER_CONFIG_PROCESSED="${LOG_DIR}/vllm-sr-config.processed.yaml"
ENVOY_CONFIG_PROCESSED="${LOG_DIR}/envoy-config.processed.yaml"

if command -v envsubst &>/dev/null; then
    envsubst < "${SCRIPT_DIR}/vllm-sr-config.yaml" > "$ROUTER_CONFIG_PROCESSED"
    envsubst < "${SCRIPT_DIR}/.vllm-sr/envoy/envoy-config.yaml" > "$ENVOY_CONFIG_PROCESSED"
else
    echo -e "${ORANGE}  Warning: envsubst not found, using raw config templates${NC}"
    echo -e "${ORANGE}  Install gettext for automatic variable substitution${NC}"
    cp "${SCRIPT_DIR}/vllm-sr-config.yaml" "$ROUTER_CONFIG_PROCESSED"
    cp "${SCRIPT_DIR}/.vllm-sr/envoy/envoy-config.yaml" "$ENVOY_CONFIG_PROCESSED"
fi

# --- 1. Semantic Router ---

echo -e "🌴 ${ORANGE}Starting semantic router...${NC}"
podman network create vllm-sr-network &>/dev/null || true
# Cache models in ~/.cache so they persist across project cleanups (one-time ~7G download)
MODELS_CACHE="${HOME}/.cache/vllm-sr/models"
mkdir -p "$MODELS_CACHE"
HF_TOKEN_ARG=()
if [ -n "${HF_TOKEN:-}" ]; then
    HF_TOKEN_ARG=(-e "HF_TOKEN=${HF_TOKEN}")
fi
start_container vllm-sr-container \
    -d --name vllm-sr-container --network vllm-sr-network \
    --ulimit nofile=65536:65536 \
    -p 50051:50051 -p 9190:9190 -p 8080:8080 \
    -e "TOKEN=${TOKEN}" \
    "${HF_TOKEN_ARG[@]}" \
    -v "${ROUTER_CONFIG_PROCESSED}:/app/config.yaml:z" \
    -v "${SCRIPT_DIR}/.vllm-sr:/app/.vllm-sr:z" \
    -v "${MODELS_CACHE}:/app/models:z" \
    ghcr.io/vllm-project/semantic-router/vllm-sr:latest || exit 1

# --- 2. Sidecars (parallel) ---

echo -e "🌴 ${ORANGE}Starting sidecars in parallel...${NC}"
FAIL=0

start_container gcp-token-server \
    -d --name gcp-token-server --network vllm-sr-network \
    --userns=keep-id --user "$(id -u)" \
    -e CONFIG_PATH=/app/config.yaml \
    -v "${ADC_PATH}:/adc/application_default_credentials.json:ro,z" \
    -v "${SCRIPT_DIR}/.vllm-sr/sidecars/gcp-token-server/server.py:/app/server.py:z" \
    -v "${CONFIG_FILE}:/app/config.yaml:ro,z" \
    registry.access.redhat.com/ubi9/python-312:latest python /app/server.py >"$LOG_DIR/gcp-token-server.log" 2>&1 &
PID_GCP=$!

start_container vllm-sr-envoy \
    -d --name vllm-sr-envoy --network vllm-sr-network \
    -p 8899:8899 -p 9901:9901 \
    -v "${ENVOY_CONFIG_PROCESSED}:/etc/envoy/envoy.yaml:z" \
    --entrypoint envoy docker.io/envoyproxy/envoy:v1.32-latest \
    -c /etc/envoy/envoy.yaml >"$LOG_DIR/vllm-sr-envoy.log" 2>&1 &
PID_ENVOY=$!

start_container anthropic-proxy \
    -d --name anthropic-proxy --network vllm-sr-network \
    -p 8819:8819 \
    -e UPSTREAM_HOST=vllm-sr-envoy -e UPSTREAM_PORT=8899 \
    -e CONFIG_PATH=/app/config.yaml \
    -v "${SCRIPT_DIR}/.vllm-sr/sidecars/anthropic-proxy/proxy.py:/app/proxy.py:z" \
    -v "${CONFIG_FILE}:/app/config.yaml:ro,z" \
    registry.access.redhat.com/ubi9/python-312:latest python /app/proxy.py >"$LOG_DIR/anthropic-proxy.log" 2>&1 &
PID_PROXY=$!

start_container vllm-sr-prometheus \
    -d --name vllm-sr-prometheus --network vllm-sr-network \
    -p 9090:9090 \
    -v "${SCRIPT_DIR}/.vllm-sr/grafana/prometheus.serve.yaml:/etc/prometheus/prometheus.yml:z" \
    docker.io/prom/prometheus:v3.4.1 \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.retention.time=15d >"$LOG_DIR/vllm-sr-prometheus.log" 2>&1 &
PID_PROM=$!

start_container vllm-sr-grafana \
    -d --name vllm-sr-grafana --network vllm-sr-network \
    -e GF_SECURITY_ADMIN_USER=admin \
    -e GF_SECURITY_ADMIN_PASSWORD=admin \
    -e PROMETHEUS_URL=vllm-sr-prometheus:9090 \
    -v "${SCRIPT_DIR}/.vllm-sr/grafana/grafana.serve.ini:/etc/grafana/grafana.ini:ro,z" \
    -v "${SCRIPT_DIR}/.vllm-sr/grafana/grafana-datasource.serve.yaml:/etc/grafana/provisioning/datasources/datasource.yaml:ro,z" \
    -v "${SCRIPT_DIR}/.vllm-sr/grafana/grafana-datasource-jaeger.serve.yaml:/etc/grafana/provisioning/datasources/datasource_jaeger.yaml:ro,z" \
    -v "${SCRIPT_DIR}/.vllm-sr/grafana/grafana-dashboard.serve.yaml:/etc/grafana/provisioning/dashboards/dashboard.yaml:ro,z" \
    -v "${SCRIPT_DIR}/.vllm-sr/grafana/llm-router-dashboard.serve.json:/etc/grafana/provisioning/dashboards/llm-router-dashboard.json:ro,z" \
    -p 3000:3000 \
    docker.io/grafana/grafana:11.5.1 >"$LOG_DIR/vllm-sr-grafana.log" 2>&1 &
PID_GRAF=$!

for pid in $PID_GCP $PID_ENVOY $PID_PROXY $PID_PROM $PID_GRAF; do
    wait "$pid" || FAIL=1
done

if [ "$FAIL" -eq 1 ]; then
    echo -e "\n  ${RED}✗${NC} One or more containers failed to start"
    exit 1
fi

# --- Done ---

echo ""
echo -e "${GREEN}🌴 All services started successfully!${NC}"
echo ""
echo -e "  ${BLUE}OpenAI API${NC}      http://localhost:8899/v1/chat/completions"
echo -e "  ${BLUE}Anthropic API${NC}   http://localhost:8819/v1/messages"
echo -e "  ${BLUE}Grafana${NC}         http://localhost:3000"
echo -e "  ${BLUE}Envoy Admin${NC}     http://localhost:9901"
echo -e "  ${BLUE}Prometheus${NC}      http://localhost:9090"
echo ""
echo -e "  🌴 ${ORANGE}Claude Code:${NC}"
echo -e "     export ANTHROPIC_BASE_URL=\"http://localhost:8819\""
echo -e "     export ANTHROPIC_API_KEY=\"fake\""
echo -e "     claude --model=claude-sonnet-4-6"
echo ""
