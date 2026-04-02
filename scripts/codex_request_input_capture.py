#!/usr/bin/env python3
import argparse
import json
import os
import sqlite3
import subprocess
from pathlib import Path


def resolve_rollout(thread_id: str) -> Path:
    base = Path.home() / ".codex" / "sessions"
    for path in sorted(base.rglob("rollout-*.jsonl")):
        try:
            with path.open("r", encoding="utf-8") as fh:
                first = fh.readline()
            if not first:
                continue
            obj = json.loads(first)
            payload = obj.get("payload", {})
            if payload.get("id") == thread_id:
                return path
        except Exception:
            continue
    raise SystemExit(f"Could not resolve rollout for thread {thread_id}")


def load_entries(path: Path):
    entries = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            entries.append(json.loads(line))
    return entries


def extract_call(entries, call_id: str):
    for index, entry in enumerate(entries):
        payload = entry.get("payload", {})
        if payload.get("type") == "function_call" and payload.get("call_id") == call_id:
            return index, entry
    raise SystemExit(f"Could not find call_id {call_id}")


def query_logs(start: str, end: str) -> str:
    result = subprocess.run(
        [
            "/usr/bin/log",
            "show",
            "--style",
            "compact",
            "--start",
            start,
            "--end",
            end,
            "--predicate",
            'subsystem == "com.claudeisland"',
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout + ("\nSTDERR:\n" + result.stderr if result.stderr else "")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--thread-id", required=True)
    parser.add_argument("--call-id", required=True)
    parser.add_argument("--output-dir", default="/tmp/codex-request-input-evidence")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    rollout = resolve_rollout(args.thread_id)
    entries = load_entries(rollout)
    index, call_entry = extract_call(entries, args.call_id)

    excerpt = entries[max(0, index - 5): min(len(entries), index + 10)]
    payload = call_entry["payload"]
    arguments = json.loads(payload.get("arguments") or "{}")

    output_dir.joinpath("request_user_input.payload.json").write_text(
        json.dumps(
            {
                "rollout_path": str(rollout),
                "line_index": index + 1,
                "call_id": args.call_id,
                "function_call": payload,
                "parsed_arguments": arguments,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    output_dir.joinpath("request_user_input.excerpt.jsonl").write_text(
        "\n".join(json.dumps(item, ensure_ascii=False) for item in excerpt) + "\n",
        encoding="utf-8",
    )

    timestamp = call_entry.get("timestamp")
    if timestamp:
        start = timestamp.replace("T", " ").replace("Z", "")
        end = start
        # log show requires a small range around the event.
        from datetime import datetime, timedelta

        dt = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        start = (dt - timedelta(minutes=5)).strftime("%Y-%m-%d %H:%M:%S")
        end = (dt + timedelta(minutes=10)).strftime("%Y-%m-%d %H:%M:%S")
        output_dir.joinpath("claudeisland.log.txt").write_text(
            query_logs(start, end),
            encoding="utf-8",
        )

    hook_log = Path(os.environ.get("CLAUDE_ISLAND_HOOK_LOG_PATH", "/tmp/claude-island-codex-hook.log"))
    interaction_log = Path(os.environ.get("CLAUDE_ISLAND_INTERACTION_LOG_PATH", "/tmp/claude-island-interactions.log"))
    if hook_log.exists():
        output_dir.joinpath("hook.log.jsonl").write_text(hook_log.read_text(encoding="utf-8"), encoding="utf-8")
    if interaction_log.exists():
        output_dir.joinpath("interaction.log.jsonl").write_text(interaction_log.read_text(encoding="utf-8"), encoding="utf-8")

    print(str(output_dir))


if __name__ == "__main__":
    main()
