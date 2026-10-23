"""Sync the repo Skills into a temporary project and let Codex discover them.

This exercises the real client discovery engine (app-server skills/list) against
a freshly synced root. It never reads or writes a real user-level Skills root.
"""

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import uuid


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def finish(output, record, transcript, start, root):
    record["durationMs"] = round((time.monotonic() - start) * 1000)
    record["finishedUtc"] = dt.datetime.now(dt.timezone.utc).isoformat()
    record["fixtureRoot"] = str(root)
    record["fixtureRemoved"] = False
    (output / "protocol.json").write_text(json.dumps(transcript, ensure_ascii=False, indent=2), encoding="utf-8")
    (output / "verification.json").write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
    shutil.rmtree(root, ignore_errors=True)
    record["fixtureRemoved"] = not root.exists()
    (output / "verification.json").write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"status": record["status"], "client": record["client"],
                      "version": record.get("version"), "skills": len(record.get("skills", [])),
                      "reason": record.get("reason"), "output": str(output)}, ensure_ascii=False))
    raise SystemExit(0 if record["status"] == "PASS" else 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--executable", required=True)
    ap.add_argument("--client", required=True)
    ap.add_argument("--repo", default=str(pathlib.Path(__file__).resolve().parents[3]))
    ap.add_argument("--output", required=True)
    ap.add_argument("--timeout", type=float, default=60)
    args = ap.parse_args()

    repo = pathlib.Path(args.repo).resolve(strict=True)
    output = pathlib.Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    root = pathlib.Path(tempfile.gettempdir()) / f"p58_codex_isolated_{uuid.uuid4().hex}"
    project = root / "project"
    skills = project / ".agents" / "skills"
    backups = root / "backups"
    project.mkdir(parents=True)

    transcript = []
    start = time.monotonic()
    record = {
        "schema": "mas-client-skill-discovery/1",
        "phase": "5.8",
        "client": args.client,
        "scope": "isolated project root; sync then client skills/list; no model call",
        "status": "FAIL",
        "startedUtc": dt.datetime.now(dt.timezone.utc).isoformat(),
    }

    sync_script = repo / "scripts" / "Sync-Skills.ps1"
    sync_cmd = [
        "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(sync_script),
        "-RepositoryRoot", str(repo), "-SkillRoot", str(skills), "-BackupRoot", str(backups),
    ]
    try:
        sync_run = subprocess.run(sync_cmd, capture_output=True, text=True, encoding="utf-8",
                                  errors="replace", timeout=180)
        text = sync_run.stdout
        begin = text.find("{")
        sync = json.loads(text[begin:]) if sync_run.returncode == 0 and begin >= 0 else None
        record["sync"] = {
            "exitCode": sync_run.returncode,
            "ok": sync_run.returncode == 0 and sync is not None,
            "installed": (sync or {}).get("installed"),
            "updated": (sync or {}).get("updated"),
            "unchanged": (sync or {}).get("unchanged"),
            "skillRoot": str(skills),
        }
        if not record["sync"]["ok"] or record["sync"]["installed"] != 9:
            raise RuntimeError("isolated sync did not install all 9 Skills")
        repo_hashes = {p.parent.name: sha256(p) for p in sorted((repo / "skills").glob("matlab-*/SKILL.md"))}
        synced_hashes = {p.parent.name: sha256(p) for p in sorted(skills.glob("matlab-*/SKILL.md"))}
        record["hashesMatchRepo"] = repo_hashes == synced_hashes
        if not record["hashesMatchRepo"]:
            raise RuntimeError("synced SKILL.md hashes do not match the repository")
    except Exception as error:
        record["reason"] = f"{type(error).__name__}: {error}"
        finish(output, record, transcript, start, root)

    try:
        executable = str(pathlib.Path(args.executable).resolve(strict=True))
        version = subprocess.run([executable, "--version"], capture_output=True, text=True,
                                 timeout=15, check=True).stdout.strip()
        command = [executable, "app-server", "--listen", "stdio://"]
        record.update(version=version, command=command, cwd=str(project), skillRoot=str(skills))
    except Exception as error:
        record["reason"] = f"{type(error).__name__}: {error}"
        finish(output, record, transcript, start, root)

    received = queue.Queue()
    with (output / "stderr.log").open("wb") as stderr:
        try:
            process = subprocess.Popen(command, cwd=str(project), stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=stderr, text=True, encoding="utf-8")
        except Exception as error:
            record["reason"] = f"{type(error).__name__}: {error}"
            finish(output, record, transcript, start, root)

        def read_stdout():
            try:
                for line in process.stdout:
                    received.put(line)
            finally:
                received.put(None)

        threading.Thread(target=read_stdout, daemon=True).start()

        def request(method, params, request_id):
            message = {"id": request_id, "method": method, "params": params}
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()
            transcript.append({"direction": "send", "message": message})
            deadline = time.monotonic() + args.timeout
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"{method} timeout")
                line = received.get(timeout=remaining)
                if line is None:
                    raise RuntimeError("client exited before responding")
                reply = json.loads(line)
                transcript.append({"direction": "receive", "message": reply})
                if reply.get("id") == request_id:
                    if "error" in reply:
                        raise RuntimeError(json.dumps(reply["error"], ensure_ascii=False))
                    return reply["result"]

        try:
            record["initialize"] = request("initialize", {
                "clientInfo": {"name": "mas_phase58_probe", "version": "1.0"},
                "capabilities": {"experimentalApi": True}}, 1)
            process.stdin.write(json.dumps({"method": "initialized", "params": {}}) + "\n")
            process.stdin.flush()
            result = request("skills/list", {"cwds": [str(project)], "forceReload": True}, 2)
            (output / "skills_list_response.json").write_text(
                json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
            entries = result.get("data")
            if not isinstance(entries, list) or len(entries) != 1:
                raise ValueError("skills/list did not return exactly one cwd entry")
            if pathlib.Path(entries[0]["cwd"]).resolve() != project.resolve():
                raise ValueError("skills/list cwd mismatch")
            errors = entries[0].get("errors", [])
            if errors:
                raise ValueError(f"discovery errors: {errors}")
            found = []
            for skill in entries[0].get("skills", []):
                path = pathlib.Path(skill["path"]).resolve()
                try:
                    path.relative_to(skills.resolve())
                except ValueError:
                    continue
                if skill.get("enabled") is True and skill["name"].startswith("matlab-"):
                    found.append(skill)
            record["skills"] = found
            record["discoveryErrors"] = errors
            record["expectedCount"] = 9
            record["status"] = "PASS" if len(found) == 9 else "FAIL"
            if record["status"] == "FAIL":
                record["reason"] = f"isolated root supplied 9 Skills but client listed {len(found)}"
        except Exception as error:
            record["status"] = "FAIL"
            record["reason"] = f"{type(error).__name__}: {error}"
        finally:
            try:
                process.stdin.close()
            except (BrokenPipeError, OSError):
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
    finish(output, record, transcript, start, root)


if __name__ == "__main__":
    main()
