#!/usr/bin/env python3
"""
AlphaCode Web Bridge - portable edition
WebSocket <-> harness-socket NDJSON relay with static file serving, plus a
legacy-socket ENGINE CONTROL PLANE for model/provider/session management.

Environment:
  BRIDGE_HOST    bind address (default 127.0.0.1; use 0.0.0.0 for direct-IP)
  BRIDGE_BIND    legacy alias for BRIDGE_HOST
  BRIDGE_PORT    TCP port (default 8765)
  ALPHACODE_API_SOCKET    path to the harness API unix socket
  ALPHACODE_LEGACY_SOCKET path to the legacy daemon unix socket
  ALPHACODE_WORKSPACE     default working directory advertised to clients

Auth: bearer token read from ~/.alphacode/web_token (auto-generated, mode 0600).
Accepted as ?token=<SECRET> query param or Authorization: Bearer ***

Engine control plane:
  The harness API (alphacode-api.sock) exposes sessions + streaming only.
  Model switching, the model catalog, reasoning effort and session renames live
  on the legacy daemon protocol (alphacode.sock). For every browser connection
  this bridge opens a dedicated legacy-socket connection subscribed to the same
  session, and translates a small set of `engine_*` browser requests onto it.
  Nothing is invented: every request below is a verified daemon wire frame.
"""

import asyncio
import json
import os
import pathlib
import re
import secrets
import sys
from urllib.parse import parse_qs, urlsplit

import websockets
from websockets.http11 import Response
from websockets.datastructures import Headers

# == Configuration =============================================================

HOME = pathlib.Path.home()
RUNTIME_DIR = pathlib.Path(
    os.environ.get("ALPHACODE_RUNTIME_DIR", str(HOME / ".alphacode"))
)
SOCKET_PATH = os.environ.get(
    "ALPHACODE_API_SOCKET", str(RUNTIME_DIR / "alphacode-api.sock")
)
LEGACY_SOCKET = os.environ.get(
    "ALPHACODE_LEGACY_SOCKET", str(RUNTIME_DIR / "alphacode.sock")
)
WORKSPACE = os.environ.get("ALPHACODE_WORKSPACE", str(HOME / "workspace"))
CONFIG_DIR = HOME / ".config" / "alphacode"
CONFIG_TOML = CONFIG_DIR / "config.toml"
TOKEN_FILE = RUNTIME_DIR / "web_token"
STATIC_DIR = pathlib.Path(__file__).resolve().parent / "static"

BIND_HOST = (
    os.environ.get("BRIDGE_HOST")
    or os.environ.get("BRIDGE_BIND")
    or "127.0.0.1"
)
BIND_PORT = int(os.environ.get("BRIDGE_PORT", "8765"))

ENGINE_TIMEOUT = 15.0  # seconds to wait for a legacy reply

# == Token =====================================================================


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


# == Engine environment inventory (read-only, never touches secrets) ===========


def _read_config_public():
    """Top-level scalar settings + provider section NAMES from config.toml.

    Secrets are never read: provider credentials live in provider-<name>.env
    files and are only ever reported by file name.
    """
    out = {"config_file": str(CONFIG_TOML), "settings": {}, "provider_sections": []}
    try:
        text = CONFIG_TOML.read_text()
    except OSError:
        return out
    section = ""
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^\[([^\]]+)\]$", line)
        if m:
            section = m.group(1)
            if section.startswith("providers."):
                out["provider_sections"].append(section.split(".", 1)[1])
            continue
        if "." in section:  # nested provider tables may carry keys - skip
            continue
        m = re.match(r"^([A-Za-z_][\w-]*)\s*=\s*(.+)$", line)
        if m:
            key, val = m.group(1), m.group(2).strip().strip('"')
            if "key" in key or "token" in key or "secret" in key:
                continue  # never surface credential material
            out["settings"][key] = val
    return out


