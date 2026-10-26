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
REPO_SLUG="${ALPHACODE_WEB_REPO:-AhmedFayala/alphacode-web}"
REF="${ALPHACODE_WEB_REF:-main}"
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
usage() {
  cat <<'USAGE'
deploy_alphacode.sh — portable, idempotent AlphaCode web-chat installer

Usage:
  sudo bash deploy_alphacode.sh [OPTIONS]

Options:
  --mode <loopback|direct-ip|quick-tunnel>  Access mode            (default: loopback)
  --port <PORT>            Bridge TCP port                        (default: 8765)
  --version <vX.Y.Z>       AlphaCode version to install           (default: v1.0.89)
  --repo <owner/name>      Source repository for web files        (default: AhmedFayala/alphacode-web)
  --ref <branch|tag>       Git ref to fetch web files from        (default: main)
  --provider-name <NAME>   OpenAI-compatible profile name         (optional)
  --base-url <URL>         OpenAI-compatible base URL             (optional)
  --model <MODEL>          Model id for that profile              (optional)
  --api-key <KEY>          API key (or env ALPHACODE_API_KEY)     (optional)
  --force                  Reinstall the binary / overwrite configs
  --uninstall              Remove services, files and user
  -h|--help                Show this help

Modes:
  loopback      Bind 127.0.0.1. Pair with a reverse proxy or a named tunnel.
  direct-ip     Bind 0.0.0.0 and open the port in UFW. Plain-HTTP access:
                http://<SERVER_IP>:<PORT>/?token=<TOKEN>
  quick-tunnel  Bind 127.0.0.1 and run a Cloudflare quick tunnel, giving an
                instant https://*.trycloudflare.com URL with no account.

Idempotent: safe to re-run. The web token and provider keys are preserved
unless --force is given. Web files are fetched from the repository at --ref.
USAGE
  exit 0;
}

# ── Argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)          MODE="${2:-}"; shift 2 ;;
    --port)          PORT="${2:-}"; shift 2 ;;
    --version)       VERSION="${2:-}"; shift 2 ;;
    --repo)          REPO_SLUG="${2:-}"; shift 2 ;;
    --ref)           REF="${2:-}"; shift 2 ;;
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
log "Downloading web bridge and UI (repo: ${REPO_SLUG}, ref: ${REF})"
fetch_raw() {  # $1 = path in repo, $2 = destination, $3 = octal mode
  curl -fsSL --retry 3 --max-time 60 \
    "https://raw.githubusercontent.com/${REPO_SLUG}/${REF}/$1" -o "$2" \
    || die "download failed: $1 (ref ${REF}) — check --repo/--ref or network"
  chmod "$3" "$2"
}
fetch_raw "src/bridge.py"        "${WEB_DIR}/bridge.py"        600
fetch_raw "src/static/index.html" "${STATIC_DIR}/index.html"   644
ok "bridge.py + index.html deployed"

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
