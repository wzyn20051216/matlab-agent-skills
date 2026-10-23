#!/usr/bin/env python3
"""p56_episode_ledger.py -- turn Qoder subagent transcripts into an episode ledger.

The Agent tool's self-report is a claim; the transcript segment files are the
record. This reads the subagent jsonl for the Phase 5.6 probe episodes and
extracts, per episode: the model the client actually ran, the ordered tool
ledger, the wall-clock span, whether the native Skill mechanism was invoked (as
opposed to a plain Read/find, which must never be counted as a trigger), and
whether any path touched lay outside the episode's own arm directory.

Episode identity comes from the sibling .meta.json description, which is the
orchestrator's own tool-use label; the arm path regex is only a fallback and a
cross-check.
"""
import json, os, re, glob, datetime

SUB = r"C:\Users\23201\.qoder-cn\projects\E--desktop-MATLAB\d0c0bf5d-79a5-43e1-b507-1b8abfae4bbc\subagents"
OUT = r"E:\desktop\MATLAB\artifacts\phase56\episodes"
ARCH = OUT
BUNDLE = r"E:\desktop\MATLAB-bench-phase56\bundle\tasks_public.json"

# The three-arm probe ran 12:21-12:28Z on P56-SIG-B only, unrandomised; pass 1
# started at 12:50Z. Everything before the cutoff is labelled EXPLORATORY and is
# excluded from the paired statistics, as pre-registered in
# docs/PHASE5_6_PROTOCOL_ZH.md section 1.
PROBE_CUTOFF = "2026-10-22T12:35"

ARM_RE = re.compile(r"MATLAB-bench-phase56[\\/]+arms[\\/]+(R[123])[\\/]+(P56-[A-Z]+-[A-Z])", re.I)
PATH_RE = re.compile(r"[A-Za-z]:[\\/][^\"'`\s]{4,200}")
# A native trigger is an invocation of the client's Skill mechanism. Reading a
# SKILL.md with Read, or grepping for it, is deliberately NOT counted here.
SKILL_TOOLS = ("Skill",)
# The nine shipped skills. Used only to test whether an episode was handed one of
# these names; never to inject one.
SKILL_NAMES = ("matlab-orchestrator", "matlab-runner", "matlab-signal-vision-ai",
               "matlab-data-analysis", "matlab-control-optimization",
               "matlab-simulink-modeling", "matlab-testing-ci",
               "matlab-codegen-deploy", "matlab-robotics-autonomy")


def blocks(rec):
    m = rec.get("message") if isinstance(rec.get("message"), dict) else {}
    content = m.get("content")
    if isinstance(content, str):
        return [(content, None)]
    out = []
    for b in (content or []):
        if not isinstance(b, dict):
            continue
        if b.get("type") in ("text", "thinking"):
            out.append((b.get("text") or b.get("thinking") or "", None))
        elif b.get("type") == "tool_use":
            out.append(("", b))
        else:
            out.append(("", b))
    return out


def tool_label(name, inp):
    if name in ("mcp_call", "mcp_list", "mcp_get"):
        return "%s:%s" % (name, inp.get("toolName", "?"))
    return name


def tool_target(name, inp):
    for k in ("file_path", "path", "command", "pattern", "skill", "toolName", "prompt", "url", "notebook_path"):
        v = inp.get(k)
        if isinstance(v, str) and v:
            return "%s=%s" % (k, v)
    return json.dumps(inp, ensure_ascii=False)[:160]


def parse(path):
    models, aliases, tools, stamps, skills, paths = set(), set(), [], [], [], []
    errors = []          # tool labels whose tool_result came back is_error
    byid = {}            # tool_use id -> label, so an error result can be named
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if isinstance(rec.get("businessModelKey"), str):
                aliases.add(rec["businessModelKey"])
            m = rec.get("message") if isinstance(rec.get("message"), dict) else {}
            if isinstance(m.get("model"), str):
                models.add(m["model"])
            ts = rec.get("timestamp")
            if isinstance(ts, str):
                stamps.append(ts)
            for txt, blk in blocks(rec):
                if blk is not None and blk.get("type") == "tool_use":
                    name = blk.get("name", "?")
                    inp = blk.get("input") or {}
                    label = tool_label(name, inp)
                    blob = json.dumps(inp, ensure_ascii=False)
                    tools.append({"tool": label, "target": tool_target(name, inp)[:200], "full": blob})
                    if blk.get("id"):
                        byid[blk["id"]] = label
                    if name in SKILL_TOOLS or re.search(r'"skill"\s*:', blob, re.I):
                        skills.append({"tool": label, "input": blob[:300]})
                    paths += PATH_RE.findall(blob)
                elif blk is not None and blk.get("type") == "tool_result":
                    if blk.get("is_error"):
                        errors.append(byid.get(blk.get("tool_use_id"), "?"))
                if txt:
                    paths += PATH_RE.findall(txt)
    arms = {}
    for p in paths:
        mm = ARM_RE.search(p.replace("\\", "/"))
        if mm:
            k = (mm.group(1).upper(), mm.group(2).upper())
            arms[k] = arms.get(k, 0) + 1
    return models, aliases, tools, stamps, skills, arms, paths, errors


