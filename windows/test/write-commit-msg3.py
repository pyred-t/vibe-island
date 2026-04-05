import pathlib

msg = """fix(windows): resolve persistent SSH tunnel exit 255 caused by remote port conflicts

When establishing reverse tunnels (especially via ProxyJump or reconnecting to a host), SSH would instantly disconnect with exit code 255 due to the remote port still being bound by a lingering session.
1. Removed `-o ExitOnForwardFailure=yes` to prevent fatal aborts on temporary port availability issues.
2. Added an explicit remote cleanup routine (`fuser -k <port>/tcp`) before `ssh -R` binds, ensuring the listener port is free for the new tunnel session.
"""

pathlib.Path(r"C:/Users/pangy/AppData/Local/Temp/cm3.txt").write_text(msg, encoding="utf-8")
print("Written.")
