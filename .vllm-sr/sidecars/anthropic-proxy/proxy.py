"""Anthropic-to-OpenAI translation proxy for vllm-sr.

Accepts Anthropic Messages API requests on /v1/messages,
translates to OpenAI Chat Completions format, forwards to
vllm-sr (Envoy), and translates streaming responses back.

Runs as a sidecar container on vllm-sr-network.
"""

import json
import logging
import os
import http.client
import socket
from http.server import HTTPServer, BaseHTTPRequestHandler
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
                "known_models": ["auto", "kimi-k2-5", "claude-sonnet"]
            },
            "timeouts": {"http_request": 300},
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
KNOWN_MODELS = set(config.get("models", {}).get("known_models", ["auto", "kimi-k2-5", "claude-sonnet"]))

# Request size limits
MAX_BODY_SIZE = 10 * 1024 * 1024  # 10MB


class ProxyError(Exception):
    """Custom exception for proxy errors."""
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

    def do_POST(self):
        path = self.path.split("?")[0]
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
            conn.close()
            log.info("Streaming rejected by upstream, retrying without streaming")
            openai_req["stream"] = False
            upstream_resp, conn = self._upstream_request(openai_req)
            if upstream_resp is None:
                return

        if upstream_resp.status != 200:
            self.send_response(upstream_resp.status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            error_body = upstream_resp.read().decode("utf-8", errors="replace")
            self._send_json_error(upstream_resp.status, f"Upstream error: {error_body}")
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

    def _upstream_request(self, openai_req):
        """Send request to upstream, return (response, connection) or (None, None) on error."""
        conn_timeout = config.get("timeouts", {}).get("upstream_connect", 30)
        read_timeout = config.get("timeouts", {}).get("http_request", 300)
        body = json.dumps(openai_req).encode()
        try:
            conn = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=conn_timeout)
            conn.request(
                "POST", "/v1/chat/completions", body=body,
                headers={"Content-Type": "application/json", "Content-Length": str(len(body))},
            )
            resp = conn.getresponse()
            # Set socket-level read timeout to prevent hangs on long streaming responses
            if conn.sock:
                conn.sock.settimeout(read_timeout)
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
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
            return

        if self.path == "/v1/models":
            # Return list of available models
            models = [{"id": m, "object": "model", "owned_by": "vllm-sr"} for m in KNOWN_MODELS]
            response = json.dumps({"object": "list", "data": models}).encode()
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


if __name__ == "__main__":
    port = int(os.getenv("PORT", config.get("network", {}).get("ports", {}).get("anthropic_proxy", 8819)))
    host = config.get("network", {}).get("internal_bind_host", "0.0.0.0")

    server = HTTPServer((host, port), ProxyHandler)
    log.info(f"Anthropic-to-OpenAI proxy listening on {host}:{port}")
    log.info(f"Upstream: {UPSTREAM_HOST}:{UPSTREAM_PORT}")
    log.info(f"Known models: {KNOWN_MODELS}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down...")
        server.shutdown()
