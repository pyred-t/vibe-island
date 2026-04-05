"""Quick connectivity test: can Python connect to Claude Island TCP server?"""
import socket
import json
import sys
import io

# Fix Windows GBK encoding for stdout
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

HOST = "127.0.0.1"
PORT = 51515

print(f"Testing connection to {HOST}:{PORT}...")
try:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(3)
    sock.connect((HOST, PORT))
    print("OK: Connected!")

    payload = {
        "session_id": "diag-test",
        "event": "SessionStart",
        "status": "waiting_for_input",
        "cwd": "C:\\Users\\pangy\\test",
        "pid": 999,
        "agent_id": "claude"
    }
    sock.sendall(json.dumps(payload).encode())
    print(f"OK: Sent payload")
    sock.close()
    print("OK: Done! App should now show a session.")
except ConnectionRefusedError:
    print(f"FAILED: Connection refused -- is Claude Island app running on port {PORT}?")
    sys.exit(1)
except socket.timeout:
    print(f"FAILED: Timeout connecting to {HOST}:{PORT}")
    sys.exit(1)
except Exception as e:
    print(f"FAILED: {type(e).__name__}: {e}")
    sys.exit(1)
