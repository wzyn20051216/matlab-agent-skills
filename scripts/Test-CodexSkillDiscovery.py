"""通过客户端自身的 skills/list 验证发现；不调用模型或 MATLAB。"""

import argparse
import datetime as dt
import json
import pathlib
import queue
import subprocess
import threading
import time


def finish(output, record, transcript, start):
    """所有失败路径都覆写本次状态，不能留下上次的 PASS 供验收误用。"""
    record["durationMs"] = round((time.monotonic() - start) * 1000)
    record["finishedUtc"] = dt.datetime.now(dt.timezone.utc).isoformat()
    (output / "protocol.json").write_text(
        json.dumps(transcript, ensure_ascii=False, indent=2), encoding="utf-8")
    (output / "verification.json").write_text(
        json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"status": record["status"], "client": record["client"],
                      "version": record.get("version"), "skills": len(record.get("skills", [])),
                      "reason": record.get("reason"), "output": str(output)}, ensure_ascii=False))
    raise SystemExit(0 if record["status"] == "PASS" else 1)


def main():
    """冷启动指定版本的 app-server，并保存实际协议返回。"""
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--skill-root", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--client", required=True)
    parser.add_argument("--expected-count", required=True, type=int)
    parser.add_argument("--timeout", type=float, default=45)
    args = parser.parse_args()
    output = pathlib.Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    transcript = []
    start = time.monotonic()
    started = dt.datetime.now(dt.timezone.utc).isoformat()
    record = {"schema": "mas-client-skill-discovery/1", "client": args.client,
              "cwd": args.cwd, "skillRoot": args.skill_root, "status": "FAIL",
              "startedUtc": started,
              "scope": "客户端内置发现引擎；不代表 Desktop UI 或 MATLAB 执行验收"}
    try:
        executable = str(pathlib.Path(args.executable).resolve(strict=True))
        work = str(pathlib.Path(args.cwd).resolve(strict=True))
        skill_root = pathlib.Path(args.skill_root).resolve()
        version = subprocess.run([executable, "--version"], capture_output=True,
                                 text=True, timeout=15, check=True).stdout.strip()
        command = [executable, "app-server", "--listen", "stdio://"]
        record.update(version=version, cwd=work, skillRoot=str(skill_root), command=command)
    except Exception as error:
        record["reason"] = f"{type(error).__name__}: {error}"
        finish(output, record, transcript, start)
    received = queue.Queue()
    with (output / "stderr.log").open("wb") as stderr:
        try:
            process = subprocess.Popen(command, cwd=work, stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=stderr,
                                       text=True, encoding="utf-8")
        except Exception as error:
            record["reason"] = f"{type(error).__name__}: {error}"
            finish(output, record, transcript, start)

        def read_stdout():
            """后台读取，主线程用有界队列等待，防止协议探针挂起。"""
            try:
                for line in process.stdout:
                    received.put(line)
            finally:
                received.put(None)

        threading.Thread(target=read_stdout, daemon=True).start()

        def request(method, params, request_id):
            """只消费本次请求的响应；保留通知与错误供复核。"""
            message = {"id": request_id, "method": method, "params": params}
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()
            transcript.append({"direction": "send", "message": message})
            deadline = time.monotonic() + args.timeout
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"{method} 超时")
                line = received.get(timeout=remaining)
                if line is None:
                    raise RuntimeError("客户端在返回响应前退出")
                message = json.loads(line)
                transcript.append({"direction": "receive", "message": message})
                if message.get("id") == request_id:
                    if "error" in message:
                        raise RuntimeError(json.dumps(message["error"], ensure_ascii=False))
                    return message["result"]

        try:
            record["initialize"] = request("initialize", {
                "clientInfo": {"name": "mas_phase44_probe", "version": "1.0"},
                "capabilities": {"experimentalApi": True}}, 1)
            process.stdin.write(json.dumps({"method": "initialized", "params": {}}) + "\n")
            process.stdin.flush()
            result = request("skills/list", {"cwds": [work], "forceReload": True}, 2)
            # 原始响应先落盘，结构错误也必须有可复核的协议证据。
            (output / "skills_list_response.json").write_text(
                json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
            record["discoveryErrors"] = []
            record["expectedCount"] = args.expected_count
            entries = result.get("data")
            if not isinstance(entries, list) or len(entries) != 1:
                raise ValueError("skills/list 没有返回唯一的请求工作目录，不能把缺失响应当作零技能")
            if (not isinstance(entries[0].get("cwd"), str) or not entries[0]["cwd"]
                    or pathlib.Path(entries[0]["cwd"]).resolve() != pathlib.Path(work)):
                raise ValueError("skills/list 返回的工作目录与本次请求不一致")
            skills = []
            errors = []
            seen_paths = set()
            for entry in entries:
                if not isinstance(entry.get("skills"), list) or not isinstance(entry.get("errors", []), list):
                    raise ValueError("skills/list 的 skills 和 errors 必须是数组")
                errors.extend(entry.get("errors", []))
                for skill in entry["skills"]:
                    if (not isinstance(skill.get("name"), str) or not skill["name"]
                            or not isinstance(skill.get("path"), str) or not skill["path"]
                            or type(skill.get("enabled")) is not bool):
                        raise ValueError("技能名称、路径或 enabled 类型不合法")
                    try:
                        path = pathlib.Path(skill["path"]).resolve()
                        path.relative_to(skill_root)
                    except ValueError:
                        continue
                    if skill["name"].startswith("matlab-") and skill["enabled"] is True:
                        if path in seen_paths:
                            raise ValueError("skills/list 重复报告同一个技能路径，不能累计为多项")
                        seen_paths.add(path)
                        skills.append(skill)
            record["skills"] = skills
            record["discoveryErrors"] = errors
            record["expectedCount"] = args.expected_count
            # 解析失败也可能产生零技能；不能把该情况当作卸载成功。
            record["status"] = "PASS" if len(skills) == args.expected_count and not errors else "FAIL"
            if errors:
                record["reason"] = "客户端技能发现报告错误，不能确认预期技能状态"
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
                    process.kill()  # 仅处理本脚本创建的发现引擎，不涉及 MATLAB。
                    process.wait(timeout=5)
    finish(output, record, transcript, start)


if __name__ == "__main__":
    main()
