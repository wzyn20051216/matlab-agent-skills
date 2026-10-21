"""从各客户端原始证据生成 Phase 4.4 独立验收报告；不执行 MATLAB 或客户端。"""

import argparse
import copy
import datetime as dt
import hashlib
import json
import math
import pathlib
import re


SKILLS = {
    "matlab-orchestrator", "matlab-runner", "matlab-control-optimization",
    "matlab-data-analysis", "matlab-codegen-deploy", "matlab-robotics-autonomy",
    "matlab-signal-vision-ai", "matlab-simulink-modeling", "matlab-testing-ci",
}
REQUIRED_LOADS = {"matlab-orchestrator", "matlab-runner", "matlab-control-optimization"}
EXECUTION_TOOLS = {"run_matlab_file", "evaluate_matlab_code"}


def check(status, reason, **details):
    """将证据状态与原因分开保存，未执行不能折算成通过。"""
    return {"status": status, "executed": status != "NOT_EXECUTED", "reason": reason, **details}


def artifact(path):
    """只记录文件位置、大小和摘要，不复制可能混有无关信息的原始日志。"""
    path = pathlib.Path(path).resolve()
    result = {"path": str(path), "exists": path.is_file()}
    if result["exists"]:
        data = path.read_bytes()
        result.update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest().upper())
    return result


def read_json(path):
    """缺失文件和损坏 JSON 均显式返回，不以空结构冒充成功证据。"""
    path = pathlib.Path(path)
    if not path.is_file():
        return None, check("NOT_EXECUTED", "证据文件不存在", evidence=artifact(path))
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
        return value, None
    except (OSError, ValueError) as error:
        return None, check("ERROR", "证据文件无法解析", errorType=type(error).__name__, evidence=artifact(path))


def number(value):
    """bool、字符串、数组及非有限数不能充当有限标量。"""
    return type(value) in (int, float) and math.isfinite(value)


def references():
    """从幅值方程和特征多项式推导参考，不读取 MATLAB 输出或冻结答案。"""
    # |L(jw)|=1 => (w²+1)(w²+4)=100 => u²+5u-96=0。
    w = math.sqrt((-5 + math.sqrt(409)) / 2)
    pm = 180 - math.degrees(math.atan(w) + math.atan(w / 2))
    # 单位负反馈特征多项式：(s+1)(s+2)+10 = s²+3s+12。
    imag = math.sqrt(4 * 12 - 3 * 3) / 2
    return {"pmDeg": pm, "gainMargin": "Inf", "loopStable": True,
            "poles": [[-1.5, -imag], [-1.5, imag]], "gainCrossoverRadS": w,
            "derivation": [
                "(w^2+1)(w^2+4)=100；w=sqrt((-5+sqrt(409))/2)",
                "PM=180-(atan(w)+atan(w/2))*180/pi",
                "有限正频率上 atan(w)+atan(w/2)<pi，无有限 -180° 相位交越，故 GM=+Inf",
                "闭环特征多项式 s^2+3s+12；极点=(-3±j*sqrt(39))/2，实部为负",
            ]}


def pole_pairs(value):
    """兼容两行 [real,imag] 或两个 {real,imag}，拒绝字符串复数及错形数组。"""
    if not isinstance(value, list) or len(value) != 2:
        return None
    pairs = []
    for item in value:
        if isinstance(item, dict):
            item = [item.get("real"), item.get("imag")]
        if not isinstance(item, list) or len(item) != 2 or not all(number(v) for v in item):
            return None
        pairs.append([float(item[0]), float(item[1])])
    return sorted(pairs)


def grade_numbers(values):
    """独立数值真假判断；缺字段保留 UNDETERMINED，不读取任务自评状态。"""
    ref = references()
    if not isinstance(values, dict):
        return check("ERROR", "任务结果必须是单个 JSON 对象", checks=[])
    tests = []
    for field in ("pmDeg", "gainMargin", "loopStable", "poles"):
        if field not in values:
            tests.append({"field": field, **check("UNDETERMINED", "结果缺少必需字段")})
            continue
        got = values[field]
        details = {"observed": got, "reference": ref[field]}
        if field == "pmDeg":
            ok = number(got) and abs(got - ref[field]) < 0.05
            details.update(toleranceDeg=0.05, absoluteErrorDeg=abs(got - ref[field]) if number(got) else None)
        elif field == "gainMargin":
            # JSON 标准不允许 Infinity 数字；任务约定用字符串 Inf。
            ok = isinstance(got, str) and got == "Inf"
        elif field == "loopStable":
            ok = got is True
        else:
            pairs = pole_pairs(got)
            error = max(abs(a - b) for p, q in zip(pairs, ref[field]) for a, b in zip(p, q)) if pairs else None
            ok = error is not None and error < 1e-8
            details.update(maxAbsoluteError=error, tolerance=1e-8)
        tests.append({"field": field, **check("PASS" if ok else "FAIL", "独立解析参考比较", **details)})
    statuses = {item["status"] for item in tests}
    status = "FAIL" if "FAIL" in statuses else "UNDETERMINED" if "UNDETERMINED" in statuses else "PASS"
    return check(status, "独立解析计算；结果文件本身不证明 MCP 执行", checks=tests)


