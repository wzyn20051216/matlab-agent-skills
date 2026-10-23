"""Run four prompt-free tasks through one Codex client in an isolated project.

The project contains a freshly synced copy of the repository Skills under
`.agents/skills`; no user-level Skills directory is read or written. Each task
runs `codex exec --json` non-interactively, saves the raw event stream, and
summarizes which native mechanisms appeared (skill item, MCP call, shell,
file write). The prompts never name a Skill or a `mas_*` tool.
"""

import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parents[3]
SYNC = REPO / "scripts" / "Sync-Skills.ps1"

TASKS = {
    "A_numeric_matlab": (
        "Use MATLAB to build the 4x4 matrix M = [2 -1 0 0; -1 2 -1 0; 0 -1 2 -1; 0 0 -1 2], "
        "compute its determinant and the largest magnitude of its eigenvalues, and write "
        "them rounded to 6 decimal places as {\"determinant\": ..., \"maxAbsEigenvalue\": ...} "
        "to result.json in the current directory. Run the computation and report the values."
    ),
    "B_simulink_model": (
        "Build a small Simulink model: a Constant block with value 3 connected to a Gain block "
        "with gain 4, and a Display block receiving the Gain output. Save the model as "
        "phase58_model.slx, simulate it, and write the displayed value to result.json as "
        "{\"displayedValue\": ...}. Report whether the model was saved and simulated."
    ),
    "C_control_design": (
        "Design a PID controller for a first-order plant P(s) = 1/(s+1). Target a settling "
        "time below 2 seconds and overshoot below 10% for a unit step. Simulate the closed "
        "loop, then write {\"Kp\": ..., \"Ki\": ..., \"Kd\": ..., \"overshootPercent\": ..., "
        "\"settlingTimeSeconds\": ...} to result.json. Report the gains and achieved metrics."
    ),
    "D_nonmatlab_control": (
        "Explain in three bullet points the main differences between TCP and UDP. "
        "Do not run any commands and do not create files."
    ),
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def decode_output(data):
    """客户端在中文 Windows 上可能按 GBK 写子进程管道；先严格 UTF-8，再退回 GBK。"""
    if not data:
        return ""
    for encoding in ("utf-8", "gbk"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", "replace")


def make_project(project):
    project.mkdir(parents=True, exist_ok=True)
    sync = subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(SYNC),
         "-RepositoryRoot", str(REPO), "-SkillRoot", str(project / ".agents" / "skills")],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=300)
    if sync.returncode != 0:
        raise RuntimeError(f"sync failed: {sync.stderr[-1000:]}")
    start = sync.stdout.find("{")
    summary = json.loads(sync.stdout[start:]) if start >= 0 else {}
    if summary.get("installed") != 9 or summary.get("failed"):
        raise RuntimeError(f"unexpected sync summary: {summary}")
    repo_skills = sorted(p.name for p in (REPO / "skills").glob("matlab-*"))
    local_skills = sorted(p.name for p in (project / ".agents" / "skills").glob("matlab-*"))
    if repo_skills != local_skills:
        raise RuntimeError(f"skill set mismatch: {repo_skills} != {local_skills}")
    for name in repo_skills:
        a = sha256(REPO / "skills" / name / "SKILL.md")
        b = sha256(project / ".agents" / "skills" / name / "SKILL.md")
        if a != b:
            raise RuntimeError(f"SKILL.md hash mismatch for {name}")
    return summary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--executable", required=True)
    ap.add_argument("--entry", default="")
    ap.add_argument("--client", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--project-root", default="")
    ap.add_argument("--approval-mode", choices=("sandbox", "approve-for-me"),
                    default="sandbox")
    ap.add_argument("--task", required=True, choices=sorted(TASKS))
    ap.add_argument("--timeout", type=float, default=600)
    args = ap.parse_args()

    output = pathlib.Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    # 默认放在系统临时目录，避免仓库祖先的 AGENTS.md / git 上下文污染隔离任务。
    # Windows 沙箱在系统临时目录所在的那块盘上创建进程会被拒绝（本机实测 CreateProcessAsUserW=5）；
    # 需要可写夹具时用 --project-root 指到仓库所在的盘。
    if args.project_root:
        project = pathlib.Path(args.project_root).resolve()
        if project.exists():
            shutil.rmtree(project)
        project.mkdir(parents=True)
    else:
        project = pathlib.Path(tempfile.mkdtemp(prefix="p58_codex_task_"))
    record = {
        "schema": "mas-client-task-probe/1",
        "client": args.client,
        "task": args.task,
        "scope": "isolated project; repo Skills synced to .agents/skills; no model prompt names a Skill",
        "prompt": TASKS[args.task],
        "status": "FAIL",
    }
    started = time.monotonic()

    try:
        record["sync"] = make_project(project)
        launcher = [args.executable] + ([args.entry] if args.entry else [])
        approval = (["--approve-for-me"] if args.approval_mode == "approve-for-me"
                    else ["-s", "workspace-write"])
        command = launcher + ["exec", "--json", "--ephemeral", "--skip-git-repo-check",
                              *approval, "-C", str(project), TASKS[args.task]]
        record["approvalMode"] = args.approval_mode
        record["command"] = command
        result = subprocess.run(command, capture_output=True, stdin=subprocess.DEVNULL,
                                timeout=args.timeout)
        stdout = decode_output(result.stdout)
        stderr = decode_output(result.stderr)
        record["exitCode"] = result.returncode
        record["stderrTail"] = stderr[-8000:]
        (output / "stderr.log").write_text(stderr, encoding="utf-8")
        (output / "events.jsonl").write_text(stdout, encoding="utf-8")

        events = []
        for line in stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                events.append({"unparsed": line})
        record["eventCount"] = len(events)
        item_types = {}
        skill_items = []
        mcp_calls = []
        command_calls = []
        skill_path_mentions = []
        for event in events:
            blob = json.dumps(event, ensure_ascii=False)
            if "SKILL.md" in blob:
                skill_path_mentions.append(blob[:4000])
            item = event.get("item") if isinstance(event, dict) else None
            if not isinstance(item, dict):
                continue
            kind = str(item.get("type") or item.get("item_type") or "")
            item_types[kind] = item_types.get(kind, 0) + 1
            if "skill" in kind.lower():
                skill_items.append(item)
            if "mcp" in kind.lower():
                mcp_calls.append(item)
            if kind in ("command_execution", "shell", "exec"):
                command_calls.append(item)
        record["itemTypes"] = item_types
        record["skillItems"] = skill_items
        record["mcpCalls"] = mcp_calls
        record["commandCount"] = len(command_calls)
        record["skillPathMentions"] = skill_path_mentions

        produced = {}
        for path in sorted(project.rglob("*")):
            if path.is_file() and ".agents" not in path.parts:
                rel = path.relative_to(project).as_posix()
                produced[rel] = {"bytes": path.stat().st_size, "sha256": sha256(path)}
                if path.stat().st_size <= 2 * 1024 * 1024:
                    target = output / "artifacts" / rel
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(path, target)
        record["producedFiles"] = produced

        # 结果文件必须由任务真实产生；负控任务明确要求不创建文件。
        has_result = "result.json" in produced
        if args.task == "D_nonmatlab_control":
            record["status"] = "PASS" if result.returncode == 0 and not produced else "FAIL"
        else:
            record["status"] = "PASS" if result.returncode == 0 and has_result else "FAIL"
        record["durationSeconds"] = round(time.monotonic() - started, 1)
    except subprocess.TimeoutExpired as error:
        record["reason"] = f"timeout after {args.timeout}s"
        record["stdoutTail"] = decode_output(error.stdout or b"")[-4000:]
        record["stderrTail"] = decode_output(error.stderr or b"")[-4000:]
    except Exception as error:
        record["reason"] = f"{type(error).__name__}: {error}"
    finally:
        record["finishedUtc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        (output / "verification.json").write_text(
            json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
        shutil.rmtree(project, ignore_errors=True)

    print(json.dumps({"task": args.task, "client": args.client, "status": record["status"],
                      "events": record.get("eventCount"), "produced": list(record.get("producedFiles", {})),
                      "skillItems": len(record.get("skillItems", [])),
                      "reason": record.get("reason")}, ensure_ascii=False))
    sys.exit(0 if record["status"] == "PASS" else 1)


if __name__ == "__main__":
    main()
