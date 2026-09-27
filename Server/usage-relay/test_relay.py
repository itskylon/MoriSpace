"""Offline fixture tests. Only temporary files and local ephemeral TCP ports."""
import http.client
import io
import json
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

import relay
import snapshot

NOW = 1_800_000_000
READ = "a" * 64  # Public test fixtures, never deployment credentials.
WRITE = "b" * 64


def record(fetched=NOW - 30, used=25):
    return {"version": 1, "fetchedAt": fetched, "validUntil": fetched + 900, "status": "ready", "windows": [
        {"id": "codex:primary", "label": "Codex · 5 小时", "usedPercent": used, "windowMinutes": 300, "resetsAt": NOW + 3600}
    ]}


class SnapshotTests(unittest.TestCase):
    def test_round_trip_preserves_exact_original_timestamps(self):
        value = record()
        self.assertEqual(snapshot.decode(snapshot.encode(value, NOW), NOW), value)

    def test_swift_omitted_optional_fields_become_null_not_zero(self):
        value = record(); value["windows"] = [{"id": "codex:primary", "label": "主额度"}]
        result = snapshot.validate(value, NOW)["windows"][0]
        for key in ("usedPercent", "windowMinutes", "resetsAt"):
            self.assertIsNone(result[key])

    def test_exact_whitelist_rejects_account_payload_at_every_level(self):
        for level in ("root", "window"):
            value = record()
            (value if level == "root" else value["windows"][0])["accountId"] = "private-account"
            with self.assertRaises(snapshot.InvalidSnapshot): snapshot.validate(value, NOW)
        with self.assertRaises(snapshot.InvalidSnapshot): snapshot.decode(b'{"result":{"rateLimits":{}}}', NOW)

    def test_invalid_numeric_fields_and_booleans_are_rejected(self):
        cases = {"usedPercent": [-1, 101, True, "10", float("nan"), float("inf")],
                 "windowMinutes": [0, -1, True, "300", 300.5, 2**63],
                 "resetsAt": [0, -1, True, "tomorrow", float("inf"), snapshot.MAX_TIMESTAMP + 1]}
        for key, values in cases.items():
            for invalid in values:
                with self.subTest(key=key, value=invalid):
                    value = record(); value["windows"][0][key] = invalid
                    with self.assertRaises(snapshot.InvalidSnapshot): snapshot.validate(value, NOW)

    def test_future_and_excessive_validity_are_rejected_but_stale_records_are_allowed(self):
        for changes in ({"fetchedAt": NOW + 1}, {"validUntil": NOW + 901}, {"validUntil": NOW - 31}, {"fetchedAt": 0}):
            value = record(); value.update(changes)
            with self.assertRaises(snapshot.InvalidSnapshot): snapshot.validate(value, NOW)
        self.assertEqual(snapshot.validate(record(NOW - 10_000), NOW)["fetchedAt"], NOW - 10_000)

    def test_window_limits_duplicate_ids_and_control_characters(self):
        value = record()
        value["windows"] = [dict(value["windows"][0], id=f"codex{index}:primary") for index in range(64)]
        self.assertEqual(len(snapshot.validate(value, NOW)["windows"]), 64)
        value["windows"].append(dict(value["windows"][0], id="overflow"))
        with self.assertRaises(snapshot.InvalidSnapshot): snapshot.validate(value, NOW)
        for changes in ({"id": "x" * 161}, {"label": "x" * 121}, {"label": "\ud800"}, {"id": "foo\nbar"}, {"label": " "}):
            value = record(); value["windows"][0].update(changes)
            with self.assertRaises(snapshot.InvalidSnapshot): snapshot.validate(value, NOW)
        value = record(); value["windows"] *= 2
        with self.assertRaises(snapshot.InvalidSnapshot): snapshot.validate(value, NOW)

    def test_nonready_cannot_carry_windows(self):
        for status in ("unavailable", "notConnected"):
            value = record(); value["status"] = status
            with self.assertRaises(snapshot.InvalidSnapshot): snapshot.validate(value, NOW)
            value["windows"] = []
            self.assertEqual(snapshot.validate(value, NOW)["windows"], [])

    def test_oversized_duplicate_keys_and_nonstandard_json_are_rejected(self):
        for data in (b" " * (snapshot.MAX_BYTES + 1), b'{"version":1,"version":1}', b'{"usedPercent":NaN}', b"[" * 1500):
            with self.assertRaises(snapshot.InvalidSnapshot): snapshot.decode(data, NOW)


class FilesystemTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mori relay ")
        self.directory = Path(self.temporary.name).resolve()
        self.store = relay.SnapshotStore(self.directory / "data", clock=lambda: NOW)

    def tearDown(self):
        self.temporary.cleanup()

    def test_store_is_atomic_private_and_persists_across_instances(self):
        self.store.publish(record())
        self.assertEqual(stat.S_IMODE(self.store.file.stat().st_mode), 0o600)
        self.assertEqual(relay.SnapshotStore(self.directory / "data", clock=lambda: NOW).read(), record())
        self.assertEqual(list(self.store.directory.glob(".usage-*")), [])

    def test_failure_preserves_old_bytes_and_removes_temporary_file(self):
        self.store.publish(record()); original = self.store.file.read_bytes()
        with mock.patch.object(relay.os, "replace", side_effect=OSError("fixture-only")):
            with self.assertRaises(OSError): self.store.publish(record(NOW - 1, 40))
        self.assertEqual(self.store.file.read_bytes(), original)
        self.assertEqual(list(self.store.directory.glob(".usage-*")), [])

    def test_old_or_same_time_conflicting_record_never_replaces_latest(self):
        self.store.publish(record()); original = self.store.file.read_bytes()
        for value in (record(NOW - 31), record(used=77)):
            with self.assertRaises(relay.Conflict): self.store.publish(value)
            self.assertEqual(self.store.file.read_bytes(), original)
        modified = self.store.file.stat().st_mtime_ns
        self.store.publish(record())
        self.assertEqual(self.store.file.stat().st_mtime_ns, modified)

    def test_concurrent_writers_cannot_roll_back_latest_record(self):
        barrier = threading.Barrier(12)
        failures = []
        def write(index):
            try:
                barrier.wait(timeout=2)
                self.store.publish(record(NOW - 20 + index, index))
            except relay.Conflict:
                pass
            except Exception as error:
                failures.append(type(error).__name__)
        threads = [threading.Thread(target=write, args=(i,)) for i in range(12)]
        for thread in threads: thread.start()
        for thread in threads: thread.join(timeout=3)
        self.assertEqual(failures, [])
        self.assertEqual(self.store.read()["fetchedAt"], NOW - 9)

    def test_symlink_or_corrupt_record_is_not_served_or_overwritten(self):
        other = self.directory / "private.json"; other.write_text('{"token":"do-not-serve"}')
        self.store.file.symlink_to(other)
        with self.assertRaises(OSError): self.store.read()
        with self.assertRaises(OSError): self.store.publish(record())
        self.assertEqual(other.read_text(), '{"token":"do-not-serve"}')
        self.store.file.unlink(); self.store.file.write_text('{"token":"do-not-serve"}')
        with self.assertRaises(relay.RelayError): self.store.read()
        with self.assertRaises(relay.RelayError): self.store.publish(record())

    def test_config_requires_owned_0600_file_and_distinct_tokens(self):
        config = self.directory / "tokens.json"
        config.write_text(json.dumps({"version": 1, "readToken": READ, "writeToken": WRITE})); config.chmod(0o600)
        self.assertEqual(relay.load_tokens(config, {}), (READ, WRITE))
        config.chmod(0o644)
        with self.assertRaises(relay.RelayError): relay.load_tokens(config, {})
        with self.assertRaises(relay.RelayError): relay.validate_tokens(READ, READ)
        with self.assertRaises(relay.RelayError): relay.validate_tokens(READ, "short")
        with self.assertRaises(relay.RelayError): relay.load_tokens(config, {"MORI_USAGE_READ_TOKEN": READ})
        self.assertEqual(relay.load_tokens(environ={"MORI_USAGE_READ_TOKEN": READ, "MORI_USAGE_WRITE_TOKEN": WRITE}), (READ, WRITE))


class RelayHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mori relay http ")
        self.directory = Path(self.temporary.name).resolve()
        self.store = relay.SnapshotStore(self.directory / "data", clock=lambda: NOW)
        self.server = relay.RelayServer(("127.0.0.1", 0), self.store, READ, WRITE)
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02})
        self.thread.start()

    def tearDown(self):
        self.server.shutdown(); self.server.stop_requests(); self.server.server_close()
        self.thread.join(timeout=2)
        self.temporary.cleanup()

    def request(self, method="GET", path="/v1/usage", token=None, payload=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        fields = dict(headers or {})
        if token is not None: fields["Authorization"] = "Bearer " + token
        body = None if payload is None else (payload if isinstance(payload, bytes) else json.dumps(payload).encode())
        if body is not None: fields.setdefault("Content-Type", "application/json")
        try:
            connection.request(method, path, body=body, headers=fields)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_health_has_no_account_data_and_empty_record_is_503(self):
        status, headers, body = self.request(path="/health")
        self.assertEqual((status, json.loads(body)), (200, {"status": "ok"}))
        self.assertEqual(self.request(token=READ)[0], 503)

    def test_read_and_write_credentials_cannot_be_swapped_or_omitted(self):
        for token in (None, WRITE, "c" * 64, "bad"):
            self.assertEqual(self.request(token=token)[0], 401)
        for token in (None, READ, "c" * 64, "bad"):
            self.assertEqual(self.request("PUT", token=token, payload=record())[0], 401)
        self.assertFalse(self.store.file.exists())

    def test_authenticated_publish_read_and_idempotent_retry(self):
        self.assertEqual(self.request("PUT", token=WRITE, payload=record())[0], 200)
        status, headers, body = self.request(token=READ)
        self.assertEqual((status, json.loads(body)), (200, record()))
        self.assertEqual(headers["Cache-Control"], "no-store, max-age=0")
        self.assertNotIn("Access-Control-Allow-Origin", headers)
        self.assertEqual(self.request("PUT", token=WRITE, payload=record())[0], 200)
        for secret in (READ.encode(), WRITE.encode()): self.assertNotIn(secret, body)

    def test_older_conflicting_and_future_uploads_are_rejected_without_changes(self):
        self.store.publish(record()); before = self.store.file.read_bytes()
        for value, expected in ((record(NOW - 31), 409), (record(used=98), 409), (record(NOW + 1), 400)):
            self.assertEqual(self.request("PUT", token=WRITE, payload=value)[0], expected)
            self.assertEqual(self.store.file.read_bytes(), before)

    def test_private_payload_is_rejected_not_logged_or_persisted(self):
        private = dict(record(), email="private@example.invalid", token="private-secret")
        captured = io.StringIO()
        with mock.patch("sys.stderr", captured):
            status, headers, body = self.request("PUT", token=WRITE, payload=private)
        self.assertEqual(status, 400)
        self.assertFalse(self.store.file.exists())
        self.assertEqual(captured.getvalue(), "")
        self.assertNotIn(b"private", body)

    def test_only_exact_paths_get_and_put_exist(self):
        for method in ("POST", "PATCH", "DELETE", "OPTIONS", "HEAD", "TRACE", "CONNECT"):
            self.assertEqual(self.request(method, token=WRITE)[0], 405)
        for path in ("/", "/files", "/v1/usage?token=private-secret", "/v1/usage/", "/v1/config"):
            status, headers, body = self.request(path=path, token=READ)
            self.assertEqual(status, 404)
            self.assertNotIn(b"private-secret", body)

    def test_origins_and_transfer_encoding_are_rejected(self):
        for fields in ({"Origin": "https://example.invalid"}, {"Origin": "null"}, {"Referer": "https://example.invalid"}, {"Sec-Fetch-Site": "cross-site"}):
            self.assertEqual(self.request(token=READ, headers=fields)[0], 403)
        self.assertEqual(self.request(token=READ, headers={"Transfer-Encoding": "chunked"})[0], 400)
        self.assertEqual(self.request(token=READ, payload=b"body")[0], 400)

    def test_body_header_type_and_request_rate_limits(self):
        self.assertEqual(self.request("PUT", token=WRITE, payload=b"x" * (snapshot.MAX_BYTES + 1))[0], 413)
        self.assertEqual(self.request("PUT", token=WRITE, payload=record(), headers={"Content-Type": "text/plain"})[0], 415)
        self.assertEqual(self.request("PUT", token=WRITE, payload=record(), headers={"Content-Encoding": "gzip"})[0], 415)
        self.assertEqual(self.request(token=READ, headers={"X-Large": "x" * (relay.MAX_HEADER_BYTES + 10)})[0], 431)
        with self.server.state_lock:
            self.server.request_times["read"].extend([time.monotonic()] * 120)
        self.assertEqual(self.request(token=READ)[0], 429)

    def test_duplicate_authorization_and_content_length_are_rejected(self):
        for name, values, expected in (("Authorization", ["Bearer " + READ] * 2, 401), ("Content-Length", ["0", "0"], 400)):
            connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
            try:
                connection.putrequest("GET", "/v1/usage")
                if name != "Authorization": connection.putheader("Authorization", "Bearer " + READ)
                for value in values: connection.putheader(name, value)
                connection.endheaders()
                response = connection.getresponse()
                self.assertEqual(response.status, expected); response.read()
            finally:
                connection.close()

    def test_total_header_and_body_deadlines(self):
        with mock.patch.object(relay.time, "monotonic", side_effect=[100, 101, 102.1]):
            reader = relay.BoundedInput(io.BytesIO(b"slow header"), mock.Mock(), threading.Event())
            with self.assertRaises(TimeoutError): reader.readline()
        reader = relay.BoundedInput(io.BytesIO(b"body"), mock.Mock(), threading.Event())
        with mock.patch.object(relay.time, "monotonic", side_effect=[100, 106]):
            with self.assertRaises(TimeoutError): reader.body(4)


class ProcessTests(unittest.TestCase):
    def test_config_error_never_prints_token_and_sigterm_interrupts_pending_body(self):
        with tempfile.TemporaryDirectory(prefix="mori relay process ") as temporary:
            directory = Path(temporary).resolve()
            environment = dict(os.environ, MORI_USAGE_READ_TOKEN=READ, MORI_USAGE_WRITE_TOKEN=READ)
            script = str(Path(__file__).with_name("relay.py"))
            result = subprocess.run([sys.executable, script, "--data-dir", str(directory / "data")], env=environment, capture_output=True, timeout=3)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, b"usage-relay: invalid-token-config\n")
            environment["MORI_USAGE_WRITE_TOKEN"] = WRITE
            probe = socket.socket(); probe.bind(("127.0.0.1", 0)); port = probe.getsockname()[1]; probe.close()
            process = subprocess.Popen([sys.executable, script, "--port", str(port), "--data-dir", str(directory / "data")], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            partial = None
            try:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    try:
                        partial = socket.create_connection(("127.0.0.1", port), timeout=0.2)
                        break
                    except OSError: time.sleep(0.01)
                self.assertIsNotNone(partial)
                partial.sendall((f"PUT /v1/usage HTTP/1.1\r\nHost: localhost:{port}\r\nAuthorization: Bearer {WRITE}\r\nContent-Type: application/json\r\nContent-Length: 65536\r\n\r\n{{").encode())
                time.sleep(0.05)
                started = time.monotonic(); process.send_signal(signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=3)
                self.assertLess(time.monotonic() - started, 2)
                self.assertEqual((process.returncode, stdout, stderr), (0, b"", b""))
                self.assertFalse((directory / "data/usage-widget-v1.json").exists())
            finally:
                if partial is not None: partial.close()
                if process.poll() is None: process.kill(); process.wait()


if __name__ == "__main__":
    unittest.main()
