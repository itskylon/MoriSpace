#!/usr/bin/env python3
"""Offline tests: every app-server is a temporary fake; never uses a real account."""
import importlib.util
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

SOURCE = Path(__file__).with_name("codex-usage-helper.py").resolve()
SPEC = importlib.util.spec_from_file_location("codex_usage_helper", SOURCE)
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
NOW = 1_800_000_000


def limits(used=25, duration=300, reset=NOW + 3600):
    return {"usedPercent": used, "windowDurationMins": duration, "resetsAt": reset}


def response(primary=None, secondary=None):
    return {"rateLimits": {"limitId": "codex", "primary": primary, "secondary": secondary}}


class UsageHelperFixtures(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mori usage test ")
        self.directory = Path(self.temporary.name).resolve()
        self.output = self.directory / helper.SNAPSHOT_NAME

    def tearDown(self):
        self.temporary.cleanup()

    def parse(self, data):
        return helper.parse_rate_limits(data, NOW, now=NOW)

    def fake(self, body):
        executable = self.directory / "fake codex"
        executable.write_text("#!" + sys.executable + "\n" + body)
        executable.chmod(0o700)
        return executable

    def server(self, payload, error=False):
        methods = self.directory / "methods.json"
        return self.fake(f'''import json, pathlib, sys
methods = []
for line in sys.stdin:
    request = json.loads(line)
    methods.append(request.get("method"))
    pathlib.Path({str(methods)!r}).write_text(json.dumps(methods))
    if request.get("method") == "initialize":
        print(json.dumps({{"id": 1, "result": {{}}}}), flush=True)
        print(json.dumps({{"method": "account/updated", "params": {{"email": "sensitive@example.invalid", "token": "secret-token"}}}}), flush=True)
    elif request.get("method") == "account/rateLimits/read":
        print("secret-token sensitive@example.invalid", file=sys.stderr, flush=True)
        print(json.dumps({{"id": 2, {"'error'" if error else "'result'"}: {payload!r}}}), flush=True)
''')


class UsageHelperTests(UsageHelperFixtures):
    def test_multiple_buckets_prefer_modern_map(self):
        data = response(limits(99))
        data["rateLimitsByLimitId"] = {
            "codex_other": {"primary": limits(7, 60), "secondary": None},
            "codex": {"primary": limits(25), "secondary": limits(68, 10080)},
        }
        result = self.parse(data)
        self.assertEqual([w["id"] for w in result["windows"]], ["codex:primary", "codex:secondary", "codex_other:primary"])
        self.assertEqual([w["usedPercent"] for w in result["windows"]], [25, 68, 7])
        self.assertEqual(result["windows"][0]["label"], "Codex · 5 小时")
        self.assertEqual(result["windows"][1]["label"], "Codex · 7 天")

    def test_codex_bucket_stays_first_before_alphabetically_earlier_bucket(self):
        data = {"rateLimitsByLimitId": {"alpha": {"primary": limits(7)}, "codex": {"primary": limits(25)}}}
        self.assertEqual([w["id"] for w in self.parse(data)["windows"]], ["codex:primary", "alpha:primary"])

    def test_null_bucket_is_skipped_without_falling_back_to_legacy(self):
        data = response(limits(99))
        data["rateLimitsByLimitId"] = {"ignored": None, "codex": {"primary": limits(25)}}
        self.assertEqual([w["usedPercent"] for w in self.parse(data)["windows"]], [25])
        data["rateLimitsByLimitId"] = {"ignored": None}
        self.assertEqual(self.parse(data)["windows"], [])

    def test_missing_quota_payload_is_rejected_and_keeps_previous_snapshot(self):
        helper.atomic_write(self.output, self.parse(response(limits(40))))
        before = self.output.read_bytes()
        for invalid in ({}, {"other": "unrelated"}):
            with self.subTest(invalid=invalid):
                result = helper.run_once("unused", self.output, reader=lambda *a, **kw: invalid, clock=lambda: NOW)
                self.assertEqual(result, "invalid-data")
                self.assertEqual(self.output.read_bytes(), before)

    def test_excessive_windows_are_rejected(self):
        data = {"rateLimitsByLimitId": {"bucket" + str(index): {"primary": limits(), "secondary": limits()} for index in range(32)}}
        self.assertEqual(len(self.parse(data)["windows"]), 64)
        data["rateLimitsByLimitId"]["one_more"] = {"primary": limits()}
        with self.assertRaises(helper.UsageError): self.parse(data)
        snapshot = self.parse(response(limits()))
        snapshot["windows"] = [dict(snapshot["windows"][0], id=f"bucket{index}:primary", label=f"bucket{index} · 5 小时") for index in range(65)]
        self.assertFalse(helper.valid_snapshot(snapshot, NOW))

    def test_generated_labels_and_ids_fit_swift_size_bounds(self):
        result = self.parse({"rateLimitsByLimitId": {"x" * 128: {"primary": limits(duration=2**63 - 1)}}})
        window = result["windows"][0]
        self.assertLessEqual(len(window["id"]), 160)
        self.assertLessEqual(len(window["label"]), 120)
        self.assertTrue(helper.valid_snapshot(result, NOW))
        window["label"] = "x" * 121
        self.assertFalse(helper.valid_snapshot(result, NOW))

    def test_empty_or_null_map_falls_back(self):
        for mapped in (None, {}):
            data = response(limits(45)); data["rateLimitsByLimitId"] = mapped
            self.assertEqual(self.parse(data)["windows"][0]["usedPercent"], 45)

    def test_null_windows_do_not_become_zero(self):
        result = self.parse(response())
        self.assertEqual(result["windows"], [])
        self.assertEqual(result["status"], "unavailable")

    def test_null_fields_remain_null(self):
        result = self.parse(response(limits(None, None, None)))
        window = result["windows"][0]
        self.assertIsNone(window["usedPercent"])
        self.assertIsNone(window["windowMinutes"])
        self.assertIsNone(window["resetsAt"])
        self.assertEqual(window["label"], "Codex · 主额度")

    def test_invalid_percent_is_rejected(self):
        for value in (-1, 101, float("inf"), float("nan"), True, "25"):
            with self.subTest(value=value), self.assertRaises(helper.UsageError):
                self.parse(response(limits(value)))

    def test_invalid_duration_is_rejected(self):
        for value in (0, -30, 300.5, True, "300", 2**63):
            with self.subTest(value=value), self.assertRaises(helper.UsageError):
                self.parse(response(limits(duration=value)))

    def test_invalid_timestamps_and_future_fetch_are_rejected(self):
        for value in (0, -1, float("inf"), True, "later", helper.MAX_TIMESTAMP + 1, 10**500):
            with self.subTest(value=value), self.assertRaises(helper.UsageError):
                self.parse(response(limits(reset=value)))
        with self.assertRaises(helper.UsageError):
            helper.parse_rate_limits(response(limits()), NOW + 1, now=NOW)
        with self.assertRaises(helper.UsageError):
            helper.parse_rate_limits(response(limits()), helper.MAX_TIMESTAMP, now=helper.MAX_TIMESTAMP)

    def test_past_reset_keeps_measured_usage(self):
        result = self.parse(response(limits(82, reset=NOW - 1)))
        self.assertEqual(result["windows"][0]["usedPercent"], 82)

    def test_whitelist_drops_identifiers_and_credentials(self):
        data = response(limits())
        data.update({"token": "secret-token", "accountId": "private-account", "email": "sensitive@example.invalid"})
        data["rateLimits"].update({"limitName": "private-account", "planType": "private-plan", "credits": {"balance": 123}})
        encoded = json.dumps(self.parse(data))
        for secret in ("secret-token", "private-account", "sensitive@example.invalid", "private-plan", "credits", "accountId", "email"):
            self.assertNotIn(secret, encoded)
        data["rateLimits"]["limitId"] = "sensitive@example.invalid"
        with self.assertRaises(helper.UsageError): self.parse(data)

    def test_atomic_private_output(self):
        snapshot = self.parse(response(limits()))
        helper.atomic_write(self.output, snapshot)
        self.assertEqual(json.loads(self.output.read_bytes()), snapshot)
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        self.assertEqual(list(self.directory.glob(".mori-usage-*")), [])

    def test_failed_replace_preserves_previous_bytes_and_removes_temp(self):
        previous = self.parse(response(limits(10))); helper.atomic_write(self.output, previous)
        before = self.output.read_bytes()
        with mock.patch.object(helper.os, "replace", side_effect=OSError("fixture-only")):
            with self.assertRaises(OSError): helper.atomic_write(self.output, self.parse(response(limits(80))))
        self.assertEqual(self.output.read_bytes(), before)
        self.assertEqual(list(self.directory.glob(".mori-usage-*")), [])

    def test_failure_preserves_valid_stale_snapshot_without_refreshing_timestamp(self):
        snapshot = helper.parse_rate_limits(response(limits(40)), NOW - 3600, now=NOW)
        helper.atomic_write(self.output, snapshot); before = self.output.read_bytes()
        def fail(*args, **kwargs): raise helper.UsageError("timeout")
        category = helper.run_once("unused", self.output, reader=fail, clock=lambda: NOW)
        self.assertEqual(category, "timeout")
        self.assertEqual(self.output.read_bytes(), before)

    def test_failure_preserves_swift_nil_omission_and_custom_display_label(self):
        snapshot = self.parse(response(limits(None, None, None)))
        snapshot["windows"] = [{"id": "codex:primary", "label": "Codex 工作额度"}]
        helper.atomic_write(self.output, snapshot)
        before = self.output.read_bytes()
        self.assertTrue(helper.valid_snapshot(snapshot, NOW))
        self.assertEqual(helper.preserve_or_unavailable(self.output, NOW), "preserved")
        self.assertEqual(self.output.read_bytes(), before)

    def test_control_characters_and_extra_fields_in_cached_windows_are_rejected(self):
        for changes in ({"label": "injected\nlabel"}, {"id": "injected\nid"}, {"label": "   "}, {"accountId": "private-account"}):
            snapshot = self.parse(response(limits()))
            snapshot["windows"][0].update(changes)
            self.assertFalse(helper.valid_snapshot(snapshot, NOW))

    def test_first_failure_writes_unavailable_not_zero(self):
        def fail(*args, **kwargs): raise helper.UsageError("read-failed")
        helper.run_once("unused", self.output, reader=fail, clock=lambda: NOW)
        snapshot = json.loads(self.output.read_bytes())
        self.assertEqual(snapshot["status"], "unavailable")
        self.assertEqual(snapshot["windows"], [])
        self.assertEqual(snapshot["validUntil"], NOW)

    def test_invalid_old_snapshot_is_not_preserved(self):
        old = self.parse(response(limits())); old["accountId"] = "private-account"
        self.output.write_text(json.dumps(old))
        self.assertEqual(helper.preserve_or_unavailable(self.output, NOW), "unavailable")
        self.assertNotIn("private-account", self.output.read_text())

    def test_invalid_old_validity_is_not_preserved(self):
        for until in (NOW - 1, NOW + 901, float("inf")):
            snapshot = self.parse(response(limits())); snapshot["validUntil"] = until
            self.assertFalse(helper.valid_snapshot(snapshot, NOW))

    def test_symlink_output_refused(self):
        other = self.directory / "calendar.json"; other.write_text("calendar-data")
        self.output.symlink_to(other)
        with self.assertRaises(helper.UsageError): helper.atomic_write(self.output, self.parse(response(limits())))
        self.assertEqual(other.read_text(), "calendar-data")

    def test_only_three_read_only_protocol_messages_are_sent(self):
        executable = self.server(response(limits()))
        helper.run_once(executable, self.output)
        self.assertEqual(json.loads((self.directory / "methods.json").read_text()), ["initialize", "initialized", "account/rateLimits/read"])
        self.assertTrue(helper.valid_snapshot(json.loads(self.output.read_bytes()), time.time()))

    def test_upstream_error_and_stderr_never_leak(self):
        executable = self.server({"message": "secret-token sensitive@example.invalid", "accountId": "private-account"}, error=True)
        completed = subprocess.run([sys.executable, str(SOURCE), "--codex", str(executable), "--output", str(self.output)], capture_output=True, timeout=5)
        self.assertEqual(completed.returncode, 1)
        self.assertEqual(completed.stdout, b"")
        self.assertEqual(completed.stderr, b"codex-usage-helper: read-failed\n")
        combined = completed.stdout + completed.stderr + self.output.read_bytes()
        for secret in (b"secret-token", b"sensitive@example.invalid", b"private-account"):
            self.assertNotIn(secret, combined)

    def test_timeout_kills_and_reaps_uncooperative_cli(self):
        pid_file = self.directory / "pid"
        executable = self.fake(f'''import os, pathlib, signal, time
pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid()))
signal.signal(signal.SIGTERM, signal.SIG_IGN)
while True: time.sleep(1)
''')
        started = time.monotonic()
        with self.assertRaises(helper.UsageError) as context: helper.read_limits(executable, timeout=0.8)
        self.assertEqual(context.exception.category, "timeout")
        self.assertLess(time.monotonic() - started, 1.5)
        with self.assertRaises(ProcessLookupError): os.kill(int(pid_file.read_text()), 0)

    def test_terminating_helper_also_reaps_its_cli(self):
        pid_file = self.directory / "pid"
        executable = self.fake(f'''import os, pathlib, time
pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid()))
while True: time.sleep(1)
''')
        process = subprocess.Popen([sys.executable, str(SOURCE), "--codex", str(executable), "--output", str(self.output)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while not pid_file.exists() and time.monotonic() < deadline: time.sleep(0.01)
            self.assertTrue(pid_file.exists())
            process.terminate()
            stdout, stderr = process.communicate(timeout=3)
            self.assertEqual(stdout, b"")
            self.assertEqual(stderr, b"codex-usage-helper: cancelled\n")
            with self.assertRaises(ProcessLookupError): os.kill(int(pid_file.read_text()), 0)
        finally:
            if process.poll() is None: process.kill(); process.wait()


class UsageServiceTests(UsageHelperFixtures):
    def setUp(self):
        super().setUp()
        self.server = helper.UsageHTTPServer(self.output, port=0)
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02})
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        super().tearDown()

    def request(self, method="GET", path="/v1/usage", headers=None, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            result = connection.getresponse()
            return result.status, dict(result.getheaders()), result.read()
        finally:
            connection.close()

    def test_loopback_listener_and_read_only_snapshot_response(self):
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        snapshot = helper.parse_rate_limits(response(limits()), time.time() - 3600)
        helper.atomic_write(self.output, snapshot)
        status, headers, body = self.request(headers={"Host": f"localhost:{self.port}"})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), snapshot)
        self.assertEqual(headers["Cache-Control"], "no-store, max-age=0")
        self.assertEqual(headers["Connection"], "close")
        self.assertEqual(headers["Cross-Origin-Resource-Policy"], "same-origin")
        self.assertNotIn("Access-Control-Allow-Origin", headers)

    def test_missing_or_untrusted_cache_returns_unavailable_without_private_fields(self):
        for contents in (None, {"token": "secret-token", "email": "sensitive@example.invalid"}, dict(self.parse(response(limits())), accountId="private-account")):
            if contents is not None: self.output.write_text(json.dumps(contents))
            status, headers, body = self.request()
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body)["status"], "unavailable")
            self.assertEqual(json.loads(body)["windows"], [])
            for secret in (b"secret-token", b"sensitive@example.invalid", b"private-account", b"accountId"):
                self.assertNotIn(secret, body)

    def test_other_paths_and_queries_are_rejected(self):
        for path in ("/", "/v1/usage?refresh=true", "/v1/usage/", "/v1/config", "/exec", "http://localhost/v1/usage"):
            with self.subTest(path=path):
                self.assertEqual(self.request(path=path, headers={"Host": f"localhost:{self.port}"})[0], 404)

    def test_mutating_methods_options_and_head_are_rejected(self):
        for method in ("POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD", "CONNECT", "TRACE"):
            with self.subTest(method=method):
                status, headers, body = self.request(method=method)
                self.assertEqual(status, 405)
                self.assertNotIn("Access-Control-Allow-Origin", headers)

    def test_hosts_origins_and_browser_cross_site_requests_are_rejected(self):
        denied = [
            {"Host": "example.invalid"}, {"Host": f"example.invalid:{self.port}"},
            {"Host": f"127.0.0.1.example.invalid:{self.port}"},
            {"Origin": "https://example.invalid"}, {"Origin": "null"},
            {"Origin": f"http://localhost:{self.port}"},
            {"Referer": "https://example.invalid"}, {"Sec-Fetch-Site": "cross-site"},
        ]
        for headers in denied:
            with self.subTest(headers=headers):
                self.assertEqual(self.request(headers=headers)[0], 403)

    def test_duplicate_host_and_get_request_body_are_rejected(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.putrequest("GET", "/v1/usage")
            connection.putheader("Host", f"localhost:{self.port}")
            connection.endheaders()
            result = connection.getresponse()
            self.assertEqual(result.status, 403)
            result.read()
        finally:
            connection.close()
        self.assertEqual(self.request(body="unaccepted-body")[0], 400)
        self.assertEqual(self.request(headers={"Transfer-Encoding": "chunked"})[0], 400)

    def test_headers_are_bounded_and_request_rate_is_limited(self):
        status, headers, body = self.request(headers={"X-Large": "x" * (helper.MAX_REQUEST_BYTES + 100)})
        self.assertEqual(status, 431)
        self.assertNotIn(b"x" * 100, body)
        self.server.request_times.extend([time.monotonic()] * helper.MAX_REQUESTS_PER_MINUTE)
        self.assertEqual(self.request()[0], 429)

    def test_partial_headers_have_total_deadline_even_with_drip_feed(self):
        with mock.patch.object(helper.time, "monotonic", side_effect=[100, 101, 102.1]):
            reader = helper.BoundedRequestReader(io.BytesIO(b"Host: unfinished"), mock.Mock())
            with self.assertRaises(TimeoutError): reader.readline()

    def test_service_serves_immediately_and_sigterm_during_request_reaps_collector_cli(self):
        # The production CLI intentionally allows only this fixed port.
        probe = socket.socket()
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(("127.0.0.1", helper.SERVICE_PORT))
        except OSError:
            self.skipTest("Fixed service port belongs to an already installed helper")
        finally:
            probe.close()
        pid_file = self.directory / "pid"
        executable = self.fake(f'''import os, pathlib, signal, time
pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid()))
signal.signal(signal.SIGTERM, signal.SIG_IGN)
while True: time.sleep(1)
''')
        process = subprocess.Popen([sys.executable, str(SOURCE), "--serve", "--codex", str(executable), "--output", str(self.output)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        partial = None
        try:
            deadline = time.monotonic() + 3
            while not pid_file.exists() and time.monotonic() < deadline: time.sleep(0.01)
            self.assertTrue(pid_file.exists())
            connection = http.client.HTTPConnection("127.0.0.1", helper.SERVICE_PORT, timeout=1)
            connection.request("GET", "/v1/usage")
            result = connection.getresponse()
            self.assertEqual(result.status, 200)
            self.assertEqual(json.loads(result.read())["status"], "unavailable")
            connection.close()
            # Ensure SIGTERM escapes HTTPServer's handler exception boundary too.
            partial = socket.create_connection(("127.0.0.1", helper.SERVICE_PORT), timeout=1)
            partial.sendall(b"GET /v1/usage HTTP/1.1\r\nHost: localhost:48763\r\n")
            time.sleep(0.05)
            started = time.monotonic()
            process.terminate()
            stdout, stderr = process.communicate(timeout=3)
            self.assertLess(time.monotonic() - started, 2)
            self.assertEqual(stdout, b"")
            self.assertEqual(stderr, b"codex-usage-helper: cancelled\n")
            with self.assertRaises(ProcessLookupError): os.kill(int(pid_file.read_text()), 0)
        finally:
            if partial is not None: partial.close()
            if process.poll() is None: process.kill(); process.wait()


if __name__ == "__main__":
    unittest.main()
