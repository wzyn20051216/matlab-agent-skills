#!/usr/bin/env python3
"""p56_stats.py -- join the episode ledger to the sealed grades and apply the protocol.

Inputs are read-only:
  artifacts/phase56/episodes/episodes.json   (what each episode actually did)
  MATLAB-bench-phase56/eval/grade_R*.json    (what the grader decided, post-seal)

Rules come from docs/PHASE5_6_PROTOCOL_ZH.md and are not re-decided here:
  * correctnessPass = verdict Ok AND every declared field Ok (section 3);
  * withinBudget / taskCompleted / deliveryValid are reported separately, never
    folded into one "pass rate";
  * only same-task, same-repeat cells are paired (section 4);
  * the 3 exploratory probe episodes are excluded from every comparison.

This script deliberately prints the gap as loudly as the result: pass 1 is
3 tasks x 3 arms x 1 repeat = 9 of the planned 27 episodes.
"""
import json, os, hashlib, collections
from pathlib import Path

# 路径推导而非写死（2026-10-28 路径卫生整改）：封存评测工作区与仓库同级。
_REPO = Path(__file__).resolve().parents[3]
ARCH = str(_REPO / "artifacts" / "phase56" / "episodes")
EVAL = str(_REPO.parent / (_REPO.name + "-bench-phase56") / "eval")
OUT = os.path.join(ARCH, "statistics.json")
ARMS = ["R1", "R2", "R3"]
BUDGET = 25


def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def load_episodes():
    with open(os.path.join(ARCH, "episodes.json"), encoding="utf-8") as fh:
        return json.load(fh)["episodes"]


def load_grades():
    """arm -> task -> {verdictOk, fields:[{name,ok,detail}], expected, actual}."""
    g = {}
    for arm in ARMS:
        p = os.path.join(EVAL, "grade_%s.json" % arm)
        if not os.path.isfile(p):
            continue
        with open(p, encoding="utf-8") as fh:
            G = json.load(fh)
        rows = G["rows"]
        if isinstance(rows, dict):
            rows = [rows]
        g[arm] = {r["taskId"]: {"expected": r["expectedVerdict"], "actual": r["actualVerdict"],
                                "verdictOk": bool(r["verdictOk"]),
                                "routeOk": bool(r["routeOk"]), "toolOk": bool(r["toolOk"]),
                                "falseAccept": bool(r["falseAccept"]),
                                "fields": [{"name": f["name"], "ok": bool(f["ok"]),
                                            "detail": f["detail"]} for f in r.get("fieldResults") or []]}
                  for r in rows}
    return g


