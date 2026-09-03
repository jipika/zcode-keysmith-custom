#!/usr/bin/env python3
from __future__ import annotations

import datetime
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

ORIGINAL_RUNTIME = pathlib.Path(os.environ.get("ZCODE_KEYSMITH_ORIGINAL") or "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs")
SYSTEM_FILE = pathlib.Path(os.environ.get("ZCODE_KEYSMITH_SYSTEM_FILE") or "/Users/lixiongwei/.zcode-keysmith/system-role.md")
NODE_COMMAND = os.environ.get("ZCODE_KEYSMITH_NODE_COMMAND") or "/Applications/ZCode.app/Contents/Frameworks/ZCode Helper.app/Contents/MacOS/ZCode Helper"
PATCH_NEEDLE = "customSystemPrompt:this.config.systemPrompt,language:"
CACHE_DIR = pathlib.Path(os.environ.get("ZCODE_KEYSMITH_CACHE_DIR") or "/Users/lixiongwei/.zcode-keysmith/cache")
LOG_DIR = pathlib.Path(os.environ.get("ZCODE_KEYSMITH_LOG_DIR") or "/Users/lixiongwei/.zcode-keysmith/logs")
LOG_FILE = LOG_DIR / "wrapper-start.jsonl"
DISABLE_FILE = SYSTEM_FILE.parent / "DISABLED"
SKIP_FILE = SYSTEM_FILE.parent / "skip-channels.txt"


def acquire_cache_lock(path: pathlib.Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open("a+b")
    if os.name == "nt":
        import msvcrt

        if path.stat().st_size == 0:
            handle.write(b"\0")
            handle.flush()
        handle.seek(0)
        while True:
            try:
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                return handle
            except OSError:
                time.sleep(0.02)
    import fcntl

    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    return handle


def release_cache_lock(handle) -> None:
    try:
        if os.name == "nt":
            import msvcrt

            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl

            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    finally:
        handle.close()


def system_prompt_expression() -> str:
    system_file = json.dumps(str(SYSTEM_FILE), ensure_ascii=False)
    log_file = json.dumps(str(LOG_DIR / "config-keys.jsonl"), ensure_ascii=False)
    # 闲时任务不注入。判别依据（按可靠度）：
    # 1. 会话 modelRef 指向 offpeak 专属通道（providerId=offpeak-idle-plan，DB 验证闲时任务独占此通道）
    # 2. config 上直接带 offPeakTaskId/automationId/offPeakRunType 标记（轮次契约字段，兜底）
    # 每次判断写观测日志供验证
    probe = (
        "(()=>{try{let c=this.config||{};let m='';"
        "try{m=JSON.stringify(c.modelRef||this.defaultModelRef||null)||''}catch{}"
        "let f=require('node:fs');"
        "let dis=f.existsSync(" + json.dumps(str(DISABLE_FILE), ensure_ascii=False) + ");"
        "let pats='';try{pats=f.readFileSync(" + json.dumps(str(SKIP_FILE), ensure_ascii=False) + ",'utf8')}catch{}"
        "let lines=pats.split(/\\r?\\n/).map(s=>s.trim()).filter(Boolean);"
        "let hay=(m+' '+(c.offPeakTaskId||'')+' '+(c.automationId||'')+' '+(c.offPeakRunType||'')).toLowerCase();"
        "let hit=lines.find(p=>hay.includes(p.toLowerCase()))||null;"
        "let dis_f=" + json.dumps(str(DISABLE_FILE), ensure_ascii=False) + ";"
        "require('node:fs').appendFileSync(" + log_file + ","
        "JSON.stringify({at:new Date().toISOString(),"
        "mref:m.slice(0,120),dis:dis,skip:!!(dis||hit),pat:hit,"
        "op:c.offPeakTaskId||null,auto:c.automationId||null})+'\\n')}catch{}}"
        ")()"
    )
    skip = (
        "(()=>{try{let c=this.config||{};let m='';"
        "try{m=JSON.stringify(c.modelRef||this.defaultModelRef||null)||''}catch{}"
        "let f=require('node:fs');"
        "if(f.existsSync(" + json.dumps(str(DISABLE_FILE), ensure_ascii=False) + "))return!0;"
        "let pats='';try{pats=f.readFileSync(" + json.dumps(str(SKIP_FILE), ensure_ascii=False) + ",'utf8')}catch{}"
        "let lines=pats.split(/\\r?\\n/).map(s=>s.trim()).filter(Boolean);"
        "let hay=(m+' '+(c.offPeakTaskId||'')+' '+(c.automationId||'')+' '+(c.offPeakRunType||'')).toLowerCase();"
        "return lines.some(p=>hay.includes(p.toLowerCase()))"
        "}catch{return!1}})()"
    )
    disable_check = (
        "try{if(require('node:fs').existsSync("
        + json.dumps(str(DISABLE_FILE), ensure_ascii=False)
        + "))return void 0}catch{}"
    )
    return (
        "(this.config.systemPrompt&&this.config.systemPrompt.trim()?this.config.systemPrompt:"
        "(()=>{" + probe + ";"
        + disable_check +
        "if(" + skip + ")return void 0;"
        "try{let e=process.env.ZCODE_KEYSMITH_SYSTEM_FILE||"
        + system_file
        + ";let t=require(\"node:fs\");return t.existsSync(e)?t.readFileSync(e,\"utf8\"):void 0}catch{return void 0}})())"
    )


def patched_runtime_path() -> pathlib.Path:
    original = ORIGINAL_RUNTIME.read_text(encoding="utf-8")
    if PATCH_NEEDLE not in original:
        raise RuntimeError(f"ZCode runtime patch anchor not found: {ORIGINAL_RUNTIME}")
    replacement = "customSystemPrompt:" + system_prompt_expression() + ",language:"
    patched = original.replace(PATCH_NEEDLE, replacement, 1)
    digest = hashlib.sha256((str(ORIGINAL_RUNTIME) + "\0" + original + "\0" + replacement).encode("utf-8")).hexdigest()[:16]
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    path = CACHE_DIR / f"zcode-keysmith-runtime-{digest}.cjs"
    lock = acquire_cache_lock(path.with_name(f".{path.name}.lock"))
    try:
        if not path.exists() or path.read_text(encoding="utf-8", errors="ignore") != patched:
            tmp = None
            try:
                with tempfile.NamedTemporaryFile(
                    "w",
                    encoding="utf-8",
                    dir=str(CACHE_DIR),
                    prefix=f".{path.name}.",
                    suffix=".tmp",
                    delete=False,
                ) as handle:
                    handle.write(patched)
                    tmp = pathlib.Path(handle.name)
                tmp.replace(path)
            finally:
                if tmp is not None:
                    tmp.unlink(missing_ok=True)
    finally:
        release_cache_lock(lock)
    return path


def log_invocation(runtime: pathlib.Path, args: list[str]) -> None:
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        event = {
            "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "pid": os.getpid(),
            "argv": sys.argv,
            "agent_args": args,
            "runtime": str(runtime),
            "original_runtime": str(ORIGINAL_RUNTIME),
            "system_file": str(SYSTEM_FILE),
            "node_command": NODE_COMMAND,
        }
        with LOG_FILE.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, ensure_ascii=False, sort_keys=True) + "\n")
    except Exception:
        pass


