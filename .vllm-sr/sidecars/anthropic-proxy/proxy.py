"""Anthropic-to-OpenAI translation proxy for vllm-sr.

Accepts Anthropic Messages API requests on /v1/messages,
translates to OpenAI Chat Completions format, forwards to
vllm-sr (Envoy), and translates streaming responses back.

For Claude models on Vertex AI, requests are forwarded directly
in native Anthropic format (no format conversion) to preserve
tool definitions and avoid the double-translation problem.

Runs as a sidecar container on vllm-sr-network.
"""

import json
import logging
import os
import http.client
import socket
import ssl
import subprocess
import threading
import uuid
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from pathlib import Path

# Load configuration
CONFIG_PATH = os.getenv("CONFIG_PATH", "/app/config.yaml")
config = {}


def load_config():
    """Load configuration from YAML if available."""
    global config
    try:
        import yaml
        with open(CONFIG_PATH) as f:
            loaded = yaml.safe_load(f)
            config = loaded if loaded else {}
    except Exception:
        # Fallback to defaults
        config = {
            "models": {
                "known_models": ["auto", "kimi-k2-5", "claude-sonnet", "claude-opus", "claude-opus-4-7",
                                 "claude-sonnet-4-6", "claude-opus-4-6"]
            },
            "claude_direct_bypass": False,
            "timeouts": {"http_request": 1200},
            "network": {"ports": {"anthropic_proxy": 8819}},
            "logging": {"level": "INFO"},
        }


