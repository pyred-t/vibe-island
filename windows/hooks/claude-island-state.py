#!/usr/bin/env python3
"""
Claude Island Hook (Windows / WSL compatible)
- Sends session state to Claude Island app via TCP socket
- For PermissionRequest: waits for user decision from the app
- For AskUserQuestion: waits for user input from the app

Usage:
  python claude-island-state.py --port 51515

This script is called by Claude Code hooks system.
It reads hook event data from stdin (JSON) and communicates
with the Claude Island Windows app via TCP on localhost.
"""
import argparse
import io
import json
import os
import platform
import socket
import sys

# ── Windows encoding fix ──────────────────────────────────────────────────────
# Windows Python defaults to system locale encoding (GBK/CP936 on Chinese
# Windows). Claude Code sends UTF-8 JSON, so we must re-wrap stdin/stdout.
if sys.platform == "win32":
    sys.stdin  = io.TextIOWrapper(sys.stdin.buffer,  encoding="utf-8", errors="replace")
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")
# ─────────────────────────────────────────────────────────────────────────────

AGENT_ID = "claude"
DEFAULT_PORT = 51515
DEFAULT_HOST = "127.0.0.1"
TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions


def get_tty():
    """Get the TTY of the Claude process (parent)"""
    # On Windows, there's no TTY concept in the Unix sense
    if platform.system() == "Windows":
        return None

    import subprocess

    ppid = os.getppid()
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2,
        )
        tty = result.stdout.strip()
        if tty and tty != "??" and tty != "-":
            if not tty.startswith("/dev/"):
                tty = "/dev/" + tty
            return tty
    except Exception:
        pass

    # Fallback: try current process stdin/stdout
    try:
        return os.ttyname(sys.stdin.fileno())
    except (OSError, AttributeError):
        pass
    try:
        return os.ttyname(sys.stdout.fileno())
    except (OSError, AttributeError):
        pass
    return None


def detect_host():
    """
    Detect the correct host to connect to.
    In WSL, we need to connect to the Windows host.
    """
    # Check if we're in WSL
    if _is_wsl():
        # In WSL2, localhost usually works (mirrors Windows host)
        # But if it doesn't, try to get the Windows host IP
        try:
            # WSL2: read the nameserver from /etc/resolv.conf (Windows host IP)
            with open("/etc/resolv.conf", "r") as f:
                for line in f:
                    if line.startswith("nameserver"):
                        host_ip = line.split()[1].strip()
                        if host_ip and host_ip != "127.0.0.1":
                            # Try localhost first (WSL2 mirroring), fallback to host IP
                            return DEFAULT_HOST
            return DEFAULT_HOST
        except Exception:
            return DEFAULT_HOST

    return DEFAULT_HOST


def _is_wsl():
    """Check if running inside WSL"""
    try:
        with open("/proc/version", "r") as f:
            version_info = f.read().lower()
            return "microsoft" in version_info or "wsl" in version_info
    except Exception:
        return False


def send_event(state, host, port):
    """Send event to app via TCP, return response if any"""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect((host, port))
        sock.sendall(json.dumps(state).encode())

        should_wait = state.get("status") == "waiting_for_approval" or (
            state.get("event") == "PreToolUse"
            and state.get("tool") == "AskUserQuestion"
        )

        if should_wait:
            # Wait for response from the app
            response_data = b""
            while True:
                try:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    response_data += chunk
                except socket.timeout:
                    break

            sock.close()
            if response_data:
                return json.loads(response_data.decode())
        else:
            sock.close()

        return None
    except (socket.error, OSError, json.JSONDecodeError) as e:
        # App not running or connection failed - silently exit
        return None


def main():
    parser = argparse.ArgumentParser(description="Claude Island Hook Script")
    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help=f"TCP port to connect to (default: {DEFAULT_PORT})",
    )
    parser.add_argument(
        "--host",
        type=str,
        default=None,
        help=f"Host to connect to (default: auto-detect, usually {DEFAULT_HOST})",
    )
    args = parser.parse_args()

    host = args.host or detect_host()
    port = args.port

    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")
    tool_input = data.get("tool_input", {})

    # Get process info
    claude_pid = os.getppid()
    tty = get_tty()

    # Build state object
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": claude_pid,
        "tty": tty,
        "agent_id": AGENT_ID,
        "raw_payload": data,
    }

    # Map events to status
    if event == "UserPromptSubmit":
        state["status"] = "processing"

    elif event == "PreToolUse":
        tool_name = data.get("tool_name")
        state["tool"] = tool_name
        state["tool_input"] = tool_input
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

        if tool_name == "AskUserQuestion":
            state["status"] = "waiting_for_input"
            response = send_event(state, host, port)
            if response and response.get("updatedInput") is not None:
                print(
                    json.dumps(
                        {
                            "hookSpecificOutput": {
                                "hookEventName": "PreToolUse",
                                "permissionDecision": "allow",
                                "updatedInput": response.get("updatedInput"),
                            }
                        }
                    )
                )
                sys.exit(0)
            sys.exit(0)

        state["status"] = "running_tool"

    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PermissionRequest":
        state["status"] = "waiting_for_approval"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        tool_use_id = data.get("tool_use_id")
        if tool_use_id:
            state["tool_use_id"] = tool_use_id

        response = send_event(state, host, port)

        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")

            if decision == "allow":
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow"},
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "always_allow":
                decision_obj = {"behavior": "allow"}
                suggestions = data.get("permission_suggestions", [])
                if suggestions:
                    decision_obj["updatedPermissions"] = suggestions
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": decision_obj,
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "deny":
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via Claude Island",
                        },
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

        sys.exit(0)

    elif event == "Notification":
        notification_type = data.get("notification_type")
        if notification_type == "permission_prompt":
            sys.exit(0)
        elif notification_type == "idle_prompt":
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"
        state["notification_type"] = notification_type
        state["message"] = data.get("message")

    elif event == "Stop":
        state["status"] = "waiting_for_input"

    elif event == "SubagentStop":
        state["status"] = "waiting_for_input"

    elif event == "SessionStart":
        state["status"] = "waiting_for_input"

    elif event == "SessionEnd":
        state["status"] = "ended"

    elif event == "PreCompact":
        state["status"] = "compacting"

    else:
        state["status"] = "unknown"

    # Send to TCP socket (fire and forget for non-permission events)
    send_event(state, host, port)


if __name__ == "__main__":
    main()
