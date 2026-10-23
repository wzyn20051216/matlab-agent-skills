#!/usr/bin/env python3
"""p56_coder_diagnosis.py -- assemble the channel x entry-form table into one record.

Reads the per-run JSON files written by p56_coder_channel_probe.m,
p56_coder_entry_form_probe.m and p56_coder_syntax_probe.m and reduces them to the
one question this round was asked: does the MATLAB Coder failure follow the
execution CHANNEL (real process vs the MCP dynamic-evaluation frame), or does it
follow something else?

The conclusion is deliberately narrow. It reports which variable flips the
outcome and what remains unexplained; it does not assert a reason inside MATLAB
Coder, and it does not retract Phase 5.5 by editing Phase 5.5 -- the correction is
recorded here and referenced from the new document.
"""
import json, glob, os, hashlib

DIR = r"E:\desktop\MATLAB\artifacts\phase56\coder_channel"
OUT = os.path.join(DIR, "coder_diagnosis.json")

# p56_coder_channel_probe.m was called with a tag argument; the tag names the channel.
CHANNEL_NAME = {"A": "batch-process", "B": "mcp-dynamic-eval", "D": "mcp-run_matlab_file",
                "batch": "batch-process", "mcpfile": "mcp-run_matlab_file",
                "unlabelled": "batch-process (P56_LAUNCHER not set)"}


def load():
    rows = []
    patterns = ["channel_*.json", "form_*.json", "syntax_*.json", "scripttop_*.json"]
    paths = sorted(p for pat in patterns for p in glob.glob(os.path.join(DIR, pat)))
    for p in paths:
        d = json.load(open(p, encoding="utf-8"))
        for it in (d if isinstance(d, list) else [d]):
            it["_src"] = os.path.basename(p)
            # p56_coder_channel_probe.m wrote the tag into a field named "channel"
            if it["_src"].startswith("channel_"):
                tag = it.pop("channel")
                it["tag"] = tag
                it["channel"] = CHANNEL_NAME.get(tag, "?")
                it["form"] = "file"
            elif it["_src"].startswith("scripttop_"):
                # the script records its own launcher in `channel`
                it["channel"] = CHANNEL_NAME.get(it.get("channel"), it.get("channel"))
            table_guard(it)
            rows.append(it)
    return rows


def table_guard(it):
    """Drop the rows produced by a broken early invocation of the entry-form probe.

    The first attempt looped over a cell array with `for t = {...}`, which MATLAB
    iterates element-wise, so one file (form_scriptlocal.json) recorded tag
    'scriptlocal' with form 'inline'. It is not a measurement of anything.
    """
    if it.get("tag") == "scriptlocal":
        it["_discard"] = ("broken first invocation: `for t = {...}` iterates a cell array "
                          "element-wise in MATLAB, so tag and form were scrambled")


def direct_eval_note():
    """The last control was captured from the session log, not a probe file."""
    return {
        "tag": "DIRECT", "channel": "mcp-dynamic-eval", "form": "file-name form typed in the payload",
        "ok": True, "errorIdentifier": "", "source": "session log (manual control, no probe file)",
        "channelIdentity": "mcp-helper-frame-present",
        "call": "codegen('p56coder_entry','-args',{0.5}) written directly in the "
                "evaluate_matlab_code payload (no wrapper function)",
        "meaning": "exonerates the MCP evaluation frame itself for the documented form",
    }


MCP_MARKERS = ("LiveEditorEvaluationHelper", "mcpEval")


def frames_of(r):
    return (r.get("callFrames") or r.get("callStack") or
            r.get("errorFrames") or r.get("errorStack") or r.get("stack") or [])


def channel_identity(r):
    """What the recorded call stack says about where this row ran.

    The `channel` field is a label the probe was told; this is independent of it.
    A batch process has no MATLAB-internal MCP helper on the stack, the MCP tools
    always do.
    """
    text = " ".join(str(f) for f in frames_of(r))
    if any(m in text for m in MCP_MARKERS):
        return "mcp-helper-frame-present"
    return "no-mcp-frame"


