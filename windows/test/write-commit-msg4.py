import pathlib

msg = """fix(windows): address remote hook IPv4/IPv6 routing and UI indicators

1. Fixed an issue where connections from remote Claude hooks were lost ('Empty reply from server') despite a successful SSH reverse tunnel. `ssh -R <port>:localhost:<port>` on Windows resolves `localhost` to IPv6 `[::1]` but the Node.js server explicitly bound to IPv4 `127.0.0.1`. Changed the SSH argument to explicitly bind the reverse tunnel to `127.0.0.1`.
2. Added an explicit 'Auto Synced ✓' badge UI element to remote machine paths, visually reassuring users that SSH hook installation is handled automatically by the tunnel manager upon connection.
"""

pathlib.Path(r"C:/Users/pangy/AppData/Local/Temp/cm4.txt").write_text(msg, encoding="utf-8")
print("Written.")
