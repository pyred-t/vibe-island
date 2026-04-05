import pathlib

msg = """fix(windows): address community feedback on SSH hosts and paths

1. Added 'Add Custom Host' button to manually enter SSH hosts not mapped in the local user's ssh config.
2. Fixed a bug where removing local Claude paths failed due to unescaped Windows backslashes in HTML data attributes. Replaced raw string passing with `encodeURIComponent` and `decodeURIComponent`.
3. Fixed 'No such file or directory' when checking/modifying remote hook scripts where the target directory used a `~` prefix. Python `open()` does not automatically expand tildes; wrapped path variables in `os.path.expanduser`.
"""

pathlib.Path(r"C:/Users/pangy/AppData/Local/Temp/cm.txt").write_text(msg, encoding="utf-8")
print("Written.")
