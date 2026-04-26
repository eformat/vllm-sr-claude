#!/bin/bash
# Setup script for c2o supervisor agent
# Configures an agent as a supervisor that can orchestrate other agents via MCP
# Idempotent — safe to run multiple times

set -euo pipefail

WORKSPACE="/home/user/workspace"
REPO_RAW="https://raw.githubusercontent.com/eformat/vllm-sr-claude/main"
cd "$WORKSPACE"

echo "=== Installing MCP Python package ==="
pip3 install mcp httpx 2>&1 | tail -3

echo "=== Downloading c2o-mcp-server.py ==="
curl -fsSL "$REPO_RAW/hack/c2o-mcp-server.py" -o "$WORKSPACE/c2o-mcp-server.py"
chmod +x "$WORKSPACE/c2o-mcp-server.py"

echo "=== Downloading CLAUDE.md ==="
curl -fsSL "$REPO_RAW/.c2o/supervisor/CLAUDE.md" -o "$WORKSPACE/CLAUDE.md"

INSTANCES="${C2O_INSTANCES:-agent1,agent2}"
NAMESPACE="${C2O_NAMESPACE:-c2o-agents}"

echo "=== Creating .mcp.json (workers: $INSTANCES) ==="
cat > "$WORKSPACE/.mcp.json" <<EOF
{
  "mcpServers": {
    "c2o-agents": {
      "command": "python3",
      "args": ["/home/user/workspace/c2o-mcp-server.py"],
      "env": {
        "C2O_NAMESPACE": "$NAMESPACE",
        "C2O_MODE": "incluster",
        "C2O_INSTANCES": "$INSTANCES"
      }
    }
  }
}
EOF

echo "=== Done ==="
echo "Supervisor configured. Files:"
ls -la "$WORKSPACE/CLAUDE.md" "$WORKSPACE/.mcp.json" "$WORKSPACE/c2o-mcp-server.py"
