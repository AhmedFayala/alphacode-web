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

BRIDGE_PY_EOF

cat > "${STATIC_DIR}/index.html" <<'INDEX_HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AlphaCode</title>
<style>
:root {
  --bg: #0d1117;
  --bg2: #161b22;
  --bg3: #21262d;
  --fg: #e6edf3;
  --muted: #8b949e;
  --accent: #8b7cff;
  --green: #3fb950;
  --red: #f85149;
  --yellow: #d29922;
  --blue: #58a6ff;
  --border: #30363d;
  --mono: 'SF Mono', 'Cascadia Code', 'Fira Code', 'Consolas', monospace;
  --sans: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  --radius: 8px;
}
@media (prefers-color-scheme: light) {
  :root { --bg:#fafbfc; --bg2:#fff; --bg3:#eaeef2; --fg:#1f2328; --muted:#59636e; --border:#d0d7de; --accent:#6f57ff; }
}
* { margin:0; padding:0; box-sizing:border-box; }
body { font-family:var(--sans); background:var(--bg); color:var(--fg); height:100vh; display:flex; flex-direction:column; overflow:hidden; }

/* Header */
header { background:var(--bg2); border-bottom:1px solid var(--border); padding:8px 16px; display:flex; align-items:center; gap:12px; flex-shrink:0; }
.status-dot { width:8px; height:8px; border-radius:50%; background:var(--red); flex-shrink:0; transition:background .2s; }
.status-dot.connected { background:var(--green); }
.status-dot.busy { background:var(--yellow); animation:pulse 1s infinite; }
@keyframes pulse { 50% { opacity:.4; } }
.status-text { font-size:13px; color:var(--muted); white-space:nowrap; }
.model-info { font-size:12px; color:var(--muted); font-family:var(--mono); white-space:nowrap; }
.session-select { background:var(--bg3); color:var(--fg); border:1px solid var(--border); border-radius:6px; padding:4px 8px; font-size:12px; max-width:200px; }
.new-session-btn { background:var(--accent); color:#fff; border:none; border-radius:6px; padding:4px 10px; font-size:12px; cursor:pointer; white-space:nowrap; }
.new-session-btn:hover { opacity:.85; }
.ctx-bar { width:80px; height:6px; background:var(--bg3); border-radius:3px; overflow:hidden; flex-shrink:0; }
.ctx-fill { height:100%; background:var(--green); transition:width .3s, background .3s; width:0%; }
header .spacer { flex:1; }

/* Transcript */
main { flex:1; overflow-y:auto; padding:16px; scroll-behavior:smooth; }
main::-webkit-scrollbar { width:6px; }
main::-webkit-scrollbar-thumb { background:var(--border); border-radius:3px; }
.msg { margin-bottom:16px; max-width:900px; }
.msg-label { font-size:11px; color:var(--muted); margin-bottom:4px; text-transform:uppercase; letter-spacing:.5px; }
.msg-user { margin-left:40px; }
.msg-user .bubble { background:var(--accent); color:#fff; padding:10px 14px; border-radius:var(--radius) var(--radius) 4px var(--radius); display:inline-block; max-width:100%; word-wrap:break-word; }
.msg-assistant .bubble { background:var(--bg2); border:1px solid var(--border); padding:12px 16px; border-radius:4px var(--radius) var(--radius) var(--radius); word-wrap:break-word; line-height:1.6; }
.msg-assistant .bubble pre { background:var(--bg); border:1px solid var(--border); border-radius:6px; padding:10px; margin:8px 0; overflow-x:auto; font-family:var(--mono); font-size:13px; }
.msg-assistant .bubble code { font-family:var(--mono); font-size:13px; background:var(--bg3); padding:1px 4px; border-radius:3px; }
.msg-assistant .bubble pre code { background:none; padding:0; }

/* Tool cards */
.tool-card { background:var(--bg2); border:1px solid var(--border); border-radius:6px; margin:8px 0; font-family:var(--mono); font-size:13px; overflow:hidden; }
.tool-header { display:flex; align-items:center; gap:8px; padding:8px 12px; cursor:pointer; user-select:none; }
.tool-header:hover { background:var(--bg3); }
.tool-icon { font-size:14px; }
.tool-name { color:var(--blue); font-weight:600; }
.tool-status { margin-left:auto; font-size:11px; color:var(--muted); }
.tool-status.running { color:var(--yellow); }
.tool-status.done { color:var(--green); }
.tool-status.error { color:var(--red); }
.tool-body { display:none; padding:0 12px 8px; border-top:1px solid var(--border); margin-top:4px; }
.tool-body.open { display:block; }
.tool-body pre { white-space:pre-wrap; word-wrap:break-word; color:var(--muted); font-size:12px; padding:8px 0; max-height:300px; overflow-y:auto; }

/* Permission banner */
.perm-banner { background:var(--bg2); border:1px solid var(--yellow); border-radius:8px; padding:12px 16px; margin:8px 0; display:flex; align-items:center; gap:12px; }
.perm-text { flex:1; font-size:13px; }
.perm-text strong { color:var(--yellow); }
.perm-btn { padding:6px 16px; border:none; border-radius:6px; font-size:13px; cursor:pointer; font-weight:600; }
.perm-btn.allow { background:var(--green); color:#fff; }
.perm-btn.deny { background:var(--red); color:#fff; }
.perm-btn:hover { opacity:.85; }

/* Input area */
footer { background:var(--bg2); border-top:1px solid var(--border); padding:8px 16px; flex-shrink:0; }
.input-row { display:flex; gap:8px; align-items:flex-end; max-width:900px; }
textarea { flex:1; background:var(--bg3); color:var(--fg); border:1px solid var(--border); border-radius:var(--radius); padding:10px 14px; font-family:var(--sans); font-size:14px; resize:none; outline:none; min-height:42px; max-height:200px; transition:border-color .2s; }
textarea:focus { border-color:var(--accent); }
.send-btn { background:var(--accent); color:#fff; border:none; border-radius:var(--radius); padding:10px 20px; font-size:14px; cursor:pointer; white-space:nowrap; }
.send-btn:hover { opacity:.85; }
.send-btn:disabled { opacity:.4; cursor:default; }
.cancel-btn { background:var(--red); color:#fff; border:none; border-radius:var(--radius); padding:10px 20px; font-size:14px; cursor:pointer; display:none; }

/* Scroll anchor */
.scroll-anchor { float:left; clear:both; }

@media (max-width:600px) {
  header { flex-wrap:wrap; gap:6px; padding:6px 10px; }
  .model-info { display:none; }
  .session-select { max-width:120px; }
  main { padding:8px; }
  .msg-user { margin-left:0; }
}
</style>
</head>
<body>

<header>
  <div class="status-dot" id="statusDot"></div>
  <span class="status-text" id="statusText">Connecting…</span>
  <span class="model-info" id="modelInfo"></span>
  <div class="ctx-bar" title="Context usage"><div class="ctx-fill" id="ctxFill"></div></div>
  <div class="spacer"></div>
  <select class="session-select" id="sessionSelect" title="Sessions"></select>
  <button class="new-session-btn" id="newSessionBtn" title="New session">+ New</button>
</header>

<main id="transcript"></main>

<footer>
  <div class="input-row">
    <textarea id="input" placeholder="Type a message or /command…  (Enter to send, Shift+Enter for newline)" rows="1" disabled></textarea>
    <button class="send-btn" id="sendBtn" disabled>Send</button>
    <button class="cancel-btn" id="cancelBtn">Cancel</button>
  </div>
</footer>

<script>
// ── State ─────────────────────────────────────
let ws = null;
let nextId = 100;
let attachedSessionId = null;
let isBusy = false;
let sessions = [];
let currentToolCard = null;
let currentAssistantBubble = null;

// ── DOM ──────────────────────────────────────
const $ = id => document.getElementById(id);
const transcript = $('transcript');
const input = $('input');
const sendBtn = $('sendBtn');
const cancelBtn = $('cancelBtn');
const sessionSelect = $('sessionSelect');
const statusDot = $('statusDot');
const statusText = $('statusText');
const modelInfo = $('modelInfo');
const ctxFill = $('ctxFill');

// ── Token (injected by bridge via query param) ─
const TOKEN = new URLSearchParams(location.search).get('token') || '';
const wsProto = location.protocol === 'https:' ? 'wss:' : 'ws:';
const WS_URL = `${wsProto}//${location.host}/ws?token=${TOKEN}`;

// ── Connection ────────────────────────────────
function connect() {
  ws = new WebSocket(WS_URL);
  ws.onopen = () => { statusText.textContent = 'Authenticating…'; sendHello(); };
  ws.onmessage = ev => handleMessage(JSON.parse(ev.data));
  ws.onclose = ev => { setStatus('disconnected', `Disconnected (${ev.code})`); input.disabled = true; sendBtn.disabled = true; setTimeout(() => connect(), 3000); };
  ws.onerror = () => {};
}

function sendFrame(obj) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj)); }

function sendHello() {
  sendFrame({ id: nextId++, req: 'hello', min_version: 1, max_version: 1, client: 'alphacode-web/1.0' });
}

function setStatus(state, text) {
  statusDot.className = 'status-dot ' + state;
  statusText.textContent = text;
}

// ── Message handling ──────────────────────────
function handleMessage(frame) {
  const ev = frame.ev || '';
  const sid = frame.session_id || '';

  switch (ev) {
    case 'hello_ok':
      setStatus('connected', 'Connected');
      sendFrame({ id: nextId++, req: 'list_sessions' });
      break;

    case 'sessions':
      sessions = frame.sessions || [];
      updateSessionSelect();
      if (sessions.length > 0 && !attachedSessionId) {
        attachSession(sessions[0].session_id);
      } else if (sessions.length === 0) {
        createSession();
      }
      break;

    case 'attached':
      attachedSessionId = sid || frame.session?.session_id;
      if (frame.session) {
        modelInfo.textContent = `${frame.session.status || 'idle'}`;
      }
      input.disabled = false;
      sendBtn.disabled = false;
      input.focus();
      break;

    case 'model_info':
      const parts = [];
      if (frame.provider) parts.push(frame.provider);
      if (frame.model) parts.push(frame.model);
      modelInfo.textContent = parts.join(' / ');
      break;

    case 'session_status':
      if (frame.status === 'idle') { isBusy = false; setStatus('connected', 'Connected'); cancelBtn.style.display = 'none'; sendBtn.style.display = ''; }
      else { isBusy = true; setStatus('busy', frame.status); cancelBtn.style.display = ''; sendBtn.style.display = 'none'; }
      break;

    case 'message_accepted':
      // User message confirmed — echo to transcript
      break;

    case 'text_delta':
      if (!currentAssistantBubble) currentAssistantBubble = addMessage('assistant', '');
      currentAssistantBubble.querySelector('.bubble').textContent += frame.text;
      scrollToBottom();
      break;

    case 'reasoning_delta':
      // Ignore or show dimmed — skip for now
      break;

    case 'tool_start':
      currentAssistantBubble = null;
      currentToolCard = addToolCard(frame.call_id, frame.name, 'running');
      break;

    case 'tool_exec':
      if (currentToolCard) updateToolCard(currentToolCard, frame.name, 'running', null);
      break;

    case 'tool_done':
      if (currentToolCard) updateToolCard(currentToolCard, frame.name, frame.error ? 'error' : 'done', frame.output || frame.error);
      currentToolCard = null;
      break;

    case 'tool_progress':
      // Could render a progress bar — skip for now
      break;

    case 'background_progress':
      // Could render a progress bar for background tasks
      break;

    case 'turn_done':
      currentAssistantBubble = null;
      currentToolCard = null;
      addSeparator();
      break;

    case 'permission_request':
      addPermissionBanner(frame.request_id, frame.tool_name, frame.description, sid);
      break;

    case 'memory_warning':
      ctxFill.style.width = Math.round(frame.usage * 100) + '%';
      ctxFill.style.background = frame.usage > 0.9 ? 'var(--red)' : frame.usage > 0.7 ? 'var(--yellow)' : 'var(--green)';
      break;

    case 'health_update':
      // Could display RSS/threads — skip for now
      break;

    case 'token_usage':
      // Could display token counts — skip for now
      break;

    case 'pong':
      break;

    case 'error':
      console.error('Server error:', frame);
      addMessage('system', `Error: ${frame.message || 'unknown'}`);
      break;

    default:
      console.log('Unhandled event:', frame);
  }
}

// ── Transcript rendering ──────────────────────
function addMessage(role, text) {
  const div = document.createElement('div');
  div.className = `msg msg-${role}`;
  const label = document.createElement('div');
  label.className = 'msg-label';
  label.textContent = role === 'user' ? 'You' : role === 'assistant' ? 'AlphaCode' : 'System';
  const bubble = document.createElement('div');
  bubble.className = 'bubble';
  bubble.textContent = text;
  if (text) renderMarkdown(bubble);
  div.appendChild(label);
  div.appendChild(bubble);
  transcript.appendChild(div);
  scrollToBottom();
  return div;
}

function addToolCard(callId, name, status) {
  const card = document.createElement('div');
  card.className = 'tool-card';
  card.dataset.callId = callId;
  const header = document.createElement('div');
  header.className = 'tool-header';
  header.innerHTML = `<span class="tool-icon">🔧</span><span class="tool-name">${esc(name)}</span><span class="tool-status ${status}">${esc(status)}</span>`;
  header.onclick = () => card.querySelector('.tool-body').classList.toggle('open');
  const body = document.createElement('div');
  body.className = 'tool-body';
  card.appendChild(header);
  card.appendChild(body);
  transcript.appendChild(card);
  scrollToBottom();
  return card;
}

function updateToolCard(card, name, status, output) {
  const s = card.querySelector('.tool-status');
  s.textContent = status;
  s.className = `tool-status ${status}`;
  if (output) {
    const pre = document.createElement('pre');
    pre.textContent = output;
    card.querySelector('.tool-body').appendChild(pre);
  }
  scrollToBottom();
}

function addPermissionBanner(requestId, toolName, description, sid) {
  const banner = document.createElement('div');
  banner.className = 'perm-banner';
  banner.innerHTML = `
    <div class="perm-text"><strong>⚠ ${esc(toolName)}</strong> — ${esc(description)}</div>
    <button class="perm-btn allow" data-rid="${esc(requestId)}" data-sid="${esc(sid)}">Allow</button>
    <button class="perm-btn deny" data-rid="${esc(requestId)}" data-sid="${esc(sid)}">Deny</button>
  `;
  banner.querySelector('.allow').onclick = () => {
    sendFrame({ id: nextId++, req: 'permission_response', session_id: sid, request_id: requestId, decision: 'allow' });
    banner.remove();
  };
  banner.querySelector('.deny').onclick = () => {
    sendFrame({ id: nextId++, req: 'permission_response', session_id: sid, request_id: requestId, decision: 'deny' });
    banner.remove();
  };
  transcript.appendChild(banner);
  scrollToBottom();
}

function addSeparator() {
  const hr = document.createElement('hr');
  hr.style.cssText = 'border:none;border-top:1px solid var(--border);margin:16px 0;max-width:900px;';
  transcript.appendChild(hr);
  scrollToBottom();
}

// ── Session management ────────────────────────
function updateSessionSelect() {
  sessionSelect.innerHTML = '';
  sessions.forEach(s => {
    const opt = document.createElement('option');
    opt.value = s.session_id;
    const title = s.title || s.session_id.substring(0, 8);
    opt.textContent = `${title} (${s.status})`;
    opt.selected = s.session_id === attachedSessionId;
    sessionSelect.appendChild(opt);
  });
}

sessionSelect.onchange = () => {
  const sid = sessionSelect.value;
  if (sid) attachSession(sid);
};

$('newSessionBtn').onclick = () => createSession();

function createSession() {
  sendFrame({ id: nextId++, req: 'create_session', working_dir: '/home/alphacode-runner/workspace' });
}

function attachSession(sid) {
  attachedSessionId = sid;
  sendFrame({ id: nextId++, req: 'attach_session', session_id: sid });
}

// ── Input ─────────────────────────────────────
input.addEventListener('input', () => {
  input.style.height = 'auto';
  input.style.height = Math.min(input.scrollHeight, 200) + 'px';
});

input.addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    sendMessage();
  }
});

sendBtn.onclick = sendMessage;

function sendMessage() {
  const text = input.value.trim();
  if (!text || !attachedSessionId) return;
  addMessage('user', text);
  sendFrame({ id: nextId++, req: 'send_message', session_id: attachedSessionId, content: text });
  input.value = '';
  input.style.height = 'auto';
  currentAssistantBubble = null;
  currentToolCard = null;
}

cancelBtn.onclick = () => {
  if (attachedSessionId) sendFrame({ id: nextId++, req: 'cancel', session_id: attachedSessionId });
};

// ── Helpers ───────────────────────────────────
function scrollToBottom() { transcript.scrollTop = transcript.scrollHeight; }

function esc(s) { const d = document.createElement('div'); d.textContent = s || ''; return d.innerHTML; }

function renderMarkdown(el) {
  // Minimal: code blocks (```...```), inline code (`...`)
  let html = esc(el.textContent);
  html = html.replace(/```(\w*)\n?([\s\S]*?)```/g, '<pre><code>$2</code></pre>');
  html = html.replace(/`([^`]+)`/g, '<code>$1</code>');
  el.innerHTML = html;
}

// ── Start ─────────────────────────────────────
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
