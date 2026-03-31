#!/usr/bin/env python3
"""
Vibe Island hook bridge for OpenAI Codex CLI.

- Consumes native Codex hook stdin payloads
- Normalizes them onto the shared HookEvent schema
- Sends them to Vibe Island over the shared Unix domain socket
- For approval-gated PreToolUse events, waits for a synchronous UDS reply and
  translates it back into Codex-native hook JSON
"""

import json
import os
import socket
import subprocess
import sys

AGENT_ID = "codex"
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
            return {}

    env_payload = os.environ.get("CODEX_HOOK_PAYLOAD")
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


def normalize_tool_input(value):
    if isinstance(value, dict):
        return value
    if isinstance(value, list):
        return {"items": value}
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
            if isinstance(parsed, dict):
                return parsed
            if isinstance(parsed, list):
                return {"items": parsed}
        except Exception:
            pass
        return {"value": value}
    return {}


def normalized_status(event_name, tool_name, tool_input, payload):
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

    if event_name == "SessionStart":
        return "waiting_for_input"
    if event_name == "UserPromptSubmit":
        return "processing"
    if event_name == "Stop":
        return "waiting_for_input"
    if event_name == "PostToolUse":
        return "processing"
    if event_name == "PreToolUse":
        if tool_name == "request_user_input":
            return "waiting_for_input"
        if requires_permission(tool_name, tool_input, payload):
            return "waiting_for_approval"
        return "running_tool"
    return "notification"


def requires_permission(tool_name, tool_input, payload):
    if tool_name == "request_user_input":
        return False

    permission_mode = dig(payload, "permission_mode", "permissionMode")
    if permission_mode == "bypassPermissions":
        return False

    if dig(payload, "approval_id", "approvalId", "permission_request_id", "permissionRequestId"):
        return True

    if not isinstance(tool_input, dict):
        return False

    if tool_input.get("sandbox_permissions") == "require_escalated":
        return True

    if tool_input.get("requires_approval") is True or tool_input.get("permission_required") is True:
        return True

    if tool_input.get("justification"):
        return True

    if tool_name in {"request_permissions", "apply_patch_approval", "exec_approval"}:
        return True

    return False


def build_state(payload):
    event_name = dig(payload, "hook_event_name", "hookEventName", "event_name", "event")
    if not event_name:
        return None

    cwd = dig(payload, "cwd") or os.getcwd()
    session_id = dig(payload, "session_id", "sessionId")
    if not session_id:
        session_id = "codex-" + cwd.replace("/", "-").replace(".", "-")

    tool_input = normalize_tool_input(dig(payload, "tool_input", "toolInput"))
    tool_name = dig(payload, "tool_name", "toolName", "name")
    message = dig(payload, "prompt", "last_assistant_message", "lastAssistantMessage")

    return {
        "session_id": session_id,
        "cwd": cwd,
        "event": event_name,
        "status": normalized_status(event_name, tool_name, tool_input, payload),
        "pid": os.getppid(),
        "tty": get_tty(),
        "tool": tool_name,
        "tool_input": tool_input,
        "tool_use_id": dig(payload, "tool_use_id", "toolUseId", "call_id", "callId"),
        "message": message,
        "agent_id": AGENT_ID,
        "raw_payload": payload,
    }


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


def emit_permission_response(decision, reason=None):
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
        }
    }
    if decision == "deny":
        output["hookSpecificOutput"]["permissionDecisionReason"] = (
            reason or "Denied by Vibe Island"
        )
    print(json.dumps(output))


def main():
    payload = load_payload()
    state = build_state(payload)
    if not state:
        sys.exit(0)

    response = send_event(state)
    if state["status"] != "waiting_for_approval":
        sys.exit(0)

    if not response:
        sys.exit(0)

    decision = response.get("decision", "ask")
    if decision == "allow":
        emit_permission_response("allow")
    elif decision == "deny":
        emit_permission_response("deny", response.get("reason"))
    elif decision == "ask":
        emit_permission_response("ask")


if __name__ == "__main__":
    main()
