"""GCP access token server using Application Default Credentials.

Serves fresh access tokens on GET /token, auto-refreshing as needed.
Designed to run as a sidecar container on the vllm-sr-network.
"""

import json
import logging
import os
import time
import urllib.error
import urllib.parse
import urllib.request
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
        # Fallback to defaults if config file is missing or invalid
        config = {
            "gcp": {"token_refresh_margin": 60},
            "retries": {"gcp_token": {"max_attempts": 3, "backoff_base": 1.0, "backoff_max": 10.0}},
            "timeouts": {"token_fetch": 10},
            "logging": {"level": "INFO"},
            "network": {"internal_bind_host": "0.0.0.0", "ports": {"gcp_token_server": 8888}},
        }


def setup_logging():
    """Configure logging based on config."""
    log_level = config.get("logging", {}).get("level", "INFO")
    log_format = config.get("logging", {}).get(
        "format", "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    )
    logging.basicConfig(level=getattr(logging, log_level), format=log_format)
    return logging.getLogger("gcp-token-server")


# Load ADC credentials (mounted at /adc/application_default_credentials.json)
ADC_PATH = "/adc/application_default_credentials.json"

# Cache the token with its expiry
_cached_token = None
_cached_expiry = 0


class TokenServerError(Exception):
    """Custom exception for token server errors."""
    pass


def load_adc_credentials():
    """Load ADC credentials from file with error handling.

    Returns:
        tuple: (client_id, client_secret, refresh_token, token_uri)

    Raises:
        TokenServerError: If credentials file is missing or malformed.
    """
    try:
        with open(ADC_PATH) as f:
            creds = json.load(f)
    except FileNotFoundError:
        raise TokenServerError(f"ADC credentials file not found: {ADC_PATH}")
    except json.JSONDecodeError as e:
        raise TokenServerError(f"Invalid JSON in ADC credentials file: {e}")
    except PermissionError:
        raise TokenServerError(f"Permission denied reading ADC credentials file: {ADC_PATH}")

    required_fields = ["client_id", "client_secret", "refresh_token"]
    missing = [f for f in required_fields if f not in creds]
    if missing:
        raise TokenServerError(f"Missing required fields in ADC credentials: {missing}")

    return (
        creds["client_id"],
        creds["client_secret"],
        creds["refresh_token"],
        creds.get("token_uri", "https://oauth2.googleapis.com/token"),
    )


def get_access_token_with_retry(client_id, client_secret, refresh_token, token_uri):
    """Fetch access token from Google with retry logic.

    Args:
        client_id: OAuth client ID
        client_secret: OAuth client secret
        refresh_token: Refresh token
        token_uri: Token endpoint URI

    Returns:
        tuple: (access_token, expires_in_seconds)

    Raises:
        TokenServerError: If all retry attempts fail.
    """
    retry_config = config.get("retries", {}).get("gcp_token", {})
    max_attempts = retry_config.get("max_attempts", 3)
    backoff_base = retry_config.get("backoff_base", 1.0)
    backoff_max = retry_config.get("backoff_max", 10.0)
    timeout = config.get("timeouts", {}).get("token_fetch", 10)

    data = urllib.parse.urlencode({
        "client_id": client_id,
        "client_secret": client_secret,
        "refresh_token": refresh_token,
        "grant_type": "refresh_token",
    }).encode()

    req = urllib.request.Request(token_uri, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")

    last_error = None
    for attempt in range(max_attempts):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                result = json.load(resp)

            if "access_token" not in result:
                raise TokenServerError(f"No access_token in response: {result.keys()}")

            expires_in = result.get("expires_in", 3600)
            if not isinstance(expires_in, (int, float)) or expires_in <= 0:
                log.warning(f"Invalid expires_in value: {expires_in}, using default 3600")
                expires_in = 3600

            return result["access_token"], expires_in

        except urllib.error.HTTPError as e:
            last_error = f"HTTP {e.code}: {e.reason}"
            log.warning(f"Token fetch attempt {attempt + 1}/{max_attempts} failed: {last_error}")
            # Don't retry on 4xx errors (client errors)
            if 400 <= e.code < 500:
                raise TokenServerError(f"Token fetch failed with client error: {last_error}")
        except urllib.error.URLError as e:
            last_error = f"URL error: {e.reason}"
            log.warning(f"Token fetch attempt {attempt + 1}/{max_attempts} failed: {last_error}")
        except json.JSONDecodeError as e:
            last_error = f"Invalid JSON response: {e}"
            log.warning(f"Token fetch attempt {attempt + 1}/{max_attempts} failed: {last_error}")
        except TimeoutError:
            last_error = "Request timeout"
            log.warning(f"Token fetch attempt {attempt + 1}/{max_attempts} timed out")

        if attempt < max_attempts - 1:
            sleep_time = min(backoff_base * (2 ** attempt), backoff_max)
            log.info(f"Retrying in {sleep_time:.1f}s...")
            time.sleep(sleep_time)

    raise TokenServerError(f"All {max_attempts} attempts failed. Last error: {last_error}")


def get_access_token():
    """Get cached or fresh access token.

    Returns:
        str: Valid access token

    Raises:
        TokenServerError: If token cannot be obtained.
    """
    global _cached_token, _cached_expiry

    margin = config.get("gcp", {}).get("token_refresh_margin", 60)

    # Return cached token if still valid (with margin)
    if _cached_token and time.time() < _cached_expiry - margin:
        log.debug("Returning cached token")
        return _cached_token

    log.info("Fetching new access token from Google")
    client_id, client_secret, refresh_token, token_uri = load_adc_credentials()
    token, expires_in = get_access_token_with_retry(client_id, client_secret, refresh_token, token_uri)

    _cached_token = token
    _cached_expiry = time.time() + expires_in
    log.info(f"Token refreshed, expires in {expires_in}s at {time.ctime(_cached_expiry)}")

    return _cached_token


class TokenHandler(BaseHTTPRequestHandler):
    """HTTP request handler for token endpoint."""

    def _send_json_error(self, status, message):
        """Send a JSON error response."""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        error_body = json.dumps({"error": message, "status": status})
        self.wfile.write(error_body.encode())

    def do_GET(self):
        """Handle GET requests."""
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
            return

        if self.path != "/token":
            self._send_json_error(404, "Not found")
            return

        try:
            token = get_access_token()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.end_headers()
            self.wfile.write(token.encode())
            log.debug("Token served successfully")
        except TokenServerError as e:
            log.error(f"Token server error: {e}")
            self._send_json_error(500, str(e))
        except Exception as e:
            log.exception("Unexpected error serving token")
            self._send_json_error(500, f"Internal server error: {e}")

    def log_message(self, format, *args):
        """Override to use structured logging."""
        log.info(f"{self.address_string()} - {format % args}")


# Load config and setup logging on module load
load_config()
log = setup_logging()


if __name__ == "__main__":
    host = config.get("network", {}).get("internal_bind_host", "0.0.0.0")
    port = config.get("network", {}).get("ports", {}).get("gcp_token_server", 8888)

    # Validate ADC file exists on startup
    try:
        load_adc_credentials()
        log.info(f"ADC credentials loaded successfully from {ADC_PATH}")
    except TokenServerError as e:
        log.error(f"Failed to load ADC credentials: {e}")
        raise SystemExit(1)

    server = HTTPServer((host, port), TokenHandler)
    log.info(f"GCP token server listening on {host}:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down...")
        server.shutdown()