def setup_logging():
    """Configure logging based on config."""
    log_level = config.get("logging", {}).get("level", "INFO")
    log_format = config.get("logging", {}).get(
        "format", "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    )
    logging.basicConfig(level=getattr(logging, log_level), format=log_format)
    return logging.getLogger("anthropic-proxy")


# Load config on module load
load_config()
log = setup_logging()

# Upstream configuration
UPSTREAM_HOST = os.getenv("UPSTREAM_HOST", "vllm-sr-envoy")
UPSTREAM_PORT = int(os.getenv("UPSTREAM_PORT", "8899"))

# Models known to vllm-sr — pass these through as-is.
KNOWN_MODELS = set(config.get("models", {}).get("known_models", ["auto", "kimi-k2-5", "claude-sonnet", "claude-opus", "claude-opus-4-7",
                                                                  "claude-sonnet-4-6", "claude-opus-4-6"]))
CLAUDE_DIRECT_BYPASS = config.get("claude_direct_bypass", False)

# Request size limits
MAX_BODY_SIZE = 10 * 1024 * 1024  # 10MB

# --- Vertex AI direct path for Claude models ---
# When a Claude model is explicitly requested, bypass the OpenAI format
# conversion and forward directly to Vertex AI in native Anthropic format.
# This avoids the double-translation (Anthropic→OpenAI→Anthropic) that
# causes tool definitions to be sent in the wrong format.
VERTEX_HOST = os.getenv("VERTEX_HOST", "us-east5-aiplatform.googleapis.com")
VERTEX_REGION = os.getenv("VERTEX_REGION", "us-east5")
GCP_PROJECT_ID = os.getenv("GCP_PROJECT_ID", "")
GCP_TOKEN_HOST = os.getenv("GCP_TOKEN_HOST", "localhost")
GCP_TOKEN_PORT = int(os.getenv("GCP_TOKEN_PORT", "8888"))

# Short name → full Anthropic model ID for Vertex AI URL
CLAUDE_MODEL_MAP = {
    "claude-sonnet": "claude-sonnet-4-6",
    "claude-opus": "claude-opus-4-6",
    "claude-opus-4-7": "claude-opus-4-7",
}


def is_claude_model(model: str) -> bool:
    """Check if the model should be routed directly to Vertex AI."""
    return model.startswith("claude") and bool(GCP_PROJECT_ID)


def get_vertex_model_id(model: str) -> str:
    """Map model name to full Vertex AI model ID."""
    return CLAUDE_MODEL_MAP.get(model, model)


def get_gcp_token() -> str:
    """Fetch a fresh GCP access token from the token server sidecar."""
    try:
        conn = http.client.HTTPConnection(GCP_TOKEN_HOST, GCP_TOKEN_PORT, timeout=5)
        conn.request("GET", "/token")
        resp = conn.getresponse()
        token = resp.read().decode().strip()
        conn.close()
        if resp.status == 200 and token:
            return token
        log.warning(f"GCP token server returned status {resp.status}")
    except Exception as e:
        log.error(f"Failed to get GCP token: {e}")
    return ""


class ProxyError(Exception):
    """Custom exception for proxy errors."""
    pass


# --- Agent task tracking ---

_agent_tasks = {}  # task_id -> {"pid": int, "process": Popen}
_agent_tasks_lock = threading.Lock()


def _kill_process(proc, grace_period=5):
    """SIGTERM, then SIGKILL after grace period."""
    try:
        proc.terminate()
        try:
            proc.wait(timeout=grace_period)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
    except Exception:
        pass


# ---------- Request translation: Anthropic -> OpenAI ----------

def translate_request(req):
    """Translate Anthropic request to OpenAI format.

    Args:
        req: Parsed JSON request body

    Returns:
        dict: OpenAI-formatted request

    Raises:
        ProxyError: If request is invalid.
    """
    if not isinstance(req, dict):
        raise ProxyError("Request body must be a JSON object")

    model = req.get("model", "auto")
    if model not in KNOWN_MODELS:
        model = "auto"
        log.debug(f"Unknown model '{req.get('model')}', remapping to 'auto'")

    out = {
        "model": model,
        "stream": req.get("stream", False),
    }

    # Simple passthrough params
    for key in ("max_tokens", "temperature", "top_p", "top_k"):
        if key in req:
            out[key] = req[key]
    if "stop_sequences" in req:
        out["stop"] = req["stop_sequences"]

    # System prompt: Anthropic top-level -> OpenAI system message
    messages = []
    system = req.get("system")
    if system:
        if isinstance(system, str):
            messages.append({"role": "system", "content": system})
        elif isinstance(system, list):
            text = "\n".join(b.get("text", "") for b in system if b.get("type") == "text")
            if text:
                messages.append({"role": "system", "content": text})
        else:
            log.warning(f"Unsupported system prompt type: {type(system)}")

    # Messages
    for msg in req.get("messages", []):
        if not isinstance(msg, dict):
            log.warning(f"Skipping invalid message: {msg}")
            continue

        role = msg.get("role")
        if role not in ("user", "assistant"):
            log.warning(f"Unknown message role: {role}")

        content = msg.get("content")

        if role == "assistant":
            messages.extend(_translate_assistant_msg(content))
        elif role == "user" and isinstance(content, list):
            messages.extend(_translate_user_blocks(content))
        else:
            messages.append({"role": role, "content": content})

    out["messages"] = messages

    # Tools
    if "tools" in req and isinstance(req["tools"], list):
        out["tools"] = [
            {
                "type": "function",
                "function": {
                    "name": t.get("name", ""),
                    "description": t.get("description", ""),
                    "parameters": t.get("input_schema", {}),
                },
            }
            for t in req["tools"]
            if isinstance(t, dict) and "name" in t
        ]

    return out


def _translate_assistant_msg(content):
    """Convert assistant message content (may contain tool_use blocks)."""
    if isinstance(content, str) or content is None:
        return [{"role": "assistant", "content": content or ""}]

    if not isinstance(content, list):
        log.warning(f"Unexpected assistant content type: {type(content)}")
        return [{"role": "assistant", "content": str(content)}]

    asst = {"role": "assistant"}
    texts = []
    tool_calls = []

    for block in content:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text":
            texts.append(block.get("text", ""))
        elif btype == "tool_use":
            tool_calls.append({
                "id": block.get("id", ""),
                "type": "function",
                "function": {
                    "name": block.get("name", ""),
                    "arguments": json.dumps(block.get("input", {})),
                },
            })
        # Skip thinking blocks — they don't map to OpenAI

    if texts:
        asst["content"] = "\n".join(texts)
    if tool_calls:
        asst["tool_calls"] = tool_calls

    return [asst]


def _translate_user_blocks(blocks):
    """Convert user message content blocks (may contain tool_result)."""
    if not isinstance(blocks, list):
        return [{"role": "user", "content": str(blocks)}]

    msgs = []
    other = []

    for block in blocks:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "tool_result":
            tc = block.get("content", "")
            if isinstance(tc, list):
                tc = "\n".join(b.get("text", "") for b in tc if b.get("type") == "text")
            msgs.append({
                "role": "tool",
                "tool_call_id": block.get("tool_use_id", ""),
                "content": str(tc),
            })
        elif block.get("type") == "text":
            other.append(block.get("text", ""))
        elif block.get("type") == "image":
            source = block.get("source", {})
            if source.get("type") == "base64":
                other.append({
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:{source.get('media_type','image/png')};base64,{source.get('data', '')}"
                    },
                })

    if other:
        # If all strings, join them; otherwise use content array
        if all(isinstance(o, str) for o in other):
            msgs.insert(0, {"role": "user", "content": "\n".join(other)})
        else:
            content = []
            for o in other:
                if isinstance(o, str):
                    content.append({"type": "text", "text": o})
                else:
                    content.append(o)
            msgs.insert(0, {"role": "user", "content": content})

    return msgs


