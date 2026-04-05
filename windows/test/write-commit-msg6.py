import pathlib

msg = """perf(windows): aggressively reduce TCP response latency for hook server

By default, Node.js TCP sockets enable Nagle's algorithm, which delays small payloads by ~40-200ms hoping to batch them into larger frames. When paired with SSH reverse tunneling, this could cause noticeable latency when releasing Claude Code's PreToolUse blocking hook.
1. Enabled `socket.setNoDelay(true)` for all incoming hook TCP connections.
2. Compressed `socket.write()` and `socket.end()` into a synchronized `socket.end(buffer)` flush mechanism to avoid secondary tick polling on event loop boundaries.
"""

pathlib.Path(r"C:/Users/pangy/AppData/Local/Temp/cm6.txt").write_text(msg, encoding="utf-8")
print("Written.")