def same_numbers(left, right):
    """确认原始 MCP 数值与结果文件对应，不能拿另一端的结果文件替代。"""
    if not isinstance(left, dict) or not isinstance(right, dict):
        return False
    if any(field not in left or field not in right for field in ("pmDeg", "gainMargin", "loopStable", "poles")):
        return False
    if not number(left["pmDeg"]) or not number(right["pmDeg"]) or abs(left["pmDeg"] - right["pmDeg"]) > 1e-9:
        return False
    a, b = pole_pairs(left["poles"]), pole_pairs(right["poles"])
    return (a is not None and b is not None and
            max(abs(x - y) for p, q in zip(a, b) for x, y in zip(p, q)) < 1e-9 and
            left["gainMargin"] == right["gainMargin"] and
            type(left["loopStable"]) is bool and type(right["loopStable"]) is bool and
            left["loopStable"] == right["loopStable"])


def raw_numbers(text):
    """仅从本端成功 MCP 返回提取数值；支持 Desktop JSON 标记与 CLI 数值日志。"""
    text = text.replace("\r\n", "\n")
    markers = re.findall(r"^MAS_RESULT\s+(\{[^\n]*\})\s*$", text, re.MULTILINE)
    if len(markers) == 1:
        try:
            return json.loads(markers[0])
        except ValueError:
            return None
    if markers or "ANALYSIS_STATUS=PASS" not in text or "ANALYSIS_STATUS=FAIL" in text:
        return None
    try:
        pm = re.search(r"^PHASE_MARGIN_DEG=([^\r\n]+)$", text, re.MULTILINE).group(1)
        gm = re.search(r"^GAIN_MARGIN=([^\r\n]+)$", text, re.MULTILINE).group(1)
        stable = re.search(r"^CLOSED_LOOP_STABLE=(TRUE|FALSE)$", text, re.MULTILINE).group(1)
        poles = re.findall(r"^CLOSED_LOOP_POLE_\d+_REAL=([^\s]+) IMAG=([^\s]+)$", text, re.MULTILINE)
        return {"pmDeg": float(pm), "gainMargin": gm, "loopStable": stable == "TRUE",
                "poles": [[float(real), float(imag)] for real, imag in poles]}
    except (AttributeError, ValueError):
        return None


def content_text(result):
    """只读取 MCP 的文本内容块，不混入调用参数或会话消息。"""
    if not isinstance(result, dict):
        return ""
    return "\n".join(block.get("text", "") for block in result.get("content", []) if block.get("type") == "text")


def read_events(path):
    """读取完成的 CLI JSONL；活跃会话的未完成尾行记为待定错误。"""
    try:
        return [json.loads(line) for line in pathlib.Path(path).read_text(encoding="utf-8-sig").splitlines() if line.strip()], None
    except (OSError, ValueError) as error:
        return [], type(error).__name__


