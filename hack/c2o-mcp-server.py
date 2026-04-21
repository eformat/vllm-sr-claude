#!/usr/bin/env python3
"""c2o Agent Harness - MCP server for orchestrating remote c2o agents.

Auto-detects local (laptop) vs in-cluster (OpenShift pod) mode:
- Local: uses `oc exec` + `claude -p` to task agents
- In-cluster: uses HTTP to c2o-anthropic-{instance}:8819 service endpoints
"""

import asyncio
import json
import os
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


# --- Async task registry ---

# task_id -> {instance, prompt, model, status, result, started, finished, asyncio_task}
TASKS: dict[str, dict] = {}


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
    """Return 'oc' for local mode, 'kubectl' for in-cluster."""
    return "oc" if MODE == "local" else "kubectl"


async def get_pods() -> list[dict]:
    """Get all c2o agent pods in the namespace."""
    cmd = kube_cmd()
    rc, stdout, stderr = await run_cmd(
        cmd, "get", "pods",
        "-l", "app=c2o",
        "-n", NAMESPACE,
        "-o", "json",
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
        ready = any(
            c.get("type") == "Ready" and c.get("status") == "True"
            for c in conditions
        )
        pods.append({
            "instance": instance,
            "pod": name,
            "phase": phase,
            "ready": ready,
        })
    return pods


async def find_pod(instance: str) -> str:
    """Find the pod name for a given instance."""
    pods = await get_pods()
    for p in pods:
        if p["instance"] == instance:
            return p["pod"]
    available = [p["instance"] for p in pods]
    raise RuntimeError(
        f"No pod found for instance '{instance}'. "
        f"Available instances: {available}"
    )


async def exec_in_pod(pod: str, command: list[str], timeout: int = 300) -> str:
    """Execute a command in a pod."""
    cmd = kube_cmd()
    rc, stdout, stderr = await run_cmd(
        cmd, "exec", pod, "-n", NAMESPACE, "--", *command,
        timeout=timeout,
    )
    if rc != 0:
        return f"Error (exit {rc}):\n{stderr}\n{stdout}"
    return stdout


async def send_task_local(pod: str, prompt: str, model: str, working_dir: str | None) -> str:
    """Local mode: pipe prompt via stdin to claude -p in the pod.

    Uses python3 as intermediary to avoid bash interpreting special chars
    (backticks, $, quotes) in the prompt text.
    """
    parts = ["import sys,subprocess as sp"]
    if working_dir:
        parts[0] = "import sys,os,subprocess as sp"
        parts.append(f"os.chdir({working_dir!r})")
    parts.append(
        f'r=sp.run(["claude","-p",sys.stdin.read(),"--model","{model}","--output-format","text","--permission-mode","bypassPermissions"])'
    )
    parts.append("sys.exit(r.returncode)")
    py_code = ";".join(parts)

    cmd = kube_cmd()
    try:
        rc, stdout, stderr = await run_cmd(
            cmd, "exec", "-i", pod, "-n", NAMESPACE, "--",
            "python3", "-c", py_code,
            timeout=3600,
            stdin_data=prompt,
        )
    except asyncio.CancelledError:
        # Kill any orphaned claude processes in the pod
        await run_cmd(
            cmd, "exec", pod, "-n", NAMESPACE, "--",
            "pkill", "-f", "claude -p",
            timeout=10,
        )
        raise
    if rc != 0:
        return f"Error (exit {rc}):\n{stderr}\n{stdout}"
    return stdout


async def send_task_incluster(instance: str, prompt: str, model: str) -> str:
    """In-cluster mode: POST to the agent's Anthropic API endpoint."""
    import httpx

    url = f"http://c2o-anthropic-{instance}.{NAMESPACE}.svc.cluster.local:8819/v1/messages"
    payload = {
        "model": model,
        "max_tokens": 8192,
        "messages": [{"role": "user", "content": prompt}],
    }
    headers = {
        "Content-Type": "application/json",
        "x-api-key": "sk-ant-api03-proxy-placeholder",
        "anthropic-version": "2023-06-01",
    }

    async with httpx.AsyncClient(timeout=600) as client:
        resp = await client.post(url, json=payload, headers=headers)
        if resp.status_code != 200:
            return f"Error ({resp.status_code}): {resp.text}"
        data = resp.json()
        # Extract text from Anthropic response format
        content = data.get("content", [])
        texts = [block["text"] for block in content if block.get("type") == "text"]
        return "\n".join(texts) if texts else json.dumps(data, indent=2)


# --- Background task runner ---

RESULTS_DIR = os.path.join(os.path.dirname(__file__), ".c2o-task-results")
os.makedirs(RESULTS_DIR, exist_ok=True)


def _save_result(task_id: str, task: dict):
    """Save task result to a local file for persistence across MCP restarts."""
    try:
        path = os.path.join(RESULTS_DIR, f"{task_id}.txt")
        with open(path, "w") as f:
            f.write(f"Task: {task_id}\n")
            f.write(f"Instance: {task['instance']}\n")
            f.write(f"Status: {task['status']}\n")
            f.write(f"Model: {task['model']}\n")
            if task["started"]:
                f.write(f"Started: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(task['started']))}\n")
            if task["finished"]:
                f.write(f"Finished: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(task['finished']))}\n")
            f.write(f"\n--- Result ---\n\n")
            f.write(task.get("result") or "(no result)")
        return path
    except Exception:
        return None


async def _run_task(task_id: str):
    """Run a task in the background, updating TASKS registry."""
    task = TASKS[task_id]
    task["status"] = "running"
    task["started"] = time.time()

    try:
        instance = task["instance"]
        prompt = task["prompt"]
        model = task["model"]
        working_dir = task.get("working_dir")

        if MODE == "incluster":
            result = await send_task_incluster(instance, prompt, model)
        else:
            pod = await find_pod(instance)
            result = await send_task_local(pod, prompt, model, working_dir)

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


# --- MCP Server ---

mcp = FastMCP(
    "c2o-agents",
    instructions=(
        "Tools for orchestrating remote c2o agent pods in OpenShift. "
        f"Mode: {MODE}, Namespace: {NAMESPACE}"
    ),
)


@mcp.tool()
async def list_agents() -> str:
    """List all c2o agent instances in the namespace with their status.

    Returns a list of agents with instance name, pod name, phase, and readiness.
    """
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
    """Send a task to a c2o agent asynchronously (fire-and-forget).

    Returns a task_id immediately. Use get_task_status to poll for progress/results.

    Args:
        instance: Agent instance name, e.g. "agent1"
        prompt: The task prompt to send to the agent
        model: Model to use (default: claude-sonnet-4-6)
        working_dir: Working directory inside the pod (optional, local mode only)
    """
    task_id = f"{instance}-{uuid.uuid4().hex[:8]}"
    task = {
        "instance": instance,
        "prompt": prompt,
        "model": model,
        "working_dir": working_dir or None,
        "status": "queued",
        "result": None,
        "started": None,
        "finished": None,
    }
    TASKS[task_id] = task
    task["asyncio_task"] = asyncio.create_task(_run_task(task_id))

    return f"Task dispatched: {task_id}\nInstance: {instance}\nStatus: queued\n\nUse get_task_status(task_id=\"{task_id}\") to check progress."


@mcp.tool()
async def get_task_status(task_id: str = "", instance: str = "") -> str:
    """Check the status of dispatched tasks.

    Call with a specific task_id, or an instance name to see all tasks for that agent,
    or with neither to see all tasks.

    Args:
        task_id: Specific task ID to check (returned by send_task)
        instance: Show all tasks for this instance
    """
    if task_id:
        task = TASKS.get(task_id)
        if not task:
            return f"No task found with id '{task_id}'"
        return _format_task(task_id, task, verbose=True)

    # Filter by instance or show all
    tasks = TASKS
    if instance:
        tasks = {k: v for k, v in TASKS.items() if v["instance"] == instance}
        if not tasks:
            return f"No tasks found for instance '{instance}'"

    if not tasks:
        return "No tasks dispatched yet"

    lines = []
    for tid, task in tasks.items():
        lines.append(_format_task(tid, task, verbose=False))
    return "\n\n".join(lines)


@mcp.tool()
async def cancel_task(task_id: str) -> str:
    """Cancel a running task.

    Args:
        task_id: The task ID to cancel (returned by send_task)
    """
    task = TASKS.get(task_id)
    if not task:
        return f"No task found with id '{task_id}'"

    if task["status"] not in ("queued", "running"):
        return f"Task {task_id} is already {task['status']}"

    atask = task.get("asyncio_task")
    if atask and not atask.done():
        atask.cancel()
        # Also kill claude in the pod
        try:
            pod = await find_pod(task["instance"])
            cmd = kube_cmd()
            await run_cmd(
                cmd, "exec", pod, "-n", NAMESPACE, "--",
                "pkill", "-f", "claude -p",
                timeout=10,
            )
        except Exception:
            pass

    task["status"] = "cancelled"
    task["finished"] = time.time()
    return f"Task {task_id} cancelled"


def _format_task(task_id: str, task: dict, verbose: bool, full: bool = False) -> str:
    """Format a task for display."""
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
            result = result[:5000] + f"\n\n... (truncated, {len(result)} chars total)\nUse get_task_result(task_id=\"{task_id}\") for full output."
        line += f"\n\nResult:\n{result}"
    elif verbose and task["status"] == "running":
        line += "\n\nTask is still running. Poll again in a minute."

    return line


@mcp.tool()
async def get_agent_health(instance: str) -> str:
    """Check if a c2o agent's services are healthy.

    Args:
        instance: Agent instance name, e.g. "agent1"
    """
    if MODE == "incluster":
        import httpx
        url = f"http://c2o-anthropic-{instance}.{NAMESPACE}.svc.cluster.local:8819/health"
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(url)
                if resp.status_code == 200:
                    return f"Agent '{instance}' is healthy"
                return f"Agent '{instance}' unhealthy (status {resp.status_code}): {resp.text}"
        except Exception as e:
            return f"Agent '{instance}' unreachable: {e}"
    else:
        pod = await find_pod(instance)
        result = await exec_in_pod(pod, ["curl", "-sf", "http://localhost:8819/health"])
        if result.strip():
            return f"Agent '{instance}' is healthy"
        return f"Agent '{instance}' health check returned empty response"


@mcp.tool()
async def read_remote_file(instance: str, path: str) -> str:
    """Read a file from a c2o agent's workspace.

    Args:
        instance: Agent instance name, e.g. "agent1"
        path: File path inside the pod (e.g. /home/user/workspace/main.py)
    """
    pod = await find_pod(instance)
    return await exec_in_pod(pod, ["cat", path])


@mcp.tool()
async def get_agent_logs(instance: str, lines: int = 100) -> str:
    """Get recent logs from a c2o agent pod.

    Args:
        instance: Agent instance name, e.g. "agent1"
        lines: Number of log lines to retrieve (default: 100)
    """
    cmd = kube_cmd()
    rc, stdout, stderr = await run_cmd(
        cmd, "logs",
        f"deployment/c2o-{instance}" if instance != "default" else "deployment/c2o",
        "-n", NAMESPACE,
        f"--tail={lines}",
    )
    if rc != 0:
        return f"Error getting logs: {stderr}"
    return stdout


@mcp.tool()
async def get_task_result(task_id: str) -> str:
    """Get the full, untruncated result of a completed task.

    Use this when get_task_status shows a truncated result and you need the complete output.

    Args:
        task_id: The task ID (returned by send_task)
    """
    task = TASKS.get(task_id)
    if not task:
        return f"No task found with id '{task_id}'"
    return _format_task(task_id, task, verbose=True, full=True)


@mcp.tool()
async def exec_on_agent(instance: str, command: str, timeout: int = 30) -> str:
    """Execute a shell command on a c2o agent pod.

    Useful for inspecting files, checking processes, or running arbitrary commands
    on an agent's workspace.

    Args:
        instance: Agent instance name, e.g. "agent1"
        command: Shell command to run (passed to bash -c)
        timeout: Command timeout in seconds (default: 30)
    """
    pod = await find_pod(instance)
    return await exec_in_pod(pod, ["bash", "-c", command], timeout=timeout)


@mcp.tool()
async def list_remote_files(instance: str, path: str = "/home/user/workspace") -> str:
    """List files in a directory on a c2o agent's workspace.

    Args:
        instance: Agent instance name, e.g. "agent1"
        path: Directory path to list (default: /home/user/workspace)
    """
    pod = await find_pod(instance)
    return await exec_in_pod(pod, ["find", path, "-type", "f", "-maxdepth", "3"])


if __name__ == "__main__":
    mcp.run(transport="stdio")
