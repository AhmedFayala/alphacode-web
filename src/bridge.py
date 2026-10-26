#!/usr/bin/env python3
"""
AlphaCode Web Bridge — portable edition
WebSocket <-> Unix Socket NDJSON relay with static file serving.

Environment:
  BRIDGE_HOST    bind address (default 127.0.0.1; use 0.0.0.0 for direct-IP)
  BRIDGE_BIND    legacy alias for BRIDGE_HOST
  BRIDGE_PORT    TCP port (default 8765)
  ALPHACODE_API_SOCKET  path to harness API unix socket

Auth: bearer token read from ~/.alphacode/web_token (auto-generated, mode 0600).
Accepted as ?token=<SECRET> query param or Authorization: Bearer <SECRET>.
"""

import asyncio
import json
import os
import pathlib
import secrets
import sys
from urllib.parse import parse_qs, urlsplit

import websockets
from websockets.http11 import Response
from websockets.datastructures import Headers

# ── Configuration ──────────────────────────────────────────────

HOME = pathlib.Path.home()
SOCKET_PATH = os.environ.get(
    "ALPHACODE_API_SOCKET", str(HOME / ".alphacode" / "alphacode-api.sock")
)
TOKEN_FILE = HOME / ".alphacode" / "web_token"
STATIC_DIR = pathlib.Path(__file__).resolve().parent / "static"

BIND_HOST = (
    os.environ.get("BRIDGE_HOST")
    or os.environ.get("BRIDGE_BIND")
    or "127.0.0.1"
)
BIND_PORT = int(os.environ.get("BRIDGE_PORT", "8765"))

# ── Token ──────────────────────────────────────────────────────


def load_token():
    try:
        token = TOKEN_FILE.read_text().strip()
        if token:
            return token
    except FileNotFoundError:
        pass
    token = secrets.token_hex(32)
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    TOKEN_FILE.write_text(token)
    TOKEN_FILE.chmod(0o600)
    print(f"[bridge] Generated new token at {TOKEN_FILE}", flush=True)
    return token


VALID_TOKEN = load_token()


def _client_token(request):
    """Extract the bearer token from query string or Authorization header."""
    parts = urlsplit(request.path)
    token = parse_qs(parts.query).get("token", [None])[0]
    if not token:
        auth = request.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            token = auth[7:]
    return token


# ── HTTP request hook: static files + WS auth gate ─────────────


async def process_request(connection, request):
    parts = urlsplit(request.path)
    path = parts.path

    # WebSocket upgrade — gate on auth, then let websockets proceed.
    if path.startswith("/ws"):
        if not VALID_TOKEN or _client_token(request) != VALID_TOKEN:
            body = b'{"error":"unauthorized"}'
            return Response(
                401,
                "Unauthorized",
                Headers({"Content-Type": "application/json",
                         "Content-Length": str(len(body))}),
                body,
            )
        return None

    # Health probe (used by installers / uptime checks; no auth needed,
    # leaks nothing but liveness).
    if path == "/healthz":
        body = b'{"ok":true}'
        return Response(200, "OK", Headers({
            "Content-Type": "application/json",
            "Content-Length": str(len(body)),
        }), body)

    # Static UI. Match on the path only — never the query string, or a
    # token-bearing URL like /?token=x would 404. (This was a real bug.)
    if path in ("/", "/index.html"):
        index_path = STATIC_DIR / "index.html"
        if index_path.exists():
            content = index_path.read_bytes()
            return Response(200, "OK", Headers({
                "Content-Type": "text/html; charset=utf-8",
                "Content-Length": str(len(content)),
                "Cache-Control": "no-store",
            }), content)

    body = b"Not Found"
    return Response(404, "Not Found", Headers({
        "Content-Type": "text/plain",
        "Content-Length": str(len(body)),
    }), body)


# ── WebSocket relay ────────────────────────────────────────────


async def handle_websocket(websocket):
    # process_request already rejected unauthenticated upgrades, but keep
    # the check so the handler is safe if the hook is ever bypassed.
    if not VALID_TOKEN or _client_token(websocket.request) != VALID_TOKEN:
        await websocket.close(code=4001, reason="unauthorized")
        return

    try:
        unix_reader, unix_writer = await asyncio.open_unix_connection(SOCKET_PATH)
    except (FileNotFoundError, ConnectionRefusedError) as exc:
        print(f"[bridge] cannot reach harness socket: {exc}", flush=True)
        await websocket.close(code=1011, reason="alphacode daemon unavailable")
        return

    print("[bridge] client connected, relay started", flush=True)

    async def unix_to_ws():
        try:
            while True:
                line = await unix_reader.readline()
                if not line:
                    await websocket.close(code=1011, reason="daemon closed")
                    return
                text = line.decode(errors="replace").strip()
                if text:
                    await websocket.send(text)
        except (asyncio.CancelledError, websockets.ConnectionClosed):
            pass
        except Exception as exc:  # noqa: BLE001 - relay must not die on one client
            print(f"[bridge] unix->ws error: {exc}", flush=True)

    async def ws_to_unix():
        try:
            async for message in websocket:
                if not isinstance(message, str):
                    continue
                try:
                    json.loads(message)
                except json.JSONDecodeError:
                    # Bare text from a client becomes a chat message.
                    message = json.dumps({
                        "id": 0, "req": "send_message",
                        "session_id": "", "content": message,
                    })
                unix_writer.write((message + "\n").encode())
                await unix_writer.drain()
        except (asyncio.CancelledError, websockets.ConnectionClosed):
            pass
        except Exception as exc:  # noqa: BLE001
            print(f"[bridge] ws->unix error: {exc}", flush=True)

    t1 = asyncio.create_task(unix_to_ws())
    t2 = asyncio.create_task(ws_to_unix())
    try:
        done, pending = await asyncio.wait(
            {t1, t2}, return_when=asyncio.FIRST_COMPLETED
        )
        for task in pending:
            task.cancel()
            try:
                await task
            except BaseException:  # noqa: BLE001
                pass
    finally:
        unix_writer.close()
        try:
            await unix_writer.wait_closed()
        except Exception:  # noqa: BLE001
            pass
        print("[bridge] client disconnected, relay stopped", flush=True)


# ── Main ───────────────────────────────────────────────────────


async def main():
    scheme = "https" if os.environ.get("BRIDGE_TLS") else "http"
    ws_scheme = "wss" if scheme == "https" else "ws"
    print("[bridge] AlphaCode Web Bridge", flush=True)
    print(f"[bridge]   listen:  {scheme}://{BIND_HOST}:{BIND_PORT}", flush=True)
    print(f"[bridge]   socket:  {SOCKET_PATH}", flush=True)
    print(f"[bridge]   token:   {TOKEN_FILE} (mode 0600)", flush=True)
    print(f"[bridge]   ui:      {STATIC_DIR / 'index.html'}", flush=True)

    async with websockets.serve(
        handle_websocket,
        BIND_HOST,
        BIND_PORT,
        process_request=process_request,
        ping_interval=30,
        ping_timeout=120,
        max_size=10 * 1024 * 1024,
        close_timeout=10,
    ):
        print(f"[bridge] ready: {ws_scheme}://{BIND_HOST}:{BIND_PORT}/ws?token=<SECRET>",
              flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[bridge] shutting down", flush=True)
