import pathlib

msg = """feat(windows): add manual hook sync for SSH and optimize UI feedback latency

1. Manual SSH Hook Sync: Added a 'Force Sync' button for connected remote machines. This taps directly into the new `tunnelManager.forceInstallHooks` method to bypass standard connection checks, allowing users to forcefully synchronize their `~/.claude/settings.json` hook configurations if auto-sync fails or if they accidentally overwrote settings externally.
2. Zero-Latency Interaction UI: Fixed the "delayed response" when clicking Allow/Deny in permission dialogues. The delay occurred because the UI waited for an external IPC resolution triggered by Claude Code evaluating the hook's return payload. Implemented optimistic optimistic updating: interface buttons instantly toggle to `Allowing...`, and the backend IPC forcibly transitions the session's core state phase to `PROCESSING` locally without waiting.
"""

pathlib.Path(r"C:/Users/pangy/AppData/Local/Temp/cm5.txt").write_text(msg, encoding="utf-8")
print("Written.")
