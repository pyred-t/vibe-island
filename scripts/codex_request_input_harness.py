#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
from pathlib import Path


PROMPT = """Before answering, call request_user_input exactly once with one question:
- header: 目标
- id: primary_goal
- question: 这次你最希望我围绕这个项目做什么？
- options: 先做梳理 (Recommended), 查具体问题, 规划新功能

After you receive the answer, reply with exactly: FINAL_ANSWER=<selected answer>
"""


class HarnessServer(threading.Thread):
    def __init__(self, socket_path: str, answer_value: str):
        super().__init__(daemon=True)
        self.socket_path = socket_path
        self.answer_value = answer_value
        self.events = []
        self._ready = threading.Event()
        self._done = threading.Event()

    def run(self):
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(self.socket_path)
        server.listen(1)
        self._ready.set()
        try:
            while not self._done.is_set():
                conn, _ = server.accept()
                data = conn.recv(65536)
                event = json.loads(data.decode())
                self.events.append(event)
                if event.get("tool") == "request_user_input":
                    response = {
                        "updatedInput": {
                            "answers": {
                                "primary_goal": {
                                    "answers": [self.answer_value]
                                }
                            }
                        }
                    }
                    conn.sendall(json.dumps(response, ensure_ascii=False).encode())
                    self._done.set()
                conn.close()
        finally:
            server.close()

    def wait_ready(self):
        self._ready.wait(timeout=5)


def write_temp_codex_home(home: Path, hook_script: Path):
    codex_dir = home / ".codex"
    hooks_dir = codex_dir / "hooks"
    hooks_dir.mkdir(parents=True, exist_ok=True)

    auth_src = Path.home() / ".codex" / "auth.json"
    if auth_src.exists():
        shutil.copy2(auth_src, codex_dir / "auth.json")

    shutil.copy2(hook_script, hooks_dir / "vibe-island-codex.py")

    hooks_json = {
        "hooks": {
            "PreToolUse": [{"hooks": [{"type": "command", "command": f"python3 {hooks_dir / 'vibe-island-codex.py'}", "timeout": 30}]}],
            "PostToolUse": [{"hooks": [{"type": "command", "command": f"python3 {hooks_dir / 'vibe-island-codex.py'}", "timeout": 5}]}],
            "SessionStart": [{"hooks": [{"type": "command", "command": f"python3 {hooks_dir / 'vibe-island-codex.py'}", "timeout": 5}]}],
            "Stop": [{"hooks": [{"type": "command", "command": f"python3 {hooks_dir / 'vibe-island-codex.py'}", "timeout": 5}]}],
            "UserPromptSubmit": [{"hooks": [{"type": "command", "command": f"python3 {hooks_dir / 'vibe-island-codex.py'}", "timeout": 5}]}],
        }
    }
    (codex_dir / "hooks.json").write_text(json.dumps(hooks_json, indent=2), encoding="utf-8")

    config = f"""
model = "gpt-5.4"
personality = "pragmatic"
[features]
codex_hooks = true
[projects."{home / 'workspace'}"]
trust_level = "trusted"
"""
    (codex_dir / "config.toml").write_text(config.strip() + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--answer-value", default="规划新功能")
    parser.add_argument("--hook-script", default="ClaudeIsland/Resources/codex-island-hook.py")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    hook_script = (repo_root / args.hook_script).resolve()

    scratch_root = (repo_root / ".build" / "codex-harness").resolve()
    scratch_root.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="run-", dir=scratch_root) as tmp:
        tmp_path = Path(tmp)
        home = tmp_path / "home"
        workdir = tmp_path / "workspace"
        workdir.mkdir(parents=True, exist_ok=True)
        write_temp_codex_home(home, hook_script)

        socket_path = f"/tmp/ci-rui-{os.getpid()}.sock"
        hook_log_path = str(tmp_path / "hook.log.jsonl")
        server = HarnessServer(socket_path, args.answer_value)
        server.start()
        server.wait_ready()

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["CLAUDE_ISLAND_SOCKET_PATH"] = socket_path
        env["CLAUDE_ISLAND_HOOK_LOG_PATH"] = hook_log_path

        result = subprocess.run(
            [
                "codex",
                "exec",
                "--json",
                "--skip-git-repo-check",
                "--sandbox",
                "workspace-write",
                "--cd",
                str(workdir),
                PROMPT,
            ],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )

        stdout_lines = [line for line in result.stdout.splitlines() if line.strip()]
        parsed_lines = []
        for line in stdout_lines:
            try:
                parsed_lines.append(json.loads(line))
            except Exception:
                parsed_lines.append({"raw": line})

        summary = {
            "returncode": result.returncode,
            "events_seen_by_fake_server": server.events,
            "stdout": parsed_lines,
            "stderr": result.stderr,
            "hook_log_path": hook_log_path,
            "hook_log": Path(hook_log_path).read_text(encoding="utf-8") if Path(hook_log_path).exists() else "",
        }
        print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