def skill_checks(document, desktop=False, cli_root=None):
    """发现取各端自己的平台证据；加载记录必须能关联本端原始返回。"""
    names = document.get("skillDiscovery", {}).get("names", [])
    discovery = check("PASS" if set(names) == SKILLS else "FAIL", "本端启动上下文技能目录", names=names)
    loaded = set()
    pointers = []
    for item in document.get("loads", []):
        if desktop:
            if all(re.fullmatch(r"[A-Fa-f0-9]{64}", item.get(key, "")) for key in ("inputSha256", "outputSha256")):
                loaded.update(item.get("observedSkillNames", []))
                pointers.append({key: item.get(key) for key in ("callId", "sourcePointer", "inputSha256", "outputSha256")})
        else:
            path = item.get("eventsJSONL")
            if not path:
                continue
            if cli_root:
                try:
                    pathlib.Path(path).resolve().relative_to(cli_root.resolve())
                except ValueError:
                    continue
            events, error = read_events(path)
            if error:
                continue
            for event in events:
                raw = event.get("item", {})
                if (event.get("type") == "item.completed" and raw.get("id") == item.get("eventId") and
                        raw.get("type") == "command_execution" and raw.get("exit_code") == 0 and
                        re.sub(r"/+", "/", item.get("path", "").replace("\\", "/")).casefold() in
                        re.sub(r"/+", "/", raw.get("command", "").replace("\\", "/")).casefold() and
                        re.search(r"name:\s*" + re.escape(item.get("name", "")) + r"\b", raw.get("aggregated_output", ""))):
                    loaded.add(item["name"])
                    pointers.append({"name": item["name"], "eventId": raw["id"], "evidence": artifact(path)})
                    break
    status = "PASS" if REQUIRED_LOADS <= loaded else "UNDETERMINED"
    loading = check(status, "正文标识观察及本端来源关联；不等同于 MATLAB 执行", names=sorted(loaded), pointers=pointers)
    return discovery, loading


def desktop_report(root, result_override=None, execution_override=None, startup_override=None):
    """Desktop 仅使用 Desktop 平台会话及 Desktop Agent 官方 stdio 原始返回。"""
    base = root / "desktop"
    evidence, error = read_json(base / "skill_evidence.json")
    discovery, loading = skill_checks(evidence or {}, desktop=True) if not error else (error, error)
    result_path = result_override.resolve() if result_override else base / "control_task" / "result.json"
    result_path.resolve().relative_to(base.resolve())
    values, result_error = read_json(result_path)
    numeric = result_error or grade_numbers(values)
    mcp_path = execution_override.resolve() if execution_override else base / "control_execution" / "mcp_execution.json"
    mcp_path.resolve().relative_to(base.resolve())
    mcp, mcp_error = read_json(mcp_path)
    if mcp_error:
        execution = mcp_error
    else:
        response = mcp.get("response", {})
        result = response.get("Result", {})
        observed = raw_numbers(content_text(result))
        ok = (mcp.get("status") == "PASS" and response.get("Ok") is True and
              not result.get("isError", False) and same_numbers(observed, values))
        execution = check("PASS" if ok else "FAIL", "当前 Desktop Agent 通过官方 MCP stdio auto 执行，并核对原始返回与本端结果文件",
                          evidence=artifact(mcp_path), resultBoundToMcp=bool(ok),
                          serverArgs=mcp.get("serverArgs"), serverVersion=mcp.get("initialize", {}).get("serverInfo", {}).get("version"))
    required = [result_path, result_path.parent / "control_analysis.mat", mcp_path,
                root.parents[2] / "matlab" / "validation" / "phase44" / "desktop_control_task.m"]
    diary = artifact(result_path.parent / "matlab_output.log")
    files = check("PASS" if all(p.is_file() and p.stat().st_size for p in required) else "FAIL",
                  "Desktop 本次代码、数值、MAT 文件和非空原始 MCP 返回", files=[artifact(p) for p in required],
                  diary=diary, diaryNote="diary 为空时不作为有效日志；以原始 MCP 返回的 content 保留实际 MATLAB 输出")
    report = {"client": "Codex Desktop", "versions": {"engine": (evidence or {}).get("engineVersion"),
            "matlab": (values or {}).get("matlabVersion"), "officialMcp": execution.get("serverVersion")},
            "checks": {"discovery": discovery, "loading": loading, "mcpExecution": execution,
                       "numerical": numeric, "artifacts": files},
            "executionChannel": "Desktop Agent 直接使用官方 stdio MCP，--matlab-session-mode=auto",
            "nativeConnectorBinding": check("FAIL", "原生绑定曾超时/worker 启动失败；stdio 成功不能宣称原生绑定恢复",
                                             evidence=artifact(base / "mcp_observation.json")),
            "history": {"nativeFailure": artifact(base / "mcp_observation.json"),
                        "earlierRecoveryAttempts": [artifact(base / name) for name in ("startup_attempt.json", "mcp_recovery_report.json", "mcp_recovery_retry_report.json")],
                        "originalTaskResult": artifact(base / "control_task" / "result.json"),
                        "originalTaskExecution": artifact(base / "control_execution" / "mcp_execution.json")},
            "resultEvidence": artifact(result_path), "platformEvidence": artifact(base / "skill_evidence.json")}
    if startup_override:
        startup, startup_error = read_json(startup_override)
        if startup_error:
            binding = startup_error
        else:
            pid = (values or {}).get("matlabPid")
            runtime = startup.get("runtimePid")
            known = number(pid) and number(runtime) and pid > 0 and runtime > 0
            ok = known and pid == runtime and startup.get("status") == "READY" and startup.get("newSessionVerified") is True
            binding = check("PASS" if ok else "FAIL" if known else "UNDETERMINED",
                            "本次 MCP 执行 PID 必须等于自动打开的新实例 runtimePid；auto 模式可能复用既有会话",
                            matlabPid=pid, startupRuntimePid=runtime, evidence=artifact(startup_override))
        report["checks"]["startupSessionBinding"] = binding
    return report