# ---------- Response translation: OpenAI -> Anthropic ----------

STOP_MAP = {"stop": "end_turn", "length": "max_tokens", "tool_calls": "tool_use"}


def translate_response(resp):
    """Convert non-streaming OpenAI response to Anthropic format."""
    if not isinstance(resp, dict):
        raise ProxyError(f"Expected dict response, got {type(resp)}")

    choices = resp.get("choices")
    if not choices or not isinstance(choices, list):
        raise ProxyError("No choices in response")

    choice = choices[0]
    if not isinstance(choice, dict):
        raise ProxyError("Invalid choice format")

    message = choice.get("message", {})
    usage = resp.get("usage", {})

    content = []
    if message.get("content"):
        content.append({"type": "text", "text": message["content"]})

    for tc in message.get("tool_calls") or []:
        if not isinstance(tc, dict):
            continue
        func = tc.get("function", {})
        try:
            inp = json.loads(func.get("arguments", "{}"))
        except json.JSONDecodeError as e:
            log.warning(f"Failed to parse tool arguments: {e}")
            inp = {}
        content.append({
            "type": "tool_use",
            "id": tc.get("id", ""),
            "name": func.get("name", ""),
            "input": inp,
        })

    return {
        "id": resp.get("id", "msg_proxy"),
        "type": "message",
        "role": "assistant",
        "model": resp.get("model", "unknown"),
        "content": content,
        "stop_reason": STOP_MAP.get(choice.get("finish_reason"), choice.get("finish_reason")),
        "stop_sequence": None,
        "usage": {
            "input_tokens": usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0),
        },
    }


