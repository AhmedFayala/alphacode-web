#!/usr/bin/env python3
"""Generic AlphaCode WebSocket reachability + turn test.

Usage: ws_test.py <base-url>   e.g. ws_test.py ws://1.2.3.4:8765
                               or  ws_test.py wss://foo.trycloudflare.com
Reads the bearer token from ~/.alphacode/web_token.
"""
import asyncio, json, os, sys, time, pathlib
import websockets

TOKEN = (pathlib.Path.home() / ".alphacode" / "web_token").read_text().strip()

def build_url(base):
    base = base.rstrip("/")
    # Accept http(s) for convenience and normalise to the WS scheme.
    if base.startswith("https://"):
        base = "wss://" + base[len("https://"):]
    elif base.startswith("http://"):
        base = "ws://" + base[len("http://"):]
    return f"{base}/ws?token={TOKEN}"

async def test(base):
    url = build_url(base)
    shown = url.replace(TOKEN, TOKEN[:8] + "..." + TOKEN[-6:])
    print(f"-> {shown}")
    t0 = time.time()
    async with websockets.connect(url, max_size=10*1024*1024, open_timeout=20) as ws:
        await ws.send(json.dumps({"id":1,"req":"hello","min_version":1,"max_version":1,"client":"ws_test"}))
        r = json.loads(await asyncio.wait_for(ws.recv(), timeout=20))
        print(f"   hello: {r.get('ev')} server={r.get('server')}")

        await ws.send(json.dumps({"id":2,"req":"list_sessions"}))
        r = json.loads(await asyncio.wait_for(ws.recv(), timeout=20))
        print(f"   sessions: {len(r.get('sessions', []))}")

        await ws.send(json.dumps({"id":3,"req":"create_session",
                                  "working_dir": str(pathlib.Path.home() / "workspace")}))
        sid = None
        for _ in range(6):
            r = json.loads(await asyncio.wait_for(ws.recv(), timeout=20))
            if r.get("ev") == "attached":
                sid = r.get("session_id") or (r.get("session") or {}).get("session_id")
                break
        print(f"   attached: {sid}")

        await ws.send(json.dumps({"id":4,"req":"send_message","session_id":sid,
                                  "content":"Reply with exactly: BRIDGE_OK"}))
        deadline = time.time() + 60
        parts, done = [], False
        while time.time() < deadline:
            try:
                r = json.loads(await asyncio.wait_for(ws.recv(), timeout=max(1, deadline-time.time())))
            except asyncio.TimeoutError:
                break
            ev = r.get("ev", "")
            if ev == "text_delta":
                parts.append(r.get("text", ""))
            elif ev == "turn_done":
                done = True
                break
            elif ev == "model_info":
                print(f"   model: {r.get('provider')}/{r.get('model')}")
        text = "".join(parts)
        print(f"   reply: {text[:120]!r}")
        print(f"   turn_done={done} elapsed={time.time()-t0:.1f}s")
        return done

if __name__ == "__main__":
    base = sys.argv[1] if len(sys.argv) > 1 else "ws://127.0.0.1:8765"
    ok = asyncio.run(test(base))
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
