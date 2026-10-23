"""Read-only file-level install plan for Phase 5.8.

Compares the repository skills tree against each discovered install root and
emits every file that would be added, overwritten, left identical, or kept as a
user file. It never writes to an install root.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path

# Derived from this file's location so the plan is portable: nothing below
# bakes a machine-specific checkout path into the evidence.
REPO = Path(__file__).resolve().parents[3]

ROOTS = [
    {
        "id": "qoder-project",
        "client": "qoder",
        "path": str(REPO / ".qoder" / "skills"),
        "targeted": False,
        "reason": "Project-level root is absent; Qoder observed precedence uses the user root.",
    },
    {
        "id": "qoder-user",
        "client": "qoder",
        "path": r"C:\Users\23201\.qoder-cn\skills",
        "targeted": True,
        "reason": "Qoder override log gives this root precedence.",
    },
    {
        "id": "agents-shared",
        "client": "qoder+codex",
        "path": r"C:\Users\23201\.agents\skills",
        "targeted": True,
        "reason": "Both Codex clients list 9/9 from this root; Qoder falls back here.",
    },
    {
        "id": "workbuddy-user",
        "client": "workbuddy",
        "path": r"C:\Users\23201\.workbuddy\skills",
        "targeted": True,
        "reason": "Client-visible path is behind a linked .workbuddy directory; sync must target the physical path, resolved here with realpath.",
    },
    {
        "id": "codex-user",
        "client": "codex",
        "path": r"C:\Users\23201\.codex\skills",
        "targeted": False,
        "reason": "Legacy root; observed Codex discovery uses .agents/skills, not this root.",
    },
]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree(root):
    root = Path(root)
    out = {}
    if not root.is_dir():
        return out
    for p in sorted(root.rglob("*")):
        if p.is_file():
            rel = p.relative_to(root).as_posix()
            out[rel] = {"sha256": sha256_file(p), "size": p.stat().st_size}
    return out


def manifest_info(root):
    p = Path(root) / ".matlab-agent-skills-manifest.json"
    info = {"path": str(p), "exists": p.is_file()}
    if not p.is_file():
        return info
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001 - evidence must report malformed manifests
        info["parseError"] = str(exc)
        return info
    info["repository"] = data.get("repository", "")
    info["ownedByRepo"] = os.path.normcase(os.path.abspath(data.get("repository", ""))) == os.path.normcase(
        os.path.abspath(str(REPO))
    )
    info["skills"] = sorted((data.get("skills") or {}).keys())
    info["generatedAt"] = data.get("generatedAt", "")
    return info


def existing_backups(root):
    p = Path(root) / ".matlab-agent-skills" / "backups"
    if not p.is_dir():
        return {"path": str(p), "exists": False, "sessions": []}
    sessions = []
    for s in sorted(p.iterdir()):
        if not s.is_dir():
            continue
        files = [f for f in s.rglob("*") if f.is_file()]
        sessions.append(
            {
                "name": s.name,
                "fileCount": len(files),
                "size": sum(f.stat().st_size for f in files),
                "hasPayload": any(f.name != "manifest.json" for f in files),
            }
        )
    return {"path": str(p), "exists": True, "sessions": sessions}


def classify(repo_files, installed_files, managed, installed):
    add = sorted(set(repo_files) - set(installed_files))
    keep = sorted(set(installed_files) - set(repo_files))
    overwrite = sorted(
        rel for rel in set(repo_files) & set(installed_files) if repo_files[rel]["sha256"] != installed_files[rel]["sha256"]
    )
    identical = sorted(
        rel for rel in set(repo_files) & set(installed_files) if repo_files[rel]["sha256"] == installed_files[rel]["sha256"]
    )
    if not installed:
        decision = "install"
    elif not add and not overwrite and not keep:
        decision = "unchanged"
    elif managed:
        decision = "update"
    else:
        decision = "conflict"
    return {
        "decision": decision,
        "requiresForce": decision == "conflict",
        "add": add,
        "overwrite": overwrite,
        "identical": identical,
        "keepUserFiles": keep,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=str(REPO))
    ap.add_argument("--out", default=str(REPO / "artifacts" / "phase58" / "install" / "file_level_plan.json"))
    ap.add_argument("--csv", default=str(REPO / "artifacts" / "phase58" / "install" / "file_level_plan.csv"))
    args = ap.parse_args()

    repo = Path(args.repo)
    skills = sorted(p for p in (repo / "skills").iterdir() if p.is_dir() and p.name.startswith("matlab-"))
    repo_trees = {p.name: tree(p) for p in skills}

    plan = {
        "schema": "p58-install-file-plan/1",
        "readOnly": True,
        "repoRoot": str(repo),
        "repoSkillCount": len(skills),
        "roots": [],
    }
    csv_rows = ["rootId,skill,action,path,repoSha256,installedSha256,requiresForce"]

    for spec in ROOTS:
        path = Path(spec["path"])
        physical = Path(spec.get("physicalPath") or os.path.realpath(path))
        exists = physical.is_dir()
        root_rec = {
            "id": spec["id"],
            "client": spec["client"],
            "path": spec["path"],
            "physicalPath": str(physical),
            "pathIsLink": os.path.normcase(os.path.abspath(path)) != os.path.normcase(os.path.abspath(physical)),
            "exists": exists,
            "targeted": spec["targeted"],
            "reason": spec["reason"],
            "manifest": manifest_info(physical) if exists else {"path": str(physical / ".matlab-agent-skills-manifest.json"), "exists": False},
            "backups": existing_backups(physical) if exists else {"path": str(physical / ".matlab-agent-skills" / "backups"), "exists": False, "sessions": []},
            "skills": [],
            "keepRootEntries": [],
        }
        if exists:
            managed = root_rec["manifest"].get("ownedByRepo", False)
            for name in repo_trees:
                inst = tree(physical / name) if (physical / name).is_dir() else {}
                rec = classify(repo_trees[name], inst, managed, bool(inst))
                rec["name"] = name
                rec["installed"] = bool(inst)
                rec["installedFileCount"] = len(inst)
                rec["repoFileCount"] = len(repo_trees[name])
                root_rec["skills"].append(rec)
                for action in ("add", "overwrite", "identical", "keepUserFiles"):
                    for rel in rec[action]:
                        csv_rows.append(
                            ",".join(
                                [
                                    spec["id"],
                                    name,
                                    action,
                                    rel,
                                    repo_trees[name].get(rel, {}).get("sha256", ""),
                                    inst.get(rel, {}).get("sha256", ""),
                                    str(rec["requiresForce"]).lower(),
                                ]
                            )
                        )
            repo_names = set(repo_trees)
            for entry in sorted(physical.iterdir(), key=lambda p: p.name):
                if entry.name in repo_names:
                    continue
                root_rec["keepRootEntries"].append(
                    {"name": entry.name, "type": "dir" if entry.is_dir() else "file"}
                )
        plan["roots"].append(root_rec)

    totals = {
        "add": 0,
        "overwrite": 0,
        "identical": 0,
        "keepUserFiles": 0,
        "conflicts": 0,
        "updates": 0,
        "installs": 0,
        "unchanged": 0,
        "targetedRoots": sum(1 for r in plan["roots"] if r["targeted"]),
        "nonTargetedRoots": sum(1 for r in plan["roots"] if not r["targeted"]),
    }
    by_root = {}
    for root in plan["roots"]:
        acc = {"add": 0, "overwrite": 0, "identical": 0, "keepUserFiles": 0,
               "conflicts": 0, "updates": 0, "installs": 0, "unchanged": 0,
               "keepRootEntries": len(root["keepRootEntries"])}
        for s in root["skills"]:
            acc["add"] += len(s["add"])
            acc["overwrite"] += len(s["overwrite"])
            acc["identical"] += len(s["identical"])
            acc["keepUserFiles"] += len(s["keepUserFiles"])
            key = {"conflict": "conflicts", "update": "updates", "install": "installs", "unchanged": "unchanged"}[s["decision"]]
            acc[key] += 1
        by_root[root["id"]] = acc
        if root["targeted"]:
            for key in ("add", "overwrite", "identical", "keepUserFiles", "conflicts", "updates", "installs", "unchanged"):
                totals[key] += acc[key]
    plan["totals"] = totals
    plan["byRoot"] = by_root

    Path(args.out).write_text(json.dumps(plan, indent=1, ensure_ascii=True) + "\n", encoding="utf-8", newline="\n")
    Path(args.csv).write_text("\n".join(csv_rows) + "\n", encoding="utf-8", newline="\n")
    print(json.dumps(totals, indent=1))
    for root in plan["roots"]:
        print(
            root["id"],
            "targeted=" + str(root["targeted"]),
            "manifestOwned=" + str(root["manifest"].get("ownedByRepo", False)),
            "add=" + str(sum(len(s["add"]) for s in root["skills"])),
            "overwrite=" + str(sum(len(s["overwrite"]) for s in root["skills"])),
            "keepUser=" + str(sum(len(s["keepUserFiles"]) for s in root["skills"])),
        )


if __name__ == "__main__":
    main()