def cli_report(root):
    """CLI 只接受 verification 引用的 CLI 会话，不借用 Desktop 数值或返回。"""
    verification_path = root / "cli" / "verification.json"
    verification, error = read_json(verification_path)
    v = verification or {}
    discovery, loading = skill_checks(v, cli_root=root / "cli") if not error else (error, error)
    task = v.get("task", {})
    path_text = task.get("resultFile") or task.get("expectedResultFile")
    result_path = pathlib.Path(path_text) if path_text else root / "cli" / "not_executed_result.json"
    try:
        result_path.resolve().relative_to((root / "cli").resolve())
        values, result_error = read_json(result_path)
    except ValueError:
        values = None
        result_error = check("ERROR", "CLI 结果路径越出本端目录，拒绝跨端替代", evidence=artifact(result_path))
    numeric = result_error or grade_numbers(values)
    matched = []
    failed = []
    event_files = {call.get("eventsJSONL") for call in v.get("mcp", {}).get("calls", []) if call.get("eventsJSONL")}
    event_files.update(session.get("eventsJSONL") for session in v.get("sessions", []) if session.get("eventsJSONL"))
    for path in sorted(event_files):
        # 来源必须是本轮 CLI 目录；报告器不搜索 Desktop 会话借用结果。
        try:
            pathlib.Path(path).resolve().relative_to((root / "cli").resolve())
        except ValueError:
            continue
        events, parse_error = read_events(path)
        if parse_error:
            failed.append({"evidence": artifact(path), "reason": parse_error})
            continue
        for event in events:
            item = event.get("item", {})
            if event.get("type") != "item.completed" or item.get("type") != "mcp_tool_call" or item.get("tool") not in EXECUTION_TOOLS:
                continue
            if item.get("server") != "matlab-official":
                continue
            result = item.get("result") or {}
            text = content_text(result)
            info = {"eventId": item.get("id"), "tool": item.get("tool"), "evidence": artifact(path)}
            if (item.get("status") == "completed" and not item.get("error") and not result.get("isError", False) and
                    same_numbers(raw_numbers(text), values)):
                matched.append(info)
            else:
                failed.append(info)
    execution = check("PASS" if matched else "FAIL" if failed else "NOT_EXECUTED", "CLI 本端官方 MCP 完成返回与本端结果文件数值对应",
                      matchedCalls=matched, nonMatchingOrFailedCalls=failed)
    directory = result_path.parent
    required = [result_path, directory / "analysis.m", directory / "matlab_raw_output.txt", directory / "matlab_version.txt", directory / "evidence.json"]
    files = check("PASS" if all(p.is_file() and p.stat().st_size for p in required) else "NOT_EXECUTED" if not result_path.is_file() else "FAIL",
                  "CLI 本次代码、原始输出、版本、任务证据及结果", files=[artifact(p) for p in required])
    return {"client": "Codex CLI", "versions": v.get("version", {}),
            "checks": {"discovery": discovery, "loading": loading, "mcpExecution": execution,
                       "numerical": numeric, "artifacts": files},
            "executionChannel": "独立 CLI 会话调用官方 MATLAB MCP；不使用 Desktop 执行代替",
            "history": {"sessionCount": len(v.get("sessions", [])), "failureCount": len(v.get("failures", [])),
                        "sessions": [{key: item.get(key) for key in ("kind", "eventsJSONL", "metadataFile", "exitCode", "timedOut")} for item in v.get("sessions", [])],
                        "limitationsFromVerifier": v.get("limitations", [])},
            "resultEvidence": artifact(result_path), "platformEvidence": artifact(verification_path)}


