#!/usr/bin/env python3
"""Single-user, authenticated relay for sanitized quota snapshots only."""
import argparse
from collections import deque
import hmac
import http.client
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import re
import signal
import socket
from socketserver import ThreadingMixIn
import stat
import sys
import tempfile
import threading
import time

import snapshot

TOKEN_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
MAX_HEADER_BYTES = 16_384
HEADER_TIMEOUT = 2.0
BODY_TIMEOUT = 5.0
MAX_CONNECTIONS = 8


class RelayError(Exception):
    """Category-only errors: never include paths, secrets or request contents."""
    pass


class Conflict(RelayError):
    pass


class NoRecord(RelayError):
    pass


def validate_tokens(read_token, write_token):
    if (not isinstance(read_token, str) or not TOKEN_PATTERN.fullmatch(read_token)
            or not isinstance(write_token, str) or not TOKEN_PATTERN.fullmatch(write_token)
            or hmac.compare_digest(read_token, write_token)):
        raise RelayError("invalid-token-config")
    return read_token, write_token


def load_tokens(config=None, environ=None):
    environ = os.environ if environ is None else environ
    if config:
        if "MORI_USAGE_READ_TOKEN" in environ or "MORI_USAGE_WRITE_TOKEN" in environ:
            raise RelayError("ambiguous-token-config")
        path = Path(config)
        if not path.is_absolute() or path.resolve() != path:
            raise RelayError("invalid-token-config")
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as handle:
            attributes = os.fstat(handle.fileno())
            if (not stat.S_ISREG(attributes.st_mode) or stat.S_IMODE(attributes.st_mode) != 0o600
                    or attributes.st_uid != os.getuid() or attributes.st_size > 4096):
                raise RelayError("invalid-token-config")
            raw = handle.read(4097)
        try:
            value = json.loads(raw, object_pairs_hook=snapshot.unique_object)
            if (not isinstance(value, dict) or set(value) != {"version", "readToken", "writeToken"}
                    or value["version"] != 1 or isinstance(value["version"], bool)):
                raise ValueError()
        except (ValueError, TypeError, UnicodeError):
            raise RelayError("invalid-token-config") from None
        return validate_tokens(value["readToken"], value["writeToken"])
    return validate_tokens(environ.get("MORI_USAGE_READ_TOKEN"), environ.get("MORI_USAGE_WRITE_TOKEN"))