def _provider_profiles():
    """Named provider profiles (file names only - contents hold API keys)."""
    names = []
    try:
        for p in sorted(CONFIG_DIR.glob("provider-*.env")):
            names.append(p.stem.removeprefix("provider-"))
    except OSError:
        pass
    return names


def engine_env_payload():
    cfg = _read_config_public()
    return {
        "workspace": WORKSPACE,
        "config": cfg["settings"],
        "config_file": cfg["config_file"],
        "provider_sections": cfg["provider_sections"],
        "provider_profiles": _provider_profiles(),
        "runtime_dir": str(RUNTIME_DIR),
    }



# == Legacy-socket engine control plane ========================================


class EngineControl:
    """One legacy-socket connection per browser client, session-following.

    Frames verified against alphacode v1.0.89 (upstream 2a61d47):
      subscribe {working_dir, target_session_id} -> ack, session, done
      get_model_catalog -> ack, history(id, provider_name, provider_model,
                          available_models[], available_model_routes[])
      set_model {model} -> ack, model_changed(id, model, provider_name)
      set_reasoning_effort {effort} -> ack, reasoning_effort_changed(id, effort)
      rename_session {title} -> ack, session_renamed(session_id, title), done
      state -> ack, state(id, session_id, message_count, is_processing)
    """

    def __init__(self, ws):
        self.ws = ws
        self.writer = None
        self._reader = None
        self._reader_task = None
        self.session_id = None
        self.next_id = 0
        self.pending = []  # list of dicts: {id, want, fut}

    async def _connect(self):
        # limit: the model-catalog reply is a single NDJSON line well past the
        # 64 KiB default (584+ models with route metadata) — allow 16 MiB.
        reader, writer = await asyncio.open_unix_connection(LEGACY_SOCKET, limit=16 * 1024 * 1024)
        self._reader = reader
        self.writer = writer
        self.session_id = None
        self._reader_task = asyncio.create_task(self._read_loop())

    def _send(self, payload):
        self.next_id += 1
        payload["id"] = self.next_id
        self.writer.write((json.dumps(payload) + "\n").encode())
        return self.next_id

    async def _read_loop(self):
        try:
            reader = self._reader
            while True:
                line = await reader.readline()
                if not line:
                    break
                try:
                    frame = json.loads(line.decode(errors="replace"))
                except json.JSONDecodeError:
                    continue
                self._dispatch(frame)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            print(f"[engine] legacy read error: {exc}", flush=True)
        finally:
            self._fail_pending("daemon connection closed")
            self.writer = None

    def _dispatch(self, frame):
        ftype = frame.get("type", "")
        fid = frame.get("id")

        # 1. Pending requests first: model_changed / session_renamed are BOTH
        #    replies to set_model / rename_session and unsolicited pushes, so
        #    reply matching must win over push mirroring.
        for entry in list(self.pending):
            if entry["fut"].done():
                continue
            if entry["want"] == "session":
                if ftype == "session":
                    entry["fut"].set_result(frame)
                    self.pending.remove(entry)
                    return
                continue
            if ftype == entry["want"] and (fid is None or fid == entry["id"]):
                entry["fut"].set_result(frame)
                self.pending.remove(entry)
                return
            if ftype == "error" and fid is not None and fid == entry["id"]:
                entry["fut"].set_exception(
                    RuntimeError(frame.get("message", "daemon error")))
                self.pending.remove(entry)
                return
            if ftype == "done" and fid is not None and fid == entry["id"]:
                # Completed without the wanted frame — surface what we got.
                entry["fut"].set_result(frame)
                self.pending.remove(entry)
                return

        # 2. Unsolicited pushes worth mirroring to the browser.
        if ftype == "model_changed" and not frame.get("error"):
            asyncio.ensure_future(self.ws.send(json.dumps({
                "v": 1, "ev": "model_info",
                "session_id": frame.get("session_id") or self.session_id or "",
                "provider": frame.get("provider_name"),
                "model": frame.get("model"),
            })))
            return
        if ftype == "available_models_updated":
            asyncio.ensure_future(self.ws.send(json.dumps({
                "v": 1, "ev": "model_info",
                "session_id": self.session_id or "",
                "provider": frame.get("provider_name"),
                "model": frame.get("provider_model"),
                "available_models": frame.get("available_models", []),
            })))
            return
        if ftype == "session_renamed":
            asyncio.ensure_future(self.ws.send(json.dumps({
                "v": 1, "ev": "session_renamed",
                "session_id": frame.get("session_id") or "",
                "title": frame.get("title"),
            })))
            return

    def _fail_pending(self, message):
        for entry in list(self.pending):
            if not entry["fut"].done():
                entry["fut"].set_exception(RuntimeError(message))
        self.pending.clear()

    async def _request(self, payload, want, timeout=ENGINE_TIMEOUT):
        if self.writer is None or self.writer.is_closing():
            await self._connect()
        fut = asyncio.get_event_loop().create_future()
        req_id = self._send(payload)
        self.pending.append({"id": req_id, "want": want, "fut": fut})
        try:
            return await asyncio.wait_for(fut, timeout)
        finally:
            self.pending[:] = [e for e in self.pending if e["fut"] is not fut]

    async def ensure_session(self, session_id):
        """(Re)connect and follow the harness connection's active session."""
        if self.writer is None or self.writer.is_closing():
            await self._connect()
        if session_id and self.session_id != session_id:
            frame = await self._request(
                {"type": "subscribe", "working_dir": WORKSPACE,
                 "target_session_id": session_id},
                "session",
            )
            got = frame.get("session_id", "")
            self.session_id = got or session_id

    async def close(self):
        if self.writer is not None:
            self._fail_pending("client disconnected")
            try:
                self.writer.close()
                await self.writer.wait_closed()
            except Exception:  # noqa: BLE001
                pass
            self.writer = None


