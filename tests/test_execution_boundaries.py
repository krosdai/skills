"""Offline contract tests: fake GitHub, disposable scripts, and a loopback video API.

Run with: python -m unittest discover -s tests -v
No credentials or remote services are used.
"""

import copy
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(__file__).resolve().parents[1]
PR_SCRIPTS = ROOT / "skills/pr-shepherd/scripts"
VIDEO = ROOT / "skills/video-generation/scripts/seedance.sh"


def executable(path, body):
    path.write_text(body)
    path.chmod(0o755)


def check(status="COMPLETED", conclusion="SUCCESS"):
    return {
        "__typename": "CheckRun",
        "name": "test",
        "status": status,
        "conclusion": conclusion,
    }


def pull_request():
    return {
        "number": 1,
        "title": "fixture",
        "state": "OPEN",
        "isDraft": False,
        "mergeable": "MERGEABLE",
        "mergeStateStatus": "CLEAN",
        "reviewDecision": "APPROVED",
        "reviewThreads": {"nodes": [], "pageInfo": {"hasNextPage": False}},
        "commits": {
            "nodes": [{"commit": {"statusCheckRollup": {"contexts": {
                "nodes": [check()], "pageInfo": {"hasNextPage": False}
            }}}}]
        },
    }


class PRGateTests(unittest.TestCase):
    def test_verdict_and_exit_code(self):
        base = pull_request()
        cases = []
        for label, changes, nodes, verdict, code in [
            ("green", {}, [check()], "GREEN", 0),
            ("pending", {}, [check("IN_PROGRESS", None)], "WAITING_CI", 10),
            ("failure while pending", {}, [check("IN_PROGRESS", None), check(conclusion="FAILURE")], "NEEDS_WORK", 20),
            ("approval while pending", {"reviewDecision": "REVIEW_REQUIRED"}, [check("IN_PROGRESS", None)], "BLOCKED_HUMAN", 30),
            ("action while pending", {}, [check("IN_PROGRESS", None), check(conclusion="ACTION_REQUIRED")], "BLOCKED_HUMAN", 30),
            ("blocked due to pending", {"mergeStateStatus": "BLOCKED"}, [check("IN_PROGRESS", None)], "WAITING_CI", 10),
            ("protection", {"mergeStateStatus": "BLOCKED"}, [check()], "BLOCKED_HUMAN", 30),
            ("unknown mergeability", {"mergeable": "UNKNOWN"}, [check()], "WAITING_CI", 10),
            ("conflict while pending", {"mergeable": "CONFLICTING"}, [check("IN_PROGRESS", None)], "NEEDS_WORK", 20),
            ("draft", {"isDraft": True}, [check()], "NOT_ELIGIBLE", 40),
            ("closed", {"state": "CLOSED"}, [check()], "NOT_ELIGIBLE", 40),
        ]:
            pr = copy.deepcopy(base)
            pr.update(changes)
            pr["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["nodes"] = nodes
            cases.append((label, pr, verdict, code))
        for label in ["open review", "truncated reviews", "truncated checks"]:
            pr = copy.deepcopy(base)
            contexts = pr["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]
            contexts["nodes"] = [check("IN_PROGRESS", None)]
            if label == "open review":
                pr["reviewThreads"]["nodes"] = [{"id": "T1", "isResolved": False, "isOutdated": False, "comments": {"nodes": []}}]
            elif label == "truncated reviews":
                pr["reviewThreads"]["pageInfo"]["hasNextPage"] = True
            else:
                contexts["pageInfo"]["hasNextPage"] = True
            cases.append((label, pr, "NEEDS_WORK", 20))
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            executable(folder / "gh", f"#!{sys.executable}\nimport os\nprint(os.environ['PR_FIXTURE'])\n")
            for label, pr, verdict, code in cases:
                with self.subTest(label=label):
                    env = dict(os.environ, PATH=f"{folder}:{os.environ['PATH']}", PR_FIXTURE=json.dumps({"data": {"repository": {"pullRequest": pr}}}))
                    result = subprocess.run(["bash", str(PR_SCRIPTS / "pr_status.sh"), "owner/repo", "1"], env=env, capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, code, result.stderr)
                    self.assertEqual(json.loads(result.stdout)["verdict"], verdict)


class PRWaitTests(unittest.TestCase):
    def run_wait(self, status_body, budget=1, interval=10, fallback=False):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            script = folder / "wait_for_settle.sh"
            shutil.copy(PR_SCRIPTS / script.name, script)
            executable(folder / "pr_status.sh", f"#!{sys.executable}\n" + status_body)
            env = dict(os.environ, WAIT_COUNTER=str(folder / "counter"))
            if fallback:
                # Exercise the portable watchdog without timeout/gtimeout.
                binary_dir = folder / "bin"
                binary_dir.mkdir()
                for command in ["dirname", "mktemp", "cat", "rm", "sleep", "pkill"]:
                    (binary_dir / command).symlink_to(shutil.which(command))
                env["PATH"] = str(binary_dir)
            started = time.monotonic()
            result = subprocess.run([shutil.which("bash"), str(script), "--max-wait", str(budget), "--interval", str(interval), "owner/repo", "1"], env=env, capture_output=True, text=True, timeout=8)
            return result, time.monotonic() - started

    def test_slow_read_is_bounded(self):
        for fallback in [False, True]:
            with self.subTest(fallback=fallback):
                result, elapsed = self.run_wait("import time\ntime.sleep(5)\n", fallback=fallback)
                self.assertEqual(result.returncode, 10, result.stderr)
                self.assertLess(elapsed, 2.5)

    def test_sleep_is_clipped(self):
        result, elapsed = self.run_wait("import sys\nprint('{\"verdict\":\"WAITING_CI\"}')\nsys.exit(10)\n")
        self.assertEqual(result.returncode, 10)
        self.assertLess(elapsed, 2.5)

    def test_new_action_interrupts_wait(self):
        body = """import os, pathlib, sys
p = pathlib.Path(os.environ['WAIT_COUNTER'])
if p.exists():
    print('{"verdict":"NEEDS_WORK","blockers":["unresolved_review_threads"]}')
    sys.exit(20)
p.touch()
print('{"verdict":"WAITING_CI"}')
sys.exit(10)
"""
        result, elapsed = self.run_wait(body, budget=5, interval=1)
        self.assertEqual(result.returncode, 20, result.stderr)
        self.assertEqual(json.loads(result.stdout)["verdict"], "NEEDS_WORK")
        self.assertLess(elapsed, 3)

    def test_first_access_error_returns_immediately(self):
        result, elapsed = self.run_wait("import sys\nsys.exit(50)\n", budget=5)
        self.assertEqual(result.returncode, 50)
        self.assertLess(elapsed, 1)

    def test_zero_wait_budget_is_rejected(self):
        result, elapsed = self.run_wait("print('unexpected gate read')\n", budget=0)
        self.assertEqual(result.returncode, 50)
        self.assertEqual(result.stdout, "")
        self.assertIn("--max-wait must be >= 1", result.stderr)
        self.assertLess(elapsed, 1)


class BrowserTemplateTests(unittest.TestCase):
    def test_templates_require_and_wait_for_ready_state(self):
        templates = ROOT / "skills/browser-automation/templates"
        for name in ["capture-workflow.sh", "form-automation.sh", "authenticated-session.sh"]:
            for ready, fail_wait in [(False, False), (True, False), (True, True)]:
                with self.subTest(template=name, ready=ready, fail_wait=fail_wait), tempfile.TemporaryDirectory() as temp:
                    folder = Path(temp)
                    log = folder / "calls"
                    executable(folder / "agent-browser", f"#!{sys.executable}\n" + """import json, os, sys
from pathlib import Path
with Path(os.environ['BROWSER_LOG']).open('a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1] == 'wait' and os.environ['BROWSER_WAIT_FAIL'] == '1':
    sys.exit(1)
if sys.argv[1:3] == ['get', 'url']:
    print('https://example.com/account')
""")
                    executable(folder / "eza", "#!/bin/sh\nexit 0\n")
                    env = dict(os.environ, PATH=f"{folder}:{os.environ['PATH']}", BROWSER_LOG=str(log), BROWSER_WAIT_FAIL=str(int(fail_wait)))
                    for key in ["READY_SELECTOR", "LOGIN_READY_SELECTOR", "AUTH_READY_SELECTOR"]:
                        env.pop(key, None)
                    if ready:
                        env["READY_SELECTOR"] = "#task-ready"
                        env["LOGIN_READY_SELECTOR"] = "#login-ready"
                        env["AUTH_READY_SELECTOR"] = "#auth-ready"
                    # Exercise authenticated state reuse without accessing real credentials.
                    (folder / "auth-state.json").write_text('{}')
                    result = subprocess.run(["bash", str(templates / name), "https://example.com"], cwd=folder, env=env, capture_output=True, text=True, timeout=5)
                    calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
                    if not ready:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(calls, [])
                    else:
                        selector = "#login-ready, #auth-ready" if name == "authenticated-session.sh" else "#task-ready"
                        wait_index = calls.index(["wait", selector])
                        self.assertFalse(any(call[0] in ["get", "snapshot", "screenshot", "pdf"] for call in calls[:wait_index]))
                        if fail_wait:
                            self.assertNotEqual(result.returncode, 0)
                            self.assertFalse(any(call[0] in ["get", "snapshot", "screenshot", "pdf"] for call in calls[wait_index + 1:]))
                        else:
                            self.assertEqual(result.returncode, 0, result.stderr)

    def test_expired_session_reaches_login_discovery(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            executable(folder / "agent-browser", f"#!{sys.executable}\n" + """import json, os, sys
from pathlib import Path
with Path(os.environ['BROWSER_LOG']).open('a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:3] == ['get', 'url']:
    print('https://example.com/login')
if sys.argv[1:] == ['wait', '#auth-ready']:
    sys.exit(1)
""")
            (folder / "auth-state.json").write_text('{}')
            log = folder / "calls"
            env = dict(os.environ, PATH=f"{folder}:{os.environ['PATH']}", BROWSER_LOG=str(log), LOGIN_READY_SELECTOR="#login-ready", AUTH_READY_SELECTOR="#auth-ready")
            result = subprocess.run(["bash", str(ROOT / "skills/browser-automation/templates/authenticated-session.sh"), "https://example.com/login"], cwd=folder, env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertIn(["wait", "#login-ready, #auth-ready"], calls)
            self.assertIn(["wait", "#login-ready"], calls)
            self.assertIn("Login form structure:", result.stdout)


class VideoTests(unittest.TestCase):
    def test_credential_bearing_endpoints_are_rejected_before_output_or_requests(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            marker = folder / "curl-called"
            executable(folder / "curl", f"#!{sys.executable}\nimport os\nfrom pathlib import Path\nPath(os.environ['CURL_MARKER']).touch()\nraise SystemExit(91)\n")
            env = dict(os.environ, PATH=f"{folder}:{os.environ['PATH']}", SEEDANCE_API_KEY="fixture-key", CURL_MARKER=str(marker))
            for endpoint in ["https://user:endpoint-secret@example.com", "https://example.com?token=endpoint-secret", "https://example.com/#endpoint-secret"]:
                with self.subTest(endpoint=endpoint):
                    result = subprocess.run(["bash", str(VIDEO), "--task-id", "cgt-fixture", "--base-url", endpoint, "--max-wait", "1"], env=env, capture_output=True, text=True, timeout=3)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn("endpoint-secret", result.stdout + result.stderr)
                    self.assertFalse(marker.exists())

    def run_video(self, responses, resume=False, budget=8, interval=1, download=None, follow_hint=False, api_key_flag=False):
        requests = []
        replies = list(responses)

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def respond(self):
                requests.append(self.command)
                if self.command == "POST":
                    self.rfile.read(int(self.headers.get("Content-Length", 0)))
                code, body, delay = replies.pop(0) if len(replies) > 1 else replies[0]
                time.sleep(delay)
                try:
                    self.send_response(code)
                    self.end_headers()
                    self.wfile.write(body.replace("__VIDEO_URL__", f"http://127.0.0.1:{self.server.server_port}/video").encode())
                except (BrokenPipeError, ConnectionResetError):
                    # Budget tests deliberately disconnect before the delayed response.
                    pass

            do_GET = respond
            do_POST = respond

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            args = ["bash", str(VIDEO), "--task-id", "cgt-test"] if resume else ["bash", str(VIDEO), "fixture prompt"]
            args += ["--max-wait", str(budget), "--poll-interval", str(interval)]
            env = dict(os.environ, SEEDANCE_API_KEY="offline-test-only", SEEDANCE_BASE_URL=f"http://127.0.0.1:{server.server_port}", SEEDANCE_MODEL="doubao-seedance-2-0-fast-260128")
            if api_key_flag:
                args += ["--api-key", env.pop("SEEDANCE_API_KEY")]
            if download is not None:
                args += ["--download", str(download)]
            if follow_hint:
                args += ["--base-url", env["SEEDANCE_BASE_URL"]]
                env["SEEDANCE_BASE_URL"] = "http://127.0.0.1:1"
            started = time.monotonic()
            result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=budget + 3)
            if follow_hint:
                hint = next(line.split("Resume:", 1)[1].strip() for line in result.stderr.splitlines() if "Resume:" in line)
                command = shlex.split(hint)
                self.assertEqual(command[command.index("--download") + 1], str(download))
                self.assertEqual(command[command.index("--base-url") + 1], f"http://127.0.0.1:{server.server_port}")
                self.assertEqual(command[command.index("--poll-interval") + 1], str(interval))
                self.assertNotIn("offline-test-only", hint)
                if api_key_flag:
                    self.assertIn("Credentials came from --api-key", result.stderr)
                    self.assertIn("set SEEDANCE_API_KEY", result.stderr)
                    env["SEEDANCE_API_KEY"] = "offline-test-only"
                result = subprocess.run(["bash", *command], env=env, capture_output=True, text=True, timeout=budget + 3)
            elapsed = time.monotonic() - started
            return result, requests, elapsed
        finally:
            server.shutdown()
            server.server_close()

    def test_create_once_then_succeed(self):
        result, requests, _ = self.run_video([(200, '{"id":"cgt-test"}', 0), (200, '{"status":"succeeded","content":{"video_url":"https://example.com/video.mp4"}}', 0)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, ["POST", "GET"])

    def test_creation_is_not_retried(self):
        result, requests, _ = self.run_video([(503, '{}', 0)])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(requests, ["POST"])

    def test_creation_rejection_reports_redacted_diagnostic(self):
        result, requests, _ = self.run_video([(400, '{"error":{"code":"InvalidParameter","message":"unsupported value; key offline-test-only"}}', 0)])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(requests, ["POST"])
        self.assertIn("InvalidParameter: unsupported value", result.stderr)
        self.assertNotIn("offline-test-only", result.stderr)
        self.assertNotIn("task list", result.stderr)

    def test_resume_only_queries(self):
        result, requests, _ = self.run_video([(200, '{"status":"succeeded","content":{"video_url":"https://example.com/video.mp4"}}', 0)], resume=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, ["GET"])

    def test_resume_hint_preserves_endpoint_and_download(self):
        with tempfile.TemporaryDirectory() as temp:
            download = Path(temp) / "clips with spaces"
            result, requests, _ = self.run_video([
                (401, '{}', 0),
                (200, '{"status":"succeeded","content":{"video_url":"__VIDEO_URL__"}}', 0),
                (200, 'video fixture', 0),
            ], resume=True, download=download, follow_hint=True, api_key_flag=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(requests, ["GET", "GET", "GET"])
            self.assertEqual((download / "cgt-test.mp4").read_text(), "video fixture")

    def test_permanent_error_and_terminal_failure(self):
        for code, body in [(401, '{}'), (200, '{"status":"failed","error":{"message":"fixture"}}'), (200, '{"status":"expired"}')]:
            with self.subTest(code=code, body=body):
                result, requests, elapsed = self.run_video([(code, body, 0)], resume=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(requests, ["GET"])
                self.assertIn("cgt-test", result.stderr)
                self.assertLess(elapsed, 1)
                if code == 200:
                    self.assertNotIn("Resume:", result.stderr)

    def test_invalid_responses_do_not_reset_error_count(self):
        result, requests, elapsed = self.run_video([(200, 'not-json', 0), (200, '{}', 0)], resume=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(requests), 5)
        self.assertIn("Five consecutive", result.stderr)
        self.assertLess(elapsed, 6)

    def test_transient_query_can_recover(self):
        result, requests, _ = self.run_video([(503, '{}', 0), (200, '{"status":"succeeded","content":{"video_url":"https://example.com/video.mp4"}}', 0)], resume=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, ["GET", "GET"])

    def test_slow_request_and_long_interval_respect_budget(self):
        for delay in [0, 4]:
            with self.subTest(delay=delay):
                result, requests, elapsed = self.run_video([(200, '{"status":"running"}', delay)], resume=True, budget=1, interval=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(requests, ["GET"])
                self.assertLess(elapsed, 2.5)
                self.assertIn("cgt-test", result.stderr)


if __name__ == "__main__":
    unittest.main()
