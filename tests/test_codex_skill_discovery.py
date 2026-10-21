"""用模拟协议响应验证发现探针的退出码和落盘证据，不启动客户端或 MATLAB。"""

import contextlib
import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROBE_PATH = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "Test-CodexSkillDiscovery.py"
SPEC = importlib.util.spec_from_file_location("mas_skill_discovery_probe", PROBE_PATH)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class DiscoveryProbeTests(unittest.TestCase):
    """驱动完整 main，从协议输入到 verification.json 及 SystemExit 验证结果。"""

    def run_probe(self, errors, expected_count=0, include_skill=False, change_listing=None):
        """仅替换客户端进程；其余队列消费、判定和证据写入都执行真实代码。"""
        with tempfile.TemporaryDirectory(prefix="mas-discovery-test-") as directory:
            root = pathlib.Path(directory)
            skills = []
            if include_skill:
                skills.append({"name": "matlab-runner", "enabled": True,
                               "path": str(root / "skills" / "matlab-runner" / "SKILL.md")})
            listing = {"data": [{"cwd": str(root), "skills": skills, "errors": errors}]}
            if change_listing:
                change_listing(listing, root)
            responses = [{"id": 1, "result": {"capabilities": {}}}, {"id": 2, "result": listing}]
            process = mock.Mock()
            process.stdin = io.StringIO()
            process.stdout = io.StringIO("".join(json.dumps(item) + "\n" for item in responses))
            process.wait.return_value = 0
            argv = [str(PROBE_PATH), "--executable", sys.executable, "--cwd", str(root),
                    "--skill-root", str(root / "skills"), "--output", str(root / "out"),
                    "--client", "test-client", "--expected-count", str(expected_count), "--timeout", "2"]
            version = subprocess.CompletedProcess([], 0, "codex-test 1.0\n", "")
            with mock.patch.object(sys, "argv", argv), \
                    mock.patch.object(PROBE.subprocess, "run", return_value=version), \
                    mock.patch.object(PROBE.subprocess, "Popen", return_value=process), \
                    contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit) as exit_result:
                    PROBE.main()
            evidence = json.loads((root / "out" / "verification.json").read_text(encoding="utf-8"))
            protocol = json.loads((root / "out" / "protocol.json").read_text(encoding="utf-8"))
            saved_listing = json.loads((root / "out" / "skills_list_response.json").read_text(encoding="utf-8"))
            self.assertEqual([item["message"]["id"] for item in protocol if item["direction"] == "receive"], [1, 2])
            self.assertEqual(saved_listing, listing)
            self.assertEqual(evidence["discoveryErrors"], errors)
            return exit_result.exception.code, evidence

    def test_zero_skills_with_discovery_error_fails(self):
        """无法解析仍在磁盘上的技能时，零数量不能证明卸载成功。"""
        errors = [{"path": "matlab-runner/SKILL.md", "message": "invalid YAML"}]
        exit_code, evidence = self.run_probe(errors)
        self.assertEqual(exit_code, 1)
        self.assertEqual(evidence["status"], "FAIL")
        self.assertEqual(evidence["skills"], [])
        self.assertIn("reason", evidence)

    def test_zero_skills_without_errors_passes(self):
        """客户端成功发现零项时保持卸载正例。"""
        exit_code, evidence = self.run_probe([])
        self.assertEqual(exit_code, 0)
        self.assertEqual(evidence["status"], "PASS")
        self.assertEqual(evidence["skills"], [])

    def test_matching_count_with_discovery_error_still_fails(self):
        """数量相符不能掩盖客户端报告的其他发现错误。"""
        errors = [{"message": "skill discovery failed"}]
        exit_code, evidence = self.run_probe(errors, expected_count=1, include_skill=True)
        self.assertEqual(exit_code, 1)
        self.assertEqual(evidence["status"], "FAIL")
        self.assertEqual(len(evidence["skills"]), 1)

    def test_missing_cwd_response_is_not_successful_removal(self):
        """缺失工作目录结果不能折算成发现零技能。"""
        exit_code, evidence = self.run_probe([], change_listing=lambda listing, _: listing.update(data=[]))
        self.assertEqual(exit_code, 1)
        self.assertEqual(evidence["status"], "FAIL")

    def test_wrong_cwd_response_fails(self):
        """其他工作目录的零技能返回不能替代请求的目录。"""
        def change(listing, root):
            listing["data"][0]["cwd"] = str(root / "other")
        exit_code, evidence = self.run_probe([], change_listing=change)
        self.assertEqual(exit_code, 1)
        self.assertEqual(evidence["status"], "FAIL")

    def test_text_enabled_does_not_count_as_true(self):
        """字符串 false 在 Python 中为真，但不是协议中的布尔启用标志。"""
        def change(listing, _):
            listing["data"][0]["skills"][0]["enabled"] = "false"
        exit_code, evidence = self.run_probe([], expected_count=1, include_skill=True, change_listing=change)
        self.assertEqual(exit_code, 1)
        self.assertEqual(evidence["status"], "FAIL")

    def test_duplicate_skill_paths_cannot_inflate_count(self):
        """同一路径的重复技能不能累计为两个安装项。"""
        def change(listing, _):
            listing["data"][0]["skills"] *= 2
        exit_code, evidence = self.run_probe([], expected_count=2, include_skill=True, change_listing=change)
        self.assertEqual(exit_code, 1)
        self.assertEqual(evidence["status"], "FAIL")

    def test_version_failure_replaces_stale_pass(self):
        """版本探测在协议前失败，也必须覆写旧 PASS 并返回失败退出码。"""
        with tempfile.TemporaryDirectory(prefix="mas-discovery-startup-test-") as directory:
            root = pathlib.Path(directory)
            output = root / "out"
            output.mkdir()
            (output / "verification.json").write_text('{"status":"PASS"}', encoding="utf-8")
            argv = [str(PROBE_PATH), "--executable", sys.executable, "--cwd", str(root),
                    "--skill-root", str(root / "skills"), "--output", str(output),
                    "--client", "test-client", "--expected-count", "0"]
            with mock.patch.object(sys, "argv", argv), \
                    mock.patch.object(PROBE.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "version")), \
                    mock.patch.object(PROBE.subprocess, "Popen") as start, \
                    contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit) as exit_result:
                    PROBE.main()
            evidence = json.loads((output / "verification.json").read_text(encoding="utf-8"))
            self.assertEqual(exit_result.exception.code, 1)
            self.assertEqual(evidence["status"], "FAIL")
            self.assertIn("CalledProcessError", evidence["reason"])
            start.assert_not_called()


if __name__ == "__main__":
    unittest.main()
