#!/usr/bin/env bash
# ============================================================================
#  deploy_alphacode.sh — portable, idempotent AlphaCode web-chat installer
#
#  Installs AlphaCode + a hardened WebSocket web UI on any Ubuntu/Debian host.
#  No domain and no Cloudflare account required.
#
#  Usage:
#    sudo bash deploy_alphacode.sh [OPTIONS]
#
#  Options:
#    --mode <loopback|direct-ip|quick-tunnel>  Access mode          (default: loopback)
#    --port <PORT>            Bridge TCP port                       (default: 8765)
#    --version <vX.Y.Z>       AlphaCode version to install          (default: v1.0.89)
#    --provider-name <NAME>   OpenAI-compatible profile name        (optional)
#    --base-url <URL>         OpenAI-compatible base URL            (optional)
#    --model <MODEL>          Model id for that profile             (optional)
#    --api-key <KEY>          API key for that profile              (or env ALPHACODE_API_KEY)
#    --force                  Reinstall the binary / overwrite configs
#    --uninstall              Remove services, files and user
#    -h|--help                Show this help
#
#  Modes:
#    loopback      Bind 127.0.0.1. Pair with a reverse proxy or named tunnel.
#    direct-ip     Bind 0.0.0.0 and open the port in UFW. Access over
#                  http://<SERVER_IP>:<PORT>/?token=<TOKEN>  (plain HTTP!)
#    quick-tunnel  Bind 127.0.0.1 and run a Cloudflare quick tunnel, giving an
#                  instant https://*.trycloudflare.com URL with no account.
#
#  Idempotent: safe to re-run. The web token and existing provider keys are
#  preserved unless --force is given.
# ============================================================================
set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
ALPHACODE_USER="${ALPHACODE_USER:-alphacode-runner}"
ALPHACODE_HOME="/home/${ALPHACODE_USER}"
WEB_DIR="${ALPHACODE_HOME}/web"
STATIC_DIR="${WEB_DIR}/static"
VENV_DIR="${WEB_DIR}/venv"
RUNTIME_DIR="${ALPHACODE_HOME}/.alphacode"
CONFIG_DIR="${ALPHACODE_HOME}/.config/alphacode"
CONFIG_TOML="${CONFIG_DIR}/config.toml"
TOKEN_FILE="${RUNTIME_DIR}/web_token"
WEB_CONF="/etc/alphacode-web.conf"
PROVIDER_ENV="/etc/alphacode-provider.conf"
HELPER="/usr/local/bin/alphacode-web"
TUNNEL_HELPER="/usr/local/bin/alphacode-tunnel"
VERIFY_HELPER="/usr/local/bin/alphacode-verify"

MODE="loopback"
PORT="8765"
VERSION="v1.0.89"
FORCE="no"
DO_UNINSTALL="no"
PROVIDER_NAME=""
BASE_URL=""
MODEL=""
API_KEY="${ALPHACODE_API_KEY:-}"

# ── Output helpers ──────────────────────────────────────────────────────────
C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
log()  { printf '%s\n' "${C_BLUE}==>${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GREEN}  ✓${C_RESET} $*"; }
warn() { printf '%s\n' "${C_YELLOW}  !${C_RESET} $*" >&2; }
die()  { printf '%s\n' "${C_RED}  ✗ $*${C_RESET}" >&2; exit 1; }

# Run a command as the unprivileged user. Prefer sudo, fall back to runuser
# (util-linux) then su, so the installer also works on minimal images without sudo.
as_user() {
  if command -v sudo >/dev/null 2>&1; then
    as_user "$@"
  elif command -v runuser >/dev/null 2>&1; then
    runuser -u "$ALPHACODE_USER" -- "$@"
  else
    su -s /bin/bash "$ALPHACODE_USER" -c "$(printf '%q ' "$@")"
  fi
}

# ── Usage ───────────────────────────────────────────────────────────────────
usage() { sed -n '3,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ── Argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)          MODE="${2:-}"; shift 2 ;;
    --port)          PORT="${2:-}"; shift 2 ;;
    --version)       VERSION="${2:-}"; shift 2 ;;
    --provider-name) PROVIDER_NAME="${2:-}"; shift 2 ;;
    --base-url)      BASE_URL="${2:-}"; shift 2 ;;
    --model)         MODEL="${2:-}"; shift 2 ;;
    --api-key)       API_KEY="${2:-}"; shift 2 ;;
    --force)         FORCE="yes"; shift ;;
    --uninstall)     DO_UNINSTALL="yes"; shift ;;
    -h|--help)       usage ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

case "$MODE" in
  loopback|direct-ip|quick-tunnel) ;;
  *) die "--mode must be loopback, direct-ip or quick-tunnel (got '$MODE')" ;;
esac
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be numeric"
[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo bash $0)"

# ── Uninstall ───────────────────────────────────────────────────────────────
if [[ "$DO_UNINSTALL" == "yes" ]]; then
  log "Uninstalling AlphaCode web deployment"
  systemctl disable --now alphacode-web.service alphacode-api-bridge.service \
      alphacode-daemon.service alphacode-tunnel.service 2>/dev/null || true
  rm -f /etc/systemd/system/alphacode-web.service \
        /etc/systemd/system/alphacode-api-bridge.service \
        /etc/systemd/system/alphacode-daemon.service \
        /etc/systemd/system/alphacode-tunnel.service \
        "$WEB_CONF" "$PROVIDER_ENV" "$HELPER" "$TUNNEL_HELPER" "$VERIFY_HELPER"
  ufw delete allow "${PORT}/tcp" >/dev/null 2>&1 || true
  systemctl daemon-reload
  if id -u "$ALPHACODE_USER" >/dev/null 2>&1; then
    userdel -r "$ALPHACODE_USER" 2>/dev/null || warn "could not remove user home"
  fi
  ok "uninstalled (cloudflared and apt packages left in place)"
  exit 0
fi

# ── Locate the running script (for the self-installed helper) ───────────────
SELF="$(readlink -f "$0")"

# ── 1. OS detection & dependencies ──────────────────────────────────────────
log "Checking OS and installing dependencies"
if ! command -v apt-get >/dev/null 2>&1; then
  die "this installer targets Debian/Ubuntu (apt-get not found)"
fi
export DEBIAN_FRONTEND=noninteractive
PKGS=(libxkbcommon0 python3 python3-venv curl tar xxd ca-certificates)
MISSING=()
for p in "${PKGS[@]}"; do
  dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  apt-get update -qq
  apt-get install -y -qq "${MISSING[@]}" >/dev/null
  ok "installed: ${MISSING[*]}"
else
  ok "all packages already present"
fi

if [[ "$MODE" == "quick-tunnel" ]] && ! command -v cloudflared >/dev/null 2>&1; then
  log "Installing cloudflared (for quick-tunnel mode)"
  arch="$(dpkg --print-architecture)"
  curl -fsSL -o /tmp/cloudflared.deb \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb"
  dpkg -i /tmp/cloudflared.deb >/dev/null
  rm -f /tmp/cloudflared.deb
  ok "cloudflared $(cloudflared --version 2>/dev/null | awk '{print $3}')"
fi

# ── 2. Unprivileged user ────────────────────────────────────────────────────
log "Provisioning unprivileged user '${ALPHACODE_USER}'"
if id -u "$ALPHACODE_USER" >/dev/null 2>&1; then
  ok "user already exists (uid $(id -u "$ALPHACODE_USER"))"
else
  useradd -r -m -d "$ALPHACODE_HOME" -s /bin/bash "$ALPHACODE_USER"
  ok "created uid $(id -u "$ALPHACODE_USER")"
fi

install -d -o "$ALPHACODE_USER" -g "$ALPHACODE_USER" -m 700 "$RUNTIME_DIR"
install -d -o "$ALPHACODE_USER" -g "$ALPHACODE_USER" -m 755 "$WEB_DIR" "$STATIC_DIR"
install -d -o "$ALPHACODE_USER" -g "$ALPHACODE_USER" -m 755 "${ALPHACODE_HOME}/workspace"
install -d -o "$ALPHACODE_USER" -g "$ALPHACODE_USER" -m 700 "$CONFIG_DIR"

# ── 3. AlphaCode binary ─────────────────────────────────────────────────────
BIN="${ALPHACODE_HOME}/.local/bin/alphacode"
log "Installing AlphaCode ${VERSION}"
INSTALLED_VER=""
[[ -x "$BIN" ]] && INSTALLED_VER="$("$BIN" --version 2>/dev/null || true)"
if [[ "$FORCE" == "no" && "$INSTALLED_VER" == *"${VERSION#v}"* ]]; then
  ok "already at $INSTALLED_VER"
else
  # Run from the user's home: the upstream installer uses cwd during extraction
  # and fails silently when it cannot traverse there.
  as_user bash -c "
    cd \"\$HOME\"
    curl -fsSL https://raw.githubusercontent.com/dragonked2/alphacode/main/scripts/install.sh \
      | bash -s -- --version '${VERSION}'
  " || die "AlphaCode install failed"
  [[ -x "$BIN" ]] || die "binary missing at $BIN after install"
  ok "installed $("$BIN" --version 2>/dev/null || echo "$VERSION")"
fi

# ── 4. Config (telemetry off) ───────────────────────────────────────────────
if [[ ! -f "$CONFIG_TOML" || "$FORCE" == "yes" ]]; then
  cat > "$CONFIG_TOML" <<'EOF'
# AlphaCode configuration (managed by deploy_alphacode.sh)
telemetry = "nothing"
reasoning_effort = "low"
max_child_agents = 8
EOF
  chown "$ALPHACODE_USER:$ALPHACODE_USER" "$CONFIG_TOML"
  chmod 600 "$CONFIG_TOML"
  ok "wrote $CONFIG_TOML (telemetry=nothing)"
else
  ok "config preserved at $CONFIG_TOML"
fi

# ── 5. Web files ────────────────────────────────────────────────────────────
log "Deploying web bridge and UI"
cat > "${WEB_DIR}/bridge.py" <<'BRIDGE_PY_EOF'
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
BRIDGE_PY_EOF

cat > "${STATIC_DIR}/index.html" <<'INDEX_HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
<meta name="color-scheme" content="dark light">
<title>AlphaCode</title>
<style>
/* ═══════════════════════════ Design tokens ═══════════════════════════ */
:root {
  --bg: #08090d;
  --bg-elev: rgba(22, 24, 32, .72);
  --bg-elev-solid: #14161e;
  --bg-input: #101218;
  --bg-hover: rgba(255,255,255,.045);
  --bg-active: rgba(255,255,255,.08);
  --border: rgba(255,255,255,.075);
  --border-strong: rgba(255,255,255,.13);
  --fg: #eceef4;
  --fg-dim: #9aa0ae;
  --fg-faint: #5d6270;
  --accent: #8b7cff;
  --accent-soft: rgba(139,124,255,.14);
  --green: #4ade80;
  --yellow: #fbbf24;
  --red: #f87171;
  --blue: #7cb8ff;
  --pink: #f472b6;
  --mono: ui-monospace, "SF Mono", "Cascadia Code", "JetBrains Mono", Menlo, Consolas, monospace;
  --sans: -apple-system, BlinkMacSystemFont, "Segoe UI Variable", "Segoe UI", Inter, Roboto, sans-serif;
  --r-sm: 8px; --r-md: 12px; --r-lg: 16px;
  --shadow: 0 8px 32px rgba(0,0,0,.45);
  --glow: 0 0 0 1px rgba(139,124,255,.22), 0 4px 24px rgba(139,124,255,.09);
  --sb-w: 264px;
}
@media (prefers-color-scheme: light) {
  :root {
    --bg: #f7f8fa; --bg-elev: rgba(255,255,255,.82); --bg-elev-solid: #fff;
    --bg-input: #fff; --bg-hover: rgba(0,0,0,.04); --bg-active: rgba(0,0,0,.08);
    --border: rgba(0,0,0,.09); --border-strong: rgba(0,0,0,.16);
    --fg: #17181c; --fg-dim: #5c6370; --fg-faint: #9aa0ae;
    --accent: #6d5ae0; --accent-soft: rgba(109,90,224,.1);
    --shadow: 0 8px 32px rgba(20,22,30,.12);
    --glow: 0 0 0 1px rgba(109,90,224,.2), 0 4px 24px rgba(109,90,224,.08);
  }
}
* { margin:0; padding:0; box-sizing:border-box; }
html, body { height:100%; }
body {
  font-family:var(--sans); background:var(--bg); color:var(--fg);
  overflow:hidden; -webkit-font-smoothing:antialiased; text-rendering:optimizeLegibility;
}
::selection { background:rgba(139,124,255,.35); }
button { font-family:inherit; cursor:pointer; border:none; background:none; color:inherit; }
textarea, input, select { font-family:inherit; color:inherit; }