def coverage(root, startup_path=None):
    """明确区分 Windows 双端内置引擎冷启动与未测的物理环境/UI 重启。"""
    summary, error = read_json(root / "native_lifecycle_retry" / "summary.json")
    rows = []
    for item in summary if isinstance(summary, list) else []:
        raw, raw_error = read_json(item.get("evidence", ""))
        expected = 0 if item.get("stage") == "removed" else 9
        ok = (not raw_error and item.get("status") == "PASS" and item.get("skillCount") == expected and
              raw.get("status") == "PASS" and not raw.get("discoveryErrors") and len(raw.get("skills", [])) == expected)
        rows.append({"stage": item.get("stage"), "client": item.get("client"), "skillCount": item.get("skillCount"), "status": "PASS" if ok else "FAIL", "evidence": artifact(item.get("evidence", ""))})
    combinations = {(item["stage"], item["client"]) for item in rows}
    expected_combinations = {(stage, client) for stage in ("upgraded", "removed", "reinstalled") for client in ("cli", "desktop-engine")}
    installed = error or check("PASS" if combinations == expected_combinations and all(item["status"] == "PASS" for item in rows) else "FAIL",
                               "同一 Windows 用户共享根；两版本内置发现引擎独立冷启动实测升级9/卸载0/重装9", runs=rows)
    startup = check("NOT_EXECUTED", "未取得自动打开新实例的实测证据")
    cold = check("NOT_EXECUTED", "未取得零既有 MATLAB 进程条件下的冷启动验收证据")
    if startup_path:
        source, source_error = read_json(startup_path)
        if source_error:
            startup = source_error
            cold = source_error
        else:
            ready = (source.get("status") == "READY" and source.get("newSessionVerified") is True and
                     source.get("bootstrapReached") is True and source.get("desktopObserved") is True)
            failed = source.get("status") in ("TIMEOUT", "START_FAILED")
            startup = check("PASS" if ready else "FAIL" if failed else "NOT_EXECUTED",
                            "自动打开的新 MATLAB 实例；复用已有实例不计新实例启动",
                            evidence=artifact(startup_path), reportedStatus=source.get("status"), runtimePid=source.get("runtimePid"),
                            mcpExecutionVerified=source.get("mcpExecutionVerified"))
            cold_status = ("PASS" if ready and source.get("coldStartVerified") is True else
                           "FAIL" if failed and source.get("beforeProcesses") == [] else "NOT_EXECUTED")
            cold = check(cold_status, "保留旧 MATLAB 进程时的新实例启动不构成零既有实例冷启动",
                         evidence=artifact(startup_path), coldStartVerified=source.get("coldStartVerified"))
    return {"windowsSharedRootLifecycle": installed,
            "cliOnlyPhysicalMachine": check("NOT_EXECUTED", "未在只安装 CLI 的独立物理环境实测"),
            "desktopOnlyPhysicalMachine": check("NOT_EXECUTED", "未在只安装 Desktop 的独立物理环境实测"),
            "realWsl": check("NOT_EXECUTED", "只有路径解析模拟，未在真实 WSL 验收"),
            "desktopUiApplicationRestart": check("NOT_EXECUTED", "内置引擎冷启动已测；完整 Desktop UI 应用重启未测"),
            "matlabAutomaticNewSession": startup,
            "matlabAutomaticColdStart": cold}


def self_test():
    """负对照验证独立评分器不会把错误、错类型、缺测证据当作数值通过。"""
    good = {key: value for key, value in references().items() if key in ("pmDeg", "gainMargin", "loopStable", "poles")}
    tests = []
    for label, patch, want in (
            ("解析正例", {}, "PASS"), ("相位裕度错误1度", {"pmDeg": good["pmDeg"] + 1}, "FAIL"),
            ("增益裕度错误", {"gainMargin": 1}, "FAIL"), ("字符串true不能充当logical", {"loopStable": "true"}, "FAIL"),
            ("闭环极点错误", {"poles": [[1.5, 0], [-1.5, 0]]}, "FAIL"),
            ("单元素数组不能充当标量", {"pmDeg": [good["pmDeg"]]}, "FAIL"),
            ("NaN不能通过", {"pmDeg": float("nan")}, "FAIL")):
        values = copy.deepcopy(good)
        values.update(patch)
        got = grade_numbers(values)["status"]
        tests.append({"case": label, "expected": want, "got": got, "pass": got == want})
    missing = copy.deepcopy(good)
    del missing["pmDeg"]
    tests.append({"case": "缺字段不折算通过", "pass": grade_numbers(missing)["status"] == "UNDETERMINED"})
    structured = copy.deepcopy(good)
    structured["poles"] = [{"real": real, "imag": imag} for real, imag in good["poles"]]
    tests.append({"case": "CLI复数结构与Desktop二维数组等价", "pass": grade_numbers(structured)["status"] == "PASS" and same_numbers(good, structured)})
    return {"status": "PASS" if all(item["pass"] for item in tests) else "FAIL", "passed": sum(item["pass"] for item in tests), "total": len(tests), "cases": tests}


