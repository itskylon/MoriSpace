#!/usr/bin/env python3
"""Read-only Codex quota export and loopback service for Mori Space's widget.

Protocol: https://learn.chatgpt.com/docs/app-server#auth-endpoints
Only initialize, initialized, and account/rateLimits/read are sent. The official
CLI owns authentication; this program never opens credential files, creates a
conversation, consumes reset credits, or persists raw RPC responses.
"""
import argparse
from collections import deque
import http.client
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import math
import os
from pathlib import Path
import re
import selectors
import signal
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

SNAPSHOT_NAME = "usage-widget-v1.json"
MAX_AGE = 900
MAX_BYTES = 1024 * 1024
MAX_TIMESTAMP = 253_402_300_799
MAX_WINDOWS = 64
DEFAULT_TIMEOUT = 20.0
SERVICE_PORT = 48763
COLLECTION_INTERVAL = 300
MAX_REQUEST_BYTES = 16_384
MAX_REQUESTS_PER_MINUTE = 120
ID_PATTERN = re.compile(r"[A-Za-z0-9_.-]{1,128}\Z")
RELAY_CONFIG_NAME = "relay-config.json"
RELAY_CONFIG_MAX_BYTES = 8192
RELAY_MAX_BYTES = 65_536
RELAY_RESPONSE_MAX_BYTES = 8192
RELAY_TIMEOUT = 8.0


class UsageError(Exception):
    """Only fixed, non-sensitive categories may cross the command boundary."""
    def __init__(self, category):
        self.category = category
        super().__init__(category)


def finite_number(value):
    try:
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    except OverflowError:
        return False


def timestamp(value):
    if not finite_number(value) or not 0 < value <= MAX_TIMESTAMP:
        raise UsageError("invalid-data")
    return value


def percent(value):
    if value is not None and (not finite_number(value) or not 0 <= value <= 100):
        raise UsageError("invalid-data")
    return value


def minutes(value):
    if value is not None and (not isinstance(value, int) or isinstance(value, bool) or not 0 < value <= 2**63 - 1):
        raise UsageError("invalid-data")
    return value


