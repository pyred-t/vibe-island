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
import sqlite3
import subprocess
import sys
from datetime import datetime

AGENT_ID = "codex"
SOCKET_PATH = os.environ.get("CLAUDE_ISLAND_SOCKET_PATH", "/tmp/claude-island.sock")
TIMEOUT_SECONDS = 300
HOOK_LOG_PATH = os.environ.get(
    "CLAUDE_ISLAND_HOOK_LOG_PATH",
    "/tmp/claude-island-codex-hook.log",
)


def append_debug(kind, payload):
    try:
        record = {
            "timestamp": datetime.utcnow().isoformat(timespec="milliseconds") + "Z",
            "kind": kind,
            "payload": payload,
        }
        with open(HOOK_LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
    except Exception:
        pass


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
        "sessionstart": "SessionStart",
        "sessionend": "SessionEnd",
        "userpromptsubmit": "UserPromptSubmit",
        "promptsubmit": "UserPromptSubmit",
        "pretooluse": "PreToolUse",
        "posttooluse": "PostToolUse",
        "toolstart": "PreToolUse",
        "toolend": "PostToolUse",
        "stop": "Stop",
        "notification": "Notification",
        "approvalrequest": "PermissionRequest",
        "permissionrequest": "PermissionRequest",
        "precompact": "PreCompact",
        "compact": "PreCompact",
    }
    return mapping.get(lowered, str(event))


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


def parse_json_object(value):
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
            if isinstance(parsed, dict):
                return parsed
        except Exception:
            return None
    return None


def extract_tool_name(payload, nested):
    candidates = [
        dig(payload, "tool_name", "toolName", "name"),
        dig(nested, "tool_name", "toolName", "name"),
        dig(payload, "function_name", "functionName"),
        dig(nested, "function_name", "functionName"),
    ]
    for value in candidates:
        if isinstance(value, str) and value:
            return value

    for candidate in (payload, nested):
        if isinstance(candidate, dict):
            function_call = candidate.get("function_call")
            if isinstance(function_call, dict):
                name = dig(function_call, "name")
                if isinstance(name, str) and name:
                    return name
            inner_payload = candidate.get("payload")
            if isinstance(inner_payload, dict):
                name = dig(inner_payload, "name", "tool_name", "toolName")
                if isinstance(name, str) and name:
                    return name
    return None


def extract_tool_use_id(payload, nested):
    candidates = [
        dig(payload, "tool_use_id", "toolUseId", "call_id", "callId"),
        dig(nested, "tool_use_id", "toolUseId", "call_id", "callId"),
    ]
    for value in candidates:
        if isinstance(value, str) and value:
            return value

    for candidate in (payload, nested):
        if isinstance(candidate, dict):
            function_call = candidate.get("function_call")
            if isinstance(function_call, dict):
                call_id = dig(function_call, "call_id", "callId")
                if isinstance(call_id, str) and call_id:
                    return call_id
            inner_payload = candidate.get("payload")
            if isinstance(inner_payload, dict):
                call_id = dig(inner_payload, "call_id", "callId", "tool_use_id", "toolUseId")
                if isinstance(call_id, str) and call_id:
                    return call_id
    return None


def extract_tool_input(payload, nested, tool_name):
    direct = (
        dig(payload, "tool_input", "toolInput")
        or dig(nested, "tool_input", "toolInput")
    )
    normalized_direct = normalize_tool_input(direct)
    if normalized_direct:
        return normalized_direct

    candidates = [
        dig(payload, "arguments", "input"),
        dig(nested, "arguments", "input"),
    ]
    for value in candidates:
        normalized = normalize_tool_input(value)
        if normalized:
            return normalized

    function_call_candidates = []
    for candidate in (payload, nested):
        if isinstance(candidate, dict):
            function_call = candidate.get("function_call")
            if isinstance(function_call, dict):
                function_call_candidates.append(function_call)
            inner_payload = candidate.get("payload")
            if isinstance(inner_payload, dict):
                function_call_candidates.append(inner_payload)

    for function_call in function_call_candidates:
        normalized = normalize_tool_input(function_call.get("input"))
        if normalized:
            return normalized

        arguments = function_call.get("arguments")
        parsed_arguments = parse_json_object(arguments)
        if parsed_arguments:
            return parsed_arguments

    if tool_name == "request_user_input":
        raw_arguments = (
            dig(payload, "arguments")
            or dig(nested, "arguments")
        )
        parsed_arguments = parse_json_object(raw_arguments)
        if parsed_arguments:
            return parsed_arguments

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
    if event_name == "PermissionRequest":
        return "waiting_for_approval"
    if event_name == "SessionEnd":
        return "ended"
    if event_name == "PreCompact":
        return "compacting"
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


def resolve_thread_session_id(cwd):
    if not cwd:
        return None

    db_path = os.path.expanduser("~/.codex/state_5.sqlite")
    if not os.path.exists(db_path):
        return None

    try:
        connection = sqlite3.connect(db_path)
        try:
            cursor = connection.cursor()
            cursor.execute(
                """
                select id
                from threads
                where cwd = ? and archived = 0
                order by updated_at desc
                limit 1
                """,
                (cwd,),
            )
            row = cursor.fetchone()
            if row and row[0]:
                return f"codex-thread-{row[0]}"
        finally:
            connection.close()
    except Exception:
        return None

    return None


