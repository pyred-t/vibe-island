import pathlib

msg = """cleanup(windows): remove optimistic UI updates after TCP latency optimization

Since the TCP Nagle algorithm has been disabled and response handling has been optimized to be near-instant, the complex 'optimistic' UI logic (disabling buttons, changing labels manually before state sync) is no longer necessary.
1. Reverted changes in `main.js` that forcibly updated session phases.
2. Simplified `renderer/app.js` handlers to remove manual button state management.
"""

pathlib.Path(r"C:/Users/pangy/AppData/Local/Temp/cm7.txt").write_text(msg, encoding="utf-8")
print("Written.")