/* Ambient glow — pure CSS, zero JS/CPU when idle */
body::before {
  content:""; position:fixed; inset:0; pointer-events:none; z-index:0;
  background:
    radial-gradient(60% 45% at 12% -8%, rgba(139,124,255,.09), transparent 60%),
    radial-gradient(50% 40% at 95% 8%, rgba(124,184,255,.055), transparent 60%),
    radial-gradient(45% 40% at 50% 108%, rgba(244,114,182,.045), transparent 60%);
}
@media (prefers-reduced-motion: reduce) { *, *::before, *::after { animation-duration:.01ms !important; transition-duration:.01ms !important; } }

/* ═══════════════════════════ Layout shell ═══════════════════════════ */
.app { display:flex; height:100dvh; position:relative; z-index:1; }

/* ── Sidebar ── */
.sidebar {
  width:var(--sb-w); flex-shrink:0; display:flex; flex-direction:column;
  background:var(--bg-elev); backdrop-filter:blur(24px); -webkit-backdrop-filter:blur(24px);
  border-right:1px solid var(--border); z-index:40;
  transition:transform .28s cubic-bezier(.32,.72,0,1);
}
.sb-head { padding:14px 14px 10px; display:flex; align-items:center; gap:10px; }
.logo-mark {
  width:30px; height:30px; border-radius:9px; flex-shrink:0;
  background:linear-gradient(135deg, var(--accent), #5a8bff);
  display:grid; place-items:center; font-size:15px; color:#fff;
  box-shadow:var(--glow);
}
.sb-title { font-size:14px; font-weight:650; letter-spacing:-.01em; }
.sb-sub { font-size:11px; color:var(--fg-faint); margin-top:1px; }
.sb-new {
  margin:8px 12px; padding:9px 12px; border-radius:var(--r-md);
  background:var(--accent-soft); color:var(--accent);
  border:1px solid rgba(139,124,255,.25);
  font-size:13px; font-weight:550; display:flex; align-items:center; gap:8px;
  transition:background .15s, transform .1s;
}
.sb-new:hover { background:rgba(139,124,255,.22); }
.sb-new:active { transform:scale(.98); }
.sb-list { flex:1; overflow-y:auto; padding:4px 8px 12px; }
.sb-list::-webkit-scrollbar { width:4px; }
.sb-list::-webkit-scrollbar-thumb { background:var(--border-strong); border-radius:2px; }
.sb-item {
  display:flex; align-items:center; gap:9px; padding:9px 10px; border-radius:var(--r-sm);
  cursor:pointer; transition:background .12s; margin-bottom:2px;
}
.sb-item:hover { background:var(--bg-hover); }
.sb-item.active { background:var(--accent-soft); }
.sb-dot { width:7px; height:7px; border-radius:50%; background:var(--fg-faint); flex-shrink:0; }
.sb-item.active .sb-dot { background:var(--accent); box-shadow:0 0 8px var(--accent); }
.sb-name { font-size:13px; flex:1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.sb-st { font-size:10px; color:var(--fg-faint); text-transform:uppercase; letter-spacing:.04em; }
.sb-foot { padding:10px 14px; border-top:1px solid var(--border); font-size:11px; color:var(--fg-faint); }

/* ── Chat column ── */
.chat { flex:1; display:flex; flex-direction:column; min-width:0; position:relative; }

.chat-head {
  display:flex; align-items:center; gap:10px; padding:10px 16px; flex-shrink:0;
  background:var(--bg-elev); backdrop-filter:blur(24px); -webkit-backdrop-filter:blur(24px);
  border-bottom:1px solid var(--border); z-index:30; height:52px;
}
.hamburger { display:none; width:34px; height:34px; border-radius:var(--r-sm); align-items:center; justify-content:center; font-size:17px; color:var(--fg-dim); }
.hamburger:hover { background:var(--bg-hover); }
.pill {
  display:inline-flex; align-items:center; gap:7px; padding:4px 11px;
  border-radius:999px; font-size:12px; font-weight:500;
  background:var(--bg-input); border:1px solid var(--border); color:var(--fg-dim);
  transition:border-color .2s, color .2s; white-space:nowrap;
}
.pill .dot { width:7px; height:7px; border-radius:50%; background:var(--red); transition:background .25s; }
.pill.on .dot { background:var(--green); box-shadow:0 0 7px rgba(74,222,128,.7); }
.pill.busy .dot { background:var(--yellow); animation:pulse 1.1s ease-in-out infinite; }
.pill.model { font-family:var(--mono); font-size:11px; gap:6px; }
.pill.model .dot { background:var(--pink); box-shadow:0 0 7px rgba(244,114,182,.55); }
@keyframes pulse { 50% { opacity:.35; } }
.ctx-wrap { display:flex; align-items:center; gap:6px; }
.ctx-track { width:74px; height:5px; border-radius:3px; background:var(--bg-input); overflow:hidden; border:1px solid var(--border); }
.ctx-fill { height:100%; width:0%; background:var(--green); border-radius:3px; transition:width .4s, background .4s; }
.ctx-label { font-size:10px; font-family:var(--mono); color:var(--fg-faint); min-width:34px; }
.spacer { flex:1; }
.icon-btn {
  width:34px; height:34px; border-radius:var(--r-sm); display:grid; place-items:center;
  color:var(--fg-dim); font-size:15px; transition:background .15s;
}
.icon-btn:hover { background:var(--bg-hover); }

/* ── Transcript ── */
.scroll { flex:1; overflow-y:auto; overscroll-behavior:contain; scroll-behavior:smooth; }
.scroll::-webkit-scrollbar { width:9px; }
.scroll::-webkit-scrollbar-thumb { background:var(--border-strong); border-radius:5px; border:2px solid transparent; background-clip:content-box; }
.transcript { max-width:860px; margin:0 auto; padding:24px 20px 30px; display:flex; flex-direction:column; gap:22px; }

.msg { display:flex; gap:12px; animation:rise .3s cubic-bezier(.2,.8,.2,1) both; }
@keyframes rise { from { opacity:0; transform:translateY(9px); } }
.msg.user { flex-direction:row-reverse; }
.avatar {
  width:30px; height:30px; border-radius:9px; flex-shrink:0; display:grid; place-items:center;
  font-size:12px; font-weight:650; margin-top:2px;
}
.msg.user .avatar { background:linear-gradient(135deg,#2a2d3a,#1c1e28); color:var(--blue); border:1px solid var(--border-strong); }
.msg.assistant .avatar { background:linear-gradient(135deg, var(--accent), #5a8bff); color:#fff; box-shadow:var(--glow); }
.content { min-width:0; max-width:100%; flex:1; display:flex; flex-direction:column; gap:9px; }
.msg.user .content { align-items:flex-end; }
.byline { font-size:11px; color:var(--fg-faint); letter-spacing:.02em; }

/* user bubble */
.ububble {
  background:linear-gradient(135deg, var(--accent-soft), rgba(90,139,255,.1));
  border:1px solid rgba(139,124,255,.28); color:var(--fg);
  padding:11px 15px; border-radius:var(--r-lg) var(--r-lg) var(--r-sm) var(--r-lg);
  max-width:min(78%, 640px); font-size:14.5px; line-height:1.55; word-wrap:break-word;
  white-space:pre-wrap;
}

/* assistant bubble */
.abubble {
  background:var(--bg-elev); border:1px solid var(--border);
  backdrop-filter:blur(14px); -webkit-backdrop-filter:blur(14px);
  border-radius:var(--r-sm) var(--r-lg) var(--r-lg) var(--r-sm);
  padding:14px 18px; font-size:14.5px; line-height:1.66; word-wrap:break-word; overflow-wrap:break-word;
}
.abubble > *:first-child { margin-top:0; } .abubble > *:last-child { margin-bottom:0; }
.abubble p { margin:.55em 0; }
.abubble h1,.abubble h2,.abubble h3,.abubble h4 { margin:1em 0 .45em; line-height:1.3; letter-spacing:-.015em; }
.abubble h1 { font-size:1.35em; } .abubble h2 { font-size:1.2em; } .abubble h3 { font-size:1.07em; }
.abubble ul,.abubble ol { margin:.55em 0; padding-left:1.5em; }
.abubble li { margin:.28em 0; }
.abubble blockquote {
  border-left:3px solid var(--accent); background:var(--accent-soft);
  padding:.5em .9em; border-radius:0 var(--r-sm) var(--r-sm) 0; margin:.7em 0; color:var(--fg-dim);
}
.abubble hr { border:none; border-top:1px solid var(--border); margin:1em 0; }
.abubble a { color:var(--blue); text-decoration:none; border-bottom:1px solid rgba(124,184,255,.35); }
.abubble a:hover { border-bottom-color:var(--blue); }
.abubble strong { font-weight:640; }
.abubble table { border-collapse:collapse; margin:.7em 0; font-size:.92em; width:100%; }
.abubble th, .abubble td { border:1px solid var(--border); padding:7px 11px; text-align:left; }
.abubble th { background:var(--bg-hover); font-weight:600; }
.abubble code:not(pre code) {
  font-family:var(--mono); font-size:.87em;
  background:var(--bg-hover); border:1px solid var(--border);
  padding:1.5px 5.5px; border-radius:5px; color:var(--pink);
}
.caret { display:inline-block; width:7px; height:1.05em; background:var(--accent); vertical-align:text-bottom; border-radius:1.5px; animation:blink 1s steps(2) infinite; margin-left:1px; }
@keyframes blink { 50% { opacity:0; } }

/* ── Code blocks ── */
.codeblock { margin:.75em 0; border-radius:var(--r-md); overflow:hidden; border:1px solid var(--border-strong); background:#0b0d13; direction:ltr; }
.cb-bar {
  display:flex; align-items:center; gap:8px; padding:7px 12px;
  background:rgba(255,255,255,.035); border-bottom:1px solid var(--border);
}
.cb-dots { display:flex; gap:5px; }
.cb-dots i { width:10px; height:10px; border-radius:50%; }
.cb-dots i:nth-child(1) { background:#ff5f57; } .cb-dots i:nth-child(2) { background:#febc2e; } .cb-dots i:nth-child(3) { background:#28c840; }
.cb-lang { font-family:var(--mono); font-size:10.5px; color:var(--fg-faint); text-transform:lowercase; letter-spacing:.05em; }
.cb-copy {
  margin-left:auto; font-size:11px; color:var(--fg-dim); padding:3px 9px;
  border-radius:6px; border:1px solid var(--border); background:rgba(255,255,255,.03);
  transition:all .15s; display:flex; align-items:center; gap:5px;
}
.cb-copy:hover { color:var(--fg); background:rgba(255,255,255,.07); }
.cb-copy.ok { color:var(--green); border-color:rgba(74,222,128,.4); }
.codeblock pre {
  margin:0; padding:12px 14px; overflow-x:auto;
  font-family:var(--mono); font-size:12.8px; line-height:1.62; color:#dfe3ec;
  tab-size:4;
}
.codeblock pre::-webkit-scrollbar { height:7px; }
.codeblock pre::-webkit-scrollbar-thumb { background:var(--border-strong); border-radius:4px; }
/* syntax palette */
.tk-kw { color:#c792ea; } .tk-str { color:#a5d6a7; } .tk-num { color:#f7a76c; }
.tk-com { color:#5d6478; font-style:italic; } .tk-fn { color:#82aaff; }
.tk-var { color:#f78c6c; } .tk-bi { color:#4dd0e1; } .tk-op { color:#89ddff; }
@media (prefers-color-scheme: light) {
  .codeblock { background:#fbfbfd; }
  .tk-kw { color:#8250df; } .tk-str { color:#0a7d33; } .tk-num { color:#b3541e; }
  .tk-com { color:#8b949e; } .tk-fn { color:#0550ae; } .tk-var { color:#953800; }
  .tk-bi { color:#0969da; } .tk-op { color:#57606a; }
  .codeblock pre { color:#24292f; }
}

/* ── Thinking block ── */
.thinking {
  border:1px solid var(--border); border-radius:var(--r-md);
  background:var(--bg-input); overflow:hidden; margin-bottom:2px;
  transition:border-color .2s;
}
.thinking.live { border-color:rgba(139,124,255,.35); box-shadow:0 0 18px rgba(139,124,255,.07); }
.th-head {
  display:flex; align-items:center; gap:9px; padding:9px 13px; cursor:pointer;
  user-select:none; font-size:12.5px;
}
.th-head:hover { background:var(--bg-hover); }
.th-spark { color:var(--accent); font-size:13px; }
.th-label { font-weight:550; color:var(--fg-dim); }
.thinking.live .th-label { background:linear-gradient(90deg, var(--fg-dim) 25%, var(--accent) 50%, var(--fg-dim) 75%); background-size:200% 100%; -webkit-background-clip:text; background-clip:text; -webkit-text-fill-color:transparent; animation:shimmer 1.7s linear infinite; }
@keyframes shimmer { from { background-position:200% 0; } to { background-position:-200% 0; } }
.th-time { font-family:var(--mono); font-size:10.5px; color:var(--fg-faint); }
.th-chev { margin-left:auto; color:var(--fg-faint); font-size:10px; transition:transform .22s; }
.thinking.open .th-chev { transform:rotate(180deg); }
.th-body { display:none; padding:2px 14px 11px; font-size:12.8px; line-height:1.6; color:var(--fg-dim); white-space:pre-wrap; font-style:italic; max-height:280px; overflow-y:auto; }
.thinking.open .th-body { display:block; }
.thinking.open .th-body::-webkit-scrollbar { width:4px; }
.thinking.open .th-body::-webkit-scrollbar-thumb { background:var(--border-strong); border-radius:2px; }

/* ── Tool cards ── */
.tool {
  border:1px solid var(--border); border-radius:var(--r-md);
  background:#0b0d13; overflow:hidden; font-family:var(--mono); font-size:12.5px;
}
@media (prefers-color-scheme: light) { .tool { background:#f6f7f9; } }
.tool.running { border-color:rgba(251,191,36,.32); }
.tool.error { border-color:rgba(248,113,113,.38); }
.tool.ok { border-color:rgba(74,222,128,.22); }
.t-head { display:flex; align-items:center; gap:9px; padding:8px 13px; cursor:pointer; user-select:none; }
.t-head:hover { background:rgba(255,255,255,.03); }
.t-prompt { color:var(--accent); font-weight:700; }
.t-name { color:var(--blue); font-weight:600; }
.t-arg { color:var(--fg-dim); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; max-width:46%; }
.t-badge {
  margin-left:auto; display:inline-flex; align-items:center; gap:5px;
  font-size:10px; font-weight:600; letter-spacing:.05em; text-transform:uppercase;
  padding:2.5px 8px; border-radius:999px; flex-shrink:0;
}
.t-badge.running { color:var(--yellow); background:rgba(251,191,36,.12); }
.t-badge.ok { color:var(--green); background:rgba(74,222,128,.1); }
.t-badge.error { color:var(--red); background:rgba(248,113,113,.12); }
.t-badge .spin { width:9px; height:9px; border:1.5px solid rgba(251,191,36,.3); border-top-color:var(--yellow); border-radius:50%; animation:spin .7s linear infinite; }
@keyframes spin { to { transform:rotate(360deg); } }
.t-chev { color:var(--fg-faint); font-size:9px; transition:transform .2s; }
.tool.open .t-chev { transform:rotate(180deg); }
.t-body { display:none; border-top:1px solid var(--border); }
.tool.open .t-body { display:block; }
.t-args, .t-out { padding:9px 14px; white-space:pre-wrap; word-break:break-word; overflow-y:auto; }
.t-args { color:var(--fg-dim); max-height:150px; }
.t-out { color:#b7bdcc; max-height:320px; font-size:12px; line-height:1.55; }
@media (prefers-color-scheme: light) { .t-out { color:#41485a; } }
.t-out::-webkit-scrollbar, .t-args::-webkit-scrollbar { width:4px; }
.t-out::-webkit-scrollbar-thumb, .t-args::-webkit-scrollbar-thumb { background:var(--border-strong); border-radius:2px; }
.t-sec { font-size:9px; letter-spacing:.1em; text-transform:uppercase; color:var(--fg-faint); padding:7px 14px 0; }

/* ── Permission banner ── */
.perm {
  display:flex; align-items:center; gap:12px; flex-wrap:wrap;
  border:1px solid rgba(251,191,36,.4); border-radius:var(--r-md);
  background:linear-gradient(135deg, rgba(251,191,36,.08), transparent);
  padding:11px 15px; animation:rise .25s ease both;
}
.perm-txt { flex:1; min-width:200px; font-size:13px; line-height:1.45; }
.perm-txt b { color:var(--yellow); }
.perm-txt .desc { color:var(--fg-dim); font-size:12px; display:block; margin-top:2px; }
.pbtn { padding:7px 17px; border-radius:var(--r-sm); font-size:12.5px; font-weight:600; transition:all .14s; }
.pbtn.allow { background:var(--green); color:#052e12; }
.pbtn.allow:hover { filter:brightness(1.12); }
.pbtn.deny { background:transparent; border:1px solid var(--border-strong); color:var(--fg-dim); }
.pbtn.deny:hover { color:var(--red); border-color:var(--red); }

/* ── Separator / system ── */
.turn-sep { display:flex; align-items:center; gap:12px; color:var(--fg-faint); font-size:10px; }
.turn-sep::before, .turn-sep::after { content:""; flex:1; border-top:1px solid var(--border); }
.sysmsg { text-align:center; font-size:12px; color:var(--red); padding:8px; border:1px solid rgba(248,113,113,.3); border-radius:var(--r-md); background:rgba(248,113,113,.06); }

/* ── Empty state ── */
.hero { flex:1; display:flex; flex-direction:column; align-items:center; justify-content:center; gap:20px; padding:40px 20px; text-align:center; }
.hero-mark { width:64px; height:64px; border-radius:19px; background:linear-gradient(135deg, var(--accent), #5a8bff); display:grid; place-items:center; font-size:30px; box-shadow:var(--glow), 0 12px 40px rgba(139,124,255,.2); animation:float 5s ease-in-out infinite; }
@keyframes float { 50% { transform:translateY(-7px); } }
.hero h1 { font-size:24px; font-weight:680; letter-spacing:-.03em; }
.hero h1 span { background:linear-gradient(90deg, var(--accent), var(--blue)); -webkit-background-clip:text; background-clip:text; -webkit-text-fill-color:transparent; }
.hero p { color:var(--fg-dim); font-size:14px; max-width:420px; }
.chips { display:flex; flex-wrap:wrap; gap:9px; justify-content:center; max-width:560px; }
.chip {
  padding:8px 14px; border-radius:999px; font-size:12.5px;
  background:var(--bg-elev); border:1px solid var(--border); color:var(--fg-dim);
  transition:all .16s; backdrop-filter:blur(10px); -webkit-backdrop-filter:blur(10px);
}
.chip:hover { color:var(--fg); border-color:rgba(139,124,255,.4); background:var(--accent-soft); transform:translateY(-1px); }

/* ── Composer ── */
.composer-wrap { padding:0 20px 14px; }
.composer {
  max-width:860px; margin:0 auto; position:relative;
  background:var(--bg-elev); border:1px solid var(--border-strong);
  border-radius:var(--r-lg); backdrop-filter:blur(20px); -webkit-backdrop-filter:blur(20px);
  box-shadow:var(--shadow); transition:border-color .2s, box-shadow .2s;
  padding:4px 6px 4px 14px; display:flex; align-items:flex-end; gap:8px;
}
.composer:focus-within { border-color:rgba(139,124,255,.5); box-shadow:var(--glow), var(--shadow); }
.composer textarea {
  flex:1; background:none; border:none; outline:none; resize:none;
  font-size:14.5px; line-height:1.5; padding:10px 0; max-height:190px; color:var(--fg);
}
.composer textarea::placeholder { color:var(--fg-faint); }
.send {
  width:36px; height:36px; border-radius:11px; background:linear-gradient(135deg, var(--accent), #5a8bff);
  color:#fff; display:grid; place-items:center; font-size:15px; flex-shrink:0;
  transition:transform .12s, opacity .15s; box-shadow:0 2px 12px rgba(139,124,255,.35);
}
.send:hover { transform:translateY(-1px) scale(1.04); }
.send:active { transform:scale(.95); }
.send:disabled { opacity:.4; cursor:default; transform:none; }
.stop { width:36px; height:36px; border-radius:11px; background:var(--bg-active); color:var(--red); display:none; place-items:center; font-size:13px; flex-shrink:0; border:1px solid rgba(248,113,113,.3); }
.composer.busy .stop { display:grid; }
.composer.busy .send { display:none; }
.composer-hint { max-width:860px; margin:7px auto 0; text-align:center; font-size:10.5px; color:var(--fg-faint); }
.composer-hint kbd { font-family:var(--mono); background:var(--bg-hover); border:1px solid var(--border); border-radius:4px; padding:0 4px; font-size:10px; }

/* ── Slash palette ── */
.palette {
  position:absolute; bottom:100%; left:0; right:0; margin-bottom:8px;
  background:var(--bg-elev-solid); border:1px solid var(--border-strong);
  border-radius:var(--r-md); box-shadow:var(--shadow); overflow:hidden;
  display:none; z-index:50; max-height:290px; overflow-y:auto;
}
.palette.show { display:block; animation:rise .16s ease both; }
.pal-item {
  display:flex; align-items:center; gap:11px; padding:9px 14px; cursor:pointer;
  transition:background .1s; font-size:13px;
}
.pal-item.sel, .pal-item:hover { background:var(--accent-soft); }
.pal-cmd { font-family:var(--mono); font-size:12.5px; color:var(--accent); font-weight:600; min-width:128px; }
.pal-desc { color:var(--fg-dim); font-size:12px; }
.pal-empty { padding:14px; text-align:center; color:var(--fg-faint); font-size:12.5px; }

/* ── Scroll-to-bottom ── */
.jump {
  position:absolute; bottom:110px; left:50%; transform:translateX(-50%) translateY(14px);
  width:34px; height:34px; border-radius:50%; z-index:25;
  background:var(--bg-elev-solid); border:1px solid var(--border-strong);
  color:var(--fg-dim); display:grid; place-items:center; font-size:14px;
  opacity:0; pointer-events:none; transition:all .22s; box-shadow:var(--shadow);
}
.jump.show { opacity:1; pointer-events:auto; transform:translateX(-50%) translateY(0); }
.jump:hover { color:var(--fg); border-color:var(--accent); }

/* ── Mobile drawer ── */
.backdrop { position:fixed; inset:0; background:rgba(0,0,0,.55); z-index:39; opacity:0; pointer-events:none; transition:opacity .25s; backdrop-filter:blur(2px); -webkit-backdrop-filter:blur(2px); }
.backdrop.show { opacity:1; pointer-events:auto; }
@media (max-width: 860px) {
  .sidebar { position:fixed; inset:0 auto 0 0; transform:translateX(-102%); box-shadow:var(--shadow); }
  .sidebar.show { transform:translateX(0); }
  .hamburger { display:grid; }
  .pill.model { display:none; }
  .ctx-label { display:none; }
  .transcript { padding:16px 12px 24px; gap:18px; }
  .composer-wrap { padding:0 10px 12px; }
  .msg.user .content { align-items:flex-end; }
  .ububble { max-width:88%; }
  .content { gap:7px; }
  .hero h1 { font-size:20px; }
  .jump { bottom:104px; }
}
@media (min-width:861px) { .backdrop { display:none; } }

/* ── Engine parity: model switcher, effort menu, inspector ── */
.pill.clickable { cursor:pointer; }
.pill.clickable:hover { color:var(--fg); border-color:rgba(139,124,255,.45); }
.ctx-tokens { font-size:10px; font-family:var(--mono); color:var(--fg-faint); white-space:nowrap; }
.overlay { position:fixed; inset:0; background:rgba(0,0,0,.55); z-index:60; display:none;
  align-items:center; justify-content:center; backdrop-filter:blur(3px); -webkit-backdrop-filter:blur(3px); }
.overlay.show { display:flex; animation:fade .18s ease both; }
@keyframes fade { from { opacity:0; } }
.sheet {
  width:min(560px, 94vw); max-height:78vh; display:flex; flex-direction:column;
  background:var(--bg-elev-solid); border:1px solid var(--border-strong);
  border-radius:var(--r-lg); box-shadow:var(--shadow); overflow:hidden;
  animation:rise .22s cubic-bezier(.2,.8,.2,1) both;
}
.sheet-head { display:flex; align-items:center; gap:10px; padding:14px 18px; border-bottom:1px solid var(--border); }
.sheet-title { font-size:14px; font-weight:650; }
.sheet-sub { font-size:11px; color:var(--fg-faint); font-family:var(--mono); margin-top:2px; }
.sheet-x { margin-left:auto; width:28px; height:28px; border-radius:8px; color:var(--fg-dim); display:grid; place-items:center; flex-shrink:0; }
.sheet-x:hover { background:var(--bg-hover); color:var(--fg); }
.sheet-search { margin:12px 16px 8px; padding:9px 12px; border-radius:var(--r-sm);
  background:var(--bg-input); border:1px solid var(--border); color:var(--fg); font-size:13px; outline:none; width:calc(100% - 32px); }
.sheet-search:focus { border-color:rgba(139,124,255,.5); }
.sheet-body { flex:1; overflow-y:auto; padding:4px 8px 12px; }
.sheet-body::-webkit-scrollbar { width:6px; }
.sheet-body::-webkit-scrollbar-thumb { background:var(--border-strong); border-radius:3px; }
.ms-group { font-size:10px; letter-spacing:.08em; text-transform:uppercase; color:var(--fg-faint); padding:10px 10px 5px; }
.ms-item { display:flex; align-items:center; gap:10px; padding:8px 11px; border-radius:var(--r-sm); cursor:pointer; transition:background .1s; }
.ms-item:hover { background:var(--bg-hover); }
.ms-item.cur { background:var(--accent-soft); }
.ms-item.dis { opacity:.45; cursor:default; }
.ms-name { font-family:var(--mono); font-size:12.5px; color:var(--fg); word-break:break-all; }
.ms-prov { font-size:10.5px; color:var(--fg-faint); }
.ms-meta { margin-left:auto; text-align:right; font-size:10px; color:var(--fg-faint); font-family:var(--mono); flex-shrink:0; }
.ms-item.cur .ms-meta { color:var(--accent); }
.ms-empty { padding:26px; text-align:center; color:var(--fg-faint); font-size:12.5px; }
.effmenu { position:fixed; z-index:55; min-width:180px;
  background:var(--bg-elev-solid); border:1px solid var(--border-strong);
  border-radius:var(--r-md); box-shadow:var(--shadow); padding:5px; display:none; }
.effmenu.show { display:block; animation:rise .16s ease both; }
.eff-item { display:flex; align-items:center; justify-content:space-between; gap:12px; padding:8px 12px; border-radius:var(--r-sm); cursor:pointer; font-size:12.5px; }
.eff-item:hover { background:var(--bg-hover); }
.eff-item.on { color:var(--accent); font-weight:600; }
.ins-grid { display:grid; grid-template-columns:112px 1fr; gap:7px 12px; font-size:12.5px; padding:4px 12px; }
.ins-k { color:var(--fg-faint); }
.ins-v { font-family:var(--mono); font-size:11.5px; word-break:break-all; color:var(--fg-dim); }
.ins-v b { color:var(--fg); font-weight:600; }
.ins-sec { font-size:10px; letter-spacing:.08em; text-transform:uppercase; color:var(--fg-faint); padding:12px 14px 4px; }
.t-dur { font-family:var(--mono); font-size:9.5px; color:var(--fg-faint); }
.sb-ren { opacity:0; width:22px; height:22px; border-radius:6px; color:var(--fg-faint); font-size:11px; display:grid; place-items:center; flex-shrink:0; }
.sb-item:hover .sb-ren { opacity:1; }
.sb-ren:hover { background:var(--bg-active); color:var(--fg); }
</style>
</head>
<body>

<div class="app">
  <!-- ══ Sidebar ══ -->
  <aside class="sidebar" id="sidebar">
    <div class="sb-head">
      <div class="logo-mark">◈</div>
      <div>
        <div class="sb-title">AlphaCode</div>
        <div class="sb-sub">terminal agent · web ui</div>
      </div>
    </div>
    <button class="sb-new" id="newBtn"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" style="vertical-align:-1px"><path d="M12 5v14M5 12h14"/></svg>&ensp;New session</button>
    <div class="sb-list" id="sessionList"></div>
    <div class="sb-foot" id="sbFoot">connecting…</div>
  </aside>
  <div class="backdrop" id="backdrop"></div>

  <!-- ══ Chat ══ -->
  <div class="chat">
    <header class="chat-head">
      <button class="hamburger" id="menuBtn">☰</button>
      <span class="pill" id="statusPill"><span class="dot"></span><span id="statusText">connecting</span></span>
      <span class="pill model clickable" id="modelPill" title="Switch model / provider"><span class="dot"></span><span id="modelText">—</span></span>
      <span class="pill model clickable" id="effortPill" title="Reasoning effort"><span id="effortText">effort</span><span style="font-size:9px">▾</span></span>
      <div class="spacer"></div>
      <div class="ctx-wrap" id="ctxWrap" title="Context usage">
        <span class="ctx-tokens" id="tokLabel" title="tokens"></span>
        <div class="ctx-track"><div class="ctx-fill" id="ctxFill"></div></div>
        <span class="ctx-label" id="ctxLabel">0%</span>
      </div>
      <button class="icon-btn" id="inspBtn" title="Engine inspector">⌘</button>
      <button class="icon-btn" id="newBtnTop" title="New session"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" style="vertical-align:-1px"><path d="M12 5v14M5 12h14"/></svg></button>
    </header>

    <div class="scroll" id="scroll">
      <div class="transcript" id="transcript">
        <div class="hero" id="hero">
          <div class="hero-mark">◈</div>
          <h1>Your terminal agent, <span>on the web</span></h1>
          <p>Describe what you want built, fixed, or tested. AlphaCode plans, edits, runs and verifies — you review the diff.</p>
          <div class="chips">
            <button class="chip" data-fill="/skills">/skills&ensp;· what can it do?</button>
            <button class="chip" data-fill="/swarm &quot;plan a refactor&quot;">/swarm&ensp;· parallel agents</button>
            <button class="chip" data-fill="Explain this project in simple terms.">explain this project</button>
            <button class="chip" data-fill="/doctor">/doctor&ensp;· health check</button>
          </div>
        </div>
      </div>
    </div>

    <button class="jump" id="jumpBtn" title="Jump to latest">↓</button>

    <div class="composer-wrap">
      <div class="composer" id="composer">
        <div class="palette" id="palette"></div>
        <textarea id="input" rows="1" placeholder="Message AlphaCode…  type / for commands"></textarea>
        <button class="send" id="sendBtn" title="Send">➤</button>
        <button class="stop" id="stopBtn" title="Stop generation">■</button>
      </div>
      <div class="composer-hint"><kbd>Enter</kbd> send · <kbd>Shift</kbd>+<kbd>Enter</kbd> newline · <kbd>/</kbd> commands</div>
    </div>
  </div>
</div>

<!-- ══ Model switcher ══ -->
<div class="overlay" id="msOverlay">
  <div class="sheet" role="dialog" aria-label="Model switcher">
    <div class="sheet-head">
      <div style="min-width:0">
        <div class="sheet-title">Switch model</div>
        <div class="sheet-sub" id="msCur">—</div>
      </div>
      <button class="sheet-x" id="msClose">✕</button>
    </div>
    <input class="sheet-search" id="msSearch" placeholder="Filter by model or provider..." autocomplete="off">
    <div class="sheet-body" id="msList"></div>
  </div>
</div>

<!-- ══ Engine inspector ══ -->
<div class="overlay" id="insOverlay">
  <div class="sheet" role="dialog" aria-label="Engine inspector">
    <div class="sheet-head">
      <div style="min-width:0">
        <div class="sheet-title">Engine inspector</div>
        <div class="sheet-sub" id="insSub">—</div>
      </div>
      <button class="sheet-x" id="insClose">✕</button>
    </div>
    <div class="sheet-body" id="insBody"></div>
  </div>
</div>

<script>
"use strict";
/* ═══════════════════════════ State ═══════════════════════════ */
let ws = null, nextId = 100, sessionId = null, sessions = [];
let busy = false, reconnectDelay = 1200;
let curBubble = null, curBuf = "", curRenderTimer = null;
let thinking = null, thinkStart = 0, thinkTimer = null, thinkBuf = "";
let curTool = null, toolBuf = "";
let userSent = false, autoSwitched = false, pendingResumeId = null, resumeAttempted = false;
const LS_KEY = "alphacode:lastSession";
const lsGet = k => { try { return localStorage.getItem(k); } catch { return null; } };
const lsSet = (k, v) => { try { localStorage.setItem(k, v); } catch {} };
let pendingToolInputs = {};
/* engine-parity state */
let catalog = null;                  // last engine_catalog payload
let engineProvider = null, engineModel = null, effort = null, harnessVersion = "";
let tok = { input: 0, output: 0, cache: 0 };
const toolsSeen = new Map();         // tool name -> {calls, lastMs, lastStatus}
const pendingEngine = new Map();     // request id -> resolve fn
const localTitles = new Map();       // session_id -> title (daemon list carries none)
const $ = id => document.getElementById(id);
const el = (t, c) => { const n = document.createElement(t); if (c) n.className = c; return n; };

const TOKEN = new URLSearchParams(location.search).get("token") || "";
const WS_PROTO = location.protocol === "https:" ? "wss:" : "ws:";
const WS_URL = `${WS_PROTO}//${location.host}/ws${TOKEN ? "?token=" + TOKEN : ""}`;

const SLASH = [
  ["/swarm", "Split a task across parallel AI agents"],
  ["/skills", "Browse built-in skill playbooks"],
  ["/model", "Switch model / provider"],
  ["/provider", "Switch or inspect providers"],
  ["/plan", "Show or manage the execution plan"],
  ["/diff", "Review the current diff"],
  ["/memory", "Inspect / manage project memory"],
  ["/sessions", "List and manage sessions"],
  ["/compact", "Compact the conversation context"],
  ["/clear", "Clear conversation history"],
  ["/doctor", "Diagnose setup and environment"],
  ["/help", "Show every command"],
];

/* ═══════════════════════════ Syntax highlighting ═══════════════════════════ */
const KW = {
  bash: "if then else elif fi for while until do done case esac function select time coproc in return exit local readonly declare export unset shift eval trap set",
  python: "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case None True False",
  javascript: "as async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield null undefined true false",
  typescript: "abstract any as async await boolean break case catch class const constructor continue declare default delete do else enum export extends finally for from function get if implements import in infer instanceof interface is keyof let module namespace never new number of private protected public readonly return set static string super switch symbol this throw try type typeof undefined union unique var void while with yield null true false",
  rust: "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while",
  go: "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false",
  json: "true false null",
  sql: "select from where insert into values update set delete create table drop alter join left right inner outer on group by order limit offset union all as and or not null primary key foreign references index distinct having exists between like in",
  c: "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while NULL true false",
};
const LANG_ALIAS = { sh:"bash", shell:"bash", zsh:"bash", console:"bash", py:"python", python3:"python",
  js:"javascript", jsx:"javascript", mjs:"javascript", ts:"typescript", tsx:"typescript",
  rs:"rust", golang:"go", gsh:"bash", html:"html", css:"css", yml:"yaml" };

const RX = {
  comment: { bash:'#[^\\n]*', python:'#[^\\n]*', rust:'//[^\\n]*|/\\*[\\s\\S]*?\\*/', go:'//[^\\n]*|/\\*[\\s\\S]*?\\*/',
             javascript:'//[^\\n]*|/\\*[\\s\\S]*?\\*/', typescript:'//[^\\n]*|/\\*[\\s\\S]*?\\*/',
             c:'//[^\\n]*|/\\*[\\s\\S]*?\\*/', sql:'--[^\\n]*', json:null, default:'#[^\\n]*|//[^\\n]*|/\\*[\\s\\S]*?\\*/' },
  string:  { bash:'"[^"\\n]*"'+"|'[^'\\n]*'", python:'[rbf]{0,2}"""[\\s\\S]*?"""'+"|[rbf]{0,2}'''[\\s\\S]*?'''"+'|[rbfu]{0,2}"[^"\\n]*"'+ "|[rbfu]{0,2}'[^'\\n]*'",
             default:'"(?:[^"\\\\\\n]|\\\\.)*"'+"|'(?:[^'\\\\\\n]|\\\\.)*'"+'|`(?:[^`\\\\]|\\\\.)*`' },
  number:  { default:'\\b0[xX][0-9a-fA-F_]+\\b|\\b\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b' },
  variable:{ bash:'\\$\\{?[^}"\\s]+\\}?|\\$\\([^)]*\\)', default:'(?<![\\w$])[$@][A-Za-z_]\\w*' },
};
function langOf(l) { l = (l||"").toLowerCase().trim().split(/[\s;{]/)[0]; return LANG_ALIAS[l] || (KW[l] ? l : "default"); }
function escHtml(s) { return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;"); }

function highlight(code, lang) {
  const L = langOf(lang);
  const cm = RX.comment[L] !== undefined ? RX.comment[L] : RX.comment.default;
  const parts = [];
  if (cm) parts.push(`(?<c>${cm})`);
  parts.push(`(?<s>${RX.string[L] || RX.string.default})`);
  parts.push(`(?<n>${RX.number.default})`);
  const kw = KW[L];
  if (kw) parts.push(`(?<k>\\b(?:${kw.trim().split(/\s+/).join("|")})\\b)`);
  parts.push(`(?<f>[A-Za-z_$][\\w$]*(?=\\s*\\())`);
  const vr = RX.variable[L] || RX.variable.default;
  if (vr) parts.push(`(?<v>${vr})`);
  let re;
  try { re = new RegExp(parts.join("|"), "g"); } catch { return escHtml(code); }
  let out = "", last = 0, m;
  while ((m = re.exec(code))) {
    if (m.index > last) out += escHtml(code.slice(last, m.index));
    const kind = m.groups.c ? "com" : m.groups.s ? "str" : m.groups.n ? "num" : m.groups.k ? "kw" : m.groups.f ? "fn" : "var";
    out += `<span class="tk-${kind}">${escHtml(m[0])}</span>`;
    last = m.index + m[0].length;
    if (m[0].length === 0) re.lastIndex++;
  }
  out += escHtml(code.slice(last));
  return out;
}

/* ═══════════════════════════ Markdown renderer ═══════════════════════════ */
function inlineMd(s) {
  s = escHtml(s);
  s = s.replace(/`([^`]+)`/g, (m, c) => `<code>${c}</code>`);
  s = s.replace(/\*\*\*([^*]+)\*\*\*/g, "<strong><em>$1</em></strong>");
  s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/(^|[\s(])\*([^*\n]+)\*/g, "$1<em>$2</em>");
  s = s.replace(/~~([^~]+)~~/g, "<del>$1</del>");
  s = s.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
  s = s.replace(/&lt;(https?:\/\/[^&\s]+)&gt;/g, '<a href="$1" target="_blank" rel="noopener noreferrer">$1</a>');
  return s;
}

function renderMarkdown(src) {
  const root = el("div");
  const lines = src.split("\n");
  let i = 0;
  const flushPara = buf => { if (buf.length) { const p = el("p"); p.innerHTML = inlineMd(buf.join(" ")); root.appendChild(p); } };

  while (i < lines.length) {
    const line = lines[i];

    // fenced code (streaming-safe: unterminated fence still renders)
    const fence = line.match(/^\s*```[\s]*([\w+#.-]*)\s*$/);
    if (fence) {
      const lang = fence[1] || "";
      const body = [];
      i++;
      let closed = false;
      while (i < lines.length) {
        if (/^\s*```/.test(lines[i])) { closed = true; i++; break; }
        body.push(lines[i]); i++;
      }
      root.appendChild(makeCodeBlock(body.join("\n").replace(/\n$/, ""), lang));
      continue;
    }

    // heading
    const h = line.match(/^(#{1,4})\s+(.*)/);
    if (h) { const n = el("h" + h[1].length); n.innerHTML = inlineMd(h[2]); root.appendChild(n); i++; continue; }

    // hr
    if (/^\s*([-*_])\s*\1\s*\1[\s\-*_]*$/.test(line)) { root.appendChild(el("hr")); i++; continue; }

    // blockquote
    if (/^\s*>\s?/.test(line)) {
      const q = el("blockquote"), buf = [];
      while (i < lines.length && /^\s*>\s?/.test(lines[i])) { buf.push(lines[i].replace(/^\s*>\s?/, "")); i++; }
      q.innerHTML = inlineMd(buf.join(" ")); root.appendChild(q); continue;
    }

    // table: |a|b| row then |---|---| separator
    if (/^\s*\|.+\|\s*$/.test(line) && i + 1 < lines.length && /^\s*\|[\s:|-]+\|\s*$/.test(lines[i+1])) {
      const head = line.split("|").slice(1, -1).map(s => s.trim());
      i += 2;
      const rows = [];
      while (i < lines.length && /^\s*\|.+\|\s*$/.test(lines[i])) { rows.push(lines[i].split("|").slice(1, -1).map(s => s.trim())); i++; }
      const t = el("table"), tr = el("tr");
      head.forEach(c => { const th = el("th"); th.innerHTML = inlineMd(c); tr.appendChild(th); });
      t.appendChild(tr);
      rows.forEach(r => { const trr = el("tr"); r.forEach(c => { const td = el("td"); td.innerHTML = inlineMd(c); trr.appendChild(td); }); t.appendChild(trr); });
      root.appendChild(t); continue;
    }

    // lists
    const ulM = line.match(/^\s*[-*+]\s+/), olM = line.match(/^\s*\d+[.)]\s+/);
    if (ulM || olM) {
      const list = el(ulM ? "ul" : "ol"), re = ulM ? /^\s*[-*+]\s+/ : /^\s*\d+[.)]\s+/;
      while (i < lines.length) {
        if (re.test(lines[i])) {
          const li = el("li");
          let text = lines[i].replace(re, "");
          i++;
          // continuation lines (indented, non-list)
          while (i < lines.length && /^\s{2,}\S/.test(lines[i]) && !/^\s*([-*+]|\d+[.)])\s+/.test(lines[i])) { text += " " + lines[i].trim(); i++; }
          li.innerHTML = inlineMd(text); list.appendChild(li);
        } else if (/^\s*$/.test(lines[i]) && i + 1 < lines.length && re.test(lines[i+1])) { i++; }
        else break;
      }
      root.appendChild(list); continue;
    }

    // blank
    if (/^\s*$/.test(line)) { i++; continue; }

    // paragraph
    const buf = [];
    while (i < lines.length && !/^\s*$/.test(lines[i]) && !/^\s*(```|#{1,4}\s|>|[-*+]\s|\d+[.)]\s|\|)/.test(lines[i])) { buf.push(lines[i].trim()); i++; }
    if (!buf.length) { buf.push(lines[i].trim()); i++; }
    flushPara(buf);
  }
  return root;
}

function makeCodeBlock(code, lang) {
  const box = el("div", "codeblock");
  const bar = el("div", "cb-bar");
  bar.innerHTML = `<div class="cb-dots"><i></i><i></i><i></i></div><span class="cb-lang">${escHtml(lang || "text")}</span>`;
  const copy = el("button", "cb-copy");
  copy.innerHTML = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg><span style="margin-left:4px">copy</span>';
  copy.onclick = () => {
    (navigator.clipboard ? navigator.clipboard.writeText(code) : Promise.reject()).then(
      () => { copy.classList.add("ok"); copy.innerHTML = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><polyline points="20 6 9 17 4 12"/></svg><span style="margin-left:4px">copied</span>'; setTimeout(() => { copy.classList.remove("ok"); copy.innerHTML = "⧉ copy"; }, 1400); },
      () => {});
  };
  bar.appendChild(copy);
  const pre = el("pre");
  pre.innerHTML = highlight(code, lang);
  box.appendChild(bar); box.appendChild(pre);
  return box;
}

/* ═══════════════════════════ Transcript helpers ═══════════════════════════ */
const transcript = $("transcript"), scroll = $("scroll");
let stick = true;

function nearBottom() { return scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 90; }
scroll.addEventListener("scroll", () => {
  stick = nearBottom();
  $("jumpBtn").classList.toggle("show", !stick);
});
function toBottom() { if (stick) scroll.scrollTop = scroll.scrollHeight; }

function hideHero() { const h = $("hero"); if (h) h.remove(); }
function addUserQuiet(text) { const d = addUser(text); return d; }
function addUser(text) {
  hideHero();
  const m = el("div", "msg user");
  m.innerHTML = `<div class="avatar">Y</div><div class="content"><div class="byline">you</div><div class="ububble"></div></div>`;
  m.querySelector(".ububble").textContent = text;
  transcript.appendChild(m); toBottom();
}
function addSystem(text) {
  const d = el("div", "sysmsg"); d.textContent = text;
  transcript.appendChild(d); toBottom();
}
function newAssistant() {
  hideHero();
  const m = el("div", "msg assistant");
  const c = el("div", "content");
  c.appendChild(Object.assign(el("div", "byline"), { textContent: "alphacode" }));
  const bub = el("div", "abubble");
  c.appendChild(bub);
  m.appendChild(el("div", "avatar")); m.appendChild(c);
  transcript.appendChild(m); toBottom();
  return { msg: m, bub, content: c };
}
function renderBuf() {
  if (!curBubble) return;
  curBubble.bub.innerHTML = "";
  if (curBuf) curBubble.bub.appendChild(renderMarkdown(curBuf));
  if (busy) { const sp = el("span", "caret"); curBubble.bub.appendChild(sp); }
  toBottom();
}
function scheduleRender() {
  if (curRenderTimer) return;
  curRenderTimer = setTimeout(() => { curRenderTimer = null; renderBuf(); }, 140);
}

/* ═══════════════════════════ Thinking block ═══════════════════════════ */
function startThinking() {
  if (thinking) return;
  const host = curBubble ? curBubble.content : null;
  if (!host) return;
  const box = el("div", "thinking open live");
  box.innerHTML = `<div class="th-head"><span class="th-spark">✦</span><span class="th-label">Thinking</span><span class="th-time">0.0s</span><span class="th-chev">▾</span></div><div class="th-body"></div>`;
  box.querySelector(".th-head").onclick = () => box.classList.toggle("open");
  host.insertBefore(box, host.querySelector(".abubble"));
  thinking = { box, body: box.querySelector(".th-body") };
  thinkBuf = ""; thinkStart = Date.now();
  thinkTimer = setInterval(() => {
    const t = ((Date.now() - thinkStart) / 1000).toFixed(1) + "s";
    const n = box.querySelector(".th-time"); if (n) n.textContent = t;
  }, 100);
  toBottom();
}
function feedThinking(text) { if (!thinking) startThinking(); if (!thinking) return; thinkBuf += text; thinking.body.textContent = thinkBuf; thinking.body.scrollTop = thinking.body.scrollHeight; toBottom(); }
function stopThinking(done) {
  if (!thinking) return;
  clearInterval(thinkTimer);
  const secs = ((Date.now() - thinkStart) / 1000).toFixed(1);
  thinking.box.classList.remove("live", "open");
  thinking.box.querySelector(".th-label").textContent = done ? "Thought process" : "Thinking";
  thinking.box.querySelector(".th-time").textContent = secs;
  thinking = null;
}

/* ═══════════════════════════ Tool cards ═══════════════════════════ */
function startTool(callId, name) {
  stopThinking(true);                       // thinking ends once work begins
  if (curBubble && curBuf) { renderBuf(); curBubble.bub.querySelectorAll(".caret").forEach(n => n.remove()); curBubble = null; curBuf = ""; }
  if (!curBubble) curBubble = newAssistant();
  const host = curBubble.content;
  const card = el("div", "tool running");
  card.innerHTML =
    `<div class="t-head"><span class="t-prompt">❯</span><span class="t-name">${escHtml(name)}</span>` +
    `<span class="t-arg"></span><span class="t-badge running"><span class="spin"></span>running</span><span class="t-chev">▾</span></div>` +
    `<div class="t-body"><div class="t-sec">input</div><div class="t-args"></div><div class="t-sec">output</div><div class="t-out"></div></div>`;
  card.querySelector(".t-head").onclick = () => card.classList.toggle("open");
  host.appendChild(card);
  curTool = { card, name, callId, args: "", out: "", t0: performance.now() };
  const rec = toolsSeen.get(name) || { calls: 0 };
  rec.calls++; rec.lastStatus = "running"; rec.lastMs = null;
  toolsSeen.set(name, rec);
  toBottom();
}
function feedToolInput(text) {
  if (!curTool) return;
  curTool.args += text;
  const a = curTool.card.querySelector(".t-args");
  a.textContent = curTool.args; a.scrollTop = a.scrollHeight;
  const arg = curTool.card.querySelector(".t-arg");
  arg.textContent = curTool.args.replace(/\s+/g, " ").slice(0, 60);
}
function endTool(status, output) {
  if (!curTool) return;
  const { card, name, t0 } = curTool;
  const dur = t0 ? (performance.now() - t0) / 1000 : null;
  const rec = toolsSeen.get(name);
  if (rec) { rec.lastStatus = status; rec.lastMs = dur != null ? dur * 1000 : null; }
  card.classList.remove("running");
  if (status === "error") card.classList.add("error");
  else if (status === "ok") card.classList.add("ok");
  const badge = card.querySelector(".t-badge");
  badge.className = "t-badge " + status;
  badge.innerHTML = (status === "error" ? "✕ error" : status === "ok" ? "✓ done" : "· ended")
    + (dur != null ? ` <span class="t-dur">${dur.toFixed(1)}s</span>` : "");
  if (output !== undefined && output !== null && output !== "") {
    const o = card.querySelector(".t-out");
    o.textContent = String(output);
    if (String(output).length > 0) card.classList.add("open");
  }
  if (curTool.args) { /* args already shown */ }
  curTool = null;
  toBottom();
}

/* ═══════════════════════════ Permission ═══════════════════════════ */
function addPermission(req) {
  stopThinking(true);
  const host = curBubble ? curBubble.content : transcript;
  const p = el("div", "perm");
  p.innerHTML = `<div class="perm-txt"><b>⚠ ${escHtml(req.tool_name || "tool")} wants to run</b>` +
    `<span class="desc">${escHtml(req.description || "")}</span></div>` +
    `<button class="pbtn allow">Allow</button><button class="pbtn deny">Deny</button>`;
  const reply = decision => send({ id: nextId++, req: "permission_response", session_id: sessionId, request_id: req.request_id, decision });
  p.querySelector(".allow").onclick = () => { reply("allow"); p.remove(); };
  p.querySelector(".deny").onclick = () => { reply("deny"); p.remove(); };
  (host === transcript ? transcript : host).appendChild(p);
  toBottom();
}

/* ═══════════════════════════ Sessions ═══════════════════════════ */
function renderSessions() {
  const list = $("sessionList"); list.innerHTML = "";
  if (!sessions.length) {
    list.innerHTML = `<div style="padding:14px 10px;font-size:12px;color:var(--fg-faint);text-align:center">no sessions yet</div>`;
    return;
  }
  sessions.forEach(s => {
    const it = el("div", "sb-item" + (s.session_id === sessionId ? " active" : ""));
    const title = localTitles.get(s.session_id) || (s.title && s.title.trim()) || s.session_id.slice(0, 14) || "session";
    it.innerHTML = `<span class="sb-dot"></span><span class="sb-name"></span><span class="sb-st">${escHtml(s.status || "")}</span><button class="sb-ren" title="Rename">✎</button>`;
    it.querySelector(".sb-name").textContent = title;
    it.onclick = () => { attach(s.session_id); closeDrawer(); };
    it.querySelector(".sb-ren").onclick = e => { e.stopPropagation(); renameSession(title.replace(/^archived · /, "")); };
    list.appendChild(it);
  });
}
function openDrawer() { $("sidebar").classList.add("show"); $("backdrop").classList.add("show"); }
function closeDrawer() { $("sidebar").classList.remove("show"); $("backdrop").classList.remove("show"); }
$("menuBtn").onclick = openDrawer;
$("backdrop").onclick = closeDrawer;
$("newBtn").onclick = () => { createSession(); closeDrawer(); };
$("newBtnTop").onclick = () => createSession();

/* ═══════════════════════════ Status / header ═══════════════════════════ */
function setStatus(state, text) {
  const pill = $("statusPill");
  pill.className = "pill" + (state === "on" ? " on" : state === "busy" ? " busy" : "");
  $("statusText").textContent = text;
  $("sbFoot").textContent = state === "on" ? "connected" : state === "busy" ? "working…" : "offline";
}
function setModel(p, m) {
  const t = [p, m].filter(Boolean).join(" · ");
  $("modelText").textContent = t || "—";
  $("modelPill").title = t;
}
function setContext(frac) {
  if (frac == null) return;
  const pct = Math.max(0, Math.min(100, Math.round(frac * 100)));
  const f = $("ctxFill");
  f.style.width = pct + "%";
  f.style.background = pct > 88 ? "var(--red)" : pct > 68 ? "var(--yellow)" : "var(--green)";
  $("ctxLabel").textContent = pct + "%";
}

/* ═══════════════════════════ Engine control plane ═══════════════════════════ */
const fmtTok = n => { n = Number(n) || 0; return n >= 1e6 ? (n/1e6).toFixed(1) + "M" : n >= 1e3 ? (n/1e3).toFixed(1) + "k" : String(n); };
function renderTok() {
  const total = (tok.input || 0) + (tok.output || 0) + (tok.cache || 0);
  $("tokLabel").textContent = total ? `${fmtTok(tok.input || 0)}↑ ${fmtTok((tok.output || 0) + (tok.cache || 0))}↓` : "";
  $("tokLabel").title = `tokens · in ${tok.input || 0} · out ${tok.output || 0} · cache ${tok.cache || 0}`;
}
function sendEngine(req, extra) {
  return new Promise(resolve => {
    const id = nextId++;
    pendingEngine.set(id, resolve);
    send(Object.assign({ id, req, session_id: sessionId }, extra || {}));
    setTimeout(() => { if (pendingEngine.has(id)) { pendingEngine.delete(id); resolve(null); } }, 20000);
  });
}

/* ── reasoning-effort menu ── */
const EFFORTS = ["none", "low", "medium", "high"];
function renderEffortMenu() {
  const m = $("effMenu");
  m.innerHTML = "";
  EFFORTS.forEach(e => {
    const it = el("div", "eff-item" + (effort === e ? " on" : ""));
    it.innerHTML = `<span>${e}</span>${effort === e ? "<span>✓</span>" : ""}`;
    it.onclick = async () => {
      m.classList.remove("show");
      if (effort === e) return;
      const r = await sendEngine("engine_set_effort", { effort: e });
      if (r && r.ev === "engine_effort_changed") {
        effort = r.effort; $("effortText").textContent = "effort · " + effort;
      } else addSystem("effort change failed" + (r && r.message ? ": " + r.message : ""));
    };
    m.appendChild(it);
  });
}
$("effortPill").onclick = e => {
  e.stopPropagation();
  const m = $("effMenu");
  if (m.classList.contains("show")) { m.classList.remove("show"); return; }
  renderEffortMenu();
  const r = $("effortPill").getBoundingClientRect();
  m.style.left = Math.max(8, r.left - 10) + "px";
  m.style.top = (r.bottom + 8) + "px";
  m.classList.add("show");
};
document.addEventListener("click", e => {
  const m = $("effMenu");
  if (m.classList.contains("show") && !m.contains(e.target)) m.classList.remove("show");
});

/* ── model switcher ── */
const fmtPrice = r => {
  const c = r.cheapness || {};
  if (c.monthly_price_micros && c.billing_kind === "subscription")
    return "$" + (c.monthly_price_micros / 1e6).toFixed(0) + "/mo est";
  if (c.estimated_reference_cost_micros)
    return "$" + (c.estimated_reference_cost_micros / 1e6).toFixed(4) + "/ref";
  return "";
};
function renderModelList(q) {
  const box = $("msList");
  if (!catalog || catalog.ev !== "engine_catalog") { box.innerHTML = `<div class="ms-empty">catalog unavailable</div>`; return; }
  const needle = (q || "").toLowerCase();
  const seen = new Set(); const avail = [], dis = [];
  for (const r of (catalog.available_model_routes || [])) {
    const key = r.model + "@" + (r.provider || "") + "@" + (r.api_method || "");
    if (seen.has(key)) continue; seen.add(key);
    if (needle && !(r.model.toLowerCase().includes(needle) || (r.provider || "").toLowerCase().includes(needle))) continue;
    (r.available ? avail : dis).push(r);
  }
  const row = r => {
    const cur = catalog.provider_model === r.model;
    const it = el("div", "ms-item" + (cur ? " cur" : "") + (r.available ? "" : " dis"));
    it.innerHTML = `<div style="min-width:0"><div class="ms-name"></div><div class="ms-prov"></div></div><div class="ms-meta"></div>`;
    it.querySelector(".ms-name").textContent = r.model;
    it.querySelector(".ms-prov").textContent = [r.provider, r.api_method].filter(Boolean).join(" · ");
    it.querySelector(".ms-meta").textContent = (r.available ? fmtPrice(r) : (r.detail || "unavailable")) + (cur ? "  · active" : "");
    if (r.available && !cur) it.onclick = async () => {
      it.innerHTML = `<div class="ms-name" style="color:var(--accent)">switching…</div>`;
      const resp = await sendEngine("engine_set_model", { model: r.model });
      if (resp && resp.ev === "engine_model_changed") {
        engineProvider = resp.provider; engineModel = resp.model;
        if (catalog) { catalog.provider_name = resp.provider; catalog.provider_model = resp.model; }
        setModel(engineProvider, engineModel);
        closeMs();
      } else {
        addSystem("model switch failed" + (resp && resp.message ? ": " + resp.message : ""));
        renderModelList($("msSearch").value);
      }
    };
    return it;
  };
  box.innerHTML = "";
  const sec = (title, list) => {
    if (!list.length) return;
    const g = el("div", "ms-group"); g.textContent = title; box.appendChild(g);
    list.slice(0, 900).forEach(r => box.appendChild(row(r)));
  };
  sec("available", avail);
  sec("needs credentials / unavailable", dis);
  if (!avail.length && !dis.length) box.innerHTML = `<div class="ms-empty">no models match</div>`;
  }

  /* ── effort menu lives outside the header (fixed positioning) ── */
  if (!document.getElementById("effMenu")) {
  const em = el("div", "effmenu"); em.id = "effMenu"; document.body.appendChild(em);
  }
  async function openMs() {
  $("msOverlay").classList.add("show");
  $("msSearch").value = ""; $("msSearch").focus();
  $("msCur").textContent = [engineProvider, engineModel].filter(Boolean).join(" · ") || "loading…";
  renderModelList("");
  catalog = await sendEngine("engine_catalog");
  if (catalog && catalog.ev === "engine_catalog") {
    if (catalog.provider_name) engineProvider = catalog.provider_name;
    if (catalog.provider_model) engineModel = catalog.provider_model;
    setModel(engineProvider, engineModel);
    const nAvail = (catalog.available_model_routes || []).filter(r => r.available).length;
    $("msCur").textContent = [engineProvider, engineModel].filter(Boolean).join(" · ") + `  ·  ${nAvail} available`;
  } else {
    $("msCur").textContent = "catalog unavailable" + (catalog && catalog.message ? " — " + catalog.message : "");
  }
  renderModelList("");
}
function closeMs() { $("msOverlay").classList.remove("show"); }
$("modelPill").onclick = openMs;
$("msClose").onclick = closeMs;
$("msOverlay").addEventListener("click", e => { if (e.target === $("msOverlay")) closeMs(); });
$("msSearch").addEventListener("input", () => renderModelList($("msSearch").value));

/* ── engine inspector ── */
function renameSession(current) {
  const t = prompt("Session title:", current || "");
  if (!t) return;
  sendEngine("engine_rename", { title: t }).then(r => {
    if (r && r.ev === "engine_renamed") {
      if (r.session_id) localTitles.set(r.session_id, r.title);
      renderSessions();
      send({ id: nextId++, req: "list_sessions" });
    }
    else addSystem("rename failed" + (r && r.message ? ": " + r.message : ""));
  });
}
async function openInspector() {
  $("insOverlay").classList.add("show");
  const body = $("insBody");
  body.innerHTML = `<div class="ms-empty">reading engine state…</div>`;
  $("insSub").textContent = [engineProvider, engineModel].filter(Boolean).join(" · ") || "—";
  const [state, env] = await Promise.all([sendEngine("engine_state"), sendEngine("engine_env")]);
  const cur = sessions.find(s => s.session_id === sessionId) || {};
  const rows = pairs => pairs.map(([k, v]) => (v == null || v === "") ? "" :
    `<div class="ins-k">${escHtml(k)}</div><div class="ins-v">${escHtml(String(v))}</div>`).join("");
  let html = "";
  html += `<div class="ins-sec">session</div><div class="ins-grid">` + rows([
    ["id", sessionId],
    ["title", cur.title || ""],
    ["status", cur.status || "—"],
    ["working dir", cur.working_dir || "—"],
    ["transcript", cur.transcript_bytes != null ? (cur.transcript_bytes / 1024).toFixed(1) + " KiB" : "—"],
    ["messages", state && state.ev === "engine_state" ? state.message_count : "—"],
  ]) + `</div>`;
  html += `<div class="ins-sec">engine</div><div class="ins-grid">` + rows([
    ["provider", engineProvider || "—"],
    ["model", engineModel || "—"],
    ["effort", effort || (env && env.config && env.config.reasoning_effort) || "—"],
    ["harness", harnessVersion || "—"],
    ["tokens", `↑${fmtTok(tok.input)} ↓${fmtTok(tok.output)} · cache ${fmtTok(tok.cache)}`],
    ["catalog", catalog && catalog.ev === "engine_catalog"
      ? `${(catalog.available_model_routes || []).length} routes · ${(catalog.available_model_routes || []).filter(r => r.available).length} available`
      : "not loaded"],
  ]) + `</div>`;
  if (env && env.ev === "engine_env") {
    html += `<div class="ins-sec">environment</div><div class="ins-grid">` + rows([
      ["workspace", env.workspace],
      ["default model", (env.config || {}).default_model || "—"],
      ["telemetry", (env.config || {}).telemetry || "—"],
      ["max agents", (env.config || {}).max_child_agents || "—"],
      ["provider profiles", (env.provider_profiles || []).join(", ") || "—"],
      ["config sections", (env.provider_sections || []).join(", ") || "—"],
    ]) + `</div>`;
  }
  const tools = [...toolsSeen.entries()];
  html += `<div class="ins-sec">tools observed this session</div>`;
  if (!tools.length) html += `<div class="ms-empty">no tool calls yet</div>`;
  else html += `<div class="ins-grid">` + tools.map(([n, t]) =>
    `<div class="ins-k">${escHtml(n)}</div><div class="ins-v">${t.calls} call${t.calls > 1 ? "s" : ""} · last ${t.lastStatus || "?"}${t.lastMs ? " · " + (t.lastMs / 1000).toFixed(1) + "s" : ""}</div>`).join("") + `</div>`;
  html += `<div class="ins-sec">session actions</div>
    <div style="display:flex; gap:8px; padding:6px 12px 16px; flex-wrap:wrap">
      <button class="pbtn" id="insRename" style="border:1px solid var(--border-strong); color:var(--fg)">✎ Rename</button>
      <button class="pbtn" id="insArchive" style="border:1px solid var(--border-strong); color:var(--fg)">📦 Archive</button>
      <button class="pbtn" id="insModel" style="border:1px solid var(--border-strong); color:var(--fg)">⇄ Model</button>
      <button class="pbtn" id="insFresh" style="border:1px solid var(--border-strong); color:var(--fg)">＋ New session</button>
    </div>`;
  body.innerHTML = html;
  $("insRename").onclick = () => { closeIns(); renameSession(cur.title || ""); };
  $("insArchive").onclick = async () => {
    const base = (cur.title || "session").replace(/^archived · /, "");
    const r = await sendEngine("engine_rename", { title: "archived · " + base });
    if (r && r.ev === "engine_renamed") {
      if (r.session_id) localTitles.set(r.session_id, r.title);
      renderSessions();
      send({ id: nextId++, req: "list_sessions" });
      addSystem("session archived as: " + r.title);
    } else addSystem("rename failed" + (r && r.message ? ": " + r.message : ""));
    closeIns();
  };
  $("insFresh").onclick = () => { closeIns(); createSession(); };
  $("insModel").onclick = () => { closeIns(); openMs(); };
}
function closeIns() { $("insOverlay").classList.remove("show"); }
$("inspBtn").onclick = openInspector;
$("insClose").onclick = closeIns;
$("insOverlay").addEventListener("click", e => { if (e.target === $("insOverlay")) closeIns(); });

/* ═══════════════════════════ Connection ═══════════════════════════ */
function send(obj) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj)); }

function connect() {
  setStatus("", "connecting");
  ws = new WebSocket(WS_URL);
  ws.onopen = () => { reconnectDelay = 1200; send({ id: nextId++, req: "hello", min_version: 1, max_version: 1, client: "alphacode-web/2.0" }); };
  ws.onmessage = ev => { try { handle(JSON.parse(ev.data)); } catch (e) { console.warn("bad frame", e); } };
  ws.onclose = ev => {
    setStatus("", ev.code === 4001 ? "unauthorized" : "reconnecting…");
    sessionId = null; renderSessions();
    setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 1.6, 12000);
  };
  ws.onerror = () => {};
}

function handle(f) {
  const ev = f.ev || "";
  switch (ev) {
    case "hello_ok":
      harnessVersion = f.server || harnessVersion;
      setStatus("on", "connected"); send({ id: nextId++, req: "list_sessions" });
      break;
    case "sessions":
      sessions = f.sessions || [];
      renderSessions();
      if (!sessionId) {
        if (sessions.length) attach(pickBest(sessions));
        else tryResumeLast();
      } else if (!userSent && !autoSwitched) {
        // Cold daemons register sessions lazily: the first list is often empty and
        // we create a fresh session, then the registry appears. If a materially
        // richer session exists and the user hasn't spoken yet, adopt it once.
        const cur = sessions.find(x => x.session_id === sessionId);
        const best = [...sessions].sort((a, b) => (b.transcript_bytes || 0) - (a.transcript_bytes || 0))[0];
        if (best && best.session_id !== sessionId &&
            (best.transcript_bytes || 0) > ((cur && cur.transcript_bytes) || 0)) {
          autoSwitched = true;
          attach(best.session_id);
        }
      }
      break;
    case "session_status": {
      const BUSY_STATES = ["generating", "tool_running", "compacting", "queued", "working"];
      if (BUSY_STATES.includes(f.status)) { busy = true; composer.classList.add("busy"); setStatus("busy", f.status); }
      else { busy = false; composer.classList.remove("busy"); setStatus("on", "connected"); }
      break;
    }
    case "attached": {
      const s = f.session || {};
      sessionId = s.session_id || f.session_id || sessionId;
      renderSessions();
      const ta = $("input"); ta.disabled = false; $("sendBtn").disabled = false;
      lsSet(LS_KEY, sessionId);
      send({ id: nextId++, req: "peek_session", session_id: sessionId, limit: 80 });
      send({ id: nextId++, req: "list_sessions" });   // refresh titles/status after attach
      break;
    }
    case "history": {
      // Stored-record replay via peek_session. Internal <system-reminder> blocks
      // are part of the record but are not conversation content — skip them.
      const msgs = (f.messages || []).filter(m =>
        !(m.role === "user" && (m.content || "").trim().startsWith("<system-reminder>")));
      if (pendingResumeId && f.session_id === pendingResumeId) {
        pendingResumeId = null;
        if (msgs.length) { attach(f.session_id); return; }  // rich record → adopt it
        createSession();                                     // probe was empty
        break;
      }
      if (!msgs.length) break;
      // Replaying a persisted transcript: assistant text re-renders as markdown;
      // tool records render as compact dim blocks (streaming cards are lost).
      for (const m of msgs) {
        if (m.role === "user") { addUserQuiet(m.content || ""); }
        else if (m.role === "assistant") {
          if (!m.content || !m.content.trim()) continue;
          const b = newAssistant();
          curBuf = m.content; renderBuf();
          curBubble = null; curBuf = "";
          b.bub.querySelectorAll(".caret").forEach(n => n.remove());
        } else if (m.role === "tool" && (m.content || "").trim()) {
          const c = curBubble ? curBubble.content : transcript;
          const t = el("div", "tool");
          t.innerHTML = `<div class="t-head"><span class="t-prompt">❯</span><span class="t-arg" style="max-width:100%"></span></div><div class="t-body" style="display:block"><div class="t-out"></div></div>`;
          t.querySelector(".t-arg").textContent = "historical tool record";
          t.querySelector(".t-out").textContent = m.content.slice(0, 2000);
          t.querySelector(".t-head").onclick = () => t.classList.toggle("open") || t.classList.add("open");
          (c === transcript ? transcript : c).appendChild(t);
        }
      }
      addTurnSep();
      break;
    }
    case "model_info":
      if (f.provider) engineProvider = f.provider;
      if (f.model) engineModel = f.model;
      setModel(f.provider, f.model);
      break;
    case "session_renamed":
      if (f.session_id && f.title) {
        localTitles.set(f.session_id, f.title);
        renderSessions();
      }
      break;
    case "message_accepted": break;
    case "reasoning_delta": feedThinking(f.text || ""); break;
    case "reasoning_done": stopThinking(true); break;
    case "text_delta": {
      stopThinking(true);
      if (!curBubble) curBubble = newAssistant();
      curBuf += f.text || "";
      scheduleRender();
      break;
    }
    case "tool_start": startTool(f.call_id, f.name); break;
    case "tool_input_delta": feedToolInput(f.delta || ""); break;
    case "tool_exec": break;
    case "tool_done": endTool(f.error ? "error" : "ok", f.error || f.output || ""); break;
    case "tool_progress": break;
    case "background_progress": break;
    case "memory_warning": setContext(f.usage); break;
    case "token_usage":
      if (f.input != null) tok.input = f.input;
      if (f.output != null) tok.output = f.output;
      if (f.cache_read_input != null) tok.cache = f.cache_read_input;
      renderTok();
      break;
    case "health_update": break;
    case "permission_request": addPermission(f); break;
    case "turn_done":
      stopThinking(true);
      if (curTool) endTool("ok", curTool.out);
      if (curBubble) { if (curRenderTimer) { clearTimeout(curRenderTimer); curRenderTimer = null; } renderBuf(); }
      curBubble = null; curBuf = ""; curTool = null;
      addTurnSep();
      send({ id: nextId++, req: "list_sessions" });   // refresh titles/status
      break;
    case "error":
      if (f.reply_to != null && pendingEngine.has(f.reply_to)) {
        const r = pendingEngine.get(f.reply_to); pendingEngine.delete(f.reply_to); r(f);
        break;
      }
      if (pendingResumeId) { pendingResumeId = null; createSession(); break; }
      addSystem("error: " + (f.message || "unknown")); break;
    default:
      if (f.reply_to != null && pendingEngine.has(f.reply_to)) {
        const r = pendingEngine.get(f.reply_to); pendingEngine.delete(f.reply_to); r(f);
      }
      break;
  }
}

function addTurnSep() {
  const d = el("div", "turn-sep"); d.textContent = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  transcript.appendChild(d); toBottom();
}

function pickBest(list) {
  // transcript_bytes is a cheap proxy for "has real conversation"; prefer the
  // richest session, with a preference for an idle one among the heavy hitters.
  const scored = [...list].sort((a, b) => (b.transcript_bytes || 0) - (a.transcript_bytes || 0));
  const top = scored[0];
  const idleTop = scored.find(s =>
    s.status === "idle" && (s.transcript_bytes || 0) >= (top.transcript_bytes || 0) * 0.5);
  return (idleTop || top).session_id;
}
function tryResumeLast() {
  if (resumeAttempted) { createSession(); return; }
  resumeAttempted = true;
  const last = lsGet(LS_KEY);
  if (!last) { createSession(); return; }
  pendingResumeId = last;
  send({ id: nextId++, req: "peek_session", session_id: last, limit: 12 });
}

function createSession() {
  curBubble = null; curBuf = ""; thinking = null; curTool = null;
  send({ id: nextId++, req: "create_session", working_dir: "/home/alphacode-runner/workspace" });
}
function attach(id) {
  sessionId = id;
  curBubble = null; curBuf = ""; thinking = null; curTool = null;
  transcript.querySelectorAll(".msg,.tool,.perm,.turn-sep,.sysmsg").forEach(n => n.remove());
  send({ id: nextId++, req: "attach_session", session_id: id });
}

/* ═══════════════════════════ Composer + slash palette ═══════════════════════════ */
const composer = $("composer"), input = $("input"), palette = $("palette");
let palItems = [], palIdx = -1;

function openPalette() {
  const v = input.value;
  if (!v.startsWith("/") || v.includes("\n")) { palette.classList.remove("show"); return; }
  const q = v.slice(1).toLowerCase();
  palItems = SLASH.filter(([c, d]) => c.slice(1).startsWith(q) || d.toLowerCase().includes(q));
  if (!palItems.length) {
    palette.innerHTML = `<div class="pal-empty">no matching command</div>`;
    palette.classList.add("show"); palIdx = -1; return;
  }
  palette.innerHTML = "";
  palItems.forEach(([c, d], i) => {
    const it = el("div", "pal-item" + (i === 0 ? " sel" : ""));
    it.innerHTML = `<span class="pal-cmd">${escHtml(c)}</span><span class="pal-desc">${escHtml(d)}</span>`;
    it.onclick = () => choose(i);
    palette.appendChild(it);
  });
  palIdx = 0;
  palette.classList.add("show");
}
function choose(i) {
  const [c] = palItems[i];
  input.value = c + " ";
  palette.classList.remove("show");
  input.focus();
  autoGrow();
}
function closePalette() { palette.classList.remove("show"); palIdx = -1; }
function paletteKey(e) {
  if (!palette.classList.contains("show")) return false;
  if (e.key === "ArrowDown" || e.key === "ArrowUp") {
    e.preventDefault();
    palIdx = (palIdx + (e.key === "ArrowDown" ? 1 : -1) + palItems.length) % Math.max(palItems.length, 1);
    palette.querySelectorAll(".pal-item").forEach((n, i) => n.classList.toggle("sel", i === palIdx));
    return true;
  }
  if (e.key === "Tab" || (e.key === "Enter" && palIdx >= 0)) { e.preventDefault(); choose(palIdx >= 0 ? palIdx : 0); return true; }
  if (e.key === "Escape") { e.preventDefault(); closePalette(); return true; }
  return false;
}

function autoGrow() { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, 190) + "px"; }
input.addEventListener("input", () => { autoGrow(); if (input.value.startsWith("/")) openPalette(); else closePalette(); });
input.addEventListener("keydown", e => {
  if (paletteKey(e)) return;
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); sendMsg(); }
});
$("sendBtn").onclick = sendMsg;
$("stopBtn").onclick = () => { if (sessionId) send({ id: nextId++, req: "cancel", session_id: sessionId }); };

function sendMsg() {
  const text = input.value.trim();
  if (!text) return;
  if (!sessionId) { addSystem("not connected to a session yet"); return; }
  addUser(text);
  userSent = true;
  send({ id: nextId++, req: "send_message", session_id: sessionId, content: text });
  input.value = ""; autoGrow(); closePalette();
  curBubble = null; curBuf = ""; curTool = null; stick = true;
}

// chips
document.querySelectorAll(".chip").forEach(ch => ch.onclick = () => { input.value = ch.dataset.fill; input.focus(); autoGrow(); if (input.value.startsWith("/")) openPalette(); });

// jump button
$("jumpBtn").onclick = () => { stick = true; scroll.scrollTop = scroll.scrollHeight; };

/* ═══════════════════════════ Boot ═══════════════════════════ */
connect();
</script>
</body>
</html>
INDEX_HTML_EOF

cat > "${WEB_DIR}/harness_probe.py" <<'PROBE_PY'
#!/usr/bin/env python3
"""Minimal harness API handshake probe (used by alphacode-verify)."""
import json, os, socket

path = os.path.join(os.path.expanduser("~"), ".alphacode", "alphacode-api.sock")
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(path)
    req = {"id": 1, "req": "hello", "min_version": 1,
           "max_version": 1, "client": "verify"}
    s.sendall((json.dumps(req) + "\n").encode())
    line = s.makefile().readline()
    print("hello_ok" if line and "hello_ok" in line else "unexpected: " + (line or "").strip())
except Exception as exc:
    print("unreachable: " + str(exc))
PROBE_PY

chown -R "$ALPHACODE_USER:$ALPHACODE_USER" "$WEB_DIR"
chmod 600 "${WEB_DIR}/bridge.py"
chmod 644 "${STATIC_DIR}/index.html"
ok "bridge.py + index.html deployed"

# ── 6. Python venv with websockets ──────────────────────────────────────────
if [[ ! -x "${VENV_DIR}/bin/python" || "$FORCE" == "yes" ]]; then
  as_user python3 -m venv "$VENV_DIR"
fi
if ! "${VENV_DIR}/bin/python" -c 'import websockets' >/dev/null 2>&1; then
  as_user "${VENV_DIR}/bin/pip" install -q --upgrade pip >/dev/null
  as_user "${VENV_DIR}/bin/pip" install -q 'websockets>=14,<17'
fi
ok "websockets $("${VENV_DIR}/bin/python" -c 'import websockets;print(websockets.__version__)')"

# ── 7. Token (preserved across re-runs) ─────────────────────────────────────
if [[ ! -s "$TOKEN_FILE" || "$FORCE" == "yes" ]]; then
  dd if=/dev/urandom bs=32 count=1 2>/dev/null | xxd -p -c 256 | tr -d '\n' > "$TOKEN_FILE"
  chown "$ALPHACODE_USER:$ALPHACODE_USER" "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  ok "generated new web token"
else
  ok "existing web token preserved"
fi
TOKEN="$(cat "$TOKEN_FILE")"

# ── 8. Bridge configuration ─────────────────────────────────────────────────
if [[ "$MODE" == "direct-ip" ]]; then BIND="0.0.0.0"; else BIND="127.0.0.1"; fi
cat > "$WEB_CONF" <<EOF
# AlphaCode Web Bridge configuration (managed by deploy_alphacode.sh)
BRIDGE_HOST=${BIND}
BRIDGE_PORT=${PORT}
EOF
chmod 644 "$WEB_CONF"
ok "bridge config: BRIDGE_HOST=${BIND} BRIDGE_PORT=${PORT}"

# ── 9. Optional provider profile ────────────────────────────────────────────
if [[ -n "$BASE_URL" && -n "$MODEL" ]]; then
  log "Configuring OpenAI-compatible provider"
  PNAME="${PROVIDER_NAME:-custom}"
  if [[ -z "$API_KEY" ]]; then
    warn "no API key supplied (--api-key or ALPHACODE_API_KEY); configuring without one"
    as_user bash -c "
      export PATH=\"${ALPHACODE_HOME}/.local/bin:\$PATH\"
      alphacode provider add '$PNAME' --provider openai-compatible \
        --base-url '$BASE_URL' --model '$MODEL' --no-api-key --set-default --quiet
    " || warn "provider setup failed"
  else
    printf '%s\n' "$API_KEY" | as_user bash -c "
      export PATH=\"${ALPHACODE_HOME}/.local/bin:\$PATH\"
      alphacode provider add '$PNAME' --provider openai-compatible \
        --base-url '$BASE_URL' --model '$MODEL' --api-key-stdin --auth bearer \
        --set-default --quiet 2>/dev/null || \
      alphacode provider add '$PNAME' --provider openai-compatible \
        --base-url '$BASE_URL' --model '$MODEL' --api-key-stdin --set-default --quiet
    " || warn "provider setup failed"
    ok "provider '${PNAME}' configured"
  fi
fi

# ── 10. systemd units ───────────────────────────────────────────────────────
log "Installing systemd units"
cat > /etc/systemd/system/alphacode-daemon.service <<'EOF'
[Unit]
Description=AlphaCode AI Agent Daemon
After=network.target

[Service]
Type=simple
User=__USER__
Group=__USER__
ExecStart=__HOME__/.local/bin/alphacode serve
WorkingDirectory=__HOME__/workspace
Environment=ALPHACODE_NO_TELEMETRY=1
Environment=ALPHACODE_RUNTIME_DIR=__HOME__/.alphacode
Environment=PATH=__HOME__/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=__HOME__
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=true
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
RemoveIPC=true
CapabilityBoundingSet=
UMask=0077
LimitNOFILE=4096
TasksMax=512
MemoryMax=2G
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/alphacode-api-bridge.service <<'EOF'
[Unit]
Description=AlphaCode Harness API Bridge
After=alphacode-daemon.service
Requires=alphacode-daemon.service

[Service]
Type=simple
User=__USER__
Group=__USER__
ExecStart=__HOME__/.local/bin/alphacode api-bridge
WorkingDirectory=__HOME__/workspace
Environment=ALPHACODE_NO_TELEMETRY=1
Environment=ALPHACODE_RUNTIME_DIR=__HOME__/.alphacode
Environment=PATH=__HOME__/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=__HOME__/.alphacode
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=true
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
RemoveIPC=true
CapabilityBoundingSet=
UMask=0077
LimitNOFILE=256
TasksMax=64
MemoryMax=256M
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/alphacode-web.service <<'EOF'
[Unit]
Description=AlphaCode Web Bridge (WebSocket to Unix Socket)
After=alphacode-api-bridge.service
Requires=alphacode-api-bridge.service

[Service]
Type=simple
User=__USER__
Group=__USER__
EnvironmentFile=-__WEBCONF__
ExecStart=__VENV__/bin/python __WEB__/bridge.py
WorkingDirectory=__WEB__
Environment=ALPHACODE_NO_TELEMETRY=1
Environment=ALPHACODE_RUNTIME_DIR=__HOME__/.alphacode
Environment=PYTHONUNBUFFERED=1
Environment=PATH=__HOME__/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=__HOME__/.alphacode
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET
RestrictNamespaces=true
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
RemoveIPC=true
CapabilityBoundingSet=
UMask=0077
LimitNOFILE=256
TasksMax=64
MemoryMax=256M
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sed -i "s|__USER__|${ALPHACODE_USER}|g; s|__HOME__|${ALPHACODE_HOME}|g; \
        s|__WEB__|${WEB_DIR}|g; s|__VENV__|${VENV_DIR}|g; \
        s|__WEBCONF__|${WEB_CONF}|g" \
  /etc/systemd/system/alphacode-daemon.service \
  /etc/systemd/system/alphacode-api-bridge.service \
  /etc/systemd/system/alphacode-web.service

# Quick-tunnel unit (only in quick-tunnel mode; removed otherwise)
if [[ "$MODE" == "quick-tunnel" ]]; then
  cat > /etc/systemd/system/alphacode-tunnel.service <<EOF
[Unit]
Description=AlphaCode Cloudflare Quick Tunnel
After=alphacode-web.service
Requires=alphacode-web.service

[Service]
Type=simple
ExecStart=/usr/bin/cloudflared tunnel --config /dev/null --url http://127.0.0.1:${PORT} --no-autoupdate
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  ok "quick-tunnel unit installed"
else
  rm -f /etc/systemd/system/alphacode-tunnel.service
fi

chmod 644 /etc/systemd/system/alphacode-*.service
systemctl daemon-reload
ok "units installed"

# ── 11. Enable and start ────────────────────────────────────────────────────
log "Starting services"
# enable + restart so a changed unit file actually takes effect on re-runs
systemctl enable alphacode-daemon.service >/dev/null 2>&1
systemctl restart alphacode-daemon.service
sleep 3
systemctl enable alphacode-api-bridge.service >/dev/null 2>&1
systemctl restart alphacode-api-bridge.service
sleep 2
systemctl enable alphacode-web.service >/dev/null 2>&1
systemctl restart alphacode-web.service
sleep 2
if [[ "$MODE" == "quick-tunnel" ]]; then
  systemctl enable alphacode-tunnel.service >/dev/null 2>&1 || true
  systemctl restart alphacode-tunnel.service >/dev/null 2>&1 || true
  sleep 6
fi

FAILED=()
for svc in alphacode-daemon alphacode-api-bridge alphacode-web; do
  systemctl is-active --quiet "$svc.service" || FAILED+=("$svc")
done
[[ ${#FAILED[@]} -eq 0 ]] || die "services not running: ${FAILED[*]}
  check: journalctl -u ${FAILED[0]} -n 50"
ok "all three services active"

# ── 12. Firewall for direct-ip ──────────────────────────────────────────────
if [[ "$MODE" == "direct-ip" ]] && command -v ufw >/dev/null 2>&1; then
  ufw allow "${PORT}/tcp" comment 'alphacode-web' >/dev/null 2>&1 || true
  ok "ufw: allowed ${PORT}/tcp"
fi

# ── 13. Helper commands ─────────────────────────────────────────────────────
cat > "$HELPER" <<EOF
#!/usr/bin/env bash
# Print the AlphaCode web-chat access URL and service status.
TOKEN="\$(cat ${TOKEN_FILE} 2>/dev/null)"
PORT="\$(grep -oP '^BRIDGE_PORT=\\\\K.*' ${WEB_CONF} 2>/dev/null || echo ${PORT})"
HOST="\$(grep -oP '^BRIDGE_HOST=\\\\K.*' ${WEB_CONF} 2>/dev/null || echo 127.0.0.1)"
echo "AlphaCode web chat"
echo "  services: \$(systemctl is-active alphacode-daemon alphacode-api-bridge alphacode-web | tr '\n' ' ')"
if [[ "\$HOST" == "0.0.0.0" ]]; then
  IP="\$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \\\\K[0-9.]+' | head -1)"
  echo "  direct:   http://\${IP:-<SERVER_IP>}:\${PORT}/?token=\${TOKEN}"
else
  if [[ -f /etc/systemd/system/alphacode-tunnel.service ]]; then
    QURL="\$(journalctl -u alphacode-tunnel --no-pager -n 300 2>/dev/null | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1)"
    echo "  tunnel:   \${QURL:-<starting, retry in a few seconds>}/?token=\${TOKEN}"
  else
    echo "  local:    http://127.0.0.1:\${PORT}/?token=\${TOKEN}"
    echo "  note:     loopback-only. Put a reverse proxy in front, or redeploy with"
    echo "            --mode direct-ip (LAN/public HTTP) or --mode quick-tunnel (HTTPS)."
  fi
fi
EOF
chmod 755 "$HELPER"

if [[ "$MODE" == "quick-tunnel" ]]; then
  cat > "$TUNNEL_HELPER" <<'EOF'
#!/usr/bin/env bash
# Show / watch the current quick-tunnel public URL.
journalctl -u alphacode-tunnel --no-pager -n 300 \
  | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1
EOF
  chmod 755 "$TUNNEL_HELPER"
fi

# Self-test: services, bridge HTTP, and a harness NDJSON handshake.
cat > "$VERIFY_HELPER" <<EOF
#!/usr/bin/env bash
set -uo pipefail
PORT="\$(grep -oP '^BRIDGE_PORT=\\K.*' ${WEB_CONF} 2>/dev/null || echo ${PORT})"
fail=0

echo "AlphaCode health check"
echo "  --- services ---"
for s in alphacode-daemon alphacode-api-bridge alphacode-web; do
  st="\$(systemctl is-active \$s.service 2>/dev/null || true)"
  printf '  %-24s %s\\n' "\$s" "\$st"
  [[ "\$st" == "active" ]] || fail=1
done

echo "  --- bridge ---"
code="\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:\$PORT/healthz 2>/dev/null || echo 000)"
printf '  %-24s %s\\n' "/healthz" "\$code"
[[ "\$code" == "200" ]] || fail=1

echo "  --- harness socket ---"
if [[ "\$(id -u)" -eq 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    RUN_AS="sudo -u ${ALPHACODE_USER}"
  else
    RUN_AS="runuser -u ${ALPHACODE_USER} --"
  fi
  hs="\$(\${RUN_AS} ${VENV_DIR}/bin/python ${WEB_DIR}/harness_probe.py 2>&1 | tail -1)"
else
  hs="\$(${VENV_DIR}/bin/python ${WEB_DIR}/harness_probe.py 2>&1 | tail -1)"
fi
printf '  %-24s %s\\n' "alphacode-api.sock" "\$hs"
[[ "\$hs" == "hello_ok" ]] || fail=1

echo
if [[ \$fail -eq 0 ]]; then
  echo "RESULT: healthy"
else
  echo "RESULT: problems detected (see above)"
fi
exit \$fail
EOF
chmod 755 "$VERIFY_HELPER"

# Install a copy of this installer for re-use
install -m 755 "$SELF" /usr/local/bin/deploy_alphacode.sh 2>/dev/null || true

# ── 14. Summary ─────────────────────────────────────────────────────────────
echo
log "Deployment complete"
echo "  mode:      ${MODE}"
SVCS="alphacode-daemon, alphacode-api-bridge, alphacode-web"
[[ "$MODE" == "quick-tunnel" ]] && SVCS="$SVCS, alphacode-tunnel"
echo "  services:  $SVCS"
echo "  token:     ${TOKEN}"
echo
sleep 2
"$HELPER" || true
echo
echo "  Run 'alphacode-web' any time to print the access URL."
echo "  Logs:  journalctl -u alphacode-web -f"
