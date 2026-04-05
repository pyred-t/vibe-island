import pathlib

msg = """fix(windows): remove overly eager SSH auth failure check

`ssh -v` outputs `Authentications that can continue: publickey,password` during normal negotiation. The previous logic saw 'publickey,' and immediately flagged the connection as AUTH_REQUIRED even for successful connections.

Removed the 'publickey,' check and now trust the actual 'Permission denied' / 'Authentication failed' error strings that are emitted when auth truly fails.
"""

pathlib.Path(r"C:/Users/pangy/AppData/Local/Temp/cm2.txt").write_text(msg, encoding="utf-8")
print("Written.")
