#!/bin/bash
# Setup script for c2o supervisor agent
# Run this on agent3 to configure it as a supervisor that can orchestrate agent1 and agent2

set -euo pipefail

WORKSPACE="/home/user/workspace"
cd "$WORKSPACE"

echo "=== Installing MCP Python package ==="
pip3 install mcp httpx 2>&1 | tail -3

echo "=== Creating c2o-mcp-server.py ==="
cat > "$WORKSPACE/c2o-mcp-server.py" << 'MCPEOF'
#!/usr/bin/env python3
"""c2o Agent Harness - MCP server for orchestrating remote c2o agents.

Auto-detects local (laptop) vs in-cluster (OpenShift pod) mode:
- Local: uses `oc exec` + `claude -p` to task agents
- In-cluster: uses HTTP SSE streaming to c2o-anthropic-{instance}:8819
"""

import asyncio
import json
import os
import signal
import time
import uuid

from mcp.server.fastmcp import FastMCP

# --- Configuration ---

NAMESPACE = os.environ.get("C2O_NAMESPACE", f"c2o-{os.environ.get('USER', 'default')}")
SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
SA_NAMESPACE_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"


def detect_mode():
    if os.path.exists(SA_TOKEN_PATH):
        return "incluster"
    return "local"


MODE = detect_mode()

if MODE == "incluster" and os.path.exists(SA_NAMESPACE_PATH):
    with open(SA_NAMESPACE_PATH) as f:
        NAMESPACE = f.read().strip()


# --- Task registry ---

TASKS: dict[str, dict] = {}
_instance_queues: dict[str, asyncio.Queue] = {}
_instance_workers: dict[str, asyncio.Task] = {}


# --- Transport helpers ---

async def run_cmd(*args: str, timeout: int = 300, stdin_data: str | None = None) -> tuple[int, str, str]:
    proc = await asyncio.create_subprocess_exec(
        *args,
        stdin=asyncio.subprocess.PIPE if stdin_data else None,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(input=stdin_data.encode() if stdin_data else None),
            timeout=timeout,
        )
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return 1, "", f"Command timed out after {timeout}s"
    except asyncio.CancelledError:
        proc.kill()
        await proc.wait()
        raise
    return proc.returncode, stdout.decode(), stderr.decode()


def kube_cmd():
    return "oc" if MODE == "local" else "kubectl"


async def get_pods() -> list[dict]:
    cmd = kube_cmd()
    rc, stdout, stderr = await run_cmd(
        cmd, "get", "pods", "-l", "app=c2o", "-n", NAMESPACE, "-o", "json",
    )
    if rc != 0:
        raise RuntimeError(f"Failed to list pods: {stderr}")
    data = json.loads(stdout)
    pods = []
    for item in data.get("items", []):
        labels = item.get("metadata", {}).get("labels", {})
        instance = labels.get("c2o.instance", "default")
        name = item["metadata"]["name"]
        phase = item.get("status", {}).get("phase", "Unknown")
        conditions = item.get("status", {}).get("conditions", [])
        ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in conditions)
        pods.append({"instance": instance, "pod": name, "phase": phase, "ready": ready})
    return pods


async def find_pod(instance: str) -> str:
    pods = await get_pods()
    for p in pods:
        if p["instance"] == instance:
            return p["pod"]
    available = [p["instance"] for p in pods]
    raise RuntimeError(f"No pod found for instance '{instance}'. Available: {available}")


async def exec_in_pod(pod: str, command: list[str], timeout: int = 300) -> str:
    cmd = kube_cmd()
    rc, stdout, stderr = await run_cmd(cmd, "exec", pod, "-n", NAMESPACE, "--", *command, timeout=timeout)
    if rc != 0:
        return f"Error (exit {rc}):\n{stderr}\n{stdout}"
    return stdout