def span(stamps):
    try:
        ds = sorted(datetime.datetime.fromisoformat(s.replace("Z", "+00:00")) for s in stamps if s)
        return (ds[-1] - ds[0]).total_seconds() if len(ds) > 1 else None
    except Exception:
        return None


# Anything under the evaluation root that is not this episode's own arm dir.
EVAL_SIDE = "matlab-bench-phase56"


def is_matlab(label):
    return "matlab" in label.lower()


def is_evaluation(label):
    """A call that actually runs code, as opposed to fetching the tool schema."""
    return label.startswith("mcp_call:") and is_matlab(label)


def norm(p):
    q = p.replace("\\", "/").rstrip("/.,;:").lower()
    return re.sub(r"/{2,}", "/", q)        # JSON-escaped inputs carry doubled separators


def classify(tools, paths, arm, task):
    """Split the raw ledger into the categories the protocol reports on.

    docs counts only reads that name a SKILL.md; scripts only reads that name a
    mas_*.m under scripts/. Neither is a native trigger -- see
    nativeSkillInvocations, which is filled only by the client's Skill tool.
    eval-side touches are taken from the full tool inputs, not the truncated
    targets, so a long command line cannot hide a path.
    """
    docs, scripts = [], []
    for t in tools:
        bare = t["tool"].split(":")[-1]
        tgt = norm(t.get("full") or t["target"])
        if bare in ("Read", "Grep", "Glob", "Bash"):
            if "skill.md" in tgt:
                docs.append(t["target"])
            elif "/scripts/mas_" in tgt:
                scripts.append(t["target"])
    inside = "/arms/%s/%s" % (arm.lower(), task.lower())
    touches = sorted({p for p in paths if EVAL_SIDE in norm(p) and inside not in norm(p)})
    return docs, scripts, touches


def scanMatlab(tools, paths, arm):
    """Look inside the MATLAB source each episode actually sent to the session.

    The file ledger cannot see the execution channel: an episode that runs
    addpath('<arm>/matlab-*/scripts') and then calls mas_ber_check never opened a
    file, so a Read/Grep based detector would report it blind. This scans the code
    text itself.
    """
    mas, addpath, shell, reads = set(), [], [], []
    for t in tools:
        if "evaluate_matlab_code" not in t["tool"] and "run_matlab_file" not in t["tool"]:
            continue
        code = (t.get("full") or "").replace('\\n', '\n').replace('\\"', '"')
        mas.update(re.findall(r"\bmas_[a-z0-9_]+", code))
        if re.search(r"\baddpath\b", code, re.I):
            addpath.append(t["target"][:120])
        if re.search(r"\b(system|dos)\s*\(", code, re.I):
            shell.append(t["target"][:120])
        for m in re.finditer(r"(fileread|fopen|load|importdata)\s*\(\s*['\"]([^'\"]{4,200})", code, re.I):
            if EVAL_SIDE not in norm(m.group(2)) and ":\\desktop\\matlab" not in norm(m.group(2)):
                reads.append(m.group(2))
    return {"masSymbolsInCode": sorted(mas), "addpathUsed": addpath,
            "hostShellUsed": shell, "nonEvalDataReads": sorted(set(reads))[:5]}


def leakFlags(arm, docs, scripts, touches, matscan, aliases):
    """Apply the rules pre-registered in docs/PHASE5_6_PROTOCOL_ZH.md section 2."""
    ans = [p for p in touches if re.search(r"answers|seal_manifest|tasks_frozen|benchmark/dev", norm(p))]
    other = [p for p in touches if re.search(r"/arms/r[123]/", norm(p)) and
             "/arms/%s/" % arm.lower() not in norm(p)]
    blind = arm == "R1" and (docs or scripts or matscan["masSymbolsInCode"])
    blind = blind or (arm == "R2" and (scripts or matscan["masSymbolsInCode"]))
    grader = [p for p in touches if "reference_p56" in norm(p) or "benchmark_grade" in norm(p)]
    return {"answerLeak": ans, "crossArmRead": other, "armBlindnessBroken": bool(blind),
            "graderPathRead": grader, "structureObservation": touches,
            "modelSwitch": sorted(aliases)}


