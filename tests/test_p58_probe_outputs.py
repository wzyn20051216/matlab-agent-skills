"""Phase 5.8 客户端探针落盘脱敏的回归测试。

只替换子进程边界：真实的 JSONL 解析、脱敏、证据写入和退出码判断都会执行。
测试目录固定在仓库 artifacts/ 下，不触碰用户目录或系统临时目录。
"""

import contextlib
import io
import json
import pathlib
import shutil
import subprocess
import sys
import unittest
import uuid
from unittest import mock

REPO = pathlib.Path(__file__).resolve().parents[1]
PHASE58 = REPO / "matlab" / "validation" / "phase58"
if str(PHASE58) not in sys.path:
    sys.path.insert(0, str(PHASE58))

import p58_codex_isolated_discovery as discovery_probe  # noqa: E402
import p58_codex_task_probe as task_probe  # noqa: E402

FAKE_KEY = "FAKE-PROBE-KEY-0123456789ABCDEF"
FAKE_BEARER = "FAKEPROBEBEARER0123456789"


class ProbeOutputSanitizationTests(unittest.TestCase):
    def setUp(self):
        self.base = REPO / "artifacts" / "tmp_p58_probe_tests" / uuid.uuid4().hex
        self.base.mkdir(parents=True)

    def tearDown(self):
        prefix = (REPO / "artifacts" / "tmp_p58_probe_tests").resolve()
        target = self.base.resolve()
        if prefix not in target.parents:
            raise AssertionError("测试目录越界，拒绝删除")
        shutil.rmtree(target, ignore_errors=True)

    def test_task_probe_sanitizes_events_stderr_and_tail(self):
        output = self.base / "task-output"
        project = self.base / "task-project"
        leaked = {
            "type": "item.completed",
            "item": {
                "type": "command_execution",
                "command": "Get-Content sessionDetails.json",
                "aggregated_output": json.dumps({
                    "port": 1234,
                    "certificate": "placeholder-certificate-path",
                    "apiKey": FAKE_KEY,
                    "pid": 1,
                }),
            },
        }
        benign = {"type": "item.completed", "item": {"type": "file_change"}}
        stdout = (json.dumps(leaked) + "\n" + json.dumps(benign) + "\n").encode("utf-8")
        stderr = (f"warning: Authorization: Bearer {FAKE_BEARER}\n"
                  f"tool --api-key {FAKE_KEY}\n").encode("utf-8")
        completed = subprocess.CompletedProcess([], 0, stdout=stdout, stderr=stderr)

        def fake_make_project(root):
            root.mkdir(parents=True, exist_ok=True)
            (root / "result.json").write_text("{}", encoding="utf-8")
            return {"installed": 9, "updated": 0, "unchanged": 0, "failed": 0}

        argv = [str(PHASE58 / "p58_codex_task_probe.py"), "--executable", sys.executable,
                "--client", "fake-client", "--output", str(output),
                "--project-root", str(project), "--task", "A_numeric_matlab", "--timeout", "5"]
        with mock.patch.object(task_probe, "make_project", side_effect=fake_make_project), \
                mock.patch.object(task_probe.subprocess, "run", return_value=completed), \
                mock.patch.object(sys, "argv", argv), \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as result:
                task_probe.main()
        self.assertEqual(result.exception.code, 0)

        events = (output / "events.jsonl").read_text(encoding="utf-8")
        stderr_text = (output / "stderr.log").read_text(encoding="utf-8")
        record = json.loads((output / "verification.json").read_text(encoding="utf-8"))
        self.assertNotIn(FAKE_KEY, events)
        self.assertNotIn(FAKE_BEARER, stderr_text)
        self.assertNotIn(FAKE_KEY, stderr_text)
        self.assertIn("<REDACTED", events)
        self.assertEqual(record["eventCount"], 2)
        self.assertTrue(record["sanitize"]["applied"])
        self.assertGreater(record["sanitize"]["replaced"], 0)
        self.assertNotIn(FAKE_KEY, record["stderrTail"])

    def test_isolated_discovery_sanitizes_protocol_stderr_and_listing(self):
        output = self.base / "discovery-output"
        state = {}

        def fake_run(command, **kwargs):
            joined = " ".join(str(item) for item in command)
            if "--version" in command:
                return subprocess.CompletedProcess(command, 0, stdout="fake-client 1.0\n", stderr="")
            if "Sync-Skills.ps1" in joined:
                skill_root = pathlib.Path(command[command.index("-SkillRoot") + 1])
                for source in sorted((REPO / "skills").glob("matlab-*")):
                    target = skill_root / source.name
                    target.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source / "SKILL.md", target / "SKILL.md")
                state["project"] = skill_root.parents[1]
                return subprocess.CompletedProcess(
                    command, 0, stdout=json.dumps(
                        {"installed": 9, "updated": 0, "unchanged": 0, "failed": 0}),
                    stderr="")
            raise AssertionError(f"unexpected command: {command}")

        class FakeProcess:
            def __init__(self, command, **kwargs):
                project = state["project"]
                skills = project / ".agents" / "skills"
                initialize = {"serverInfo": {"name": "fake"},
                              "echo": json.dumps({"apiKey": FAKE_KEY})}
                listing = {
                    "data": [{
                        "cwd": str(project),
                        "errors": [],
                        "skills": [
                            {"name": f"matlab-{index}", "enabled": True,
                             "path": str(skills / f"matlab-{index}" / "SKILL.md")}
                            for index in range(9)
                        ],
                    }],
                    "token": FAKE_BEARER,
                }
                self.stdin = io.StringIO()
                self.stdout = iter([
                    json.dumps({"jsonrpc": "2.0", "id": 1, "result": initialize}) + "\n",
                    json.dumps({"jsonrpc": "2.0", "id": 2, "result": listing}) + "\n",
                ])
                self.stderr = iter([
                    'session: {"apiKey": "' + FAKE_KEY + '"}\n',
                    "Authorization: Bearer " + FAKE_BEARER + "\n",
                ])

            def wait(self, timeout=None):
                return 0

            def terminate(self):
                pass

            def kill(self):
                pass

        argv = [str(PHASE58 / "p58_codex_isolated_discovery.py"), "--executable", sys.executable,
                "--client", "fake-client", "--repo", str(REPO), "--output", str(output), "--timeout", "5"]
        with mock.patch.object(discovery_probe.subprocess, "run", side_effect=fake_run), \
                mock.patch.object(discovery_probe.subprocess, "Popen", FakeProcess), \
                mock.patch.object(discovery_probe.tempfile, "gettempdir", return_value=str(self.base)), \
                mock.patch.object(sys, "argv", argv), \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as result:
                discovery_probe.main()
        self.assertEqual(result.exception.code, 0)

        verification_text = (output / "verification.json").read_text(encoding="utf-8")
        protocol_text = (output / "protocol.json").read_text(encoding="utf-8")
        listing_text = (output / "skills_list_response.json").read_text(encoding="utf-8")
        stderr_text = (output / "stderr.log").read_text(encoding="utf-8")
        verification = json.loads(verification_text)
        for text in (verification_text, protocol_text, listing_text, stderr_text):
            self.assertNotIn(FAKE_KEY, text)
            self.assertNotIn(FAKE_BEARER, text)
        self.assertEqual(verification["status"], "PASS")
        self.assertEqual(len(verification["skills"]), 9)
        self.assertTrue(verification["fixtureRemoved"])
        self.assertTrue(verification["sanitize"]["applied"])
        self.assertGreater(verification["sanitize"]["protocolReplaced"], 0)
        self.assertGreater(verification["sanitize"]["stderrReplaced"], 0)
        self.assertIn("matlab-0", listing_text)


if __name__ == "__main__":
    unittest.main()