_AGENT_RUNNER = (
    "import sys,os,subprocess as sp,json;"
    "t=json.loads(sys.stdin.read());"
    "d=t.get('working_dir');"
    "d and os.chdir(d);"
    "r=sp.run(['claude','-p',t['prompt'],"
    "'--model',t.get('model','claude-sonnet-4-6'),"
    "'--output-format','json',"
    "'--permission-mode','bypassPermissions',"
    "'--verbose'],capture_output=True,text=True);"
    "j=json.loads(r.stdout) if r.stdout.strip() else [];"
    "res=[e.get('result','') for e in j if isinstance(e,dict) and e.get('type')=='result'];"
    "print(res[-1] if res else r.stdout);"
    "sys.exit(r.returncode)"
)


async def send_task_local(task_id: str, pod: str, prompt: str, model: str, working_dir: str | None) -> str:
    task_json = json.dumps({"prompt": prompt, "model": model, "working_dir": working_dir})
    cmd = kube_cmd()
    proc = await asyncio.create_subprocess_exec(
        cmd, "exec", "-i", pod, "-n", NAMESPACE, "--", "python3", "-c", _AGENT_RUNNER,
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    TASKS[task_id]["pid"] = proc.pid
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(input=task_json.encode()), timeout=3600)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return "Error: task timed out after 3600s"
    except asyncio.CancelledError:
        await _kill_process_in_pod(pod, proc)
        raise
    if proc.returncode != 0:
        return f"Error (exit {proc.returncode}):\n{stderr.decode()}\n{stdout.decode()}"
    return stdout.decode()


async def send_task_incluster(task_id: str, instance: str, prompt: str, model: str) -> str:
    import httpx
    url = f"http://c2o-anthropic-{instance}.{NAMESPACE}.svc.cluster.local:8819/v1/agent/task"
    payload = {"prompt": prompt, "model": model}
    result_text = ""
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(3600, connect=30)) as client:
            async with client.stream("POST", url, json=payload) as resp:
                if resp.status_code != 200:
                    body = await resp.aread()
                    return f"Error ({resp.status_code}): {body.decode()}"
                remote_task_id = resp.headers.get("x-task-id", "")
                TASKS[task_id]["remote_task_id"] = remote_task_id
                TASKS[task_id]["remote_instance"] = instance
                async for line in resp.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    try:
                        event = json.loads(line[6:])
                    except json.JSONDecodeError:
                        continue
                    etype = event.get("type", "")
                    if etype == "result":
                        result_text = event.get("result", "")
                    elif etype == "task_finished" and event.get("exit_code", 0) != 0:
                        stderr_text = event.get("stderr", "")
                        if stderr_text:
                            result_text += f"\n\nstderr:\n{stderr_text}"
    except Exception as e:
        return await _send_task_incluster_fallback(instance, prompt, model)
    return result_text or "(no result)"


async def _send_task_incluster_fallback(instance: str, prompt: str, model: str) -> str:
    import httpx
    url = f"http://c2o-anthropic-{instance}.{NAMESPACE}.svc.cluster.local:8819/v1/messages"
    payload = {"model": model, "max_tokens": 8192, "messages": [{"role": "user", "content": prompt}]}
    headers = {"Content-Type": "application/json", "x-api-key": "sk-ant-api03-proxy-placeholder", "anthropic-version": "2023-06-01"}
    async with httpx.AsyncClient(timeout=600) as client:
        resp = await client.post(url, json=payload, headers=headers)
        if resp.status_code != 200:
            return f"Error ({resp.status_code}): {resp.text}"
        data = resp.json()
        content = data.get("content", [])
        texts = [block["text"] for block in content if block.get("type") == "text"]
        return "\n".join(texts) if texts else json.dumps(data, indent=2)


async def _kill_process_in_pod(pod: str, local_proc):
    try:
        local_proc.terminate()
        try:
            await asyncio.wait_for(local_proc.wait(), timeout=5)
        except asyncio.TimeoutError:
            local_proc.kill()
            await local_proc.wait()
    except ProcessLookupError:
        pass
    cmd = kube_cmd()
    await run_cmd(
        cmd, "exec", pod, "-n", NAMESPACE, "--", "bash", "-c",
        "pid=$(pgrep -f 'claude -p' | head -1) && [ -n \"$pid\" ] && kill -TERM $pid && sleep 3 && kill -0 $pid 2>/dev/null && kill -KILL $pid; true",
        timeout=15,
    )


# --- Background task runner ---

RESULTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".c2o-task-results")
os.makedirs(RESULTS_DIR, exist_ok=True)


def _save_result(task_id: str, task: dict):
    try:
        path = os.path.join(RESULTS_DIR, f"{task_id}.txt")
        with open(path, "w") as f:
            f.write(f"Task: {task_id}\nInstance: {task['instance']}\nStatus: {task['status']}\nModel: {task['model']}\n")
            if task["started"]:
                f.write(f"Started: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(task['started']))}\n")
            if task["finished"]:
                f.write(f"Finished: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(task['finished']))}\n")
            f.write(f"\n--- Result ---\n\n{task.get('result') or '(no result)'}")
        return path
    except Exception:
        return None


async def _run_task(task_id: str):
    task = TASKS[task_id]
    task["status"] = "running"
    task["started"] = time.time()
    try:
        instance = task["instance"]
        prompt = task["prompt"]
        model = task["model"]
        working_dir = task.get("working_dir")
        if MODE == "incluster":
            result = await send_task_incluster(task_id, instance, prompt, model)
        else:
            pod = await find_pod(instance)
            task["pod"] = pod
            result = await send_task_local(task_id, pod, prompt, model, working_dir)
        task["status"] = "completed"
        task["result"] = result
    except asyncio.CancelledError:
        task["status"] = "cancelled"
        task["result"] = "Task was cancelled"
    except Exception as e:
        task["status"] = "failed"
        task["result"] = f"Error: {e}"
    finally:
        task["finished"] = time.time()
        _save_result(task_id, task)


async def _instance_worker(instance: str, queue: asyncio.Queue):
    while True:
        task_id = await queue.get()
        try:
            await _run_task(task_id)
        except Exception:
            pass
        finally:
            queue.task_done()


def _get_instance_queue(instance: str) -> asyncio.Queue:
    if instance not in _instance_queues:
        q = asyncio.Queue()
        _instance_queues[instance] = q
        _instance_workers[instance] = asyncio.create_task(_instance_worker(instance, q))
    return _instance_queues[instance]


# --- MCP Server ---

mcp = FastMCP(
    "c2o-agents",
    instructions=f"Tools for orchestrating remote c2o agent pods in OpenShift. Mode: {MODE}, Namespace: {NAMESPACE}",
)


@mcp.tool()
async def list_agents() -> str:
    """List all c2o agent instances in the namespace with their status."""
    pods = await get_pods()
    if not pods:
        return f"No c2o agents found in namespace {NAMESPACE}"
    lines = [f"c2o agents in {NAMESPACE} (mode: {MODE}):", ""]
    for p in pods:
        status = "ready" if p["ready"] else p["phase"]
        lines.append(f"  {p['instance']:20s}  {p['pod']:40s}  {status}")
    return "\n".join(lines)


@mcp.tool()
async def send_task(instance: str, prompt: str, model: str = "claude-sonnet-4-6", working_dir: str = "") -> str:
    """Send a task to a c2o agent asynchronously. Returns task_id. Use get_task_status to poll."""
    task_id = f"{instance}-{uuid.uuid4().hex[:8]}"
    task = {"instance": instance, "prompt": prompt, "model": model, "working_dir": working_dir or None,
            "status": "queued", "result": None, "started": None, "finished": None, "pid": None}
    TASKS[task_id] = task
    queue = _get_instance_queue(instance)
    await queue.put(task_id)
    queued = queue.qsize()
    queue_msg = f" ({queued} ahead in queue)" if queued > 1 else ""
    return f"Task dispatched: {task_id}\nInstance: {instance}{queue_msg}\nStatus: queued\n\nUse get_task_status(task_id=\"{task_id}\") to check progress."


@mcp.tool()
async def get_task_status(task_id: str = "", instance: str = "") -> str:
    """Check the status of dispatched tasks."""
    if task_id:
        task = TASKS.get(task_id)
        if not task:
            return f"No task found with id '{task_id}'"
        return _format_task(task_id, task, verbose=True)
    tasks = {k: v for k, v in TASKS.items() if v["instance"] == instance} if instance else TASKS
    if not tasks:
        return "No tasks found" if instance else "No tasks dispatched yet"
    return "\n\n".join(_format_task(tid, t, verbose=False) for tid, t in tasks.items())


