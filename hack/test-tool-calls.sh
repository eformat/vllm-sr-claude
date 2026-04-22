#!/bin/bash
# Test tool calls against c2o agent pods to verify no hallucinations.
# Usage:
#   ./hack/test-tool-calls.sh [agent-instance]
#   ./hack/test-tool-calls.sh agent1
#
# Tests claude-sonnet, claude-opus, and kimi-k2-5 via the anthropic proxy.
# claude-opus-4-7 is pre-configured but not yet available on Vertex AI.
# To include it in tests: MODELS="claude-sonnet claude-opus claude-opus-4-7 kimi-k2-5" ./hack/test-tool-calls.sh
# Each test sends a simple prompt requiring a real tool call and checks
# the response contains a tool_use block (not hallucinated XML text).

set -euo pipefail

NAMESPACE="${C2O_NAMESPACE:-c2o-agents}"
INSTANCE="${1:-agent1}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config.lightning}"
export KUBECONFIG

if [[ -n "${MODELS:-}" ]]; then
    read -ra MODELS <<< "$MODELS"
else
    MODELS=("claude-sonnet" "claude-opus" "kimi-k2-5")
fi
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

for model in "${MODELS[@]}"; do
    echo ""
    echo "--- Testing: ${model} ---"

    # Craft a request that requires a tool call (get_weather)
    payload=$(cat <<'ENDJSON'
{
  "model": "MODEL_PLACEHOLDER",
  "max_tokens": 1024,
  "tools": [
    {
      "name": "get_weather",
      "description": "Get the current weather in a given location",
      "input_schema": {
        "type": "object",
        "properties": {
          "location": {
            "type": "string",
            "description": "City name, e.g. San Francisco, CA"
          }
        },
        "required": ["location"]
      }
    }
  ],
  "messages": [
    {
      "role": "user",
      "content": "What is the weather in Tokyo? Use the get_weather tool."
    }
  ]
}
ENDJSON
)
    payload="${payload//MODEL_PLACEHOLDER/$model}"

    # Send to the anthropic proxy inside the pod
    result=$(oc exec "${pod}" -n "${NAMESPACE}" -- \
        curl -sf -X POST http://localhost:8819/v1/messages \
        -H "Content-Type: application/json" \
        -H "x-api-key: sk-ant-api03-proxy-placeholder" \
        -H "anthropic-version: 2023-06-01" \
        -d "${payload}" \
        --max-time 120 2>&1) || {
        echo "  FAIL: curl error"
        FAIL=$((FAIL + 1))
        ERRORS+=("${model}: curl error")
        continue
    }

    # Check for tool_use in the response
    if echo "${result}" | jq -e '.content[] | select(.type == "tool_use")' >/dev/null 2>&1; then
        tool_name=$(echo "${result}" | jq -r '.content[] | select(.type == "tool_use") | .name' 2>/dev/null | head -1)
        tool_input=$(echo "${result}" | jq -c '.content[] | select(.type == "tool_use") | .input' 2>/dev/null | head -1)
        stop_reason=$(echo "${result}" | jq -r '.stop_reason' 2>/dev/null)
        echo "  PASS: tool_use detected"
        echo "    tool: ${tool_name}"
        echo "    input: ${tool_input}"
        echo "    stop_reason: ${stop_reason}"
        PASS=$((PASS + 1))
    else
        # Check if it hallucinated tool XML in text
        has_xml=$(echo "${result}" | jq -r '.content[]? | select(.type == "text") | .text' 2>/dev/null | grep -c '<tool_call>\|<function_call>\|```tool' || true)
        stop_reason=$(echo "${result}" | jq -r '.stop_reason // "unknown"' 2>/dev/null)
        error_msg=$(echo "${result}" | jq -r '.error.message // empty' 2>/dev/null)

        if [[ -n "${error_msg}" ]]; then
            echo "  FAIL: API error: ${error_msg}"
            ERRORS+=("${model}: API error - ${error_msg}")
        elif [[ "${has_xml}" -gt 0 ]]; then
            echo "  FAIL: hallucinated tool XML in text (no real tool_use block)"
            ERRORS+=("${model}: hallucinated tool XML")
        else
            echo "  FAIL: no tool_use block in response"
            echo "    stop_reason: ${stop_reason}"
            echo "    response preview: $(echo "${result}" | jq -c '.content[:1]' 2>/dev/null | head -c 200)"
            ERRORS+=("${model}: no tool_use block")
        fi
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "========================================="
echo "Results: ${PASS} passed, ${FAIL} failed (out of ${#MODELS[@]} models)"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        echo "  - ${err}"
    done
    exit 1
fi
echo "All models produced real tool calls. No hallucinations detected."
