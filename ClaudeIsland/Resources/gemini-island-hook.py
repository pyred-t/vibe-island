#!/usr/bin/env python3
"""
Vibe Island hook bridge for Gemini CLI.

- Normalizes Gemini hook payloads onto the shared HookEvent schema
- Sends them to the shared Unix socket ingress
- Reuses the same permission response loop as Claude when Gemini provides one
"""

import json
import os
import socket
import subprocess
import sys

AGENT_ID = "gemini"
SOCKET_PATH = "/tmp/claude-island.sock"
TIMEOUT_SECONDS = 300


def get_tty():
    ppid = os.getppid()
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2,
        )
        tty = result.stdout.strip()
        if tty and tty not in {"??", "-"}:
            return tty if tty.startswith("/dev/") else "/dev/" + tty
    except Exception:
        pass

    for handle in (sys.stdin, sys.stdout):
        try:
            return os.ttyname(handle.fileno())
        except Exception:
            continue
    return None


def load_payload():
    raw = None
    try:
        raw = sys.stdin.read()
    except Exception:
        raw = None

    if raw:
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            pass

    env_payload = os.environ.get("GEMINI_HOOK_PAYLOAD")
    if env_payload:
        try:
            return json.loads(env_payload)
        except json.JSONDecodeError:
            return {}

    return {}


def dig(source, *keys):
    for key in keys:
        if isinstance(source, dict) and key in source and source[key] is not None:
            return source[key]
    return None


def raw_event_name(payload):
    nested = payload.get("payload") if isinstance(payload.get("payload"), dict) else {}
    return dig(
        payload,
        "hook_event_name",
        "hookEventName",
        "event_name",
        "event",
        "type",
    ) or dig(nested, "hook_event_name", "hookEventName", "event_name", "event", "type")


def normalized_event_name(payload):
    event = raw_event_name(payload)
    if not event:
        return ""

    lowered = str(event).strip().lower().replace("_", "").replace("-", "")
    mapping = {
        "userpromptsubmit": "UserPromptSubmit",
        "promptsubmit": "UserPromptSubmit",
        "promptsubmitted": "UserPromptSubmit",
        "pretooluse": "PreToolUse",
        "toolstart": "PreToolUse",
        "posttooluse": "PostToolUse",
        "toolend": "PostToolUse",
        "permissionrequest": "PermissionRequest",
        "approvalrequest": "PermissionRequest",
        "notification": "Notification",
        "stop": "Stop",
        "sessionstart": "SessionStart",
        "sessionend": "SessionEnd",
        "precompact": "PreCompact",
        "compact": "PreCompact",
    }
    return mapping.get(lowered, str(event))


def normalize_tool_input(value):
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
            if isinstance(parsed, dict):
                return parsed
        except Exception:
            pass
        return {"input": value}
    return value or {}


def normalized_status(event_name, payload):
    explicit_status = dig(payload, "status")
    if explicit_status in {
        "waiting_for_input",
        "waiting_for_approval",
        "processing",
        "running_tool",
        "starting",
        "compacting",
        "ended",
    }:
        return explicit_status

    nested = payload.get("payload") if isinstance(payload.get("payload"), dict) else {}
    notification_type = dig(payload, "notification_type", "notificationType") or dig(
        nested, "notification_type", "notificationType"
    )

    if event_name == "PermissionRequest":
        return "waiting_for_approval"
    if event_name == "PreToolUse":
        return "running_tool"
    if event_name in {"UserPromptSubmit", "PostToolUse"}:
        return "processing"
    if event_name in {"Stop", "SessionStart"}:
        return "waiting_for_input"
    if event_name == "SessionEnd":
        return "ended"
    if event_name == "PreCompact":
        return "compacting"
    if event_name == "Notification" and notification_type == "idle_prompt":
        return "waiting_for_input"
    return "notification"


def send_event(event):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(event).encode())

        if event.get("status") == "waiting_for_approval":
            response = sock.recv(4096)
            sock.close()
            if response:
                return json.loads(response.decode())
        else:
            sock.close()
    except Exception:
        return None

    return None


def main():
    payload = load_payload()
    nested = payload.get("payload") if isinstance(payload.get("payload"), dict) else {}

    event_name = normalized_event_name(payload)
    if not event_name:
        sys.exit(0)

    cwd = dig(payload, "cwd") or dig(nested, "cwd") or os.getcwd()
    session_id = dig(payload, "session_id", "sessionId") or dig(
        nested, "session_id", "sessionId"
    )
    if not session_id:
        session_id = "gemini-" + cwd.replace("/", "-").replace(".", "-")

    tool_input = normalize_tool_input(
        dig(payload, "tool_input", "toolInput", "arguments", "input")
        or dig(nested, "tool_input", "toolInput", "arguments", "input")
    )
    notification_type = dig(payload, "notification_type", "notificationType") or dig(
        nested, "notification_type", "notificationType"
    )
    message = dig(payload, "message", "prompt") or dig(nested, "message", "prompt")

    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event_name,
        "status": normalized_status(event_name, payload),
        "pid": os.getppid(),
        "tty": get_tty(),
        "tool": dig(payload, "tool_name", "toolName", "name") or dig(
            nested, "tool_name", "toolName", "name"
        ),
        "tool_input": tool_input,
        "tool_use_id": dig(payload, "tool_use_id", "toolUseId", "call_id", "callId")
        or dig(nested, "tool_use_id", "toolUseId", "call_id", "callId"),
        "notification_type": notification_type,
        "message": message,
        "agent_id": AGENT_ID,
        "raw_payload": payload,
    }

    response = send_event(state)
    if state["status"] != "waiting_for_approval" or not response:
        sys.exit(0)

    decision = response.get("decision", "ask")
    if decision == "allow":
        print(
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": event_name,
                        "decision": {"behavior": "allow"},
                    }
                }
            )
        )
    elif decision == "deny":
        print(
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": event_name,
                        "decision": {
                            "behavior": "deny",
                            "message": response.get("reason") or "Denied by Vibe Island",
                        },
                    }
                }
            )
        )


if __name__ == "__main__":
    main()
