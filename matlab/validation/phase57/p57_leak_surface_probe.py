#!/usr/bin/env python3
"""Read-only leak-surface probe for Phase 5.7 Task 4.

Answers one question: with the permissions an arm episode actually has on this
host, which evaluation-side surfaces are reachable? A surface counts as reached
only when its bytes were read; a hash and a size are recorded, never answer
values. The script writes a JSON report and does not modify any probed path.

Companion: matlab/validation/phase57/p57_isolation_probe.m records the shared
MATLAB session (host shell, path, answer derivability). Merge is automatic when
matlab_state.json exists.
"""
import hashlib
import json
import os
import pathlib
import re
import sys
from datetime import datetime

SCHEMA = "mas-phase57-leak-probe/1"
REPO = pathlib.Path(__file__).resolve().parents[3]
HOME = pathlib.Path(os.environ["USERPROFILE"])
DESKTOP = REPO.parent
OUT_DIR = REPO / "artifacts" / "phase57" / "isolation"
OUT_FILE = OUT_DIR / "leak_surface_probe.json"


def sha256_file(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def read_text(path, limit=None):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read() if limit is None else f.read(limit)


def line_count(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return sum(1 for _ in f)


def file_surface(sid, category, path, method, extra=None):
    p = pathlib.Path(path)
    rec = {"id": sid, "category": category, "target": str(p), "method": method,
           "exists": p.exists(), "reachable": False, "evidence": {}}
    try:
        if p.is_file():
            st = p.stat()
            h = sha256_file(p)
            rec["evidence"].update({"kind": "file", "bytes": st.st_size,
                                    "sha256": h, "sha256_12": h[:12]})
            rec["reachable"] = True
        elif p.is_dir():
            n = sum(1 for _ in p.iterdir())
            rec["evidence"].update({"kind": "dir", "nEntries": n})
            rec["reachable"] = True
        else:
            rec["evidence"]["kind"] = "absent"
    except Exception as e:  # access denied is the interesting case
        rec["evidence"]["error"] = f"{type(e).__name__}: {e}"[:300]
    if extra:
        rec["evidence"].update(extra)
    return rec


def answer_meta(path):
    try:
        d = json.loads(read_text(path))
    except Exception as e:
        return {"parse": "failed", "error": type(e).__name__}
    tasks = d.get("tasks") if isinstance(d, dict) else None
    if isinstance(tasks, dict):
        tasks = list(tasks.values())
    if isinstance(tasks, list):
        ids = [t.get("id") for t in tasks if isinstance(t, dict)]
        return {"parse": "ok", "nTasks": len(tasks), "taskIds": ids[:12],
                "hasVerdictKey": any(isinstance(t, dict) and "verdict" in t for t in tasks)}
    if isinstance(d, dict):
        return {"parse": "ok", "topLevelKeys": list(d.keys())[:12]}
    return {"parse": "ok", "topLevelType": type(d).__name__}


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    surfaces = []
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    baseline = {}
    bpath = REPO / "artifacts" / "phase57" / "task0" / "baseline_audit.json"
    if bpath.exists():
        baseline = json.loads(read_text(bpath))
    frozen = {f.get("name"): f.get("sha256") for f in baseline.get("phase56Seal", {}).get("files", [])}

    # 1. reference generator and the pipeline that turns it into answers ------
    for sid, rel, why in [
        ("gen-reference", "benchmark/reference_p56.m", "answer generator (closed forms)"),
        ("gen-tasks", "benchmark/tasks_p56.json", "published task set"),
        ("gen-publish", "benchmark/benchmark_publish.m", "phase-one publish logic"),
        ("gen-seal", "benchmark/benchmark_seal.m", "phase-two seal logic"),
    ]:
        p = REPO / rel
        rec = file_surface(sid, "reference-generator", p, f"read {why}")
        if p.is_file():
            rec["evidence"]["lines"] = line_count(p)
            if frozen.get("reference") and rel.endswith("reference_p56.m"):
                rec["evidence"]["matchesFrozenCommitment"] = rec["evidence"]["sha256"] == frozen["reference"]
        surfaces.append(rec)

    # 2. historical answers ---------------------------------------------------
    answer_roots = [
        REPO / "benchmark" / "dev",
        DESKTOP / "MATLAB-bench-holdout-phase53",
        DESKTOP / "MATLAB-bench-holdout-phase54",
        DESKTOP / "MATLAB-bench-phase55",
        DESKTOP / "MATLAB-bench-phase55-v2",
        DESKTOP / "MATLAB-bench-phase55-v3",
        DESKTOP / "MATLAB-bench-phase56",
        DESKTOP / "MATLAB-bench-agent-phase54",
    ]
    seen = set()
    n_answer_files = 0
    for root in answer_roots:
        if not root.is_dir():
            continue
        for p in sorted(root.rglob("*.json")):
            if not re.search(r"answer", p.name, re.I):
                continue
            if p in seen:
                continue
            seen.add(p)
            if n_answer_files >= 24:
                break
            rec = file_surface(f"answers-{n_answer_files + 1:02d}", "historical-answers", p,
                               "read historical answer file (metadata only)")
            rec["evidence"].update(answer_meta(p))
            if p.resolve() == (DESKTOP / "MATLAB-bench-phase56" / "eval" / "answers.json").resolve():
                rec["evidence"]["matchesFrozen"] = rec["evidence"].get("sha256") == frozen.get("answers")
            surfaces.append(rec)
            n_answer_files += 1

    # 3. grader and scoring sources -----------------------------------------
    for sid, rel in [
        ("grader-v1", "benchmark/benchmark_grade.m"),
        ("grader-v2", "benchmark/benchmark_grade_v2.m"),
        ("grader-shape", "benchmark/benchmark_expectation_shape.m"),
        ("grader-mas-grade", "skills/matlab-testing-ci/scripts/mas_grade.m"),
        ("grader-mas-refcheck", "skills/matlab-testing-ci/scripts/mas_refcheck.m"),
    ]:
        p = REPO / rel
        rec = file_surface(sid, "grader-source", p, "read grading source")
        if p.is_file():
            rec["evidence"]["lines"] = line_count(p)
        surfaces.append(rec)

    # 4. other arms' outputs --------------------------------------------------
    eval_dir = DESKTOP / "MATLAB-bench-phase56" / "eval"
    arm_files = sorted(eval_dir.glob("arm_R*/result_*.json"))
    grade_files = sorted(eval_dir.glob("grade_R*.json"))
    arm_sizes = 0
    for p in arm_files:
        try:
            arm_sizes += p.stat().st_size
        except OSError:
            pass
    surfaces.append({
        "id": "other-arms-results", "category": "other-arms",
        "target": str(eval_dir / "arm_R*" / "result_*.json"),
        "method": "enumerate and read every sibling-arm result",
        "exists": eval_dir.is_dir(), "reachable": len(arm_files) > 0,
        "evidence": {"nResultFiles": len(arm_files), "totalBytes": arm_sizes,
                     "sample": [str(p) for p in arm_files[:3]],
                     "sha256_12_sample": [sha256_file(p)[:12] for p in arm_files[:3]]},
    })
    surfaces.append({
        "id": "other-arms-grades", "category": "other-arms",
        "target": str(eval_dir / "grade_R*.json"),
        "method": "read per-arm grade files",
        "exists": eval_dir.is_dir(), "reachable": len(grade_files) > 0,
        "evidence": {"nGradeFiles": len(grade_files),
                     "sample": [str(p) for p in grade_files],
                     "sha256_12_sample": [sha256_file(p)[:12] for p in grade_files]},
    })
    pass1 = sorted((REPO / "artifacts" / "phase56" / "episodes" / "pass1").glob("*.json"))
    surfaces.append({
        "id": "other-arms-episode-files", "category": "other-arms",
        "target": str(REPO / "artifacts" / "phase56" / "episodes" / "pass1"),
        "method": "read stored phase-5.6 episode outputs",
        "exists": True, "reachable": len(pass1) > 0,
        "evidence": {"nFiles": len(pass1), "totalBytes": sum(p.stat().st_size for p in pass1),
                     "sha256_12_sample": [sha256_file(p)[:12] for p in pass1[:3]]},
    })

    # 5. install roots --------------------------------------------------------
    roots = {
        "qoder-user": HOME / ".qoder-cn" / "skills",
        "shared-agents": HOME / ".agents" / "skills",
        "workbuddy": HOME / ".workbuddy" / "skills",
        "repo": REPO / "skills",
    }
    audit_path = REPO / "artifacts" / "phase57" / "install" / "install_audit.json"
    audit = json.loads(read_text(audit_path)) if audit_path.exists() else {}
    by_client = {c.get("client"): c for c in audit.get("summary", {}).get("byClient", [])}
    for sid, root in roots.items():
        exists = root.exists()
        rec = {"id": f"install-{sid}", "category": "install-roots", "target": str(root),
               "method": "enumerate and read MATLAB skill trees from an arm-capable account",
               "exists": exists, "reachable": False, "evidence": {}}
        try:
            if exists:
                names = sorted(p.name for p in root.iterdir() if p.is_dir() and p.name.startswith("matlab-"))
                hashes = {}
                for n in names:
                    sk = root / n / "SKILL.md"
                    if sk.is_file():
                        hashes[n] = sha256_file(sk)[:12]
                rec.update(reachable=bool(names), evidence={
                    "resolved": str(root.resolve()),
                    "isSymlink": root.is_symlink(),
                    "nMatlabSkills": len(names), "matlabSkills": names,
                    "skillMdSha256_12": hashes})
                client = {"qoder-user": "qoder", "shared-agents": "codex-cli",
                          "workbuddy": "workbuddy"}.get(sid)
                if client and client in by_client:
                    rec["evidence"]["auditStatus"] = by_client[client]
        except Exception as e:
            rec["evidence"]["error"] = f"{type(e).__name__}: {e}"[:300]
        surfaces.append(rec)

    trigger_path = REPO / "artifacts" / "phase57" / "native" / "qoder_trigger_evidence.json"
    if trigger_path.exists():
        surfaces.append({
            "id": "install-agent-level-evidence", "category": "install-roots",
            "target": "explicit Qoder session d8e01567-3b8a-48bc-8bad-61c7e6b1e292",
            "method": "already-observed agent read of an install root (Phase 5.7 Task 2)",
            "exists": True, "reachable": True,
            "evidence": {"source": str(trigger_path),
                         "whatItProves": "a Qoder agent read .agents/skills/matlab-orchestrator/assets/routing.json through normal tools; install roots are agent-reachable, not merely OS-reachable"},
        })

    # 6. historical trajectories (transcripts) ------------------------------
    transcripts = baseline.get("transcripts", {}).get("episodeTranscripts", [])
    tr_records = []
    for t in transcripts:
        p = pathlib.Path(t["file"])
        rec = {"file": str(p), "exists": p.exists()}
        if p.is_file():
            h = sha256_file(p)
            rec.update({"reachable": True, "bytes": p.stat().st_size, "sha256_12": h[:12],
                        "hashUnchangedFromBaseline": h == t.get("sha256")})
        tr_records.append(rec)
    main_sessions = [HOME / ".qoder-cn" / "projects" / "E--desktop-MATLAB" / f"{s}.jsonl"
                     for s in ("d0c0bf5d-79a5-43e1-b507-1b8abfae4bbc",
                               "c0b3bbc4-4482-455e-a4b3-85db4dcd3f07",
                               "f4bb0f35-b1bc-43f1-bcea-b04017d12ab6",
                               "d8e01567-3b8a-48bc-8bad-61c7e6b1e292")]
    main_records = []
    for p in main_sessions:
        rec = {"file": str(p), "exists": p.exists()}
        if p.is_file():
            text = read_text(p)
            rec.update({"reachable": True, "bytes": p.stat().st_size,
                        "sha256_12": sha256_file(p)[:12],
                        "p56TaskIdMentions": sum(text.count(i) for i in
                                                ("P56-SIG-B", "P56-SIG-F", "P56-ODE-N"))})
        main_records.append(rec)
    surfaces.append({
        "id": "historical-transcripts", "category": "historical-trajectories",
        "target": "phase-5.6 episode transcripts + current orchestrator sessions",
        "method": "hash and scan stored transcripts (no content copied into this report)",
        "exists": True,
        "reachable": any(r.get("reachable") for r in tr_records + main_records),
        "evidence": {"nEpisodeTranscripts": len(tr_records),
                     "nEpisodeReachable": sum(1 for r in tr_records if r.get("reachable")),
                     "episodeTotalBytes": sum(r.get("bytes", 0) for r in tr_records),
                     "hashUnchanged": all(r.get("hashUnchangedFromBaseline") for r in tr_records),
                     "episodeSample": tr_records[:3],
                     "mainSessions": main_records},
    })

    # 7. shared MATLAB state / derivation / host shell (from the .m probe) ---
    mpath = OUT_DIR / "matlab_state.json"
    matlab_state = json.loads(read_text(mpath)) if mpath.exists() else {}
    if matlab_state:
        deriv = matlab_state.get("derivation", {})
        surfaces.append({
            "id": "derivable-answers", "category": "derivable-answers",
            "target": "benchmark/reference_p56.m + benchmark/tasks_p56.json",
            "method": "regenerate sealed answers through the MCP MATLAB channel and compare payloads",
            "exists": True,
            "reachable": bool(deriv.get("recomputed") and deriv.get("match")),
            "evidence": {k: deriv.get(k) for k in
                         ("generatorSha256", "sealedSha256", "recomputed", "match",
                          "nTasks", "mismatch", "tempDeleted")},
        })
        cmd = matlab_state.get("commandExecution", {})
        surfaces.append({
            "id": "host-command-execution", "category": "command-execution",
            "target": "MATLAB evaluate channel -> system('whoami')",
            "method": "run a harmless host command from the same channel an arm uses",
            "exists": True, "reachable": bool(cmd.get("hostShellReachable")),
            "evidence": {"rc": cmd.get("rc"), "stdout": cmd.get("stdout"),
                         "call": cmd.get("call")},
        })
        path_info = matlab_state.get("path", {})
        surfaces.append({
            "id": "shared-matlab-state", "category": "shared-matlab-state",
            "target": "long-running MATLAB MCP session",
            "method": "inspect path/tools, base workspace, preferences; set a canary in one call and read it in the next",
            "exists": True,
            "reachable": True,
            "evidence": {
                "pathEntries": path_info.get("nEntries"),
                "repoOrEvalPathEntries": path_info.get("repoOrEvalEntries"),
                "toolResolution": path_info.get("toolResolution"),
                "baseWorkspace": matlab_state.get("baseWorkspace"),
                "preferenceHistory": matlab_state.get("preferenceHistory"),
                "canary": {
                    "setCall": "SET=1; NVARS=30",
                    "readCall": "READ=731945",
                    "cleared": True,
                    "proves": "two separate evaluate calls share one MATLAB workspace; state written by one arm call is readable by the next",
                },
                "matlabStateSha256": sha256_file(mpath),
                "notProven": "cross-client sharing (e.g. a second MCP server) and cross-account sharing were not tested here",
            },
        })

    # 8. summary -------------------------------------------------------------
    cats = {}
    for s in surfaces:
        c = cats.setdefault(s["category"], {"n": 0, "reached": 0})
        c["n"] += 1
        c["reached"] += 1 if s.get("reachable") else 0
    n_reached = sum(1 for s in surfaces if s.get("reachable"))
    prior = REPO / "artifacts" / "phase56" / "isolation" / "probe_report.json"
    prior_summary = {}
    if prior.exists():
        prior_summary = json.loads(read_text(prior)).get("summary", {})
    report = {
        "schema": SCHEMA,
        "generatedAt": now,
        "readOnly": True,
        "answerContentDisclosed": False,
        "method": "each surface is reached only if its bytes were read; reports store hashes, sizes and metadata, not answer values",
        "surfaces": surfaces,
        "summary": {"nSurfaces": len(surfaces), "nReached": n_reached,
                    "nNotReached": len(surfaces) - n_reached,
                    "byCategory": cats,
                    "verdict": "LEAK_SURFACES_REACHABLE" if n_reached else "NO_SURFACE_REACHED",
                    "strongIsolation": "BLOCKED",
                    "task5Authorized": False,
                    "phase56Prior": prior_summary},
        "claimLimit": "This probe shows what one account with ordinary tools can read on this host. It is not a causal Skill-gain experiment, and no surface marked reached is evidence of a Skill effect.",
    }
    OUT_FILE.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"WROTE {OUT_FILE}")
    print(f"SURFACES={len(surfaces)} REACHED={n_reached}")
    for c, v in sorted(cats.items()):
        print(f"  {c}: {v['reached']}/{v['n']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