def translate_stream(raw_response, write_fn):
    """Read OpenAI SSE chunks and emit Anthropic SSE events."""
    model = "unknown"
    msg_id = "msg_proxy"
    started = False
    text_block_open = False
    text_index = 0
    tool_blocks = {}  # tool_index -> {id, name, block_index}
    next_block_index = 0
    finish_reason = None

    for raw_line in _iter_lines(raw_response):
        line = raw_line.strip()
        if not line:
            continue

        if line == "data: [DONE]":
            if text_block_open:
                _sse(write_fn, "content_block_stop", {"type": "content_block_stop", "index": text_index})
            for ti in sorted(tool_blocks):
                _sse(write_fn, "content_block_stop", {"type": "content_block_stop", "index": tool_blocks[ti]["block_index"]})
            _sse(write_fn, "message_delta", {
                "type": "message_delta",
                "delta": {"stop_reason": STOP_MAP.get(finish_reason, finish_reason or "end_turn")},
                "usage": {"output_tokens": 0},
            })
            _sse(write_fn, "message_stop", {"type": "message_stop"})
            return

        if not line.startswith("data: "):
            continue
        try:
            chunk = json.loads(line[6:])
        except json.JSONDecodeError:
            log.debug(f"Failed to parse SSE chunk: {line[:100]}")
            continue

        model = chunk.get("model", model)
        msg_id = chunk.get("id", msg_id)

        if not started:
            _sse(write_fn, "message_start", {
                "type": "message_start",
                "message": {
                    "id": msg_id, "type": "message", "role": "assistant",
                    "model": model, "content": [], "stop_reason": None,
                    "stop_sequence": None,
                    "usage": {"input_tokens": 0, "output_tokens": 0},
                },
            })
            started = True

        choices = chunk.get("choices")
        if not choices or not isinstance(choices, list):
            continue

        choice = choices[0]
        if not isinstance(choice, dict):
            continue

        delta = choice.get("delta", {})

        if choice.get("finish_reason"):
            finish_reason = choice["finish_reason"]

        # --- text content ---
        text = delta.get("content")
        if text:
            if not text_block_open:
                text_index = next_block_index
                next_block_index += 1
                _sse(write_fn, "content_block_start", {
                    "type": "content_block_start",
                    "index": text_index,
                    "content_block": {"type": "text", "text": ""},
                })
                text_block_open = True
            _sse(write_fn, "content_block_delta", {
                "type": "content_block_delta",
                "index": text_index,
                "delta": {"type": "text_delta", "text": text},
            })

        # --- reasoning (kimi) -> include as text ---
        reasoning = delta.get("reasoning")
        if reasoning:
            if not text_block_open:
                text_index = next_block_index
                next_block_index += 1
                _sse(write_fn, "content_block_start", {
                    "type": "content_block_start",
                    "index": text_index,
                    "content_block": {"type": "text", "text": ""},
                })
                text_block_open = True
            _sse(write_fn, "content_block_delta", {
                "type": "content_block_delta",
                "index": text_index,
                "delta": {"type": "text_delta", "text": reasoning},
            })

        # --- tool calls ---
        for tc in delta.get("tool_calls") or []:
            if not isinstance(tc, dict):
                continue
            ti = tc.get("index", 0)
            if ti not in tool_blocks:
                if text_block_open:
                    _sse(write_fn, "content_block_stop", {"type": "content_block_stop", "index": text_index})
                    text_block_open = False
                bi = next_block_index
                next_block_index += 1
                tool_blocks[ti] = {
                    "id": tc.get("id", ""),
                    "name": tc.get("function", {}).get("name", ""),
                    "block_index": bi,
                }
                _sse(write_fn, "content_block_start", {
                    "type": "content_block_start",
                    "index": bi,
                    "content_block": {
                        "type": "tool_use",
                        "id": tool_blocks[ti]["id"],
                        "name": tool_blocks[ti]["name"],
                        "input": {},
                    },
                })
            func = tc.get("function", {})
            args = func.get("arguments", "")
            if args:
                _sse(write_fn, "content_block_delta", {
                    "type": "content_block_delta",
                    "index": tool_blocks[ti]["block_index"],
                    "delta": {"type": "input_json_delta", "partial_json": args},
                })


def simulate_stream(openai_resp, write_fn):
    """Convert a non-streaming OpenAI response into Anthropic SSE events."""
    model = openai_resp.get("model", "unknown")
    msg_id = openai_resp.get("id", "msg_proxy")
    choices = openai_resp.get("choices") or [{}]
    choice = choices[0] if choices else {}
    message = choice.get("message", {}) if isinstance(choice, dict) else {}
    usage = openai_resp.get("usage", {})

    _sse(write_fn, "message_start", {
        "type": "message_start",
        "message": {
            "id": msg_id, "type": "message", "role": "assistant",
            "model": model, "content": [], "stop_reason": None,
            "stop_sequence": None,
            "usage": {"input_tokens": usage.get("prompt_tokens", 0), "output_tokens": 0},
        },
    })

    block_index = 0

    # Text content
    text = message.get("content")
    if text:
        _sse(write_fn, "content_block_start", {
            "type": "content_block_start", "index": block_index,
            "content_block": {"type": "text", "text": ""},
        })
        _sse(write_fn, "content_block_delta", {
            "type": "content_block_delta", "index": block_index,
            "delta": {"type": "text_delta", "text": text},
        })
        _sse(write_fn, "content_block_stop", {"type": "content_block_stop", "index": block_index})
        block_index += 1

    # Tool calls
    for tc in message.get("tool_calls") or []:
        if not isinstance(tc, dict):
            continue
        func = tc.get("function", {})
        _sse(write_fn, "content_block_start", {
            "type": "content_block_start", "index": block_index,
            "content_block": {
                "type": "tool_use", "id": tc.get("id", ""), "name": func.get("name", ""), "input": {},
            },
        })
        args = func.get("arguments", "{}")
        if args:
            _sse(write_fn, "content_block_delta", {
                "type": "content_block_delta", "index": block_index,
                "delta": {"type": "input_json_delta", "partial_json": args},
            })
        _sse(write_fn, "content_block_stop", {"type": "content_block_stop", "index": block_index})
        block_index += 1

    stop_reason = STOP_MAP.get(choice.get("finish_reason"), choice.get("finish_reason") or "end_turn")
    _sse(write_fn, "message_delta", {
        "type": "message_delta",
        "delta": {"stop_reason": stop_reason},
        "usage": {"output_tokens": usage.get("completion_tokens", 0)},
    })
    _sse(write_fn, "message_stop", {"type": "message_stop"})