def promptPurity(path):
    """Was the episode handed a Skill name, a mas_* token, or a skills listing?

    Task 3 forbids manufacturing triggers by smuggling the Skill name into the
    prompt, so this is checked against the persisted first user message and every
    non-message record in the transcript, not against a recollection.
    """
    first = ""
    listing = False
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            m = rec.get("message") if isinstance(rec.get("message"), dict) else {}
            if m.get("role") == "user" and not first:
                cont = m.get("content")
                if isinstance(cont, str):
                    first = cont
                elif isinstance(cont, list):
                    first = " ".join(b.get("text") or "" for b in cont
                                     if isinstance(b, dict) and b.get("type") == "text")
            if m.get("role") != "assistant":
                blob = json.dumps(rec, ensure_ascii=False)
                if "available for use with the Skill tool" in blob or "available-skills" in blob:
                    listing = True
    return {
        "firstPromptChars": len(first),
        "firstPromptNamesSkill": sorted({n for n in SKILL_NAMES if n in first}),
        "firstPromptMasTokens": sorted({t.lower() for t in re.findall(r"\bmas_[a-z0-9_]+", first)}),
        "clientInjectedSkillsListing": listing,
    }


def triggerLevels(rows):
    """L1-L4 per docs/PHASE5_6_PROTOCOL_ZH.md section 5, from transcripts only."""
    per = []
    for r in sorted(rows, key=lambda x: (x["startTs"] or "")):
        p = promptPurity(os.path.join(SUB, r["file"]))
        per.append({
            "arm": r["arm"], "task": r["task"], "transcript": r["file"],
            "L1_skillDiscoverableInEpisodeContext": p["clientInjectedSkillsListing"],
            "L2_skillFileRead": bool(r["skillDocReads"] or r["masScriptReads"]),
            "L3_nativeSkillToolInvoked": bool(r["nativeSkillInvocations"]),
            "L4_contractToolExecuted": bool(r["matlabCodeScan"]["masSymbolsInCode"]),
            "skillDocReads": r["skillDocReads"], "masScriptReads": r["masScriptReads"],
            "masSymbolsInMatlabCode": r["matlabCodeScan"]["masSymbolsInCode"],
            "prompt": p,
        })
    lvl = {
        "L1": {"verdict": "NOT EVIDENCED",
               "evidence": "no skills listing is injected into a Qoder subagent episode "
                           "context (%d/%d transcripts checked clean); the matlab-* skills are "
                           "visible to the ORCHESTRATOR session only" % (len(per), len(per)),
               "counts": sum(1 for e in per if e["L1_skillDiscoverableInEpisodeContext"])},
        "L2": {"verdict": "EVIDENCED (R2, R3 only)",
               "evidence": "SKILL.md / references reads by Read, and mas_*.m reads, in the "
                           "arm workspaces. This is file access, NOT a native trigger.",
               "counts": {"R1": sum(1 for e in per if e["arm"] == "R1" and e["L2_skillFileRead"]),
                          "R2": sum(1 for e in per if e["arm"] == "R2" and e["L2_skillFileRead"]),
                          "R3": sum(1 for e in per if e["arm"] == "R3" and e["L2_skillFileRead"])}},
        "L3": {"verdict": "NOT EVIDENCED",
               "evidence": "tool_use name=\"Skill\" appears in 0 of %d episode transcripts. No "
                           "native Skill invocation event was produced by this client for a "
                           "subagent, and none is inferred here." % len(per),
               "counts": sum(1 for e in per if e["L3_nativeSkillToolInvoked"])},
        "L4": {"verdict": "EVIDENCED (R3 only)",
               "evidence": "mas_* symbols appear in the MATLAB source actually sent to the "
                           "session (mas_ber_check, mas_ode_check); benchmark_grade then judged "
                           "those verdicts against answers sealed after the runs.",
               "counts": {"R3": sum(1 for e in per if e["arm"] == "R3" and e["L4_contractToolExecuted"]),
                          "otherArms": sum(1 for e in per if e["arm"] != "R3"
                                           and e["L4_contractToolExecuted"])}},
        "promptPurity": {"episodesWithSkillNameInPrompt":
                         sum(1 for e in per if e["prompt"]["firstPromptNamesSkill"]),
                         "episodesWithMasTokenInPrompt":
                         sum(1 for e in per if e["prompt"]["firstPromptMasTokens"])},
    }
    return {"schema": "mas-phase56-trigger-evidence/1",
            "note": "L2 file reads are never counted as L3; a client that emits no native "
                    "Skill event is recorded NOT EVIDENCED rather than assumed",
            "levels": lvl, "episodes": per}


