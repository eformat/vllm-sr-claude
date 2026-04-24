#!/bin/bash
# Test the /v1/agent/task SSE streaming endpoint on c2o agent pods.
# Usage:
#   ./hack/test-agent-task.sh [agent-instance]
#   ./hack/test-agent-task.sh agent1
#
# Tests: SSE streaming, task listing, and cancellation.

set -euo pipefail

NAMESPACE="${C2O_NAMESPACE:-c2o-agents}"
INSTANCE="${1:-agent1}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config.lightning}"
export KUBECONFIG

PASS=0
FAIL=0
ERRORS=()

pod=$(oc get pods -l "app=c2o,c2o.instance=${INSTANCE}" -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$pod" ]]; then
    echo "ERROR: No pod found for instance '${INSTANCE}' in namespace '${NAMESPACE}'"
    exit 1
fi
echo "Testing on pod: ${pod} (instance: ${INSTANCE})"
echo "========================================="

# --- Test 1: SSE streaming task ---
echo ""
echo "--- Test 1: SSE streaming (/v1/agent/task) ---"

result=$(oc exec "${pod}" -n "${NAMESPACE}" -- \
    curl -sf -X POST http://localhost:8819/v1/agent/task \
    -H "Content-Type: application/json" \
    -d '{"prompt": "What is 2+2? Reply with just the number.", "model": "claude-sonnet-4-6"}' \
    --max-time 120 2>&1) || {
    echo "  FAIL: curl error"
    FAIL=$((FAIL + 1))
    ERRORS+=("SSE streaming: curl error")
    result=""
}

if [[ -n "$result" ]]; then
    has_started=$(echo "$result" | grep -c "^event: task_started" || true)
    has_finished=$(echo "$result" | grep -c "^event: task_finished" || true)
    has_result=$(echo "$result" | grep -c "^event: result" || true)

    if [[ "$has_started" -gt 0 && "$has_finished" -gt 0 && "$has_result" -gt 0 ]]; then
        task_id=$(echo "$result" | grep "^data:.*task_id" | head -1 | python3 -c "import sys,json; print(json.loads(sys.stdin.read().split('data: ',1)[1])['task_id'])" 2>/dev/null || echo "?")
        exit_code=$(echo "$result" | grep "^data:.*exit_code" | python3 -c "import sys,json; print(json.loads(sys.stdin.read().split('data: ',1)[1])['exit_code'])" 2>/dev/null || echo "?")
        echo "  PASS: got task_started, result, task_finished events"
        echo "    task_id: ${task_id}"
        echo "    exit_code: ${exit_code}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: missing SSE events (started=${has_started} result=${has_result} finished=${has_finished})"
        ERRORS+=("SSE streaming: missing events")
        FAIL=$((FAIL + 1))
    fi
fi

# --- Test 2: Task listing ---
echo ""
echo "--- Test 2: Task listing (/v1/agent/tasks) ---"

tasks_result=$(oc exec "${pod}" -n "${NAMESPACE}" -- \
    curl -sf http://localhost:8819/v1/agent/tasks 2>&1) || {
    echo "  FAIL: curl error"
    FAIL=$((FAIL + 1))
    ERRORS+=("Task listing: curl error")
    tasks_result=""
}

if [[ -n "$tasks_result" ]]; then
    if echo "$tasks_result" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        echo "  PASS: valid JSON response"
        echo "    response: ${tasks_result}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: invalid JSON: ${tasks_result}"
        ERRORS+=("Task listing: invalid JSON")
        FAIL=$((FAIL + 1))
    fi
fi

# --- Test 3: Cancellation ---
echo ""
echo "--- Test 3: Cancellation (/v1/agent/task/{id}/cancel) ---"

cancel_result=$(oc exec "${pod}" -n "${NAMESPACE}" -- bash -c '
    curl -sf -X POST http://localhost:8819/v1/agent/task \
        -H "Content-Type: application/json" \
        -d "{\"prompt\": \"Write a 10000 word essay about the history of mathematics.\", \"model\": \"claude-sonnet-4-6\"}" \
        --max-time 5 > /dev/null 2>&1 &

    sleep 3

    TASK_ID=$(curl -sf http://localhost:8819/v1/agent/tasks | python3 -c "import sys,json; d=json.load(sys.stdin); print(list(d.keys())[0]) if d else print(\"\")")
    if [ -z "$TASK_ID" ]; then
        echo "NO_TASK"
        exit 0
    fi

    curl -sf -X POST "http://localhost:8819/v1/agent/task/${TASK_ID}/cancel"
    sleep 1
    REMAINING=$(curl -sf http://localhost:8819/v1/agent/tasks | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    echo "|REMAINING=${REMAINING}"
' 2>&1) || {
    echo "  FAIL: curl error"
    FAIL=$((FAIL + 1))
    ERRORS+=("Cancellation: curl error")
    cancel_result=""
}

if [[ -n "$cancel_result" ]]; then
    if [[ "$cancel_result" == "NO_TASK" ]]; then
        echo "  SKIP: task finished before cancel could run"
    elif echo "$cancel_result" | grep -q '"status".*"cancelled"'; then
        remaining=$(echo "$cancel_result" | grep -oP 'REMAINING=\K[0-9]+' || echo "?")
        echo "  PASS: task cancelled, ${remaining} tasks remaining"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: unexpected response: ${cancel_result}"
        ERRORS+=("Cancellation: unexpected response")
        FAIL=$((FAIL + 1))
    fi
fi

# --- Test 4: Error handling (missing prompt) ---
echo ""
echo "--- Test 4: Error handling (missing prompt) ---"

error_result=$(oc exec "${pod}" -n "${NAMESPACE}" -- \
    curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8819/v1/agent/task \
    -H "Content-Type: application/json" \
    -d '{"model": "claude-sonnet-4-6"}' 2>&1) || true

if [[ "$error_result" == "400" ]]; then
    echo "  PASS: returned 400 for missing prompt"
    PASS=$((PASS + 1))
else
    echo "  FAIL: expected 400, got ${error_result}"
    ERRORS+=("Error handling: expected 400, got ${error_result}")
    FAIL=$((FAIL + 1))
fi

# --- Summary ---
echo ""
echo "========================================="
echo "Results: ${PASS} passed, ${FAIL} failed (out of $((PASS + FAIL)) tests)"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        echo "  - ${err}"
    done
    exit 1
fi
echo "All agent task endpoint tests passed."
