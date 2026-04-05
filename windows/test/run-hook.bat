@echo off
echo {"session_id":"test-123","hook_event_name":"SessionStart","cwd":"C:\\Users\\pangy"} | python "C:\Users\pangy\.claude\hooks\claude-island-state.py" --port 51515
echo EXIT CODE: %ERRORLEVEL%