def clean_json(value):
    """报告必须是标准 JSON，坏输入里的非有限数用文字保留供审计。"""
    if isinstance(value, float) and not math.isfinite(value):
        return "NaN" if math.isnan(value) else "Inf" if value > 0 else "-Inf"
    if isinstance(value, dict):
        return {key: clean_json(item) for key, item in value.items()}
    if isinstance(value, list):
        return [clean_json(item) for item in value]
    return value


def main():
    """重读当前证据快照，分别覆写两个派生报告，不修改任何原始结果或历史失败。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1] / "artifacts" / "validation" / "phase44")
    parser.add_argument("--startup-evidence", type=pathlib.Path)
    parser.add_argument("--desktop-result", type=pathlib.Path, help="选择复跑 Desktop result.json；保留原始恢复证据")
    parser.add_argument("--desktop-execution", type=pathlib.Path, help="选择该复跑对应的 Desktop MCP 原始返回")
    parser.add_argument("--self-test-only", action="store_true")
    args = parser.parse_args()
    tests = self_test()
    if args.self_test_only:
        print(json.dumps(tests, ensure_ascii=False, indent=2))
        raise SystemExit(0 if tests["status"] == "PASS" else 1)
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    scope = coverage(root, args.startup_evidence)
    free, _ = read_json(root / "free_tests_final.json")
    grader, _ = read_json(root / "grader_tests.json")
    regression = {"freeSuite": {"evidence": artifact(root / "free_tests_final.json"), "totals": (free or {}).get("totals"),
                                "note": "既有硬编码盘符与 UTF-8 BOM 两项失败保留，不宣称全部回归通过"},
                  "phase43Grader": {"evidence": artifact(root / "grader_tests.json"), "passed": (grader or {}).get("nPass"), "total": (grader or {}).get("nTotal"), "pass": (grader or {}).get("pass")},
                  "independentNumericGrader": tests}
    for key, filename in (("desktopEvidencePs51", "desktop_evidence_tests_ps51.json"),
                          ("desktopEvidencePs7", "desktop_evidence_tests_ps7.json"),
                          ("probeProtocolTests", "probe_protocol_tests.json")):
        snapshot, snapshot_error = read_json(root / filename)
        regression[key] = snapshot_error or {"evidence": artifact(root / filename),
                                            "totals": snapshot.get("totals"), "status": snapshot.get("status"),
                                            "exitCode": snapshot.get("exitCode")}
    summaries = []
    for name, report in (("cli", cli_report(root)), ("desktop", desktop_report(root, args.desktop_result, args.desktop_execution, args.startup_evidence))):
        statuses = {item["status"] for item in report["checks"].values()}
        task_status = "PASS" if statuses == {"PASS"} else "FAIL" if statuses & {"FAIL", "ERROR"} else "UNDETERMINED"
        report.update(schema="mas-phase44-client-acceptance/1", generatedAt=dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).isoformat(),
                      generator=artifact(__file__), overall="PARTIAL", taskAcceptanceStatus=task_status,
                      overallReason="实际已测路径单独给出结论；独立物理环境、真实WSL、Desktop UI重启及自动冷启动仍有未测项",
                      independentReference=references(), coverage=scope, regressions=regression,
                      scope="只评价本端证据；Python仅作独立解析评分，不能替代MATLAB/MCP执行")
        destination = root / (name + "_acceptance_report.json")
        destination.write_text(json.dumps(clean_json(report), ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
        summaries.append({"client": report["client"], "taskAcceptanceStatus": task_status,
                          "numerical": report["checks"]["numerical"]["status"], "overall": "PARTIAL", "report": str(destination)})
    (root / "independent_numeric_grader_tests.json").write_text(json.dumps(tests, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summaries, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
