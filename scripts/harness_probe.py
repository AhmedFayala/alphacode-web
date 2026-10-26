#!/usr/bin/env python3
"""
AlphaCode Harness API Socket Probe — Stage 1 Diagnostic
Connects directly to alphacode-api.sock, performs Hello handshake,
then sends list_sessions. Prints raw NDJSON frames.
"""
import socket
import json
import sys
import os
import time

SOCKET_PATH = os.path.expanduser("~/.alphacode/alphacode-api.sock")
TIMEOUT = 10  # seconds per recv

def send_frame(sock, obj):
    """Send one NDJSON line."""
    line = json.dumps(obj) + "\n"
    sock.sendall(line.encode())
    print(f">>> SENT: {json.dumps(obj)}")

def recv_frame(sock):
    """Read one NDJSON line."""
    buf = b""
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            return None
        buf += chunk
        if b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            line = line.decode().strip()
            if line:
                try:
                    return json.loads(line)
                except json.JSONDecodeError:
                    print(f"<<< RAW (non-JSON): {line}")
                    return None
    return None

def main():
    print(f"=== AlphaCode Harness API Probe ===")
    print(f"Socket: {SOCKET_PATH}")
    print(f"Exists: {os.path.exists(SOCKET_PATH)}")
    print(f"PID: {os.getpid()}")
    print()

    if not os.path.exists(SOCKET_PATH):
        print("ERROR: Socket does not exist. Is the api-bridge running?")
        sys.exit(1)

    # Connect
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(TIMEOUT)
    try:
        sock.connect(SOCKET_PATH)
        print(f"CONNECTED to {SOCKET_PATH}")
        print()
    except Exception as e:
        print(f"CONNECT FAILED: {e}")
        sys.exit(1)

    # Step 1: Hello handshake
    print("--- Phase 1: Hello Handshake ---")
    hello = {
        "id": 1,
        "req": "hello",
        "min_version": 1,
        "max_version": 1,
        "client": "probe"
    }
    send_frame(sock, hello)

    response = recv_frame(sock)
    if response is None:
        print("ERROR: No response received (connection closed?)")
        sys.exit(1)

    print(f"<<< RECV: {json.dumps(response, indent=2)}")
    print()

    # Check for HelloOk
    ev = response.get("ev", "")
    if ev == "hello_ok":
        print(f"[OK] HelloOk received!")
        print(f"     Version: {response.get('version')}")
        print(f"     Server:  {response.get('server')}")
        print(f"     Caps:    {response.get('capabilities')}")
    elif ev == "error":
        print(f"[FAIL] Server returned error: {response.get('message')}")
        sys.exit(1)
    else:
        print(f"[WARN] Unexpected event type: {ev}")
        print(f"       Full response: {response}")

    print()

    # Step 2: ListSessions
    print("--- Phase 2: List Sessions ---")
    list_req = {
        "id": 2,
        "req": "list_sessions"
    }
    send_frame(sock, list_req)

    # May receive multiple frames (e.g. Ok ack first, then Sessions)
    for i in range(5):
        response2 = recv_frame(sock)
        if response2 is None:
            print("ERROR: Connection closed during list_sessions")
            break

        print(f"<<< RECV: {json.dumps(response2, indent=2)}")

        ev2 = response2.get("ev", "")
        if ev2 == "sessions":
            sessions = response2.get("sessions", [])
            print(f"\n[OK] Sessions received: {len(sessions)} session(s)")
            for s in sessions:
                print(f"     - id={s.get('session_id')}, status={s.get('status')}, "
                      f"title={s.get('title', 'N/A')}, "
                      f"transcript_bytes={s.get('transcript_bytes', 'N/A')}")
            break
        elif ev2 == "ok":
            print(f"     (ack received, waiting for sessions...)")
            continue
        elif ev2 == "error":
            print(f"[FAIL] Error: {response2.get('message')}")
            break
        else:
            print(f"     (unexpected event: {ev2})")
            continue

    print()

    # Step 3: Ping
    print("--- Phase 3: Ping ---")
    ping_req = {
        "id": 3,
        "req": "ping"
    }
    send_frame(sock, ping_req)

    for i in range(3):
        response3 = recv_frame(sock)
        if response3 is None:
            print("ERROR: Connection closed during ping")
            break

        print(f"<<< RECV: {json.dumps(response3, indent=2)}")
        ev3 = response3.get("ev", "")
        if ev3 == "pong":
            print(f"\n[OK] Pong received!")
            break
        elif ev3 == "ok":
            continue
        else:
            continue

    sock.close()
    print()
    print("=== Probe Complete ===")
    print("Socket closed cleanly.")

if __name__ == "__main__":
    main()