@mcp.tool()
async def cancel_task(task_id: str) -> str:
    """Cancel a running task."""
    task = TASKS.get(task_id)
    if not task:
        return f"No task found with id '{task_id}'"
    if task["status"] not in ("queued", "running"):
        return f"Task {task_id} is already {task['status']}"
    if task["status"] == "running":
        if MODE == "incluster" and task.get("remote_task_id"):
            try:
                import httpx
                cancel_url = f"http://c2o-anthropic-{task['remote_instance']}.{NAMESPACE}.svc.cluster.local:8819/v1/agent/task/{task['remote_task_id']}/cancel"
                async with httpx.AsyncClient(timeout=10) as client:
                    await client.post(cancel_url)
            except Exception:
                pass
        pid = task.get("pid")
        if pid:
            try:
                os.kill(pid, signal.SIGTERM)
                await asyncio.sleep(3)
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            except ProcessLookupError:
                pass
        if MODE == "local" and task.get("pod"):
            await run_cmd(kube_cmd(), "exec", task["pod"], "-n", NAMESPACE, "--", "bash", "-c",
                         "pid=$(pgrep -f 'claude -p' | head -1) && [ -n \"$pid\" ] && kill -TERM $pid; true", timeout=10)
    task["status"] = "cancelled"
    task["finished"] = time.time()
    return f"Task {task_id} cancelled"


@mcp.tool()
async def get_task_result(task_id: str) -> str:
    """Get the full, untruncated result of a completed task."""
    task = TASKS.get(task_id)
    if not task:
        return f"No task found with id '{task_id}'"
    return _format_task(task_id, task, verbose=True, full=True)


@mcp.tool()
async def get_agent_health(instance: str) -> str:
    """Check if a c2o agent's services are healthy."""
    if MODE == "incluster":
        import httpx
        url = f"http://c2o-anthropic-{instance}.{NAMESPACE}.svc.cluster.local:8819/health"
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(url)
                return f"Agent '{instance}' is healthy" if resp.status_code == 200 else f"Agent '{instance}' unhealthy ({resp.status_code})"
        except Exception as e:
            return f"Agent '{instance}' unreachable: {e}"
    else:
        pod = await find_pod(instance)
        result = await exec_in_pod(pod, ["curl", "-sf", "http://localhost:8819/health"])
        return f"Agent '{instance}' is healthy" if result.strip() else f"Agent '{instance}' health check returned empty"


@mcp.tool()
async def read_remote_file(instance: str, path: str) -> str:
    """Read a file from a c2o agent's workspace."""
    pod = await find_pod(instance)
    return await exec_in_pod(pod, ["cat", path])


@mcp.tool()
async def exec_on_agent(instance: str, command: str, timeout: int = 30) -> str:
    """Execute a shell command on a c2o agent pod."""
    pod = await find_pod(instance)
    return await exec_in_pod(pod, ["bash", "-c", command], timeout=timeout)


@mcp.tool()
async def list_remote_files(instance: str, path: str = "/home/user/workspace") -> str:
    """List files in a directory on a c2o agent's workspace."""
    pod = await find_pod(instance)
    return await exec_in_pod(pod, ["find", path, "-type", "f", "-maxdepth", "3"])


@mcp.tool()
async def get_agent_logs(instance: str, lines: int = 100) -> str:
    """Get recent logs from a c2o agent pod."""
    cmd = kube_cmd()
    rc, stdout, stderr = await run_cmd(cmd, "logs", f"deployment/c2o-{instance}" if instance != "default" else "deployment/c2o", "-n", NAMESPACE, f"--tail={lines}")
    return stdout if rc == 0 else f"Error getting logs: {stderr}"