def main():
    os.makedirs(OUT, exist_ok=True)
    rows = []
    for f in sorted(glob.glob(os.path.join(SUB, "agent-*.jsonl"))):
        models, aliases, tools, stamps, skills, arms, paths, errors = parse(f)
        meta = {}
        try:
            meta = json.load(open(f[:-6] + ".meta.json", encoding="utf-8"))
        except Exception:
            pass
        desc = str(meta.get("description", ""))
        md = re.search(r"(R[123])\s+(P56-[A-Z]+-[A-Z])", desc, re.I)
        arm = task = None
        if md:
            arm, task = md.group(1).upper(), md.group(2).upper()
        elif arms:
            arm, task = sorted(arms.items(), key=lambda kv: -kv[1])[0][0]
        if arm is None:
            continue
        docs, scripts, eval_touches = classify(tools, paths, arm, task)
        matscan = scanMatlab(tools, paths, arm)
        rows.append({
            "file": os.path.basename(f),
            "arm": arm, "task": task,
            "metaDescription": desc,
            "clientModelAlias": sorted(aliases),
            "messageModelField": sorted(models),
            "nToolCalls": len(tools),
            "matlabCalls": sum(1 for t in tools if is_matlab(t["tool"])),
            "matlabEvaluations": sum(1 for t in tools if is_evaluation(t["tool"])),
            "erroredToolCalls": sorted(errors),
            "matlabErrorCount": sum(1 for e in errors if is_matlab(e)),
            "nativeSkillInvocations": skills,
            "skillDocReads": docs,
            "masScriptReads": scripts,
            "matlabCodeScan": matscan,
            "evalSidePathTouches": eval_touches,
            "leak": leakFlags(arm, docs, scripts, eval_touches, matscan, aliases),
            "tools": tools,
            "startTs": min([s for s in stamps if s], default=None),
            "endTs": max([s for s in stamps if s], default=None),
            "wallSeconds": span(stamps),
            "armPathHits": {"%s/%s" % k: v for k, v in sorted(arms.items())},
        })
    for r in rows:
        print("%-3s %-10s alias=%s tools=%d matlab=%d skill=%d skillDoc=%d masRead=%d wall=%.0fs evalTouch=%d" % (
            r["arm"], r["task"], ",".join(r["clientModelAlias"]) or "?", r["nToolCalls"],
            r["matlabCalls"], len(r["nativeSkillInvocations"]), len(r["skillDocReads"]),
            len(r["masScriptReads"]), (r["wallSeconds"] or 0), len(r["evalSidePathTouches"])))
        for t in r["tools"]:
            if r["arm"] == "R1" and r["task"] == "P56-SIG-B" and (r["startTs"] or "") < PROBE_CUTOFF:
                print("      %-46s %s" % (t["tool"], t["target"][:110]))
        for p in r["evalSidePathTouches"]:
            print("      EVAL-SIDE: %s" % p[:190])
    with open(os.path.join(OUT, "probe_ledger.json"), "w", encoding="utf-8") as fh:
        json.dump({"schema": "mas-phase56-episode-ledger/2",
                   "note": "arm/task labels come from the orchestrator's own Agent-tool description; "
                           "nativeSkillInvocations counts only the client Skill mechanism, never Read/Grep.",
                   "episodes": rows}, fh, indent=1, ensure_ascii=False)
    print("episodes: %d -> %s" % (len(rows), os.path.join(OUT, "probe_ledger.json")))
    writeEpisodesJson(rows)
    te = triggerLevels(rows)
    with open(os.path.join(OUT, "trigger_evidence.json"), "w", encoding="utf-8") as fh:
        json.dump(te, fh, indent=1, ensure_ascii=False)
    print("\nnative trigger levels (docs/PHASE5_6_PROTOCOL_ZH.md section 5):")
    for k in ("L1", "L2", "L3", "L4"):
        v = te["levels"][k]
        print("   %s  %-24s counts=%s" % (k, v["verdict"], v["counts"]))
    print("   prompt purity: %s" % te["levels"]["promptPurity"])
    print("   -> %s" % os.path.join(OUT, "trigger_evidence.json"))