def handle_toggle(cmd: str) -> int:
    """disable/enable/status —— 手动总开关，写开关文件即生效（下一个新会话起），无需重启 ZCode"""
    if cmd == "disable":
        DISABLE_FILE.parent.mkdir(parents=True, exist_ok=True)
        DISABLE_FILE.write_text(
            datetime.datetime.now(datetime.timezone.utc).isoformat() + "\n", encoding="utf-8"
        )
        print("keysmith: 注入已关闭（下一个新会话/任务生效，无需重启 ZCode）")
        return 0
    if cmd == "enable":
        DISABLE_FILE.unlink(missing_ok=True)
        print("keysmith: 注入已开启（下一个新会话/任务生效，无需重启 ZCode）")
        return 0
    if cmd == "status":
        state = "已关闭 disabled（走开关通道时不注入）" if DISABLE_FILE.exists() else "已开启 enabled"
        print(f"keysmith 注入开关: {state}")
        print(f"开关文件: {DISABLE_FILE}")
        print(f"注入源: {SYSTEM_FILE} (存在={SYSTEM_FILE.exists()})")
        print("用法: zcode-agent-wrapper.py disable|enable|status")
        return 0
    return 1


def main() -> int:
    args = sys.argv[1:]
    if args and args[0] in {"disable", "enable", "status"}:
        return handle_toggle(args[0])
    runtime = patched_runtime_path()
    args = args or ["app-server", "--stdio"]
    log_invocation(runtime, args)
    env = os.environ.copy()
    env["ELECTRON_RUN_AS_NODE"] = "1"
    if os.name == "nt":
        # Use Popen to inherit stdin/stdout/stderr directly for stable long-running JSON-RPC communication
        proc = subprocess.Popen(
            [NODE_COMMAND, str(runtime), *args],
            env=env,
        )
        return proc.wait()
    os.execve(NODE_COMMAND, [NODE_COMMAND, str(runtime), *args], env)
    return 127


if __name__ == "__main__":
    raise SystemExit(main())