def _format_task(task_id: str, task: dict, verbose: bool, full: bool = False) -> str:
    elapsed = ""
    if task["started"]:
        end = task["finished"] or time.time()
        secs = int(end - task["started"])
        mins, secs = divmod(secs, 60)
        elapsed = f" ({mins}m{secs}s)" if mins else f" ({secs}s)"
    line = f"[{task_id}] {task['instance']}  status={task['status']}{elapsed}"
    if verbose and task["status"] in ("completed", "failed"):
        result = task["result"] or ""
        if not full and len(result) > 5000:
            result = result[:5000] + f"\n\n... (truncated)\nUse get_task_result(task_id=\"{task_id}\") for full output."
        line += f"\n\nResult:\n{result}"
    elif verbose and task["status"] == "running":
        line += "\n\nTask is still running. Poll again in a minute."
    return line


if __name__ == "__main__":
    mcp.run(transport="stdio")
MCPEOF

chmod +x "$WORKSPACE/c2o-mcp-server.py"

echo "=== Creating .mcp.json ==="
cat > "$WORKSPACE/.mcp.json" << 'EOF'
{
  "mcpServers": {
    "c2o-agents": {
      "command": "python3",
      "args": ["/home/user/workspace/c2o-mcp-server.py"],
      "env": {
        "C2O_NAMESPACE": "c2o-agents"
      }
    }
  }
}
EOF

echo "=== Creating CLAUDE.md ==="
cat > "$WORKSPACE/CLAUDE.md" << 'CLAUDEEOF'
# CLAUDE.md — c2o Supervisor Agent

## Role

You are a **supervisor agent** that orchestrates other c2o coding agents in the same OpenShift namespace. You do not write code directly — you delegate tasks to worker agents (agent1, agent2) via the c2o-agents MCP server, monitor their progress, and synthesize results.

## Available Workers

| Instance | Purpose |
|----------|---------|
| agent1   | General-purpose coding agent |
| agent2   | General-purpose coding agent |

Use `list_agents` to discover available workers and their status.

## MCP Tools

The `c2o-agents` MCP server provides:

| Tool | Purpose |
|------|---------|
| `list_agents` | List all worker agents and their status |
| `send_task` | Dispatch a task to a worker (async, returns task_id) |
| `get_task_status` | Check task progress/results |
| `get_task_result` | Get full untruncated result |
| `cancel_task` | Cancel a running task |
| `get_agent_health` | Health check a worker |
| `exec_on_agent` | Run a shell command on a worker |
| `read_remote_file` | Read a file from a worker's workspace |
| `list_remote_files` | List files in a worker's workspace |
| `get_agent_logs` | Get pod logs from a worker |

## How to Work

1. **Understand the request** — break it into independent subtasks
2. **Check worker health** — run `list_agents` and `get_agent_health` before dispatching
3. **Dispatch in parallel** — send independent tasks to different workers simultaneously
4. **Monitor progress** — poll `get_task_status` periodically until tasks complete
5. **Synthesize** — combine results, resolve conflicts, report back

## Task Dispatch Guidelines

- Tasks to the same worker are serialized (queued). Spread work across workers for parallelism.
- Use `model` parameter to control which model the worker uses (default: `claude-sonnet-4-6`).
- For complex tasks, use `claude-opus-4-6` as the model.
- Each task prompt should be self-contained — workers have no memory of previous tasks.
- Workers have their own workspaces at `/home/user/workspace/`.
- Always include full context in task prompts — file paths, requirements, constraints.

## Example Patterns

### Parallel research
```
send_task(instance="agent1", prompt="Search the codebase for all API endpoints and list them")
send_task(instance="agent2", prompt="Review the test coverage and identify gaps")
```

### Sequential with handoff
```
# Step 1: agent1 implements
send_task(instance="agent1", prompt="Implement feature X in src/foo.py")
# Step 2: after agent1 completes, agent2 reviews
send_task(instance="agent2", prompt="Review the changes agent1 made to src/foo.py")
```

### Fan-out, gather
```
# Dispatch to both workers
task1 = send_task(instance="agent1", prompt="Fix bug A")
task2 = send_task(instance="agent2", prompt="Fix bug B")
# Poll both until complete
get_task_status()  # shows all tasks
```
CLAUDEEOF

echo "=== Done ==="
echo "Supervisor agent3 is configured."
echo "Files created:"
ls -la "$WORKSPACE/CLAUDE.md" "$WORKSPACE/.mcp.json" "$WORKSPACE/c2o-mcp-server.py"
