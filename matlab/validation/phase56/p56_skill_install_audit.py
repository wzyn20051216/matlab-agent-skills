#!/usr/bin/env python3
"""p56_skill_install_audit.py -- compare the repo's skills against every installed copy.

Task 3 asks for the user-level vs project-level precedence review. That review is
only meaningful if "installed" is checked rather than assumed, so this walks the
discovery roots the client actually reads and reports, per skill: whether it is
present at all, and whether its SKILL.md and scripts/ still match the repo.

Read-only by design. It never writes to, renames, or deletes an install directory
-- the Phase 5.6 constraints forbid touching the user's real Skills roots, and a
stale copy is a finding to report, not a thing to silently overwrite.
"""
import os, json, hashlib, glob, sys
from pathlib import Path

# 路径推导而非写死（2026-10-28 路径卫生整改）：
# 仓库根从本文件位置推导，用户级根从主目录推导，不出现任何机器专属绝对路径。
_REROOT = Path(__file__).resolve().parents[3]
REPO = str(_REROOT / "skills")
ROOTS = {
    "user:qoder-cn": str(Path.home() / ".qoder-cn" / "skills"),
    "user:workbuddy": str(Path.home() / ".workbuddy" / "skills"),
    "project": str(_REROOT / ".qoder" / "skills"),
}
OUT = str(_REROOT / "artifacts" / "phase56" / "skills_install_audit.json")


def sha(p):
    if not os.path.isfile(p):
        return None
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def main():
    skills = sorted(d for d in os.listdir(REPO) if os.path.isdir(os.path.join(REPO, d)))
    rows = []
    for root_label, root in list(ROOTS.items()) + [("repo", REPO)]:
        exists = os.path.isdir(root)
        for s in skills:
            d = os.path.join(root, s)
            scripts = glob.glob(os.path.join(d, "scripts", "*.m")) if exists else []
            rows.append({
                "root": root_label, "rootPath": root.replace("\\", "/"),
                "rootExists": exists, "skill": s,
                "installed": os.path.isdir(d),
                "skillMdSha256": sha(os.path.join(d, "SKILL.md")),
                "nScripts": len(scripts),
                "nReferences": len(glob.glob(os.path.join(d, "references", "*.md"))) if exists else 0,
            })
    base = {r["skill"]: r for r in rows if r["root"] == "repo"}
    for r in rows:
        b = base[r["skill"]]
        r["matchesRepo"] = (r["skillMdSha256"] == b["skillMdSha256"]
                           and r["nScripts"] == b["nScripts"])
        r["missingScriptsVsRepo"] = b["nScripts"] - r["nScripts"]

    summary = []
    for label, root in list(ROOTS.items()) + [("repo", REPO)]:
        rs = [r for r in rows if r["root"] == label]
        summary.append({
            "root": label, "path": root.replace("\\", "/"), "rootExists": os.path.isdir(root),
            "nSkillsInstalled": sum(1 for r in rs if r["installed"]),
            "nSkillsOf": len(rs),
            "nIdenticalToRepo": sum(1 for r in rs if r["installed"] and r["matchesRepo"]),
            "nStaleOrDivergent": sum(1 for r in rs if r["installed"] and not r["matchesRepo"]),
            "scriptsTotal": sum(r["nScripts"] for r in rs if r["installed"]),
            "absentSkills": [r["skill"] for r in rs if not r["installed"]],
        })
    doc = {
        "schema": "mas-phase56-skill-install-audit/1",
        "readOnly": True,
        "rows": rows, "roots": summary,
        "consequence": [
            "an episode that loads an installed SKILL.md loads a copy that is not the "
            "repo's current text, so 'the Skills are installed and usable' and 'the Skills "
            "in this repository are what the agent sees' are two different claims",
            "the Phase 5.6 arms are unaffected: R2/R3 were staged from the repository tree "
            "(p56_stage.m copies from <repo>/skills), not from an install root",
            "no install directory was written to, renamed or removed by this round",
        ],
    }
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1, ensure_ascii=False)
    for s in summary:
        print("%-15s exists=%-5s installed=%d/%d identical=%d divergent=%d scripts=%d absent=%s" % (
            s["root"], s["rootExists"], s["nSkillsInstalled"], s["nSkillsOf"],
            s["nIdenticalToRepo"], s["nStaleOrDivergent"], s["scriptsTotal"],
            ",".join(s["absentSkills"]) or "-"))
    print("-> %s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
