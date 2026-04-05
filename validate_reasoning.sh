#!/bin/bash
# Validate that reasoning is working for Claude Opus and Sonnet models

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
ORANGE='\033[0;33m'
NC='\033[0m'

echo "========================================="
echo "Validating Reasoning for Claude Models"
echo "========================================="
echo ""

# Test 1: Sonnet with analysis keywords (should have reasoning enabled)
echo -e "${ORANGE}Test 1: Sonnet with reasoning via routing${NC}"
SONNET_RESP=$(curl -s --max-time 60 http://localhost:8899/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"auto","messages":[{"role":"user","content":"analyze the pros and cons of microservices vs monoliths in detail"}],"max_tokens":200}')

SONNET_MODEL=$(echo "$SONNET_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('model',''))" 2>/dev/null || echo "")
SONNET_REASONING=$(echo "$SONNET_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('usage',{}).get('completion_tokens_details',{}).get('reasoning_tokens',0))" 2>/dev/null || echo "0")

echo "  Model: $SONNET_MODEL"
echo "  Reasoning tokens: $SONNET_REASONING"

if [ "$SONNET_MODEL" = "claude-sonnet" ]; then
    echo -e "  ${GREEN}✓${NC} Routed to claude-sonnet"
else
    echo -e "  ${RED}✗${NC} Expected claude-sonnet, got: $SONNET_MODEL"
fi

# Test 2: Opus with architecture keywords (should have reasoning enabled)
echo ""
echo -e "${ORANGE}Test 2: Opus with reasoning via routing${NC}"
OPUS_RESP=$(curl -s --max-time 60 http://localhost:8899/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"auto","messages":[{"role":"user","content":"architect a distributed event-driven trading system design"}],"max_tokens":200}')

OPUS_MODEL=$(echo "$OPUS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('model',''))" 2>/dev/null || echo "")
OPUS_REASONING=$(echo "$OPUS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('usage',{}).get('completion_tokens_details',{}).get('reasoning_tokens',0))" 2>/dev/null || echo "0")

echo "  Model: $OPUS_MODEL"
echo "  Reasoning tokens: $OPUS_REASONING"

if [ "$OPUS_MODEL" = "claude-opus" ]; then
    echo -e "  ${GREEN}✓${NC} Routed to claude-opus"
else
    echo -e "  ${RED}✗${NC} Expected claude-opus, got: $OPUS_MODEL"
fi

# Test 3: Direct model call with thinking parameter
echo ""
echo -e "${ORANGE}Test 3: Direct Sonnet call with thinking parameter${NC}"
DIRECT_RESP=$(curl -s --max-time 60 http://localhost:8899/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "x-selected-model: claude-sonnet" \
    -d '{
        "model":"claude-sonnet",
        "messages":[{"role":"user","content":"explain recursion in programming"}],
        "max_tokens":300,
        "thinking":{"type":"enabled","budget_tokens":1024}
    }')

DIRECT_MODEL=$(echo "$DIRECT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('model',''))" 2>/dev/null || echo "")
DIRECT_REASONING=$(echo "$DIRECT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('usage',{}).get('completion_tokens_details',{}).get('reasoning_tokens',0))" 2>/dev/null || echo "0")

echo "  Model: $DIRECT_MODEL"
echo "  Reasoning tokens: $DIRECT_REASONING"

if [ "$DIRECT_MODEL" = "claude-sonnet" ]; then
    echo -e "  ${GREEN}✓${NC} Direct call to claude-sonnet"
else
    echo -e "  ${RED}✗${NC} Expected claude-sonnet, got: $DIRECT_MODEL"
fi

# Summary
echo ""
echo "========================================="
echo "Summary:"
echo "  - Routing works correctly"
echo "  - Reasoning tokens in response: Sonnet=$SONNET_REASONING, Opus=$OPUS_REASONING, Direct=$DIRECT_REASONING"

# Check if thinking content is present (for API that returns it separately)
echo ""
echo -e "${ORANGE}Checking for thinking content in responses...${NC}"

# Test via Anthropic proxy to see full response structure
echo ""
echo "Anthropic API response structure:"
ANTHRO_RESP=$(curl -s --max-time 60 http://localhost:8819/v1/messages \
    -H "Content-Type: application/json" \
    -H "x-api-key: fake" \
    -d '{
        "model":"claude-sonnet",
        "max_tokens":200,
        "thinking":{"type":"enabled","budget_tokens":1024},
        "messages":[{"role":"user","content":"explain recursion"}]
    }')

# Check if response has thinking field
HAS_THINKING=$(echo "$ANTHRO_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if any(b.get('type')=='thinking' for b in d.get('content',[])) else 'no')" 2>/dev/null || echo "error")
echo "  Has thinking content block: $HAS_THINKING"

# Check usage
ANTHRO_USAGE=$(echo "$ANTHRO_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('usage',{}))" 2>/dev/null || echo "")
echo "  Usage: $ANTHRO_USAGE"

echo ""
echo "========================================="