def _api_error(api_id, message):
    return {"v": 1, "reply_to": api_id, "ev": "error", "code": "engine_error",
            "message": message}


async def handle_engine(control, data):
    """Serve an engine_* browser request; returns the reply frame."""
    api_id = data.get("id", 0)
    req = data.get("req", "")
    session = data.get("session_id") or control.session_id
    try:
        if req == "engine_env":
            return {"v": 1, "reply_to": api_id, "ev": "engine_env",
                    **engine_env_payload()}

        await control.ensure_session(session)
        if not control.session_id:
            return _api_error(api_id, "no active session to control")

        if req == "engine_catalog":
            f = await control._request({"type": "get_model_catalog"}, "history")
            return {"v": 1, "reply_to": api_id, "ev": "engine_catalog",
                    "session_id": control.session_id,
                    "provider_name": f.get("provider_name"),
                    "provider_model": f.get("provider_model"),
                    "available_models": f.get("available_models", []),
                    "available_model_routes": f.get("available_model_routes", []),
                    "compaction_mode": f.get("compaction_mode")}

        if req == "engine_set_model":
            model = str(data.get("model", "")).strip()
            if not model:
                return _api_error(api_id, "engine_set_model requires model")
            f = await control._request({"type": "set_model", "model": model},
                                       "model_changed")
            if f.get("error"):
                return _api_error(api_id, f"model switch failed: {f['error']}")
            return {"v": 1, "reply_to": api_id, "ev": "engine_model_changed",
                    "session_id": control.session_id,
                    "provider": f.get("provider_name"),
                    "model": f.get("model")}

        if req == "engine_set_effort":
            effort = str(data.get("effort", "")).strip()
            if not effort:
                return _api_error(api_id, "engine_set_effort requires effort")
            f = await control._request(
                {"type": "set_reasoning_effort", "effort": effort},
                "reasoning_effort_changed")
            if f.get("error"):
                return _api_error(api_id, f"effort change failed: {f['error']}")
            return {"v": 1, "reply_to": api_id, "ev": "engine_effort_changed",
                    "session_id": control.session_id,
                    "effort": f.get("effort") or effort}

        if req == "engine_rename":
            title = str(data.get("title", "")).strip()
            if not title:
                return _api_error(api_id, "engine_rename requires title")
            f = await control._request({"type": "rename_session", "title": title},
                                       "session_renamed")
            return {"v": 1, "reply_to": api_id, "ev": "engine_renamed",
                    "session_id": f.get("session_id") or control.session_id,
                    "title": f.get("title") or title}

        if req == "engine_state":
            f = await control._request({"type": "state"}, "state")
            return {"v": 1, "reply_to": api_id, "ev": "engine_state",
                    "session_id": control.session_id,
                    "message_count": f.get("message_count"),
                    "is_processing": f.get("is_processing")}

        return _api_error(api_id, f"unknown engine request: {req}")
    except asyncio.TimeoutError:
        return _api_error(api_id, f"engine timeout: {req} ({ENGINE_TIMEOUT:.0f}s)")
    except (FileNotFoundError, ConnectionRefusedError) as exc:
        return _api_error(api_id, f"legacy daemon socket unavailable: {exc}")
    except RuntimeError as exc:
        return _api_error(api_id, str(exc))
    except Exception as exc:  # noqa: BLE001
        return _api_error(api_id, f"engine control error: {exc}")