def main():
    rows = load()
    dropped = [r for r in rows if r.get("_discard")]
    rows = [r for r in rows if not r.get("_discard")]
    table = []
    for r in rows:
        table.append({
            "tag": r.get("tag") or r.get("channel"),
            "channel": r.get("channel"),
            "form": r.get("form"),
            "ok": bool(r.get("ok")),
            "errorIdentifier": r.get("errorIdentifier", ""),
            "errorMessage": (r.get("errorMessage") or "")[:160],
            "artifacts": len(r.get("artifacts") or []) or r.get("nArtifacts"),
            "elapsedSeconds": r.get("elapsedSeconds"),
            "release": r.get("release"),
            "entryResolvedBy": r.get("entryResolvedBy"),
            "channelIdentity": channel_identity(r),
            "topFrames": frames_of(r)[:3],
            "source": r["_src"],
        })
    table.append(direct_eval_note())

    key = {}
    for t in table:
        k = (t["channel"], bool(t["ok"]))
        key.setdefault(str(k), []).append(t["form"])

    # The decisive cross-tabulation: entry form down the rows, observed channel
    # identity across the columns. Same-cell agreement is what makes the channel
    # claim decidable; harness-confounded rows are excluded from the matrix.
    superseded = {"form_F.json", "form_L.json", "form_scriptlocal.json"}
    matrix = {}
    for t in table:
        t["superseded"] = t["source"] in superseded
        if t["superseded"] or t["tag"] == "DIRECT":
            continue
        matrix.setdefault(str(t["form"]), {})[str(t["channelIdentity"])] = bool(t["ok"])
    supersededNote = {
        "sources": sorted(superseded),
        "identifier": "MATLAB:err_static_workspace_violation",
        "why": "the violation comes from the probe calling run() from inside a function, not "
               "from codegen; p56_coder_scripttop.m re-measures the same entry shape at true "
               "top level and reaches codegen in both channels",
    }

    env = {}
    for p in (os.path.join(DIR, "channel_A.json"), os.path.join(DIR, "channel_B.json"),
              os.path.join(DIR, "channel_D.json")):
        if os.path.isfile(p):
            d = json.load(open(p, encoding="utf-8"))
            env = {"release": d.get("release"), "matlabroot": d.get("matlabroot"),
                   "coderLicenseTest": d.get("coderLicenseTest"),
                   "codegenExists": d.get("codegenExists"),
                   "coderProducts": d.get("toolboxes"),
                   "entryResolvedBy": d.get("entryResolvedBy")}
            break

    doc = {
        "schema": "mas-phase56-coder-diagnosis/3",
        "generatedFrom": sorted(os.path.basename(p) for p in glob.glob(os.path.join(DIR, "*.json"))),
        "discardedRows": [{"tag": r.get("tag"), "form": r.get("form"), "why": r["_discard"]}
                          for r in dropped],
        "environment": env,
        "table": table,
        "byChannelAndOutcome": key,
        "entryFormByChannelMatrix": matrix,
        "supersededRows": supersededNote,
        "finding": [
            "codegen succeeds in BOTH channels when the entry is given as a file name "
            "string: codegen('p56coder_entry','-args',{0.5}) built in a real process "
            "(tag A) and through mcpEval/LiveEditorEvaluationHelper (tags B and DIRECT).",
            "codegen fails in BOTH channels with the same identifier and the same empty "
            "message, emlc:compilationError, whenever the entry is passed as a function "
            "handle -- anonymous (I/K), anonymous with the cell form (O/Q), or a handle to "
            "a function that is a resolvable file on the path (P). The console line that "
            "precedes it is '无法处理选项' (cannot process options).",
            "the handle-to-a-script-local-function case, re-measured at TRUE top level "
            "(p56_coder_scripttop.m, the exact shape Phase 5.5 used), fails the same way in "
            "a real batch process and inside the MCP frame: emlc:compilationError, empty "
            "message, 0 artifacts, in 7.75 s and 5.49 s. So the entry shape Phase 5.5 blamed "
            "the channel for is reproducible without any channel involvement.",
            "the earlier script-local rows (F/L) never reached Coder: they failed with "
            "MATLAB:err_static_workspace_violation, which comes from the probe calling run() "
            "from inside a function. They are kept but marked superseded, not deleted.",
            "run_matlab_file is not a separate execution channel on this host: its recorded "
            "call stack contains the same LiveEditorEvaluationHelper + matlab_mcp/mcpEval "
            "frames as evaluate_matlab_code, so 'file vs inline' is a difference of how the "
            "code is handed over, not of which process runs it. Tag D built 25 artifacts this "
            "way, the same as tag B.",
        ],
        "correction": {
            "whatPhase55Said": "artifacts/phase55/coder_session/coder_diagnosis.json and "
                               "docs/PHASE5_5_AUTONOMY_AND_GAIN_ZH.md section 8 concluded that "
                               "the discriminating variable is the MCP dynamic-evaluation "
                               "channel, because a fresh MCP session failed where "
                               "matlab -batch passed.",
            "whatWasActuallyVaried": "that experiment changed the channel and the entry shape "
                                     "at the same time; its failing case addressed the entry as "
                                     "a handle inside the evaluation frame.",
            "whatThisRoundShows": "with the entry form held fixed, all three ways of running "
                                  "code behave identically: file-name entry builds in batch, "
                                  "in evaluate_matlab_code and in run_matlab_file; handle entry "
                                  "fails in all three. The channel is therefore NOT the "
                                  "discriminating variable; the argument form given to codegen is.",
            "phase55FilesTouched": "none -- the Phase 5.5 record is read-only and was not edited",
        },
        "notClaimed": [
            "the reason codegen rejects the handle forms on this installation is not "
            "established. Whether this is unsupported syntax, a version behaviour, or "
            "something inside MATLAB Coder's option handling cannot be separated from "
            "outside, so no MathWorks internal root cause is asserted.",
            "no official MCP server code was modified, no product was reinstalled, and the "
            "user's MATLAB path was not persisted: addpath/rmpath were paired inside each "
            "probe and no savepath or restoredefaultpath was run.",
            "Simulink Coder, GPU Coder, coder.compileC and mexCinterface were not probed.",
            "the batch and MCP-file rows are single runs each; no timing claim is made from "
            "them, only the pass/fail and identifier.",
        ],
        "ruleGoingForward": [
            "codegen assertions run in a real process AND use the file-name entry form; "
            "an MCP-reported codegen PASS is treated as unverified until reproduced there",
            "skills must not call codegen with a function handle entry, because on this "
            "installation that path yields an empty-message emlc:compilationError with no "
            "diagnostic to act on",
            "a harness that wants to compare channels must hold the entry form fixed; "
            "changing channel and shape together produced the wrong conclusion in Phase 5.5",
        ],
    }
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1, ensure_ascii=False)
    print("rows: %d  products: %s" % (len(table), ", ".join(env.get("coderProducts") or [])))
    for t in table:
        print("  %-8s %-18s %-22s ok=%-5s %s" % (t["tag"], t["channel"], t["form"], t["ok"],
                                                  t["errorIdentifier"]))
    print("-> %s  sha256 %s" % (OUT, hashlib.sha256(open(OUT, "rb").read()).hexdigest()[:16]))


if __name__ == "__main__":
    main()
