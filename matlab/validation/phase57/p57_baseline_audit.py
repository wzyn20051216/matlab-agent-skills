#!/usr/bin/env python3
"""p57_baseline_audit.py -- Phase 5.7 Task 0: prove the Phase 5.6 baseline is intact.

Freezes what the previous phase left behind and checks it is still byte-identical
before any Phase 5.7 code changes are judged:

  1. git state (branch/head, tracked drift, untracked additions)
  2. the nine skills versus the Phase 5.6 commit
  3. the sealed Phase 5.6 evaluation workspace (tasks/answers/episodes/reference)
  4. every historical benchmark/evidence directory still present
  5. raw agent transcripts of the Phase 5.6 episodes still on disk, hashed

Read-only. It writes one report under artifacts/phase57/task0/ and never edits
skills, artifacts from earlier phases, or the evaluation workspace.
"""
import os, sys, json, subprocess, hashlib, glob, datetime, re
from pathlib import Path

# 路径推导而非写死（2026-10-28 路径卫生整改）：
# 仓库根从本文件位置推导，封存评测工作区与仓库同级，客户端根从主目录推导。
_REPO_PATH = Path(__file__).resolve().parents[3]
REPO = str(_REPO_PATH)
EVAL56 = str(_REPO_PATH.parent / (_REPO_PATH.name + "-bench-phase56") / "eval")
TRANSCRIPT_ROOT = str(Path.home() / ".qoder-cn" / "projects" / "E--desktop-MATLAB")
OUT = os.path.join(REPO, "artifacts", "phase57", "task0", "baseline_audit.json")
PHASE56_HEAD = "9543f36"


def run(*args, cwd=REPO):
    p = subprocess.run(args, cwd=cwd, capture_output=True, text=True, encoding="utf-8")
    return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def tree_hash(root):
    """Hash of relative path + content for every file below root."""
    h = hashlib.sha256()
    files = []
    for d, _, names in os.walk(root):
        for n in names:
            files.append(os.path.relpath(os.path.join(d, n), root))
    for rel in sorted(files):
        h.update(rel.replace(os.sep, "/").encode("utf-8") + b"\0")
        h.update(sha256_file(os.path.join(root, rel)).encode("ascii") + b"\n")
    return h.hexdigest(), len(files)