def _sse(write_fn, event, data):
    write_fn(f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n")


def _iter_lines(resp):
    """Yield lines from an http.client.HTTPResponse."""
    buf = b""
    while True:
        try:
            chunk = resp.read(4096)
        except (socket.timeout, OSError) as e:
            log.warning(f"Error reading response: {e}")
            if buf:
                yield buf.decode("utf-8", errors="replace")
            break

        if not chunk:
            if buf:
                yield buf.decode("utf-8", errors="replace")
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            yield line.decode("utf-8", errors="replace")


# ---------- HTTP handler ----------

class ProxyHandler(BaseHTTPRequestHandler):
    """HTTP request handler for the Anthropic proxy."""

    def _send_json_error(self, status, message):
        """Send a JSON error response."""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        error_body = json.dumps({"error": {"type": "proxy_error", "message": message}})
        self.wfile.write(error_body.encode())

    def do_HEAD(self):
        self.send_response(200)
        self.end_headers()

    def _handle_agent_task(self):
        """POST /v1/agent/task — run claude -p and stream output as SSE."""
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""

        try:
            req = json.loads(body)
        except json.JSONDecodeError as e:
            self._send_json_error(400, f"Invalid JSON: {e}")
            return

        prompt = req.get("prompt", "")
        model = req.get("model", "claude-sonnet-4-6")
        working_dir = req.get("working_dir")

        if not prompt:
            self._send_json_error(400, "prompt is required")
            return

        task_id = uuid.uuid4().hex[:8]
        cmd = [
            "claude", "-p", prompt,
            "--model", model,
            "--output-format", "stream-json",
            "--permission-mode", "bypassPermissions",
            "--verbose",
        ]

        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=working_dir,
                text=True,
            )
        except Exception as e:
            self._send_json_error(500, f"Failed to start claude: {e}")
            return

        with _agent_tasks_lock:
            _agent_tasks[task_id] = {"pid": proc.pid, "process": proc}

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.send_header("X-Task-Id", task_id)
        self.end_headers()

        def write_sse(event, data):
            self.wfile.write(f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n".encode())
            self.wfile.flush()

        try:
            write_sse("task_started", {"task_id": task_id, "pid": proc.pid})

            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                    write_sse(event.get("type", "message"), event)
                except json.JSONDecodeError:
                    write_sse("log", {"text": line})

            proc.wait()
            stderr_out = proc.stderr.read() if proc.stderr else ""

            write_sse("task_finished", {
                "task_id": task_id,
                "exit_code": proc.returncode,
                "stderr": stderr_out[:1000] if stderr_out else "",
            })
        except (BrokenPipeError, ConnectionResetError):
            _kill_process(proc)
        except Exception as e:
            log.exception("Error streaming agent task")
            try:
                write_sse("error", {"message": str(e)})
            except Exception:
                pass
            _kill_process(proc)
        finally:
            with _agent_tasks_lock:
                _agent_tasks.pop(task_id, None)

    def _handle_agent_cancel(self, task_id):
        """POST /v1/agent/task/<id>/cancel — kill a running agent task."""
        with _agent_tasks_lock:
            task = _agent_tasks.get(task_id)

        if not task:
            self._send_json_error(404, f"No active task '{task_id}'")
            return

        _kill_process(task["process"])

        out = json.dumps({"task_id": task_id, "status": "cancelled"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_POST(self):
        path = self.path.split("?")[0]

        if path == "/v1/agent/task":
            self._handle_agent_task()
            return

        if path.startswith("/v1/agent/task/") and path.endswith("/cancel"):
            parts = path.split("/")
            if len(parts) == 6:
                self._handle_agent_cancel(parts[4])
                return

        if path != "/v1/messages":
            self._send_json_error(404, "Not found")
            return

        length = int(self.headers.get("Content-Length", 0))

        # Check body size limit
        if length > MAX_BODY_SIZE:
            self._send_json_error(413, f"Request body too large (max {MAX_BODY_SIZE} bytes)")
            return

        body = self.rfile.read(length) if length else b""

        try:
            anthropic_req = json.loads(body)
        except json.JSONDecodeError as e:
            self._send_json_error(400, f"Invalid JSON: {e}")
            return

        client_wants_stream = anthropic_req.get("stream", False)
        model = anthropic_req.get("model", "auto")

        # Direct path for Claude models -> Vertex AI (native Anthropic format)
        # Bypasses semantic router. Enable via config for debugging or fallback.
        if CLAUDE_DIRECT_BYPASS and is_claude_model(model):
            self._handle_claude_direct(anthropic_req, model, client_wants_stream)
            return

        # Standard path: convert to OpenAI → semantic router → Envoy
        try:
            openai_req = translate_request(anthropic_req)
        except ProxyError as e:
            self._send_json_error(400, str(e))
            return

        # Try streaming first if client wants it; fall back to non-streaming
        upstream_resp, conn = self._upstream_request(openai_req)
        if upstream_resp is None:
            return  # error already sent

        if upstream_resp.status != 200 and openai_req.get("stream"):
            # Streaming rejected — retry without streaming
            reject_body = upstream_resp.read().decode("utf-8", errors="replace")
            conn.close()
            log.info(f"Streaming rejected by upstream (status={upstream_resp.status}): {reject_body[:200]}")
            log.info("Retrying without streaming")
            openai_req["stream"] = False
            upstream_resp, conn = self._upstream_request(openai_req)
            if upstream_resp is None:
                return

        if upstream_resp.status != 200:
            error_body = upstream_resp.read().decode("utf-8", errors="replace")
            log.warning(f"Upstream error (status={upstream_resp.status}): {error_body[:500]}")
            body = json.dumps({"error": {"type": "proxy_error", "message": f"Upstream error: {error_body}"}})
            self.send_response(upstream_resp.status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body.encode())
            conn.close()
            return

        is_real_stream = openai_req.get("stream", False)

        if client_wants_stream:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()

            def write_fn(s):
                try:
                    self.wfile.write(s.encode())
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    raise

            try:
                if is_real_stream:
                    translate_stream(upstream_resp, write_fn)
                else:
                    # Upstream returned non-streaming — simulate SSE
                    raw = upstream_resp.read().decode("utf-8", errors="replace")
                    try:
                        openai_resp = json.loads(raw)
                    except json.JSONDecodeError as e:
                        log.error(f"Failed to parse non-streaming response: {e}")
                        return
                    simulate_stream(openai_resp, write_fn)
            except (BrokenPipeError, ConnectionResetError):
                pass  # Client disconnected
            except Exception as e:
                log.exception("Error during streaming")
        else:
            raw = upstream_resp.read().decode("utf-8", errors="replace")
            try:
                openai_resp = json.loads(raw)
            except json.JSONDecodeError as e:
                self._send_json_error(502, f"Bad upstream response: {raw[:200]}")
                conn.close()
                return

            try:
                anthropic_resp = translate_response(openai_resp)
            except ProxyError as e:
                self._send_json_error(502, f"Failed to translate response: {e}")
                conn.close()
                return

            out = json.dumps(anthropic_resp).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        conn.close()

    def _handle_claude_direct(self, req, model, stream):
        """Forward request directly to Vertex AI in native Anthropic format.

        Bypasses the OpenAI format conversion entirely, preserving tool
        definitions in the format that Vertex AI Claude models understand.
        """
        model_id = get_vertex_model_id(model)
        path = (
            f"/v1/projects/{GCP_PROJECT_ID}/locations/{VERTEX_REGION}"
            f"/publishers/anthropic/models/{model_id}:rawPredict"
        )

        token = get_gcp_token()
        if not token:
            self._send_json_error(502, "Failed to obtain GCP access token")
            return

        # Prepare body: keep Anthropic format, add vertex version, strip unsupported fields
        body = dict(req)
        body.pop("model", None)
        body["anthropic_version"] = "vertex-2023-10-16"
        # Strip fields that Vertex AI rawPredict does not support
        for key in ("context_management",):
            body.pop(key, None)
        payload = json.dumps(body).encode()

        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
            "Content-Length": str(len(payload)),
        }

        read_timeout = config.get("timeouts", {}).get("http_request", 600)
        log.info(f"Claude direct → Vertex AI: model={model_id} stream={stream} tools={len(req.get('tools', []))}")

        try:
            ctx = ssl.create_default_context()
            conn = http.client.HTTPSConnection(VERTEX_HOST, 443, timeout=10, context=ctx)
            conn.request("POST", path, body=payload, headers=headers)
            if conn.sock:
                conn.sock.settimeout(read_timeout)
            resp = conn.getresponse()
        except socket.timeout:
            self._send_json_error(504, "Vertex AI connection timeout")
            return
        except Exception as e:
            log.exception("Vertex AI connection error")
            self._send_json_error(502, f"Vertex AI connection error: {e}")
            return

        if resp.status != 200:
            error_body = resp.read().decode("utf-8", errors="replace")
            log.warning(f"Vertex AI error (status={resp.status}): {error_body[:500]}")
            body = json.dumps({"error": {"type": "vertex_error", "message": error_body[:500]}})
            self.send_response(resp.status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body.encode())
            conn.close()
            return

        if stream:
            # Pass through Anthropic SSE from Vertex AI as-is
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                while True:
                    chunk = resp.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            # Pass through Anthropic JSON response as-is
            response_body = resp.read()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
            self.wfile.write(response_body)

        conn.close()

    def _upstream_request(self, openai_req):
        """Send request to upstream, return (response, connection) or (None, None) on error."""
        conn_timeout = config.get("timeouts", {}).get("upstream_connect", 10)
        read_timeout = config.get("timeouts", {}).get("http_request", 600)
        body = json.dumps(openai_req).encode()
        try:
            conn = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=conn_timeout)
            conn.request(
                "POST", "/v1/chat/completions", body=body,
                headers={"Content-Type": "application/json", "Content-Length": str(len(body))},
            )
            # Switch to read timeout before waiting for response (LLM calls can take minutes)
            if conn.sock:
                conn.sock.settimeout(read_timeout)
            resp = conn.getresponse()
            return resp, conn
        except socket.timeout:
            self._send_json_error(504, "Upstream connection timeout")
            return None, None
        except OSError as e:
            self._send_json_error(502, f"Cannot connect to upstream: {e}")
            return None, None
        except Exception as e:
            log.exception("Unexpected error connecting to upstream")
            self._send_json_error(502, f"Proxy error: {e}")
            return None, None

    def do_GET(self):
        path = self.path.split("?")[0]

        if path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
            return

        if path == "/v1/models":
            models = [{"id": m, "object": "model", "owned_by": "vllm-sr"} for m in KNOWN_MODELS]
            response = json.dumps({"object": "list", "data": models}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)
            return

        if path == "/v1/agent/tasks":
            with _agent_tasks_lock:
                tasks = {tid: {"pid": t["pid"]} for tid, t in _agent_tasks.items()}
            response = json.dumps(tasks).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)
            return

        self._send_json_error(404, "Not found")

    def log_message(self, fmt, *args):
        """Log all requests for debugging."""
        log.info(f"{self.address_string()} - {fmt % args}")


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    port = int(os.getenv("PORT", config.get("network", {}).get("ports", {}).get("anthropic_proxy", 8819)))
    host = config.get("network", {}).get("internal_bind_host", "0.0.0.0")

    server = ThreadedHTTPServer((host, port), ProxyHandler)
    log.info(f"Anthropic-to-OpenAI proxy listening on {host}:{port}")
    log.info(f"Upstream: {UPSTREAM_HOST}:{UPSTREAM_PORT}")
    log.info(f"Known models: {KNOWN_MODELS}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down...")
        server.shutdown()
