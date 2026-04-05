"""
Test Windows encoding fix: send JSON with Chinese/non-ASCII content
to verify the hook script can parse it correctly on Windows.
"""
import subprocess
import json
import sys

# Simulate Claude Code sending a hook event with Chinese path & content
test_events = [
    {
        "session_id": "win-test-001",
        "hook_event_name": "SessionStart",
        "cwd": "C:\\Users\\张三\\项目\\my-app",  # Chinese path
        "tool_input": {}
    },
    {
        "session_id": "win-test-001",
        "hook_event_name": "UserPromptSubmit",
        "cwd": "C:\\Users\\pangy\\Documents\\work",
        "tool_input": {}
    },
    {
        "session_id": "win-test-001",
        "hook_event_name": "PreToolUse",
        "tool_name": "Write",
        "tool_use_id": "tu-001",
        "cwd": "C:\\Users\\pangy\\project",
        "tool_input": {"file_path": "src/main.py", "content": "# Hello 你好"}
    },
    {
        "session_id": "win-test-001",
        "hook_event_name": "Stop",
        "cwd": "C:\\Users\\pangy\\project",
        "tool_input": {}
    },
    {
        "session_id": "win-test-001",
        "hook_event_name": "SessionEnd",
        "cwd": "C:\\Users\\pangy\\project",
        "tool_input": {}
    },
]

script_path = r"C:\Users\pangy\.claude\hooks\claude-island-state.py"
passed = 0
failed = 0

for event in test_events:
    name = event["hook_event_name"]
    input_json = json.dumps(event, ensure_ascii=False)
    
    result = subprocess.run(
        ["python", script_path, "--port", "51515"],
        input=input_json.encode("utf-8"),
        capture_output=True,
        timeout=5
    )
    
    ok = result.returncode == 0
    status = "OK  " if ok else "FAIL"
    if ok:
        passed += 1
    else:
        failed += 1
    print(f"[{status}] {name}: exit={result.returncode}", flush=True)
    if result.stderr:
        print(f"       stderr: {result.stderr.decode('utf-8', errors='replace')[:200]}", flush=True)

print(f"\nResult: {passed}/{len(test_events)} passed")
if failed > 0:
    sys.exit(1)