def main():
    doc = {"schema": "mas-phase57-baseline-audit/1",
           "readOnly": True,
           "generatedAt": datetime.datetime.now().isoformat(timespec="seconds")}

    rc, head, _ = run("git", "rev-parse", "HEAD")
    rc2, branch, _ = run("git", "branch", "--show-current")
    rc3, status, _ = run("git", "status", "--porcelain")
    tracked = [l for l in status.splitlines() if l and not l.startswith("??")]
    untracked = [l[3:] for l in status.splitlines() if l.startswith("??")]
    rc4, tags, _ = run("git", "tag", "--points-at", "HEAD")
    rc5, last, _ = run("git", "log", "-1", "--format=%H|%aI|%s")
    doc["git"] = {
        "branch": branch, "head": head, "headShort": head[:7],
        "headIsPhase56Commit": head.startswith(PHASE56_HEAD),
        "tagsAtHead": tags.splitlines() if tags else [],
        "headCommit": last,
        "trackedDrift": tracked,
        "untrackedPhase57": untracked,
        "trackedDriftEmpty": not tracked,
    }
    _, diff56, _ = run("git", "diff", "--stat", "HEAD", "--", "skills", "benchmark",
                       "matlab", "schemas", "docs")
    doc["git"]["diffSinceHeadForFrozenTrees"] = diff56

    skills = sorted(d for d in os.listdir(os.path.join(REPO, "skills"))
                    if os.path.isdir(os.path.join(REPO, "skills", d)))
    rows = []
    for s in skills:
        root = os.path.join(REPO, "skills", s)
        th, n = tree_hash(root)
        rows.append({
            "name": s,
            "skillMd": os.path.isfile(os.path.join(root, "SKILL.md")),
            "nFiles": n,
            "treeSha256": th,
            "nScripts": len(glob.glob(os.path.join(root, "scripts", "*.m"))),
            "nReferences": len(glob.glob(os.path.join(root, "references", "*.md"))),
        })
    doc["skills"] = {
        "n": len(rows),
        "allHaveSkillMd": all(r["skillMd"] for r in rows),
        "rows": rows,
    }

    frozen = []
    checks = [
        ("tasksFrozen", os.path.join(EVAL56, "tasks_frozen.json"), None),
        ("answers", os.path.join(EVAL56, "answers.json"), "5397be4bf001d65b5dae42d1f93665e075b023f4b5240714a909426df634fd2c"),
    ]
    man = json.load(open(os.path.join(EVAL56, "manifest.json"), encoding="utf-8"))
    seal = json.load(open(os.path.join(EVAL56, "seal_manifest.json"), encoding="utf-8"))
    checks[0] = ("tasksFrozen", checks[0][1], man["tasksSha256"])
    reference = os.path.join(REPO, "benchmark", "reference_p56.m")
    checks.append(("reference", reference, seal["referenceSha256"]))
    checks.append(("tasksPublished", os.path.join(REPO, "benchmark", "tasks_p56.json"),
                   seal["tasksPublishedSha256"]))
    checks.append(("episodes", os.path.join(EVAL56, "episodes.json"), seal.get("episodesSha256")))
    for name, path, want in checks:
        rec = {"name": name, "path": path.replace("\\", "/"), "exists": os.path.isfile(path)}
        if rec["exists"]:
            rec["sha256"] = sha256_file(path)
            rec["expected"] = want
            rec["matchesFrozen"] = (want is None or rec["sha256"] == want)
            if name == "episodes":
                ep = json.load(open(path, encoding="utf-8"))
                rec["nEpisodes"] = len(ep.get("episodes", []))
        frozen.append(rec)
    sealed_runs = []
    for arm in ("R1", "R2", "R3"):
        gf = os.path.join(EVAL56, "grade_%s.json" % arm)
        if os.path.isfile(gf):
            g = json.load(open(gf, encoding="utf-8"))
            sealed_runs.append({"arm": arm, "gradeSha256": sha256_file(gf),
                                "nTasks": g.get("nTasks"), "nExecuted": g.get("nExecuted"),
                                "passAll": g.get("passAll"), "agentRuns": g.get("agentRuns")})
    doc["phase56Seal"] = {"files": frozen, "grades": sealed_runs,
                          "sealSchema": seal.get("schema"),
                          "nEpisodes": seal.get("nEpisodes"),
                          "answersSha256": seal.get("answersSha256")}

    hist = []
    for ph in ("phase52", "phase53", "phase54", "phase55", "phase56"):
        root = os.path.join(REPO, "artifacts", ph)
        if not os.path.isdir(root):
            hist.append({"phase": ph, "exists": False})
            continue
        nfiles, nbytes = 0, 0
        for d, _, names in os.walk(root):
            for n in names:
                p = os.path.join(d, n)
                nfiles += 1
                nbytes += os.path.getsize(p)
        hist.append({"phase": ph, "exists": True, "nFiles": nfiles, "bytes": nbytes,
                     "treeSha256": tree_hash(root)[0]})
    doc["historicalArtifacts"] = hist

    tr = []
    pat = re.compile(r"P56-[A-Z]+-[A-Z0-9]+")
    for p in glob.glob(os.path.join(TRANSCRIPT_ROOT, "*", "subagents", "agent-*.jsonl")):
        try:
            text = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        ids = sorted(set(pat.findall(text)))
        if not ids:
            continue
        tr.append({"file": p.replace("\\", "/"), "nBytes": os.path.getsize(p),
                   "sha256": sha256_file(p), "taskIds": ids})
    main_sessions = []
    for p in glob.glob(os.path.join(TRANSCRIPT_ROOT, "*.jsonl")):
        main_sessions.append({"file": p.replace("\\", "/"), "nBytes": os.path.getsize(p),
                              "sha256": sha256_file(p)})
    doc["transcripts"] = {
        "root": TRANSCRIPT_ROOT.replace("\\", "/"),
        "episodeTranscripts": tr,
        "nEpisodeTranscripts": len(tr),
        "taskIdsCovered": sorted({i for t in tr for i in t["taskIds"]}),
        "mainSessions": main_sessions,
        "note": ("Transcripts live outside the repository and are recorded by hash only; "
                 "this audit is evidence that they were preserved, not that they are reproducible."),
    }

    ok = (doc["git"]["trackedDriftEmpty"] and doc["git"]["headIsPhase56Commit"]
          and doc["skills"]["n"] == 9 and doc["skills"]["allHaveSkillMd"]
          and all(f.get("matchesFrozen", False) for f in frozen)
          and all(h.get("exists") for h in hist)
          and len(tr) > 0)
    doc["verdict"] = "PASS" if ok else "FAIL"
    doc["issues"] = []
    if not doc["git"]["trackedDriftEmpty"]:
        doc["issues"].append("tracked files differ from the Phase 5.6 commit")
    if not doc["git"]["headIsPhase56Commit"]:
        doc["issues"].append("HEAD is not the Phase 5.6 commit")
    if doc["skills"]["n"] != 9:
        doc["issues"].append("skill count is not nine")
    for f in frozen:
        if not f.get("matchesFrozen", False):
            doc["issues"].append("frozen file hash mismatch: %s" % f["name"])
    if not tr:
        doc["issues"].append("no Phase 5.6 episode transcripts found")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1, ensure_ascii=False)
    print("HEAD %s (phase56=%s) trackedDrift=%d untracked=%d" % (
        head[:7], doc["git"]["headIsPhase56Commit"], len(tracked), len(untracked)))
    print("skills=%d allSkillMd=%s" % (doc["skills"]["n"], doc["skills"]["allHaveSkillMd"]))
    for f in frozen:
        print("frozen %-12s exists=%s match=%s" % (f["name"], f["exists"], f.get("matchesFrozen")))
    print("history " + " ".join("%s:%s" % (h["phase"], h.get("nFiles", "-")) for h in hist))
    print("episodeTranscripts=%d taskIds=%d mainSessions=%d" % (
        len(tr), len(doc["transcripts"]["taskIdsCovered"]), len(main_sessions)))
    print("verdict=%s issues=%s" % (doc["verdict"], doc["issues"]))
    print("-> %s" % OUT)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
