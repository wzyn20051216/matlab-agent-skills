#!/usr/bin/env python
"""Audit a Phase 5.5 subagent transcript for contamination and skill evidence.

Usage:
  python audit_subagent.py --jsonl <subagent.jsonl> --workspace <dir> \
      --arm R3 --task H-SIG-F --out <audit.json>

The transcript is client-native evidence: tool_use records, file paths, MATLAB
MCP arguments and timestamps. A skill name mentioned in prose is recorded as a
mention only and never treated as proof of selection or loading.
"""
import argparse, json, os, re, hashlib
from datetime import datetime

HOLDOUT = "matlab-bench-holdout"
PHASE55 = "matlab-bench-phase55"
INSTALLED = ".qoder-cn/skills"


def norm(p):
    return str(p).replace("\\", "/").rstrip("/").lower()


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for c in content:
            if isinstance(c, dict):
                for k in ("text", "thinking", "content"):
                    if isinstance(c.get(k), str):
                        out.append(c[k])
        return "\n".join(out)
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jsonl", required=True)
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--arm", required=True)
    ap.add_argument("--task", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    ws = norm(a.workspace)
    own_arm = norm(os.path.join(os.path.dirname(os.path.dirname(a.workspace)), ""))
    own_arm = norm(os.path.join(os.path.dirname(a.workspace), ""))
    records = []
    with open(a.jsonl, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                pass

    tool_counts = {}
    mcp_calls, skill_calls, reads, writes, bashes, globs, greps = [], [], [], [], [], [], []
    mentions = []
    errors = []
    timestamps = []
    model = None

    for r in records:
        ts = r.get("timestamp")
        if ts:
            timestamps.append(ts)
        msg = r.get("message") or {}
        if r.get("type") == "assistant":
            model = model or msg.get("model")
            for c in msg.get("content") or []:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "tool_use":
                    name = c.get("name") or "?"
                    tool_counts[name] = tool_counts.get(name, 0) + 1
                    inp = c.get("input") or {}
                    if name == "mcp_call":
                        tool = inp.get("toolName", "")
                        args = inp.get("arguments") or {}
                        code = ""
                        if isinstance(args, dict):
                            code = args.get("code") or (args.get("arguments") or {}).get("code") or ""
                        mcp_calls.append({"tool": tool, "code": code,
                                          "project_path": args.get("project_path", "") if isinstance(args, dict) else ""})
                    elif name == "Skill":
                        skill_calls.append(inp)
                    elif name == "Read":
                        reads.append(inp.get("file_path", ""))
                    elif name == "Write":
                        writes.append(inp.get("file_path", ""))
                    elif name == "Bash":
                        bashes.append(inp.get("command", ""))
                    elif name == "Glob":
                        globs.append(inp.get("pattern", ""))
                    elif name == "Grep":
                        greps.append(inp.get("path", ""))
                elif c.get("type") in ("text", "thinking"):
                    t = text_of([c])
                    for m in re.finditer(r"matlab-[a-z-]+", t):
                        mentions.append(m.group(0))
        elif r.get("type") == "user":
            for c in msg.get("content") or []:
                if isinstance(c, dict) and c.get("type") == "tool_result":
                    body = text_of(c.get("content"))
                    if re.search(r"matlab error|Error using|error:|失败|错误", body, re.I):
                        errors.append(body[:400])

    def in_ws(p):
        return norm(p).startswith(ws)

    violations = []
    for p in reads:
        n = norm(p)
        if in_ws(n):
            continue
        if HOLDOUT in n:
            violations.append(("ANSWER_ACCESS", p))
        elif PHASE55 in n:
            if n.startswith(own_arm):
                continue
            violations.append(("OTHER_ARM_ACCESS", p))
        elif re.search(r"e:/desktop/matlab(?!-)", n):
            violations.append(("REPO_ACCESS", p))
        elif INSTALLED in n:
            violations.append(("INSTALLED_SKILL_ACCESS", p))
    for w in writes:
        if not in_ws(w):
            violations.append(("WRITE_OUTSIDE_WORKSPACE", w))
    for code, origin in [(c["code"], "mcp") for c in mcp_calls] + [(b, "bash") for b in bashes]:
        n = norm(code)
        if HOLDOUT in n or re.search(r"answers\.json|score_spec|grade_phase55", n):
            violations.append(("ANSWER_OR_GRADER_REFERENCE", origin + ": " + code[:200]))
        if re.search(r"e:/desktop/matlab(?!-)", n) or re.search(r"e:\\\\desktop\\\\matlab(?!-)", n):
            violations.append(("REPO_REFERENCE", origin + ": " + code[:200]))
        if "savepath" in n:
            violations.append(("CONFIG_WRITE", origin + ": " + code[:200]))
        if origin == "bash" and re.search(r"matlab(\.exe)?\s+-batch|matlab\s+-r\b", n):
            violations.append(("CLI_MATLAB_EXECUTION", code[:200]))
    for c in mcp_calls:
        if c.get("project_path"):
            n = norm(c["project_path"])
            if re.search(r"e:/desktop/matlab(?!-)", n):
                violations.append(("MCP_PROJECT_PATH_REPO", c["project_path"]))

    result_path = os.path.join(a.workspace, "result.json")
    result = None
    if os.path.isfile(result_path):
        try:
            result = json.load(open(result_path, encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            result = {"_unreadable": str(e)}

    unique_violations = []
    seen = set()
    for k, v in violations:
        key = (k, str(v)[:300])
        if key not in seen:
            seen.add(key)
            unique_violations.append({"kind": k, "detail": str(v)[:400]})

    invalid_kinds = {"ANSWER_ACCESS", "OTHER_ARM_ACCESS", "REPO_ACCESS", "WRITE_OUTSIDE_WORKSPACE",
                     "ANSWER_OR_GRADER_REFERENCE", "REPO_REFERENCE", "CONFIG_WRITE",
                     "CLI_MATLAB_EXECUTION", "MCP_PROJECT_PATH_REPO"}
    invalid = any(v["kind"] in invalid_kinds for v in unique_violations)
    if a.arm == "R1" and (skill_calls or any(v["kind"] == "INSTALLED_SKILL_ACCESS" for v in unique_violations)):
        invalid = True

    elapsed = None
    if len(timestamps) >= 2:
        try:
            t0 = datetime.fromisoformat(timestamps[0].replace("Z", "+00:00"))
            t1 = datetime.fromisoformat(timestamps[-1].replace("Z", "+00:00"))
            elapsed = round((t1 - t0).total_seconds(), 1)
        except Exception:  # noqa: BLE001
            pass

    audit = {
        "schema": "mas-phase55-audit/1",
        "arm": a.arm,
        "task": a.task,
        "workspace": a.workspace,
        "transcript": a.jsonl,
        "transcriptSha256": sha256(a.jsonl),
        "model": model,
        "firstTimestamp": timestamps[0] if timestamps else None,
        "lastTimestamp": timestamps[-1] if timestamps else None,
        "elapsedS": elapsed,
        "toolCounts": tool_counts,
        "mcpCalls": len(mcp_calls),
        "mcpTools": sorted({c["tool"] for c in mcp_calls}),
        "mcpCode": [c["code"][:1200] for c in mcp_calls],
        "skillToolCalls": skill_calls,
        "skillNameMentions": sorted(set(mentions)),
        "readPaths": reads,
        "writePaths": writes,
        "bashCommands": bashes,
        "globPatterns": globs,
        "grepPaths": greps,
        "errorSignals": errors[:20],
        "violations": unique_violations,
        "invalid": invalid,
        "resultFile": result_path,
        "result": result,
        "resultSha256": sha256(result_path) if os.path.isfile(result_path) else None,
    }
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    json.dump(audit, open(a.out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print(json.dumps({k: audit[k] for k in ("arm", "task", "elapsedS", "mcpCalls",
                                            "skillToolCalls", "invalid", "violations",
                                            "result")}, ensure_ascii=False, indent=1)[:3000])


if __name__ == "__main__":
    main()
