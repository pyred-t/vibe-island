import pathlib

msg = """docs(windows): update README.md with Remote SSH and performance features

1. Added documentation for the new Machine-Centric architecture (Local vs SSH).
2. Explained Remote SSH Tunneling (reverse forwarding) and Auto-Sync mechanisms.
3. Documented Performance Optimizations (TCP NoDelay, explicit IPv4 binding, fuser cleanup).
4. Updated Troubleshooting section with SSH-specific fixes (ProxyJump, ssh-add).
5. Updated File Structure to include `tunnel-manager.js` and `ssh-config-reader.js`.
"""

pathlib.Path(r"C:/Users/pangy/AppData/Local/Temp/cm8.txt").write_text(msg, encoding="utf-8")
print("Written.")