def _extract_message(payload, event_name, tool_input):
    """Extract the best available message text from a Codex hook payload.

    Digs into nested tool_input structures to find permission/justification
    text that the top-level payload doesn't expose.
    """
    nested = payload.get("payload") if isinstance(payload.get("payload"), dict) else {}
    # Primary: explicit prompt/message fields
    msg = dig(payload, "prompt", "message", "last_assistant_message", "lastAssistantMessage")
    if not msg:
        msg = dig(nested, "prompt", "message", "last_assistant_message", "lastAssistantMessage")

    # Secondary: dig into tool_input for permission-related text
    parts = []
    if isinstance(tool_input, dict):
        for key in ("justification", "permission_request_text", "permission_text",
                     "request_text", "prompt_text", "description", "reason"):
            val = tool_input.get(key)
            if val and isinstance(val, str):
                parts.append(val)

        # Codex CLI sometimes nests the command/code being approved
        if not parts:
            for key in ("command", "code", "script"):
                val = tool_input.get(key)
                if val and isinstance(val, str):
                    parts.append(val)
                    break  # only take one command-like field

    if parts:
        fallback = "\n".join(parts)
        msg = f"{msg}\n{fallback}" if msg else fallback

    # For PreToolUse waiting_for_approval with no message, synthesize one
    if not msg and event_name == "PreToolUse":
        status = dig(payload, "status")
        tool_name = dig(payload, "tool_name", "toolName", "name")
        if status == "waiting_for_approval" and tool_name:
            msg = f"Approve {tool_name}?"

    return msg


def build_state(payload):
    nested = payload.get("payload") if isinstance(payload.get("payload"), dict) else {}
    event_name = normalized_event_name(payload)
    if not event_name:
        return None

    cwd = dig(payload, "cwd") or dig(nested, "cwd") or os.getcwd()
    session_id = dig(payload, "session_id", "sessionId") or dig(
        nested, "session_id", "sessionId"
    )
    if not session_id:
        session_id = resolve_thread_session_id(cwd) or (
            "codex-" + cwd.replace("/", "-").replace(".", "-")
        )

    tool_name = extract_tool_name(payload, nested)
    tool_input = extract_tool_input(payload, nested, tool_name)
    message = _extract_message(payload, event_name, tool_input)
    tool_use_id = extract_tool_use_id(payload, nested)

    append_debug(
        "tool_extraction",
        {
            "event": event_name,
            "tool": tool_name,
            "tool_use_id": tool_use_id,
            "tool_input_keys": sorted(tool_input.keys()) if isinstance(tool_input, dict) else [],
        },
    )

    return {
        "session_id": session_id,
        "cwd": cwd,
        "event": event_name,
        "status": normalized_status(event_name, tool_name, tool_input, payload),
        "pid": os.getppid(),
        "tty": get_tty(),
        "tool": tool_name,
        "tool_input": tool_input,
        "tool_use_id": tool_use_id,
        "notification_type": dig(payload, "notification_type", "notificationType")
        or dig(nested, "notification_type", "notificationType"),
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
        append_debug("socket_send", event)

        # Wait for response: approval events OR request_user_input interactions
        should_wait = (
            event.get("status") == "waiting_for_approval" or
            event.get("tool") == "request_user_input"
        )
        if should_wait:
            response = sock.recv(65536)
            sock.close()
            if response:
                decoded = json.loads(response.decode())
                append_debug("socket_recv", decoded)
                return decoded
        else:
            sock.close()
    except Exception:
        append_debug("socket_error", {"event": event})
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
    append_debug("raw_payload", payload)
    state = build_state(payload)
    if not state:
        sys.exit(0)

    append_debug("normalized_state", state)
    response = send_event(state)

    # Handle request_user_input interaction response
    if state.get("tool") == "request_user_input":
        if response:
            updated_input = response.get("updatedInput")
            if updated_input:
                stdout_payload = {
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "updatedInput": updated_input
                    }
                }
                append_debug("stdout_request_user_input", stdout_payload)
                print(json.dumps(stdout_payload, ensure_ascii=False))
                sys.stdout.flush()
            else:
                append_debug("request_user_input_missing_updated_input", response)
        else:
            append_debug("request_user_input_no_response", state)
        sys.exit(0)

    if state["status"] != "waiting_for_approval":
        sys.exit(0)

    if not response:
        sys.exit(0)

    decision = response.get("decision", "ask")
    if decision == "allow" or decision == "always_allow":
        append_debug("stdout_permission", {"decision": "allow"})
        emit_permission_response("allow")
    elif decision == "deny":
        append_debug("stdout_permission", {"decision": "deny", "reason": response.get("reason")})
        emit_permission_response("deny", response.get("reason"))
    elif decision == "ask":
        append_debug("stdout_permission", {"decision": "ask"})
        emit_permission_response("ask")


if __name__ == "__main__":
    main()
