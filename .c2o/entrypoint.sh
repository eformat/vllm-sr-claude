#!/bin/bash
# c2o - Container entrypoint script
# Starts all vllm-sr services in a single container

set -uo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Configuration
CONFIG_DIR="/app/config"
WORKSPACE_DIR="/home/user/workspace"
PID_DIR="/tmp/c2o-pids"
LOG_DIR="/tmp/c2o-logs"

# Ensure directories exist
mkdir -p "$PID_DIR" "$LOG_DIR" "$WORKSPACE_DIR"
mkdir -p /home/user/.claude /home/user/.cache/vllm-sr
mkdir -p /home/user/.config/gcloud

log() {
    echo -e "${BLUE}[c2o]${NC} $1"
}

error() {
    echo -e "${RED}[c2o] ERROR:${NC} $1"
}

warn() {
    echo -e "${ORANGE}[c2o] WARN:${NC} $1"
}

# Process environment substitution on config files
process_configs() {
    local log_dir="/tmp/c2o-startup-logs"
    mkdir -p "$log_dir"

    log "Processing config files..." >&2

    if command -v envsubst &>/dev/null; then
        envsubst < "$CONFIG_DIR/vllm-sr-config.yaml" > "$log_dir/vllm-sr-config.processed.yaml" 2>&1 || {
            error "Failed to process vllm-sr-config.yaml"
            cat "$log_dir/vllm-sr-config.processed.yaml" 2>/dev/null || true
        }
        envsubst < "$CONFIG_DIR/envoy-config.yaml" > "$log_dir/envoy-config.processed.yaml" 2>&1 || {
            error "Failed to process envoy-config.yaml"
            cat "$log_dir/envoy-config.processed.yaml" 2>/dev/null || true
        }
        # Replace Docker network hostnames with localhost for single-container mode
        sed -i 's/vllm-sr-container/localhost/g; s/gcp-token-server/localhost/g' \
            "$log_dir/envoy-config.processed.yaml"
    else
        warn "envsubst not found, using raw configs"
        cp "$CONFIG_DIR/vllm-sr-config.yaml" "$log_dir/vllm-sr-config.processed.yaml"
        cp "$CONFIG_DIR/envoy-config.yaml" "$log_dir/envoy-config.processed.yaml"
        sed -i 's/vllm-sr-container/localhost/g; s/gcp-token-server/localhost/g' \
            "$log_dir/envoy-config.processed.yaml"
    fi

    echo "$log_dir"
}

# Start a service and record its PID
start_service() {
    local name="$1"
    shift
    local log_file="$LOG_DIR/${name}.log"

    log "Starting ${name}..."
    "$@" > "$log_file" 2>&1 &
    local pid=$!
    echo $pid > "$PID_DIR/${name}.pid"

    # Quick health check
    sleep 2
    if kill -0 $pid 2>/dev/null; then
        log "  ✓ ${name} started (pid: $pid)"
        return 0
    else
        error "  ✗ ${name} failed to start"
        if [ -f "$log_file" ]; then
            echo "--- ${name} logs ---"
            tail -20 "$log_file"
            echo "--------------------"
        fi
        return 1
    fi
}