def main():
    eps = load_episodes()
    grades = load_grades()
    sealed_path = os.path.join(EVAL, "episodes.json")

    # the file the seal actually read must still describe the same runs
    ident = lambda e: (e["arm"], e["task"], e["repeat"], e["finishedAt"], e["model"])
    sealed = json.load(open(sealed_path, encoding="utf-8"))["episodes"] if os.path.isfile(sealed_path) else []
    identity_match = sorted(map(ident, sealed)) == sorted(map(ident, eps))

    cells, per_arm = [], collections.OrderedDict((a, []) for a in ARMS)
    for e in sorted(eps, key=lambda x: (x["task"], x["arm"])):
        if e["repeat"] != 1:
            continue
        gr = grades.get(e["arm"], {}).get(e["task"])
        fields_ok = bool(gr) and all(f["ok"] for f in gr["fields"]) and len(gr["fields"]) > 0
        correct = bool(gr) and gr["verdictOk"] and fields_ok
        fail_bits = []
        if gr:
            if not gr["verdictOk"]:
                fail_bits.append("verdict")
            fail_bits += [f["name"] for f in gr["fields"] if not f["ok"]]
        row = {
            "arm": e["arm"], "task": e["task"], "repeat": 1,
            "model": e["model"],
            "invalidForComparison": e["invalidForComparison"],
            "correctnessPass": correct,
            "failingCriteria": fail_bits,
            "withinBudget": e["toolCalls"] <= BUDGET,
            "taskCompleted": e["taskCompleted"],
            "deliveryValid": e["deliveryValid"],
            "toolCalls": e["toolCalls"], "matlabCalls": e["matlabCalls"],
            "matlabErrors": e["matlabErrors"], "wallSeconds": e["wallSeconds"],
            "nativeSkillInvocation": e["nativeSkillInvocation"],
            "undeterminedExpected": bool(gr) and gr["expected"] == "UNDETERMINED",
            "undeterminedDetected": bool(gr) and gr["expected"] == "UNDETERMINED"
                                    and gr["actual"] == "UNDETERMINED",
            "falseAccept": bool(gr) and gr["falseAccept"],
        }
        per_arm[e["arm"]].append(row)
        cells.append(row)

    summary = collections.OrderedDict()
    for arm in ARMS:
        rs = per_arm[arm]
        if not rs:
            continue
        summary[arm] = {
            "nEpisodes": len(rs),
            "correctnessPass": sum(1 for r in rs if r["correctnessPass"]),
            "withinBudget": sum(1 for r in rs if r["withinBudget"]),
            "taskCompleted": sum(1 for r in rs if r["taskCompleted"]),
            "deliveryValid": sum(1 for r in rs if r["deliveryValid"]),
            "invalidForComparison": sum(1 for r in rs if r["invalidForComparison"]),
            "verdictPass": sum(1 for r in rs if grades[arm][r["task"]]["verdictOk"]),
            "falseAccept": sum(1 for r in rs if r["falseAccept"]),
            "falseReject": sum(1 for r in rs
                               if grades[arm][r["task"]]["expected"] == "PASS"
                               and not grades[arm][r["task"]]["verdictOk"]),
            "undeterminedExpected": sum(1 for r in rs if r["undeterminedExpected"]),
            "undeterminedDetected": sum(1 for r in rs if r["undeterminedDetected"]),
            "toolCallsTotal": sum(r["toolCalls"] for r in rs),
            "toolCallsMean": round(sum(r["toolCalls"] for r in rs) / len(rs), 2),
            "matlabCallsTotal": sum(r["matlabCalls"] for r in rs),
            "matlabErrors": sum(r["matlabErrors"] for r in rs),
            "errorsRecovered": sum(1 for r in rs if r["matlabErrors"] > 0 and r["correctnessPass"]
                                   and r["withinBudget"]),
            "wallSecondsTotal": round(sum(r["wallSeconds"] for r in rs), 1),
            "wallSecondsMean": round(sum(r["wallSeconds"] for r in rs) / len(rs), 1),
            "nativeSkillInvocations": sum(1 for r in rs if r["nativeSkillInvocation"]),
        }

    # paired only within the same task and the same repeat (protocol section 4)
    paired = []
    for task in sorted({c["task"] for c in cells}):
        by = {c["arm"]: c for c in cells if c["task"] == task}
        if len(by) != len(ARMS):
            paired.append({"task": task, "complete": False,
                           "note": "not all three arms ran this cell"})
            continue
        v = {a: by[a]["correctnessPass"] for a in ARMS}
        paired.append({
            "task": task, "complete": True, "correctness": v,
            "R3_minus_R1": int(v["R3"]) - int(v["R1"]),
            "R3_minus_R2": int(v["R3"]) - int(v["R2"]),
            "R2_minus_R1": int(v["R2"]) - int(v["R1"]),
            "tools": {a: by[a]["toolCalls"] for a in ARMS},
            "wall": {a: by[a]["wallSeconds"] for a in ARMS},
            "failing": {a: by[a]["failingCriteria"] for a in ARMS},
        })
    n_pair = len([p for p in paired if p["complete"]])
    disc = collections.Counter()
    for p in paired:
        if p["complete"]:
            disc["%+d" % p["R3_minus_R1"]] += 1
    exact = sum(1 for p in paired if p["complete"] and p["R3_minus_R1"] == 0)

    doc = {
        "schema": "mas-phase56-statistics/1",
        "planned": {"tasks": 3, "arms": 3, "repeats": 3, "episodes": 27},
        "executed": {"pass1Episodes": len(cells), "repeatsCompleted": 1,
                     "exploratoryEpisodesExcluded": sum(1 for e in eps if e["repeat"] == 0),
                     "gap": "9 of 27 episodes. The target was NOT met and is reported as a "
                            "shortfall; no success rate is extrapolated from it."},
        "sealedEpisodesFileSha256": sha(sealed_path) if os.path.isfile(sealed_path) else None,
        "rederivedEpisodesFileSha256": sha(os.path.join(ARCH, "episodes.json")),
        "identityMatch": identity_match,
        "identityNote": "the sealed file holds only task/arm/repeat/finishedAt/model; the "
                        "re-derived copy adds error and field counts from the same transcripts",
        "modelAliasSet": sorted({e["model"] for e in eps}),
        "budgetToolCalls": BUDGET,
        "perArm": summary,
        "paired": paired,
        "pairedCells": n_pair,
        "pairedTies": exact,
        "pairedDifferenceDistribution": dict(disc),
        "labelsNotCombined": [
            "correctnessPass (sealed answers, verdict + every declared field)",
            "withinBudget (tool calls <= %d)" % BUDGET,
            "taskCompleted (all published report names delivered)",
            "deliveryValid (parseable by the grader)",
        ],
        "caveats": [
            "strong isolation on this host is BLOCKED (11/11 adversarial vectors reached); "
            "the trust here comes from the two-phase seal, the commitment hash and the "
            "per-call transcript ledger, not from access control",
            "the model is observable only as the client alias %s; alias equality is not "
            "vendor-model-name equality" % ", ".join(sorted({e["model"] for e in eps})),
            "n=1 repeat per cell: these are observations, not a causal estimate of the "
            "Skill exposure effect",
            "grader 'pass' additionally requires routeOk and toolOk; the published prompt "
            "is route-free by design and no arm was asked to declare a skill or a tool, so "
            "grader pass is 0/3 in every arm and is NOT the correctness label",
        ],
    }
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1, ensure_ascii=False)

    print("episodes identity match with the sealed file: %s" % identity_match)
    print("model alias set: %s   planned 27 / executed pass1 %d\n" % (doc["modelAliasSet"], len(cells)))
    hdr = ("arm", "correct", "budget", "done", "valid", "verdict", "undet", "falseA", "falseR",
           "tools", "mcp", "wall s", "skill")
    print("%-4s %8s %7s %5s %6s %8s %6s %7s %7s %6s %5s %7s %6s" % hdr)
    for arm, s in summary.items():
        print("%-4s %d/%-6d %d/%-6d %d/%-3d %d/%-4d %d/%-6d %d/%-4d %-7d %-7d %-6d %-5d %-7.1f %-6d" % (
            arm, s["correctnessPass"], s["nEpisodes"], s["withinBudget"], s["nEpisodes"],
            s["taskCompleted"], s["nEpisodes"], s["deliveryValid"], s["nEpisodes"],
            s["verdictPass"], s["nEpisodes"],
            s["undeterminedDetected"], s["undeterminedExpected"],
            s["falseAccept"], s["falseReject"], s["toolCallsTotal"], s["matlabCallsTotal"],
            s["wallSecondsTotal"], s["nativeSkillInvocations"]))
    print("\npaired cells (same task, same repeat): %d" % n_pair)
    for p in paired:
        if not p["complete"]:
            print("   %-10s %s" % (p["task"], p["note"]))
            continue
        print("   %-10s R1=%-5s R2=%-5s R3=%-5s  d(R3-R1)=%+d d(R3-R2)=%+d  tools R1=%d R2=%d R3=%d" % (
            p["task"], p["correctness"]["R1"], p["correctness"]["R2"], p["correctness"]["R3"],
            p["R3_minus_R1"], p["R3_minus_R2"],
            p["tools"]["R1"], p["tools"]["R2"], p["tools"]["R3"]))
        for arm in ARMS:
            if p["failing"][arm]:
                print("        %s fails: %s" % (arm, ", ".join(p["failing"][arm])))
    print("\nties: %d/%d   difference distribution: %s" % (exact, n_pair, dict(disc)))
    print("-> %s" % OUT)


if __name__ == "__main__":
    main()