class SnapshotStore:
    def __init__(self, directory, clock=time.time):
        self.directory = Path(directory)
        if not self.directory.is_absolute() or self.directory.resolve() != self.directory:
            raise RelayError("invalid-data-directory")
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        attributes = self.directory.stat()
        if not stat.S_ISDIR(attributes.st_mode) or attributes.st_uid != os.getuid() or attributes.st_mode & 0o022:
            raise RelayError("invalid-data-directory")
        self.file = self.directory / "usage-widget-v1.json"
        self.clock = clock
        self.lock = threading.Lock()

    def _read(self):
        try:
            descriptor = os.open(self.file, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            raise NoRecord("no-record") from None
        with os.fdopen(descriptor, "rb") as handle:
            attributes = os.fstat(handle.fileno())
            if not stat.S_ISREG(attributes.st_mode) or attributes.st_uid != os.getuid() or attributes.st_size > snapshot.MAX_BYTES:
                raise RelayError("storage-unavailable")
            try:
                return snapshot.decode(handle.read(snapshot.MAX_BYTES + 1), self.clock())
            except snapshot.InvalidSnapshot:
                raise RelayError("storage-unavailable") from None

    def read(self):
        with self.lock:
            return self._read()

    def publish(self, incoming):
        value = snapshot.validate(incoming, self.clock())
        data = snapshot.encode(value, self.clock())
        with self.lock:
            try:
                current = self._read()
            except NoRecord:
                current = None
            if current is not None:
                if value["fetchedAt"] < current["fetchedAt"]:
                    raise Conflict("older-record")
                if value["fetchedAt"] == current["fetchedAt"]:
                    if value == current:
                        return  # An exact retry is idempotent; original file/time stays untouched.
                    raise Conflict("conflicting-record")
            descriptor, temporary = tempfile.mkstemp(prefix=".usage-", suffix=".tmp", dir=self.directory)
            try:
                os.fchmod(descriptor, 0o600)
                with os.fdopen(descriptor, "wb") as handle:
                    handle.write(data)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(temporary, self.file)
                directory_fd = os.open(self.directory, os.O_RDONLY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
            finally:
                try:
                    os.unlink(temporary)
                except FileNotFoundError:
                    pass


class BoundedInput:
    def __init__(self, stream, connection, stopping):
        self.stream, self.connection, self.stopping = stream, connection, stopping
        self.remaining = MAX_HEADER_BYTES
        self.deadline = time.monotonic() + HEADER_TIMEOUT

    def check_time(self, deadline):
        remaining = deadline - time.monotonic()
        if self.stopping.is_set() or remaining <= 0:
            raise TimeoutError()
        self.connection.settimeout(remaining)

    def readline(self, size=-1):
        requested = self.remaining + 1 if size < 0 else min(size, self.remaining + 1)
        line = bytearray()
        while len(line) < requested:
            self.check_time(self.deadline)
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

    def body(self, size):
        deadline = time.monotonic() + BODY_TIMEOUT
        data = bytearray()
        while len(data) < size:
            self.check_time(deadline)
            chunk = self.stream.read1(min(8192, size - len(data)))
            if not chunk:
                raise RelayError("incomplete-body")
            data.extend(chunk)
        return bytes(data)

    def close(self):
        self.stream.close()


class RelayServer(ThreadingMixIn, HTTPServer):
    allow_reuse_address = True
    daemon_threads = False
    request_queue_size = MAX_CONNECTIONS

    def __init__(self, address, store, read_token, write_token):
        self.read_token, self.write_token = validate_tokens(read_token, write_token)
        self.store = store
        self.stopping = threading.Event()
        self.slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
        self.connections = set()
        self.state_lock = threading.Lock()
        self.request_times = {"read": deque(), "write": deque()}
        super().__init__(address, RelayHandler)

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(HEADER_TIMEOUT)
        return connection, address

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        with self.state_lock:
            self.connections.add(request)
        try:
            super().process_request(request, client_address)
        except BaseException:
            with self.state_lock:
                self.connections.discard(request)
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            with self.state_lock:
                self.connections.discard(request)
            self.slots.release()

    def handle_error(self, request, client_address):
        pass  # No access/error dumps containing addresses, headers or payloads.

    def allow_rate(self, role):
        now = time.monotonic()
        with self.state_lock:
            times = self.request_times[role]
            while times and times[0] <= now - 60:
                times.popleft()
            if len(times) >= (120 if role == "read" else 60):
                return False
            times.append(now)
            return True

    def stop_requests(self):
        self.stopping.set()
        with self.state_lock:
            for connection in self.connections:
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass


class RelayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.rfile = BoundedInput(self.rfile, self.connection, self.server.stopping)

    def version_string(self):
        return "MoriUsageRelay/1"

    def log_message(self, format, *args):
        pass

    def send_error(self, code, message=None, explain=None):
        self.reply(405 if code == 501 else code, {"error": "request-rejected"})

    def handle_expect_100(self):
        self.reply(417, {"error": "request-rejected"})
        return False

    def reply(self, code, payload):
        data = json.dumps(payload, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
        self.connection.settimeout(2)
        self.close_connection = True
        self.send_response(code)
        for key, value in {"Content-Type": "application/json; charset=utf-8", "Content-Length": str(len(data)),
                           "Connection": "close", "Cache-Control": "no-store, max-age=0", "Pragma": "no-cache",
                           "X-Content-Type-Options": "nosniff", "Cross-Origin-Resource-Policy": "same-origin",
                           "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'"}.items():
            self.send_header(key, value)
        if code == 401:
            self.send_header("WWW-Authenticate", "Bearer")
        self.end_headers()
        if getattr(self, "command", None) != "HEAD":
            self.wfile.write(data)

    def boundary(self):
        if (len(self.headers.get_all("Host", [])) != 1 or "Origin" in self.headers
                or "Referer" in self.headers or self.headers.get("Sec-Fetch-Site", "none") != "none"):
            self.reply(403, {"error": "request-rejected"})
            return False
        if "Transfer-Encoding" in self.headers or len(self.headers.get_all("Content-Length", [])) > 1:
            self.reply(400, {"error": "request-rejected"})
            return False
        return True

    def authorized(self, role):
        values = self.headers.get_all("Authorization", [])
        token = values[0][7:] if len(values) == 1 and values[0][:7].lower() == "bearer " else ""
        expected = self.server.read_token if role == "read" else self.server.write_token
        if not TOKEN_PATTERN.fullmatch(token) or not hmac.compare_digest(token, expected):
            self.reply(401, {"error": "unauthorized"})
            return False
        if not self.server.allow_rate(role):
            self.reply(429, {"error": "rate-limited"})
            return False
        return True

    def do_GET(self):
        if not self.boundary():
            return
        if self.headers.get("Content-Length", "0") != "0":
            self.reply(400, {"error": "request-rejected"})
            return
        if self.path == "/health":
            self.reply(200, {"status": "ok"})
            return
        if self.path != "/v1/usage":
            self.reply(404, {"error": "not-found"})
            return
        if not self.authorized("read"):
            return
        try:
            self.reply(200, self.server.store.read())
        except (RelayError, snapshot.InvalidSnapshot, OSError):
            self.reply(503, {"error": "unavailable"})

    def do_PUT(self):
        if not self.boundary():
            return
        if self.path != "/v1/usage":
            self.reply(404, {"error": "not-found"})
            return
        if not self.authorized("write"):
            return
        length = self.headers.get("Content-Length")
        if length is None:
            self.reply(411, {"error": "length-required"})
            return
        if not re.fullmatch(r"[0-9]{1,10}", length):
            self.reply(400, {"error": "request-rejected"})
            return
        if not 0 < int(length) <= snapshot.MAX_BYTES:
            self.reply(413, {"error": "request-too-large"})
            return
        if (self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json"
                or self.headers.get("Content-Encoding", "identity").lower() != "identity"):
            self.reply(415, {"error": "unsupported-content"})
            return
        try:
            value = snapshot.decode(self.rfile.body(int(length)), self.server.store.clock())
            self.server.store.publish(value)
            self.reply(200, {"ok": True})
        except Conflict:
            self.reply(409, {"error": "record-conflict"})
        except snapshot.InvalidSnapshot:
            self.reply(400, {"error": "invalid-snapshot"})
        except TimeoutError:
            self.reply(408, {"error": "request-timeout"})
        except (RelayError, OSError):
            self.reply(503, {"error": "unavailable"})


class QuietParser(argparse.ArgumentParser):
    def error(self, message):
        raise RelayError("invalid-arguments")


def main(argv=None):
    def stop(_signal, _frame):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    server = None
    try:
        parser = QuietParser(description="Authenticated, single-snapshot quota relay; no account or execution APIs.")
        parser.add_argument("--bind", choices=["127.0.0.1", "0.0.0.0"], default="127.0.0.1")
        parser.add_argument("--port", type=int, default=48764)
        parser.add_argument("--data-dir", required=True)
        parser.add_argument("--config", help="Absolute path to an owned 0600 token JSON file; otherwise use environment")
        args = parser.parse_args(argv)
        if not 1 <= args.port <= 65535:
            raise RelayError("invalid-arguments")
        read_token, write_token = load_tokens(args.config)
        server = RelayServer((args.bind, args.port), SnapshotStore(args.data_dir), read_token, write_token)
        server.serve_forever(poll_interval=0.5)
        return 0
    except KeyboardInterrupt:
        return 0
    except RelayError as error:
        print("usage-relay: " + str(error), file=sys.stderr)
        return 1
    except Exception:
        print("usage-relay: local-failure", file=sys.stderr)
        return 1
    finally:
        if server is not None:
            server.stop_requests()
            server.server_close()


if __name__ == "__main__":
    sys.exit(main())