# Stop all services
stop_services() {
    log "Shutting down services..."
    for pid_file in "$PID_DIR"/*.pid; do
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file" 2>/dev/null || echo "")
            local name=$(basename "$pid_file" .pid)
            if [ -n "$pid" ] && kill -0 $pid 2>/dev/null; then
                kill -TERM $pid 2>/dev/null || true
                log "  ✓ Stopped ${name}"
            fi
            rm -f "$pid_file"
        fi
    done
}

# Signal handlers
cleanup() {
    echo ""
    stop_services
    exit 0
}
trap cleanup SIGTERM SIGINT

# Main startup
echo ""
log "🌴 c2o (Claude-to-OpenShift) - Starting services"
echo ""

# Verify required env vars
if [ -z "${TOKEN:-}" ]; then
    warn "TOKEN env var not set (Kimi MaaS auth) - routing may fail"
fi

if [ -z "${KIMI_HOST:-}" ]; then
    warn "KIMI_HOST not set - Kimi routing will fail"
fi

if [ -z "${GCP_PROJECT_ID:-}" ]; then
    warn "GCP_PROJECT_ID not set - Claude routing will fail until you run 'c2o login'"
fi

# Check required binaries exist
for binary in /usr/local/bin/router python3 envoy; do
    if [ ! -x "$binary" ] && ! command -v $(basename "$binary") &>/dev/null; then
        error "Required binary not found: $binary"
        exit 1
    fi
done

log "All required binaries found"

# Process config files
PROCESSED_DIR=$(process_configs)
if [ ! -f "$PROCESSED_DIR/vllm-sr-config.processed.yaml" ]; then
    error "Failed to create processed config files"
    exit 1
fi
log "Config files processed: $PROCESSED_DIR"

# Start services in order
FAIL=0

# 1. vllm-sr semantic router
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
start_service vllm-sr \
    /usr/local/bin/router \
    -config "$PROCESSED_DIR/vllm-sr-config.processed.yaml" || {
        error "vllm-sr router failed to start - check logs at $LOG_DIR/vllm-sr.log"
        FAIL=1
    }

# Wait for vllm-sr gRPC to be ready
log "Waiting for vllm-sr to be ready..."
for i in {1..30}; do
    if nc -z localhost 50051 2>/dev/null || [ $i -eq 30 ]; then
        break
    fi
    sleep 1
done

if [ "$FAIL" -eq 1 ]; then
    error "Critical service (vllm-sr) failed to start"
    stop_services
    exit 1
fi

# 2. GCP token server (if credentials exist)
if [ -f /home/user/.config/gcloud/application_default_credentials.json ]; then
    start_service gcp-token-server \
        python3 /app/sidecars/gcp-token-server.py || {
            warn "GCP token server failed to start (Claude routing may fail)"
        }
else
    log "GCP credentials not found - skipping gcp-token-server"
    log "Run 'c2o login' to enable Claude routing"
fi

# 3. Envoy
start_service envoy \
    envoy -c "$PROCESSED_DIR/envoy-config.processed.yaml" || {
        error "Envoy failed to start - check logs at $LOG_DIR/envoy.log"
        FAIL=1
    }

if [ "$FAIL" -eq 1 ]; then
    error "Critical service (envoy) failed to start"
    stop_services
    exit 1
fi

# Wait for envoy to be ready
log "Waiting for envoy to be ready..."
for i in {1..30}; do
    if curl -sf http://localhost:8899/v1/models &>/dev/null || [ $i -eq 30 ]; then
        break
    fi
    sleep 1
done

# 4. Anthropic proxy
start_service anthropic-proxy \
    python3 /app/sidecars/anthropic-proxy.py || {
        error "Anthropic proxy failed to start - check logs at $LOG_DIR/anthropic-proxy.log"
        FAIL=1
    }

if [ "$FAIL" -eq 1 ]; then
    error "Critical service (anthropic-proxy) failed to start"
    stop_services
    exit 1
fi

# Wait for anthropic proxy to be ready
log "Waiting for anthropic proxy to be ready..."
for i in {1..30}; do
    if curl -sf http://localhost:8819/health &>/dev/null || [ $i -eq 30 ]; then
        break
    fi
    sleep 1
done

# 5. Prometheus
PROM_CONFIG="/tmp/c2o-prometheus.yaml"
sed 's/vllm-sr-container:9190/localhost:9190/g' /app/config/grafana/prometheus.serve.yaml > "$PROM_CONFIG"
start_service prometheus \
    prometheus --config.file="$PROM_CONFIG" \
    --storage.tsdb.path=/var/lib/prometheus \
    --web.listen-address=:9090 \
    --storage.tsdb.retention.time=7d || {
        warn "Prometheus failed to start - check logs at $LOG_DIR/prometheus.log"
    }

# 6. Grafana
# Set up provisioning configs with localhost references
mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards
sed 's/vllm-sr-prometheus:9090/localhost:9090/g' /app/config/grafana/grafana-datasource.serve.yaml \
    > /etc/grafana/provisioning/datasources/datasource.yaml
cp /app/config/grafana/grafana-dashboard.serve.yaml /etc/grafana/provisioning/dashboards/dashboard.yaml
cp /app/config/grafana/llm-router-dashboard.serve.json /etc/grafana/provisioning/dashboards/
start_service grafana \
    grafana-server \
    --homepath=/opt/grafana \
    --config=/app/config/grafana/grafana.serve.ini \
    cfg:default.paths.data=/var/lib/grafana \
    cfg:default.paths.logs=/var/log/grafana \
    cfg:default.paths.provisioning=/etc/grafana/provisioning \
    cfg:default.server.http_port=3000 || {
        warn "Grafana failed to start - check logs at $LOG_DIR/grafana.log"
    }

echo ""
log "🌴 All critical services started!"
echo ""
echo -e "  ${BLUE}Services:${NC}"
echo -e "    OpenAI API      http://localhost:8899/v1/chat/completions"
echo -e "    Anthropic API   http://localhost:8819/v1/messages"
echo -e ""
echo -e "  ${BLUE}Claude Code:${NC}"
echo -e "    export ANTHROPIC_BASE_URL=\"http://localhost:8819\""
echo -e "    export ANTHROPIC_API_KEY=\"fake\""
echo -e "    claude --model=claude-sonnet-4-6"
echo -e ""
echo -e "  Workspace: ${WORKSPACE_DIR}"
echo -e "  Logs:      ${LOG_DIR}"
echo ""

# Final health check
log "Running health check..."
HEALTHY=true

if curl -sf http://localhost:8899/v1/models &>/dev/null; then
    log "  ✓ Envoy proxy (:8899)"
else
    warn "  ✗ Envoy proxy (:8899) not responding"
    HEALTHY=false
fi

if curl -sf http://localhost:8819/health &>/dev/null; then
    log "  ✓ Anthropic proxy (:8819)"
else
    warn "  ✗ Anthropic proxy (:8819) not responding"
    HEALTHY=false
fi

if curl -sf http://localhost:3000/api/health &>/dev/null; then
    log "  ✓ Grafana (:3000)"
else
    warn "  ✗ Grafana (:3000) not responding"
fi

if curl -sf http://localhost:9090/-/ready &>/dev/null; then
    log "  ✓ Prometheus (:9090)"
else
    warn "  ✗ Prometheus (:9090) not responding"
fi

echo ""

if [ "$HEALTHY" = true ]; then
    log "All services healthy - container is ready!"
else
    warn "Some services may not be fully ready yet - check logs with:"
    echo "  oc logs -n c2o-\$USER deployment/c2o"
fi

echo ""

# Keep container alive and monitor services
while true; do
    sleep 30

    # Check if critical services are still running
    for service in vllm-sr envoy anthropic-proxy; do
        pid_file="$PID_DIR/${service}.pid"
        if [ -f "$pid_file" ]; then
            pid=$(cat "$pid_file" 2>/dev/null || echo "")
            if [ -n "$pid" ] && ! kill -0 $pid 2>/dev/null; then
                warn "Service $service has stopped unexpectedly"
                echo "Check logs: $LOG_DIR/${service}.log"
            fi
        fi
    done
done
