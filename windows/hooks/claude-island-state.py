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
CONNECT_TIMEOUT = 3  # seconds — short so hooks don't block Claude Code


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
    In WSL2 non-mirror mode, we need to connect to the Windows host IP
    (the nameserver entry in /etc/resolv.conf).
    """
    if not _is_wsl():
        return DEFAULT_HOST

    # Try 127.0.0.1 first (works for WSL2 mirror mode and WSL1)
    # If that fails, fall back to the Windows host IP from resolv.conf
    if _can_connect(DEFAULT_HOST, DEFAULT_PORT, timeout=0.5):
        return DEFAULT_HOST

    # WSL2 non-mirror: Windows host is the nameserver
    try:
        with open("/etc/resolv.conf", "r") as f:
            for line in f:
                if line.startswith("nameserver"):
                    host_ip = line.split()[1].strip()
                    if host_ip and host_ip != "127.0.0.1":
                        return host_ip
    except Exception:
        pass

    return DEFAULT_HOST


def _can_connect(host, port, timeout=0.5):
    """Quick probe: can we reach host:port?"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((host, port))
        s.close()
        return True
    except Exception:
        return False


def _is_wsl():
    """Check if running inside WSL"""
    try:
        with open("/proc/version", "r") as f:
            version_info = f.read().lower()
            return "microsoft" in version_info or "wsl" in version_info
    except Exception:
        return False


def send_event(state, host, port, timeout=None):
    """Send event to app via TCP, return response if any"""
    effective_timeout = timeout if timeout is not None else TIMEOUT_SECONDS
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        # Use a short connect timeout so we fail fast when firewall drops packets
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect((host, port))
        # After connect succeeds, switch to the longer read timeout for permission waits
        sock.settimeout(effective_timeout)
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
    parser.add_argument(
        "--machine",
        type=str,
        default=None,
        help="Machine alias/label to identify this remote host (injected by tunnel-manager)",
    )
    args = parser.parse_args()

    host = args.host or detect_host()
    port = args.port
    machine_alias = args.machine

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
        "hostname": machine_alias or socket.gethostname(),
        "is_remote": bool(machine_alias or os.environ.get("SSH_CLIENT") or os.environ.get("SSH_TTY")),
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
            # Fire-and-forget: show in Claude Island UI, don't block Claude Code
            state["status"] = "waiting_for_input"
            send_event(state, host, port)
            sys.exit(0)

        if tool_name == "ExitPlanMode":
            state["status"] = "plan_ready"
            send_event(state, host, port)
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
        tool_name = data.get("tool_name")

        # AskUserQuestion: don't intercept, let Claude Code handle permission natively
        if tool_name == "AskUserQuestion":
            sys.exit(0)

        state["status"] = "waiting_for_approval"
        state["tool"] = tool_name
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