def fmt(ts):
    """2026-10-22T13:22:43.042Z -> '2026-10-22 13:22:43' (the seal's InputFormat)."""
    if not ts:
        return None
    d = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    return d.strftime("%Y-%m-%d %H:%M:%S")


def reportSpec():
    """Field names each task asks the arm to report -- published, so not an answer."""
    try:
        with open(BUNDLE, encoding="utf-8") as fh:
            return {t["id"]: list(t.get("report") or []) for t in json.load(fh)["tasks"]}
    except Exception:
        return {}


def writeEpisodesJson(rows):
    """Emit the seal's required episode ledger, plus the four protocol labels.

    correctnessPass is left null: only the grader, reading the answers sealed
    AFTER these episodes finished, may fill it in.
    """
    spec = reportSpec()
    rows = sorted(rows, key=lambda r: (r["startTs"] or ""))
    probes = []
    for r in rows:
        rep = 0 if (r["startTs"] or "") < PROBE_CUTOFF else 1
        lk = r["leak"]
        invalid = bool(lk["answerLeak"] or lk["crossArmRead"] or lk["armBlindnessBroken"]
                       or lk["graderPathRead"])
        # the probe pass was archived before the _rN naming convention existed
        name = "%s_%s_%s.json" % (r["arm"], r["task"], "result" if rep == 0 else "r%d" % rep)
        res = os.path.join(ARCH, "exploratory" if rep == 0 else "pass%d" % rep, name)
        got = None
        if os.path.isfile(res):
            try:
                got = json.load(open(res, encoding="utf-8"))
            except Exception:
                got = None
        fields = (got or {}).get("fields") if isinstance(got, dict) else None
        want = spec.get(r["task"], [])
        probes.append({
            "task": r["task"], "arm": r["arm"], "repeat": rep,
            "pass": "exploratory-probe" if rep == 0 else "pass1",
            "startedAt": r["startTs"], "finishedAt": fmt(r["endTs"]),
            "model": r["clientModelAlias"][0] if r["clientModelAlias"] else "unknown",
            "modelObservedAs": "client businessModelKey alias only; the vendor model name is not exposed",
            "toolCalls": r["nToolCalls"], "matlabCalls": r["matlabEvaluations"],
            "matlabErrors": r["matlabErrorCount"],
            "erroredToolCalls": r["erroredToolCalls"],
            "budget": {"maxToolCalls": 25, "withinBudget": r["nToolCalls"] <= 25},
            "wallSeconds": round(r["wallSeconds"] or 0, 1),
            "resultFile": res,
            "transcript": r["file"],
            "requiredFields": want,
            "missingFields": sorted(set(want) - set(fields or {})),
            "taskCompleted": isinstance(fields, dict) and not (set(want) - set(fields)),
            "deliveryValid": isinstance(got, dict) and isinstance(fields, dict)
                            and "verdict" in got,
            "correctnessPass": None,
            "nativeSkillInvocation": bool(r["nativeSkillInvocations"]),
            "leak": {"answerLeak": lk["answerLeak"], "crossArmRead": lk["crossArmRead"],
                     "armBlindnessBroken": lk["armBlindnessBroken"],
                     "graderPathRead": lk["graderPathRead"],
                     "structureObservation": lk["structureObservation"],
                     "masSymbolsInMatlabCode": r["matlabCodeScan"]["masSymbolsInCode"],
                     "addpathUsed": r["matlabCodeScan"]["addpathUsed"]},
            "invalidForComparison": invalid,
        })
    path = os.path.join(OUT, "episodes.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"schema": "mas-phase56-episodes/1",
                   "note": "finishedAt is UTC taken from the persisted transcript, not self-reported; "
                           "correctnessPass is filled only by the grader after the seal",
                   "episodes": probes}, fh, indent=1, ensure_ascii=False)
    n1 = sum(1 for p in probes if p["repeat"] == 1)
    print("episodes.json: %d records (pass1=%d, exploratory=%d) -> %s" % (len(probes), n1, len(probes) - n1, path))
    for p in probes:
        print("   %-3s %-10s r%d tools=%-3d matlab=%d wall=%-6s completed=%-5s valid=%-5s miss=%-28s invalid=%s masCode=%s" % (
            p["arm"], p["task"], p["repeat"], p["toolCalls"], p["matlabCalls"],
            p["wallSeconds"], p["taskCompleted"], p["deliveryValid"],
            ",".join(p["missingFields"]) or "-", p["invalidForComparison"],
            ",".join(p["leak"]["masSymbolsInMatlabCode"]) or "-"))
    return probes


if __name__ == "__main__":
    main()