def window_label(bucket, period, duration):
    name = "Codex" if bucket == "codex" else bucket[:60]
    if duration is None:
        interval = "主额度" if period == "primary" else "次额度"
    elif duration % 1440 == 0:
        interval = str(duration // 1440) + " 天"
    elif duration % 60 == 0:
        interval = str(duration // 60) + " 小时"
    else:
        interval = str(duration) + " 分钟"
    return name + " · " + interval


def safe_text(value, maximum):
    return (isinstance(value, str) and bool(value.strip()) and len(value) <= maximum
            and not any(unicodedata.category(character) in {"Cc", "Cf"} for character in value))


def parse_rate_limits(result, fetched_at, now=None):
    now = time.time() if now is None else now
    timestamp(fetched_at)
    if fetched_at > now or not isinstance(result, dict) or not {"rateLimits", "rateLimitsByLimitId"}.intersection(result):
        raise UsageError("invalid-data")
    buckets = result.get("rateLimitsByLimitId")
    if buckets is not None and not isinstance(buckets, dict):
        raise UsageError("invalid-data")
    if not buckets:
        legacy = result.get("rateLimits")
        if legacy is None:
            buckets = {}
        elif isinstance(legacy, dict):
            buckets = {legacy.get("limitId") or "codex": legacy}
        else:
            raise UsageError("invalid-data")
    windows = []
    if any(not isinstance(key, str) for key in buckets):
        raise UsageError("invalid-data")
    for bucket in sorted(buckets, key=lambda key: (key != "codex", key)):
        limits = buckets[bucket]
        if limits is None:
            continue
        if not ID_PATTERN.fullmatch(bucket) or not isinstance(limits, dict):
            raise UsageError("invalid-data")
        for period in ("primary", "secondary"):
            source = limits.get(period)
            if source is None:
                continue
            if not isinstance(source, dict):
                raise UsageError("invalid-data")
            duration = minutes(source.get("windowDurationMins"))
            resets_at = source.get("resetsAt")
            if resets_at is not None:
                timestamp(resets_at)
            windows.append({
                "id": bucket + ":" + period,
                "label": window_label(bucket, period, duration),
                "usedPercent": percent(source.get("usedPercent")),
                "windowMinutes": duration,
                "resetsAt": resets_at,
            })
            if len(windows) > MAX_WINDOWS:
                raise UsageError("invalid-data")
    timestamp(fetched_at + MAX_AGE)
    return {"version": 1, "fetchedAt": fetched_at, "validUntil": fetched_at + MAX_AGE,
            "status": "ready" if windows else "unavailable", "windows": windows}


def valid_snapshot(value, now):
    """Only preserve our exact whitelist schema, including stale snapshots."""
    try:
        if not isinstance(value, dict) or set(value) != {"version", "fetchedAt", "validUntil", "status", "windows"}:
            return False
        if value["version"] != 1 or isinstance(value["version"], bool):
            return False
        if value["status"] not in {"ready", "notConnected", "unavailable"}:
            return False
        fetched = timestamp(value["fetchedAt"])
        until = timestamp(value["validUntil"])
        if fetched > now or not fetched <= until <= fetched + MAX_AGE:
            return False
        if not isinstance(value["windows"], list) or len(value["windows"]) > MAX_WINDOWS or (value["status"] != "ready" and value["windows"]):
            return False
        seen = set()
        for window in value["windows"]:
            if (not isinstance(window, dict) or not {"id", "label"}.issubset(window)
                    or not set(window).issubset({"id", "label", "usedPercent", "windowMinutes", "resetsAt"})):
                return False
            identifier = window["id"]
            if not safe_text(identifier, 160) or identifier in seen:
                return False
            seen.add(identifier)
            # Swift's Codable omits optional nil properties when encoding its
            # shared snapshot. Accept missing keys as well as explicit nulls.
            minutes(window.get("windowMinutes"))
            percent(window.get("usedPercent"))
            if window.get("resetsAt") is not None:
                timestamp(window["resetsAt"])
            if not safe_text(window["label"], 120):
                return False
        return True
    except (UsageError, KeyError, TypeError, ValueError):
        return False


def validate_output(output):
    output = Path(output)
    if not output.is_absolute() or output.name != SNAPSHOT_NAME:
        raise UsageError("invalid-output")
    # Refuse symlinks, including ancestors, and only write within a user-owned directory.
    if output.resolve() != output or not output.parent.is_dir() or output.parent.stat().st_uid != os.getuid():
        raise UsageError("invalid-output")
    if output.exists() and (not output.is_file() or output.stat().st_uid != os.getuid()):
        raise UsageError("invalid-output")
    return output


def atomic_write(output, value):
    output = validate_output(output)
    data = (json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n").encode()
    descriptor, temporary = tempfile.mkstemp(prefix=".mori-usage-", suffix=".tmp", dir=output.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, output)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def preserve_or_unavailable(output, now):
    output = validate_output(output)
    try:
        if output.stat().st_size <= MAX_BYTES:
            with output.open("rb") as handle:
                data = handle.read(MAX_BYTES + 1)
            previous = json.loads(data) if len(data) <= MAX_BYTES else None
            if previous is not None and valid_snapshot(previous, now):
                return "preserved"
    except (OSError, ValueError, UnicodeDecodeError):
        pass
    atomic_write(output, {"version": 1, "fetchedAt": now, "validUntil": now,
                          "status": "unavailable", "windows": []})
    return "unavailable"


def stop_process(process, grace):
    if process.stdin:
        try:
            process.stdin.close()
        except OSError:
            pass
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=grace / 2)
    except subprocess.TimeoutExpired:
        pass
    # Reap the parent and terminate any descendants in this dedicated process group.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=grace / 2)
    except subprocess.TimeoutExpired:
        raise UsageError("cleanup-failed") from None
    finally:
        if process.stdout:
            process.stdout.close()


def read_limits(codex, timeout=DEFAULT_TIMEOUT, cancel_event=None):
    executable = Path(codex)
    if not executable.is_absolute() or not executable.is_file() or not os.access(executable, os.X_OK):
        raise UsageError("cli-unavailable")
    if not finite_number(timeout) or not 0 < timeout <= DEFAULT_TIMEOUT:
        raise UsageError("invalid-timeout")
    grace = min(1.0, timeout / 4)
    deadline = time.monotonic() + timeout - grace
    selector = selectors.DefaultSelector()
    process = None
    try:
        if cancel_event is not None and cancel_event.is_set():
            raise UsageError("cancelled")
        process = subprocess.Popen([str(executable), "app-server", "--stdio"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
        selector.register(process.stdout, selectors.EVENT_READ)

        def send(message):
            process.stdin.write((json.dumps(message) + "\n").encode())
            process.stdin.flush()

        send({"id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "mori_usage_helper", "version": "1.0.0"},
            "capabilities": {"experimentalApi": True}}})
        initialized = False
        buffer = b""
        received = 0
        while time.monotonic() < deadline:
            if cancel_event is not None and cancel_event.is_set():
                raise UsageError("cancelled")
            if not selector.select(timeout=min(0.1, max(0, deadline - time.monotonic()))):
                continue
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                raise UsageError("cli-exited")
            received += len(chunk)
            if received > MAX_BYTES:
                raise UsageError("invalid-data")
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except (ValueError, UnicodeDecodeError):
                    raise UsageError("invalid-data") from None
                if not isinstance(message, dict):
                    continue
                # Ignore unsolicited notifications: they can contain account metadata.
                if message.get("id") == 1 and not initialized:
                    if "error" in message or not isinstance(message.get("result"), dict):
                        raise UsageError("initialize-failed")
                    initialized = True
                    send({"method": "initialized"})
                    send({"id": 2, "method": "account/rateLimits/read", "params": {}})
                elif message.get("id") == 2 and initialized:
                    if "error" in message or not isinstance(message.get("result"), dict):
                        raise UsageError("read-failed")
                    return message["result"]
        raise UsageError("timeout")
    except (OSError, subprocess.SubprocessError):
        raise UsageError("transport-failed") from None
    finally:
        selector.close()
        if process is not None:
            stop_process(process, grace)


def validate_relay_config(value):
    """Only an explicit HTTPS endpoint and a separate write-only token are accepted."""
    if (not isinstance(value, dict) or set(value) != {"version", "baseURL", "writeToken"}
            or type(value["version"]) is not int or value["version"] != 1
            or not isinstance(value["writeToken"], str)
            or not re.fullmatch(r"[0-9a-fA-F]{64}", value["writeToken"])):
        raise UsageError("relay-config-invalid")
    base = value["baseURL"]
    if (not isinstance(base, str) or not 1 <= len(base) <= 2048
            or any(character.isspace() or ord(character) < 32 for character in base)
            or any(character in base for character in "\\?#")):
        raise UsageError("relay-config-invalid")
    try:
        parts = urllib.parse.urlsplit(base)
        if (parts.scheme != "https" or not parts.hostname or parts.username is not None
                or parts.password is not None or parts.query or parts.fragment
                or (parts.port is not None and not 1 <= parts.port <= 65535)
                or not re.fullmatch(r"[A-Za-z0-9.:-]+", parts.hostname)
                or parts.netloc.endswith(":")):
            raise ValueError()
        prefix = parts.path.rstrip("/")
        if (parts.path not in {"", "/"} and ("//" in parts.path
                or not re.fullmatch(r"(?:/[A-Za-z0-9._~-]+)+/?", parts.path)
                or any(segment in {".", ".."} for segment in prefix.split("/")))):
            raise ValueError()
    except (ValueError, TypeError):
        raise UsageError("relay-config-invalid") from None
    return {"version": 1, "baseURL": urllib.parse.urlunsplit(("https", parts.netloc, prefix, "", "")),
            "writeToken": value["writeToken"]}


def read_relay_config(path=None, required=False):
    """Opt-in config lives beside the installed helper, never in the App Group."""
    path = Path(__file__).absolute().with_name(RELAY_CONFIG_NAME) if path is None else Path(path)
    descriptor = None
    try:
        if not path.is_absolute() or path.resolve() != path:
            raise UsageError("relay-config-invalid")
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            if not required:
                return None
            raise UsageError("relay-config-invalid") from None
        parent = path.parent.stat()
        if (not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o022
                or not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
                or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_size > RELAY_CONFIG_MAX_BYTES):
            raise UsageError("relay-config-invalid")
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        opened = os.fstat(descriptor)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid()
                or stat.S_IMODE(opened.st_mode) != 0o600 or opened.st_size > RELAY_CONFIG_MAX_BYTES):
            raise UsageError("relay-config-invalid")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = None
            data = handle.read(RELAY_CONFIG_MAX_BYTES + 1)
        if len(data) > RELAY_CONFIG_MAX_BYTES:
            raise UsageError("relay-config-invalid")
        return validate_relay_config(json.loads(data))
    except (OSError, ValueError, UnicodeDecodeError):
        raise UsageError("relay-config-invalid") from None
    finally:
        if descriptor is not None:
            os.close(descriptor)


class NoRelayRedirect(urllib.request.HTTPRedirectHandler):
    def http_error_301(self, request, response, code, message, headers):
        response.close()
        raise UsageError("relay-redirect-rejected")

    http_error_302 = http_error_301
    http_error_303 = http_error_301
    http_error_307 = http_error_301
    http_error_308 = http_error_301


def relay_opener():
    # Use the default trust store and hostname validation. No ambient proxy,
    # insecure context, or redirects can divert the write token.
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRelayRedirect(),
                                      urllib.request.HTTPSHandler(context=ssl.create_default_context()))


def upload_snapshot(snapshot, config, now=None, opener=None):
    """Send only our validated quota whitelist; discard every bounded response."""
    now = time.time() if now is None else now
    config = validate_relay_config(config)
    if not valid_snapshot(snapshot, now):
        raise UsageError("relay-data-invalid")
    data = json.dumps(snapshot, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode()
    if len(data) > RELAY_MAX_BYTES:
        raise UsageError("relay-data-too-large")
    request = urllib.request.Request(config["baseURL"] + "/v1/usage", data=data, method="PUT", headers={
        "Authorization": "Bearer " + config["writeToken"], "Content-Type": "application/json",
        "Accept": "application/json", "Connection": "close", "User-Agent": "MoriUsage/1"})
    deadline = time.monotonic() + RELAY_TIMEOUT
    try:
        with (relay_opener() if opener is None else opener).open(request, timeout=RELAY_TIMEOUT) as response:
            if not 200 <= response.status < 300:
                raise UsageError("relay-http-failed")
            length = response.headers.get("Content-Length")
            if length is not None and (not length.isascii() or not length.isdigit()
                                       or len(length) > 10 or int(length) > RELAY_RESPONSE_MAX_BYTES):
                raise UsageError("relay-response-too-large")
            received = 0
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise UsageError("relay-timeout")
                # read1 avoids waiting for the complete declared body and lets a
                # drip-fed body be checked against the deadline after each read.
                connection = getattr(getattr(getattr(response, "fp", None), "raw", None), "_sock", None)
                if connection is not None:
                    connection.settimeout(remaining)
                chunk = response.read1(min(4096, RELAY_RESPONSE_MAX_BYTES + 1 - received))
                received += len(chunk)
                if received > RELAY_RESPONSE_MAX_BYTES:
                    raise UsageError("relay-response-too-large")
                if not chunk:
                    break
    except urllib.error.HTTPError as error:
        error.close()
        raise UsageError("relay-http-failed") from None
    except TimeoutError:
        raise UsageError("relay-timeout") from None
    except (urllib.error.URLError, OSError, http.client.HTTPException):
        raise UsageError("relay-network-failed") from None


def run_once(codex, output, timeout=DEFAULT_TIMEOUT, reader=read_limits, clock=time.time, cancel_event=None,
             relay_loader=read_relay_config, uploader=upload_snapshot):
    output = validate_output(output)
    try:
        upstream = reader(codex, timeout=timeout)
        if cancel_event is not None and cancel_event.is_set():
            raise UsageError("cancelled")
        fetched = clock()
        snapshot = parse_rate_limits(upstream, fetched, now=fetched)
        atomic_write(output, snapshot)
    except UsageError as error:
        preserve_or_unavailable(output, clock())
        return error.category
    # Cloud failure never changes this successful local reading. No config means
    # no outbound upload; the next successful collection retries the latest data.
    try:
        config = relay_loader()
        if config is not None:
            if cancel_event is not None and cancel_event.is_set():
                return "cancelled"
            uploader(snapshot, config, now=fetched)
    except UsageError as error:
        return error.category
    return None


def cached_snapshot(output, now=None):
    """Never serve raw contents: read a bounded file and validate the whitelist."""
    now = time.time() if now is None else now
    try:
        output = validate_output(output)
        with output.open("rb") as handle:
            data = handle.read(MAX_BYTES + 1)
        if len(data) <= MAX_BYTES:
            snapshot = json.loads(data)
            if valid_snapshot(snapshot, now):
                return snapshot
    except (UsageError, OSError, ValueError, UnicodeDecodeError):
        pass
    return {"version": 1, "fetchedAt": now, "validUntil": now, "status": "unavailable", "windows": []}


class BoundedRequestReader:
    """Bound the whole request header, not just individual header lines."""
    def __init__(self, stream, connection):
        self.stream = stream
        self.connection = connection
        self.remaining = MAX_REQUEST_BYTES
        self.deadline = time.monotonic() + 2.0

    def readline(self, size=-1):
        requested = self.remaining + 1 if size < 0 else min(size, self.remaining + 1)
        line = bytearray()
        while len(line) < requested:
            remaining_time = self.deadline - time.monotonic()
            if remaining_time <= 0:
                raise TimeoutError("request deadline")
            # An idle-socket timeout alone allows an endless trickle of bytes.
            # Check one bounded buffered byte at a time against a total deadline.
            self.connection.settimeout(remaining_time)
            byte = self.stream.read(1)
            if not byte:
                break
            self.remaining -= 1
            if self.remaining < 0:
                raise http.client.LineTooLong("request headers")
            line.extend(byte)
            if byte == b"\n":
                break
        return bytes(line)

    def close(self):
        self.stream.close()


class UsageHTTPServer(HTTPServer):
    allow_reuse_address = True
    request_queue_size = 8

    def __init__(self, output, port=SERVICE_PORT):
        self.output = validate_output(output)
        self.request_times = deque()
        # There is deliberately no configurable address or LAN listener.
        super().__init__(("127.0.0.1", port), UsageRequestHandler)

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(2.0)
        return connection, address

    def handle_error(self, request, client_address):
        # Never log request headers, paths, peer identity, or exception payloads.
        pass

    def accept_request_rate(self):
        now = time.monotonic()
        while self.request_times and self.request_times[0] <= now - 60:
            self.request_times.popleft()
        if len(self.request_times) >= MAX_REQUESTS_PER_MINUTE:
            return False
        self.request_times.append(now)
        return True


class UsageRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.rfile = BoundedRequestReader(self.rfile, self.connection)

    def version_string(self):
        return "MoriUsage/1"

    def log_message(self, format, *args):
        pass

    def send_error(self, code, message=None, explain=None):
        # Fixed body; BaseHTTPRequestHandler's default includes user input.
        self.reply(405 if code == 501 else code, {"error": "request-rejected"})

    def reply(self, code, payload):
        data = json.dumps(payload, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode()
        self.close_connection = True
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
        # No Access-Control-Allow-Origin or other CORS permission is emitted.
        self.end_headers()
        if getattr(self, "command", None) != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        port = self.server.server_port
        hosts = self.headers.get_all("Host", [])
        if (self.client_address[0] != "127.0.0.1" or len(hosts) != 1
                or hosts[0].lower() not in {"localhost:" + str(port), "127.0.0.1:" + str(port)}):
            self.reply(403, {"error": "request-rejected"})
            return
        # Only native local clients are supported. Deny browser-originated reads,
        # DNS rebinding and cross-site subresources even before the SOP/CORS layer.
        if ("Origin" in self.headers or "Referer" in self.headers
                or self.headers.get("Sec-Fetch-Site", "none") != "none"):
            self.reply(403, {"error": "request-rejected"})
            return
        if self.path != "/v1/usage":
            self.reply(404, {"error": "request-rejected"})
            return
        if "Transfer-Encoding" in self.headers or self.headers.get_all("Content-Length", []) not in ([], ["0"]):
            self.reply(400, {"error": "request-rejected"})
            return
        if not self.server.accept_request_rate():
            self.reply(429, {"error": "request-rejected"})
            return
        self.reply(200, cached_snapshot(self.server.output))


def serve(codex, output, port=SERVICE_PORT):
    if port != SERVICE_PORT:
        raise UsageError("invalid-port")
    stopped = threading.Event()
    server = UsageHTTPServer(output, port)

    def collect():
        while not stopped.is_set():
            try:
                reader = lambda executable, timeout: read_limits(executable, timeout, cancel_event=stopped)
                category = run_once(codex, output, reader=reader, cancel_event=stopped)
            except UsageError as error:
                category = error.category
            except Exception:
                category = "local-failure"
            if category and not stopped.is_set():
                print("codex-usage-helper: " + category, file=sys.stderr, flush=True)
            stopped.wait(COLLECTION_INTERVAL)

    collector = threading.Thread(target=collect, name="mori-usage-collector", daemon=False)
    try:
        collector.start()
        server.serve_forever(poll_interval=0.2)
    finally:
        stopped.set()
        server.server_close()
        # read_limits observes stop within 0.1 s, then kills/reaps its process
        # group. The collector is not abandoned with a running app-server.
        collector.join(timeout=DEFAULT_TIMEOUT + 1)
        if collector.is_alive():
            raise UsageError("cleanup-failed")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Export sanitized Codex quota once, or serve it read-only on local loopback.")
    parser.add_argument("--codex", required=True, help="Absolute path to the official Codex CLI")
    parser.add_argument("--output", required=True, help="Absolute path ending in " + SNAPSHOT_NAME)
    parser.add_argument("--serve", action="store_true", help="Run loopback service and collect every 300 seconds")
    parser.add_argument("--port", type=int, choices=[SERVICE_PORT], default=SERVICE_PORT, help="Fixed loopback service port")
    args = parser.parse_args(argv)

    def interrupted(_signal, _frame):
        # A second termination request must not interrupt child cleanup halfway.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        if args.serve:
            # HTTPServer deliberately catches ordinary Exception from handlers.
            # BaseException propagates through that boundary to the cleanup block.
            raise KeyboardInterrupt
        raise UsageError("cancelled")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        category = serve(args.codex, args.output, args.port) if args.serve else run_once(args.codex, args.output)
    except KeyboardInterrupt:
        category = "cancelled"
    except UsageError as error:
        category = error.category
    except Exception:
        category = "local-failure"
    if category:
        print("codex-usage-helper: " + category, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
