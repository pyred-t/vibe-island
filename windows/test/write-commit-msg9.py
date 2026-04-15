import pathlib

msg = """docs(windows): synchronize README and README.zh.md with new features

1. Comprehensive documentation for Machine-Centric architecture (Local vs SSH).
2. Remote SSH Tunneling (reverse forwarding) and Auto-Sync mechanisms.
3. Performance Optimizations (TCP NoDelay, explicit IPv4 binding, fuser cleanup).
4. Troubleshooting section with SSH-specific fixes (ProxyJump, ssh-add).
5. Updated File Structure for both English and Chinese versions.
"""

pathlib.Path(r"C:/Users/pangy/AppData/Local/Temp/cm9.txt").write_text(msg, encoding="utf-8")
print("Written.")