# == HTTP request hook: static files + WS auth gate ============================


async def process_request(connection, request):
    parts = urlsplit(request.path)
    path = parts.path

    # WebSocket upgrade - gate on auth, then let websockets proceed.
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

    # Static UI. Match on the path only - never the query string, or a
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


# == WebSocket relay ===========================================================


async def handle_websocket(websocket):
    # process_request already rejected unauthenticated upgrades, but keep
    # the check so the handler is safe if the hook is ever bypassed.
    if not VALID_TOKEN or _client_token(websocket.request) != VALID_TOKEN:
        await websocket.close(code=4001, reason="unauthorized")
        return

    try:
        unix_reader, unix_writer = await asyncio.open_unix_connection(
            SOCKET_PATH, limit=16 * 1024 * 1024
        )
    except (FileNotFoundError, ConnectionRefusedError) as exc:
        print(f"[bridge] cannot reach harness socket: {exc}", flush=True)
        await websocket.close(code=1011, reason="alphacode daemon unavailable")
        return

    engine = EngineControl(websocket)
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
                    # Keep the engine control plane following the harness
                    # connection's active session.
                    try:
                        frame = json.loads(text)
                        sid = frame.get("session_id") or ""
                        if sid and frame.get("ev") in (
                            "attached", "session_status", "model_info",
                            "turn_done",
                        ) and engine.session_id != sid:
                            engine.session_id = sid
                    except json.JSONDecodeError:
                        pass
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
                    data = json.loads(message)
                except json.JSONDecodeError:
                    # Bare text from a client becomes a chat message.
                    data = {
                        "id": 0, "req": "send_message",
                        "session_id": "", "content": message,
                    }
                req = data.get("req", "") if isinstance(data, dict) else ""
                if isinstance(data, dict) and req.startswith("engine_"):
                    reply = await handle_engine(engine, data)
                    try:
                        await websocket.send(json.dumps(reply))
                    except websockets.ConnectionClosed:
                        return
                    continue
                unix_writer.write((json.dumps(data) + "\n").encode())
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
        await engine.close()
        unix_writer.close()
        try:
            await unix_writer.wait_closed()
        except Exception:  # noqa: BLE001
            pass
        print("[bridge] client disconnected, relay stopped", flush=True)


# == Main ======================================================================


async def main():
    scheme = "https" if os.environ.get("BRIDGE_TLS") else "http"
    ws_scheme = "wss" if scheme == "https" else "ws"
    print("[bridge] AlphaCode Web Bridge", flush=True)
    print(f"[bridge]   listen:  {scheme}://{BIND_HOST}:{BIND_PORT}", flush=True)
    print(f"[bridge]   socket:  {SOCKET_PATH}", flush=True)
    print(f"[bridge]   engine:  {LEGACY_SOCKET}", flush=True)
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
