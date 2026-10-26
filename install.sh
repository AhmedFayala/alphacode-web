#!/usr/bin/env bash
# ============================================================================
#  install.sh — AlphaCode Web: premier one-line installer
#
#    curl -fsSL https://raw.githubusercontent.com/AhmedFayala/alphacode-web/main/install.sh | bash
#
#  Modes: loopback | direct-ip | quick-tunnel (account-free HTTPS)
#  Idempotent: re-runs converge; token, config and provider keys are preserved.
#  Binary handling: adopt a healthy existing alphacode, else ingest the release
#  archive directly with SHA-256 verification. No upstream scripts are piped.
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
HELPER="/usr/local/bin/alphacode-web"
TUNNEL_HELPER="/usr/local/bin/alphacode-tunnel"
VERIFY_HELPER="/usr/local/bin/alphacode-verify"

MODE="loopback"
PORT="8765"
VERSION="v1.0.89"
INSTALLER_VER="v1.0.3"
REPO_SLUG="${ALPHACODE_WEB_REPO:-AhmedFayala/alphacode-web}"
REF="${ALPHACODE_WEB_REF:-main}"
FORCE="no"
DO_UNINSTALL="no"
DO_VERIFY="no"
PROVIDER_NAME=""
BASE_URL=""
MODEL=""
API_KEY="${ALPHACODE_API_KEY:-}"
TUNNEL_URL=""
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# ── UI engine: ANSI palette, progress bars, spinners, cards ─────────────────
# Falls back to plain ASCII logging on non-TTY / NO_COLOR / dumb terminals.
TTY=0
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then TTY=1; fi
# Defaults first: every palette variable must exist even on non-TTY runs
# (set -u makes an unset variable fatal — verified by the adoption test).
R=""; B=""; DIM=""; CYAN=""; SLATE=""; GREEN=""; GRAY=""; RED=""; YEL=""; VIOLET=""
# Box glyphs need a UTF-8 charset ($'\uXXXX' is locale-dependent and emits
# literal text on locale-less systems — verified in minimal containers);
# hard-coded \xNN byte escapes are locale-independent. Colors are charset-safe.
UTF8=0
if command -v locale >/dev/null 2>&1 && [[ "$(locale charmap 2>/dev/null)" == *UTF* ]]; then UTF8=1; fi
if (( TTY )); then
  R=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'
  CYAN=$'\e[38;5;80m'; SLATE=$'\e[38;5;103m'; GREEN=$'\e[38;5;114m'
  GRAY=$'\e[38;5;245m'; RED=$'\e[38;5;203m'; YEL=$'\e[38;5;179m'; VIOLET=$'\e[38;5;141m'
fi
if (( TTY && UTF8 )); then
  TL=$'\xe2\x95\xad'; TR=$'\xe2\x95\xae'; BL=$'\xe2\x95\xb0'; BR=$'\xe2\x95\xbf'
  HZ=$'\xe2\x94\x80'; VT=$'\xe2\x94\x82'
else
  TL="+"; TR="+"; BL="+"; BR="+"; HZ="-"; VT="|"
fi

log()  { printf '%b\n' "${CYAN}  ●${R} $*"; }
ok()   { printf '%b\n' "${GREEN}  ✓${R} $*"; }
warn() { printf '%b\n' "${YEL}  !${R} $*" >&2; }
die()  { printf '%b\n' "${RED}  ✗ $*${R}" >&2; exit 1; }

STEP_TOTAL=6; STEP_N=0
step() {
  STEP_N=$((STEP_N + 1))
  printf '\n%b\n' "${VIOLET}  [${STEP_N}/${STEP_TOTAL}]${R} ${B}$1${R}"
}

# In-place block progress bar:  [████████░░░░░░] 68% label
bar() { # $1 = pct, $2 = label
  local pct="$1" label="$2" w=30 filled out="" i
  if (( ! TTY )); then
    printf '    [%3d%%] %s\n' "$pct" "$label"
    return
  fi
  filled=$(( pct * w / 100 ))
  for ((i = 0; i < w; i++)); do
    if (( i < filled )); then out+="${CYAN}█${R}"; else out+="${GRAY}░${R}"; fi
  done
  printf '\r  %s %3d%% %s\e[K' "$out" "$pct" "$label"
  (( pct >= 100 )) && printf '\n'
  return 0
}

# Spinner for unbounded waits; ASCII frames render in any terminal.
SPIN_PID=""
spin_start() {
  spin_stop
  local label="$*"
  if (( ! TTY )); then printf '    … %s\n' "$label"; return; fi
  (
    local i=0
    local fr=( '|' '/' '-' '\' )
    while :; do
      printf '\r    %s%s%s %s\e[K' "$CYAN" "${fr[$((i % 4))]}" "$R" "$label"
      sleep 0.12
      i=$((i + 1))
    done
  ) &
  SPIN_PID=$!
}
spin_stop() {
  if [[ -n "${SPIN_PID:-}" ]]; then
    kill "$SPIN_PID" 2>/dev/null || true
    wait "$SPIN_PID" 2>/dev/null || true
    SPIN_PID=""
  fi
  if (( TTY )); then printf '\r    \e[K\r'; fi
  return 0
}

# ── Bordered card engine: fixed-width, cross-terminal geometry ──────────────
# One geometry for every card: CARD_W interior columns, a left AND right border
# on every row, values truncated to fit. Unicode borders require a UTF-8
# charset (hard-coded byte escapes — locale-independent); the ASCII fallback
# keeps the exact same column geometry, so nothing can misalign. Card row text
# is kept pure ASCII by construction: glyphs appear only in the border runes,
# which sit outside any width computation.
CARD_W=60   # interior columns between the two border glyphs

_sp() { printf '%*s' "$1" ''; }
_hzrun() { # $1 count — a run of HZ
  local s; s="$(_sp "$1")"; printf '%s' "${s// /$HZ}"
}
_hborder() { # $1 = left corner, $2 = right corner
  printf '%b\n' "${SLATE}$1$(_hzrun "$CARD_W")$2${R}"
}
# $1 = visible length of the interior text, $2 = the (possibly colored) text.
# Width math uses only the plain length — ANSI SGR bytes never count.
_crow_n() { # $1 = visible width, $2 = colored text
  local n="$1" text="$2" pad
  pad=$(( CARD_W - 1 - n )); (( pad < 0 )) && pad=0
  printf '%b\n' "${SLATE}${VT}${R} ${text}$(_sp "$pad")${SLATE}${VT}${R}"
}
_crow() { # $1 = plain uncolored interior text
  _crow_n "${#1}" "$1"
}
card() { # card "TITLE" — opens a bordered card
  _hborder "$TL" "$TR"
  local title="$1" w padl
  w=$(( ${#title} ))
  padl=$(( (CARD_W - 1 - w) / 2 )); (( padl < 0 )) && padl=0
  _crow_n $(( padl + w )) "$(_sp "$padl")${B}${VIOLET}${title}${R}"
  _crow ""
}
card_line() { # $1 label (<=11 chars), $2 value — auto-truncated to fit
  local label="$1" val="$2"
  local maxv=$(( CARD_W - 1 - 11 - 1 ))   # 1 gutter + 11 label + 1 gap
  ((${#val} > maxv)) && val="${val:0:$((maxv - 3))}…"
  _crow_n $(( 11 + ${#val} )) "${GRAY}$(printf '%-11s' "$label")${R}${val}"
}
card_close() {
  _hborder "$BL" "$BR"
}

# Clickable terminal hyperlink (OSC 8); falls back to plain text.
link() { # $1 url, $2 text
  if (( TTY )); then
    printf '\e]8;;%s\e\\%s%s\e]8;;\e\\\n' "$1" "$2" "$R"
  else
    printf '%s\n' "$2"
  fi
}

# ── Fetch / privilege helpers ───────────────────────────────────────────────
dl() { # $1 = url, $2 = destination
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --max-time 240 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 --timeout=90 -O "$2" "$1"
  else
    return 1
  fi
}

# Download with a live size-based progress bar (curl backgrounded; wget plain).
dlp() { # $1 url, $2 dest, $3 label
  local url="$1" dest="$2" label="$3" expected=0 cur=0 pid
  expected="$(curl -sIL --max-time 20 "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:" {v=$2} END {print v+0}')"
  if (( TTY && expected > 0 )) && command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$dest" "$url" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      cur="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
      bar $(( cur * 100 / expected )) "$label"
      sleep 0.15
    done
    wait "$pid" || { bar 0 "$label — failed"; printf '\n'; return 1; }
    bar 100 "$label"
    return 0
  fi
  dl "$url" "$dest"
}

as_user() {
  if command -v sudo >/dev/null 2>&1; then
    sudo -u "$ALPHACODE_USER" "$@"
  elif command -v runuser >/dev/null 2>&1; then
    runuser -u "$ALPHACODE_USER" -- "$@"
  else
    # No sudo/runuser: stage a root-owned script and su into it. Never nest a
    # piped subshell inside su -c; that is the fragile path this installer avoids.
    local script rc
    script="$(mktemp /tmp/alphacode-asuser.XXXXXX.sh)"
    {
      printf '%q ' "$@"
      printf '\nexit $?\n'
    } > "$script"
    chmod 755 "$script"
    su -s /bin/bash "$ALPHACODE_USER" -c "$script"
    rc=$?
    rm -f "$script"
    return $rc
  fi
}

# ── cloudflared provisioning: standalone static binary from Cloudflare ──────
ensure_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    ok "cloudflared present ($(cloudflared --version 2>&1 | awk '{print $3}'))"
    return 0
  fi
  local carch tmp
  case "$(uname -m)" in
    x86_64|amd64)  carch="amd64" ;;
    aarch64|arm64) carch="arm64" ;;
    *) die "unsupported architecture for cloudflared: $(uname -m)" ;;
  esac
  log "cloudflared not found — provisioning standalone binary (${carch})"
  tmp="$(mktemp /tmp/cloudflared.XXXXXX)"
  dlp "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${carch}" \
      "$tmp" "fetching cloudflared-linux-${carch}" \
    || { rm -f "$tmp"; die "cloudflared download failed"; }
  install -m 755 "$tmp" /usr/local/bin/cloudflared
  rm -f "$tmp"
  ok "cloudflared $(cloudflared --version 2>&1 | awk '{print $3}') installed to /usr/local/bin"
}


fetch_raw() { # $1 = path in repo, $2 = destination, $3 = octal mode
  dl "https://raw.githubusercontent.com/${REPO_SLUG}/${REF}/$1" "$2" \
    || die "download failed: $1 (ref ${REF}) — check --repo/--ref or network"
  chmod "$3" "$2"
}

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
  cat <<'USAGE'
install.sh — AlphaCode Web: premier one-line installer

Usage:
  sudo bash install.sh [OPTIONS]

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
  --verify                 End-to-end sanity check (services, HTTP, harness socket)
  --uninstall              Remove created services/files/user; never host binaries/packages
  -h|--help                Show this help

Modes:
  loopback      Bind 127.0.0.1. Pair with a reverse proxy or a named tunnel.
  direct-ip     Bind 0.0.0.0 and open the port in UFW. Plain-HTTP access:
                http://<SERVER_IP>:<PORT>/?token=<TOKEN>
  quick-tunnel  Bind 127.0.0.1 and run a Cloudflare quick tunnel, giving an
                instant https://*.trycloudflare.com URL with no account.
                cloudflared is provisioned automatically if missing.

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
    --verify)        DO_VERIFY="yes"; shift ;;
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

# ── --uninstall ─────────────────────────────────────────────────────────────
if [[ "$DO_UNINSTALL" == "yes" ]]; then
  log "Uninstalling AlphaCode web deployment"
  systemctl disable --now alphacode-web.service alphacode-api-bridge.service \
      alphacode-daemon.service alphacode-tunnel.service 2>/dev/null || true
  rm -f /etc/systemd/system/alphacode-web.service \
        /etc/systemd/system/alphacode-api-bridge.service \
        /etc/systemd/system/alphacode-daemon.service \
        /etc/systemd/system/alphacode-tunnel.service \
        "$WEB_CONF" "$HELPER" "$TUNNEL_HELPER" "$VERIFY_HELPER"
  ufw delete allow "${PORT}/tcp" >/dev/null 2>&1 || true
  systemctl daemon-reload
  if id -u "$ALPHACODE_USER" >/dev/null 2>&1; then
    userdel -r "$ALPHACODE_USER" 2>/dev/null || warn "could not remove user home"
  fi
  ok "uninstalled"
  ok "left untouched: host binaries (/usr/local/bin, /usr/bin), apt packages, cloudflared"
  exit 0
fi

# ── --verify: end-to-end sanity check ───────────────────────────────────────
if [[ "$DO_VERIFY" == "yes" ]]; then
  fail=0
  echo "AlphaCode deployment verification"
  echo "  --- services ---"
  for svc in alphacode-daemon alphacode-api-bridge alphacode-web; do
    st="$(systemctl is-active "$svc.service" 2>/dev/null || true)"
    printf '  %-24s %s\n' "$svc" "$st"
    [[ "$st" == "active" ]] || fail=1
  done
  echo "  --- binary ---"
  BV="$("$ALPHACODE_HOME/.local/bin/alphacode" --version 2>/dev/null || echo missing)"
  printf '  %-24s %s\n' "alphacode" "$BV"
  [[ "$BV" != "missing" ]] || fail=1
  echo "  --- bridge ---"
  VPORT="$(sed -n 's/^BRIDGE_PORT=//p' "$WEB_CONF" 2>/dev/null | head -1)"
  VPORT="${VPORT:-$PORT}"
  VCODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${VPORT}/healthz" 2>/dev/null || echo 000)"
  printf '  %-24s %s\n' "/healthz" "$VCODE"
  [[ "$VCODE" == "200" ]] || fail=1
  echo "  --- harness socket ---"
  if command -v sudo >/dev/null 2>&1; then
    hs="$(sudo -u "$ALPHACODE_USER" python3 "${ALPHACODE_HOME}/web/harness_probe.py" 2>&1 | tail -1)"
  else
    hs="$(runuser -u "$ALPHACODE_USER" -- python3 "${ALPHACODE_HOME}/web/harness_probe.py" 2>&1 | tail -1)"
  fi
  printf '  %-24s %s\n' "alphacode-api.sock" "$hs"
  [[ "$hs" == "hello_ok" ]] || fail=1
  echo
  if [[ $fail -eq 0 ]]; then
    echo "RESULT: healthy"
    TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
    [[ -n "$TOKEN" ]] && printf 'Access URL: http://127.0.0.1:%s/?token=%s\n' "$VPORT" "$TOKEN"
    exit 0
  fi
  echo "RESULT: problems detected (see above)"
  exit 1
fi

# ── Binary detection helpers (pure, read-only; used by profiling + step 2) ──
BIN="${ALPHACODE_HOME}/.local/bin/alphacode"
binary_healthy() {
  [[ -x "$1" ]] || return 1
  "$1" --version >/dev/null 2>&1 || return 1
  return 0
}
# Any healthy alphacode on the system, destination included.
detect_any_binary() {
  local cand invoker_home
  invoker_home="$(getent passwd "${SUDO_USER:-}" 2>/dev/null | cut -d: -f6 || true)"
  for cand in \
      "${invoker_home:+${invoker_home}/.local/bin/alphacode}" \
      "$BIN" \
      /usr/local/bin/alphacode \
      /usr/bin/alphacode \
      /opt/alphacode/bin/alphacode \
      "$(command -v alphacode 2>/dev/null || true)"; do
    [[ -n "$cand" ]] || continue
    if binary_healthy "$cand"; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}
# Healthy system binary EXCLUDING the destination (an adoption candidate).
find_existing_binary() {
  local cand invoker_home
  invoker_home="$(getent passwd "${SUDO_USER:-}" 2>/dev/null | cut -d: -f6 || true)"
  for cand in \
      "$(command -v alphacode 2>/dev/null || true)" \
      /usr/local/bin/alphacode \
      /usr/bin/alphacode \
      /opt/alphacode/bin/alphacode \
      "${invoker_home:+${invoker_home}/.local/bin/alphacode}"; do
    [[ -n "$cand" && "$cand" != "$BIN" ]] || continue
    if binary_healthy "$cand"; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

# ════════════════════════════════════════════════════════════════════════════
#  Banner
# ════════════════════════════════════════════════════════════════════════════
printf '\n'
card "AlphaCode Web Installer"
card_line "version"  "installer ${INSTALLER_VER} | agent ${VERSION}"
card_line "command"  "one-line curl | bash | idempotent"
card_close

# ════════════════════════════════════════════════════════════════════════════
#  [1/6] System Profiling
# ════════════════════════════════════════════════════════════════════════════
step "System Profiling"

HOSTN="$(hostname 2>/dev/null || echo '?')"
OS_PRETTY="$(grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2)"
OS_PRETTY="${OS_PRETTY:-unknown}"
KERNEL="$(uname -r)"
ARCH="$(uname -m)"
CORES="$(nproc 2>/dev/null || echo '?')"
CPU_MODEL="$(awk -F': ' '/model name|Model/ {print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/ *$//')"
CPU_MODEL="${CPU_MODEL:-${ARCH}}"
MEM_TOTAL_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
MEM_AVAIL_KB="$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
MEM_TOTAL="$(awk -v k="$MEM_TOTAL_KB" 'BEGIN {printf "%.1f GiB", k/1048576}')"
MEM_USED="$(awk -v t="$MEM_TOTAL_KB" -v a="$MEM_AVAIL_KB" 'BEGIN {printf "%.1f GiB", (t-a)/1048576}')"
DISK_SRC="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $1}')"
read -r DISK_TOTAL DISK_AVAIL <<<"$(df -Pk / 2>/dev/null | awk 'NR==2 {printf "%d %d", $2/1048576, $4/1048576}')"
PY_VER="$(python3 --version 2>/dev/null | awk '{print $2}')"

DETECT="not found (clean install)"
DETECT_SRC="$(detect_any_binary | head -1 || true)"
if [[ -n "${DETECT_SRC:-}" ]]; then
  DETECT="${DETECT_SRC} => will adopt ($("${DETECT_SRC}" --version 2>/dev/null | head -1))"
fi

card "System Profile"
card_line "hostname"  "$HOSTN"
card_line "os"        "$OS_PRETTY"
card_line "kernel"    "$KERNEL"
card_line "cpu"       "${CPU_MODEL} (${ARCH}, ${CORES} threads)"
card_line "memory"    "used ${MEM_USED:-?} / total ${MEM_TOTAL:-?}"
card_line "disk /"    "${DISK_SRC:-?}: ${DISK_AVAIL:-?} GiB free of ${DISK_TOTAL:-?} GiB"
card_line "python"    "${PY_VER:-not present (installed in step 4)}"
card_line "alphacode" "$DETECT"
card_line "mode"      "$MODE, port ${PORT}"
card_close

# ════════════════════════════════════════════════════════════════════════════
#  [2/6] Binary Resolution & Adoption
# ════════════════════════════════════════════════════════════════════════════
step "Binary Resolution & Adoption"

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  spin_start "installing download tooling (curl)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq curl ca-certificates >/dev/null 2>&1 || die "could not install curl"
  spin_stop
fi
spin_start "ensuring binary runtime dependencies"
export DEBIAN_FRONTEND=noninteractive
NEED=()
for p in libxkbcommon0 tar xxd; do
  dpkg -s "$p" >/dev/null 2>&1 || NEED+=("$p")
done
if [[ ${#NEED[@]} -gt 0 ]]; then
  apt-get install -y -qq "${NEED[@]}" >/dev/null 2>&1 || die "apt install failed: ${NEED[*]}"
  spin_stop
  ok "installed: ${NEED[*]}"
else
  spin_stop
  ok "runtime dependencies present"
fi

# Step 2 only RESOLVES the binary (as root — the runner user does not exist yet);
# step 3 performs the owned installation into ~/.local/bin once the user exists.
STAGE_SRC=""
STAGE_TMP=""
if [[ "$FORCE" == "no" ]] && binary_healthy "$BIN"; then
  ok "already at $("$BIN" --version 2>/dev/null || echo "$VERSION")"
else
  ADOPT_SRC="$(find_existing_binary || true)"
  if [[ -n "$ADOPT_SRC" ]]; then
    # ── Adoption: reuse the healthy system binary; never re-download ──
    STAGE_SRC="$ADOPT_SRC"
    ok "Detected existing working AlphaCode: ${ADOPT_SRC} (adopting in step 3)"
  else
    # ── Direct archive ingestion: release tarball + SHA-256, no upstream pipe ──
    case "$(uname -m)" in
      x86_64|amd64)  ASSET="alphacode-linux-x86_64.tar.gz" ;;
      aarch64|arm64) ASSET="alphacode-linux-arm64.tar.gz" ;;
      *) die "unsupported architecture: $(uname -m) (need x86_64 or aarch64)" ;;
    esac
    REL_URL="https://github.com/dragonked2/alphacode/releases/download/${VERSION}"
    TMPD="$(mktemp -d /tmp/alphacode-dl.XXXXXX)"
    dlp "${REL_URL}/${ASSET}" "${TMPD}/${ASSET}" "fetching ${ASSET}" \
      || { rm -rf "$TMPD"; die "release archive download failed"; }
    dl "${REL_URL}/SHA256SUMS" "${TMPD}/SHA256SUMS" || { rm -rf "$TMPD"; die "checksum list download failed"; }
    EXPECTED="$(grep -E "[[:space:]]${ASSET}\$" "${TMPD}/SHA256SUMS" | awk '{print $1}' | head -1)"
    [[ -n "$EXPECTED" ]] || { rm -rf "$TMPD"; die "no checksum entry for ${ASSET} in SHA256SUMS"; }
    printf '%s  %s\n' "$EXPECTED" "${TMPD}/${ASSET}" | sha256sum -c - >/dev/null 2>&1 \
      || { rm -rf "$TMPD"; die "SHA-256 verification failed for ${ASSET} — aborting"; }
    ok "checksum verified"
    tar -xzf "${TMPD}/${ASSET}" -C "$TMPD"
    NEWBIN="$(find "$TMPD" -maxdepth 3 -type f -name alphacode | head -1)"
    [[ -n "$NEWBIN" ]] || { rm -rf "$TMPD"; die "archive did not contain an alphacode binary"; }
    STAGE_SRC="$NEWBIN"
    STAGE_TMP="$TMPD"
    ok "resolved ${VERSION} from release archive (no upstream scripts executed)"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
#  [3/6] Sandboxed User & Security Boundary
# ════════════════════════════════════════════════════════════════════════════
step "Sandboxed User & Security Boundary"

if id -u "$ALPHACODE_USER" >/dev/null 2>&1; then
  ok "user ${ALPHACODE_USER} exists (uid $(id -u "$ALPHACODE_USER"), unprivileged)"
else
  useradd -r -m -d "$ALPHACODE_HOME" -s /bin/bash "$ALPHACODE_USER"
  ok "created uid $(id -u "$ALPHACODE_USER") — no sudo, no root group"
fi
install -d -o "$ALPHACODE_USER" -g "$ALPHACODE_USER" -m 700 "$RUNTIME_DIR"
install -d -o "$ALPHACODE_USER" -g "$ALPHACODE_USER" -m 755 "$WEB_DIR" "$STATIC_DIR"
install -d -o "$ALPHACODE_USER" -g "$ALPHACODE_USER" -m 755 "${ALPHACODE_HOME}/workspace"
install -d -o "$ALPHACODE_USER" -g "$ALPHACODE_USER" -m 700 "$CONFIG_DIR"
ok "home, runtime, config and workspace boundaries established"

if [[ -n "${STAGE_SRC:-}" ]]; then
  mkdir -p "$(dirname "$BIN")"
  chown "$ALPHACODE_USER:$ALPHACODE_USER" "$(dirname "$BIN")"
  install -m 755 -o "$ALPHACODE_USER" -g "$ALPHACODE_USER" "$STAGE_SRC" "$BIN"
  if [[ -n "${STAGE_TMP:-}" ]]; then
    rm -rf "$STAGE_TMP"
    ok "installed ${VERSION} into ${BIN} (checksum-verified release archive)"
  else
    printf '%s\n' "$STAGE_SRC" > "${RUNTIME_DIR}/.adopted_from"
    chown "$ALPHACODE_USER:$ALPHACODE_USER" "${RUNTIME_DIR}/.adopted_from"
    ok "adopted -> ${BIN} (from $("$BIN" --version 2>/dev/null || echo "?"))"
  fi
fi
binary_healthy "$BIN" || die "binary at $BIN is not healthy after install"
ok "AlphaCode ready: $("$BIN" --version 2>/dev/null || echo "$VERSION")"

# ════════════════════════════════════════════════════════════════════════════
#  [4/6] Web Bridge & Python Environment
# ════════════════════════════════════════════════════════════════════════════
step "Web Bridge & Python Environment"

if [[ ! -f "$CONFIG_TOML" || "$FORCE" == "yes" ]]; then
  cat > "$CONFIG_TOML" <<'EOF'
# AlphaCode configuration (managed by install.sh)
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

spin_start "fetching web bridge and UI (${REPO_SLUG}@${REF})"
fetch_raw "src/bridge.py"        "${WEB_DIR}/bridge.py"        600
fetch_raw "src/static/index.html" "${STATIC_DIR}/index.html"   644
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
spin_stop
ok "bridge.py + index.html + probe deployed"

if [[ ! -x "${VENV_DIR}/bin/python" || "$FORCE" == "yes" ]]; then
  spin_start "creating python venv"
  if ! command -v python3 >/dev/null 2>&1; then
    apt-get install -y -qq python3 >/dev/null 2>&1 || die "python3 install failed"
  fi
  dpkg -s python3-venv >/dev/null 2>&1 || apt-get install -y -qq python3-venv >/dev/null 2>&1 \
    || die "python3-venv install failed"
  as_user python3 -m venv "$VENV_DIR"
  spin_stop
  ok "venv created at ${VENV_DIR}"
fi
spin_start "installing websockets into venv"
if ! "${VENV_DIR}/bin/python" -c 'import websockets' >/dev/null 2>&1; then
  as_user "${VENV_DIR}/bin/pip" install -q --upgrade pip >/dev/null
  as_user "${VENV_DIR}/bin/pip" install -q 'websockets>=14,<17'
fi
spin_stop
ok "websockets $("${VENV_DIR}/bin/python" -c 'import websockets;print(websockets.__version__)')"

if [[ ! -s "$TOKEN_FILE" || "$FORCE" == "yes" ]]; then
  dd if=/dev/urandom bs=32 count=1 2>/dev/null | xxd -p -c 256 | tr -d '\n' > "$TOKEN_FILE"
  chown "$ALPHACODE_USER:$ALPHACODE_USER" "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  ok "generated new web token"
else
  ok "existing web token preserved"
fi
TOKEN="$(cat "$TOKEN_FILE")"

if [[ "$MODE" == "direct-ip" ]]; then BIND="0.0.0.0"; else BIND="127.0.0.1"; fi
cat > "$WEB_CONF" <<EOF
# AlphaCode Web Bridge configuration (managed by install.sh)
BRIDGE_HOST=${BIND}
BRIDGE_PORT=${PORT}
EOF
chmod 644 "$WEB_CONF"
ok "bridge config: BRIDGE_HOST=${BIND} BRIDGE_PORT=${PORT}"

if [[ -n "$BASE_URL" && -n "$MODEL" ]]; then
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

# ════════════════════════════════════════════════════════════════════════════
#  [5/6] Systemd Service Orchestration
# ════════════════════════════════════════════════════════════════════════════
step "Systemd Service Orchestration"

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

# Deterministic units: the venv interpreter must exist before we reference it,
# and every template placeholder must be gone before systemd ever sees the file.
[[ -x "${VENV_DIR}/bin/python" ]] \
  || die "venv interpreter missing at ${VENV_DIR}/bin/python (did venv setup run?)"
sed -i "s|__USER__|${ALPHACODE_USER}|g; s|__HOME__|${ALPHACODE_HOME}|g; \
        s|__WEB__|${WEB_DIR}|g; s|__VENV__|${VENV_DIR}|g; \
        s|__WEBCONF__|${WEB_CONF}|g" \
  /etc/systemd/system/alphacode-daemon.service \
  /etc/systemd/system/alphacode-api-bridge.service \
  /etc/systemd/system/alphacode-web.service

for unit in /etc/systemd/system/alphacode-daemon.service \
            /etc/systemd/system/alphacode-api-bridge.service \
            /etc/systemd/system/alphacode-web.service; do
  if grep -Eq '__[A-Z_]+__|\{\{[A-Za-z_]+\}\}' "$unit"; then
    LEFTOVER="$(grep -Eo '__[A-Z_]+__|\{\{[A-Za-z_]+\}\}' "$unit" | tr '\n' ' ')"
    die "unsubstituted template placeholder(s) in $unit: $LEFTOVER — refusing to install a unit systemd would reject"
  fi
  grep -q '^UMask=0077$' "$unit" \
    || die "$unit is missing UMask=0077 (required for 0600 socket creation)"
done
ok "units substituted and validated (no template placeholders, UMask=0077 present)"

CLOUDFLARED_BIN=""
if [[ "$MODE" == "quick-tunnel" ]]; then
  ensure_cloudflared
  CLOUDFLARED_BIN="$(command -v cloudflared)"
  [[ -n "$CLOUDFLARED_BIN" ]] || die "cloudflared resolved to an empty path"
  cat > /etc/systemd/system/alphacode-tunnel.service <<EOF
[Unit]
Description=AlphaCode Cloudflare Quick Tunnel
After=alphacode-web.service
Requires=alphacode-web.service

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} tunnel --config /dev/null --url http://127.0.0.1:${PORT} --no-autoupdate
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
ok "daemon-reload complete"

spin_start "starting service chain (daemon → api-bridge → web)"
systemctl enable alphacode-daemon.service >/dev/null 2>&1
systemctl restart alphacode-daemon.service
sleep 3
systemctl enable alphacode-api-bridge.service >/dev/null 2>&1
systemctl restart alphacode-api-bridge.service
sleep 2
systemctl enable alphacode-web.service >/dev/null 2>&1
systemctl restart alphacode-web.service
sleep 2
FAILED=()
for svc in alphacode-daemon alphacode-api-bridge alphacode-web; do
  systemctl is-active --quiet "$svc.service" || FAILED+=("$svc")
done
spin_stop
[[ ${#FAILED[@]} -eq 0 ]] || die "services not running: ${FAILED[*]}
  check: journalctl -u ${FAILED[0]} -n 50"
ok "all three services active"

# ════════════════════════════════════════════════════════════════════════════
#  [6/6] Ingress & In-flight Tunnel Verification
# ════════════════════════════════════════════════════════════════════════════
step "Ingress & In-flight Tunnel Verification"

if [[ "$MODE" == "direct-ip" ]] && command -v ufw >/dev/null 2>&1; then
  ufw allow "${PORT}/tcp" comment 'alphacode-web' >/dev/null 2>&1 || true
  ok "ufw: allowed ${PORT}/tcp"
fi

if [[ "$MODE" == "quick-tunnel" ]]; then
  systemctl enable alphacode-tunnel.service >/dev/null 2>&1 || true
  systemctl restart alphacode-tunnel.service >/dev/null 2>&1 || true

  # In-flight verification: poll the tunnel journal for the public URL (12 s max).
  deadline=$(( $(date +%s) + 12 ))
  if (( TTY )); then
    printf '    '
  else
    printf '    … establishing quick tunnel\n'
  fi
  while :; do
    TUNNEL_URL="$(journalctl -u alphacode-tunnel --no-pager -n 60 2>/dev/null \
      | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
    [[ -n "$TUNNEL_URL" ]] && break
    elapsed=$(( 12 - (deadline - $(date +%s)) ))
    if (( TTY )); then
      printf '\r    %sregistering tunnel… %ds elapsed\e[K' "$YEL" "$elapsed"
      (( $(date +%s) >= deadline )) && { printf '\n'; break; }
      sleep 0.5
    else
      (( $(date +%s) >= deadline )) && break
      sleep 0.5
    fi
  done
  if [[ -n "$TUNNEL_URL" ]]; then
    (( TTY )) && printf '\r    \e[K\r'
    ok "tunnel live: ${TUNNEL_URL}"
  else
    (( TTY )) && printf '\r    \e[K\r'
    warn "tunnel URL not observed within 12 s — it may still be registering"
    warn "check: journalctl -u alphacode-tunnel -f   or: alphacode-tunnel"
  fi
fi

# ── helper commands (sed-based config parsing: no PCRE escaping hazards) ────
cat > "$HELPER" <<EOF
#!/usr/bin/env bash
# Print the AlphaCode web-chat access URL and service status.
TOKEN="\$(cat ${TOKEN_FILE} 2>/dev/null)"
PORT="\$(sed -n 's/^BRIDGE_PORT=//p' ${WEB_CONF} 2>/dev/null | head -1)"
PORT="\${PORT:-${PORT}}"
HOST="\$(sed -n 's/^BRIDGE_HOST=//p' ${WEB_CONF} 2>/dev/null | head -1)"
HOST="\${HOST:-127.0.0.1}"
echo "AlphaCode web chat"
echo "  services: \$(systemctl is-active alphacode-daemon alphacode-api-bridge alphacode-web | tr '\n' ' ')"
if [[ "\$HOST" == "0.0.0.0" ]]; then
  IP="\$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if(\$i=="src") print \$(i+1)}' | head -1)"
  echo "  direct:   http://\${IP:-<SERVER_IP>}:\${PORT}/?token=\${TOKEN}"
else
  if [[ -f /etc/systemd/system/alphacode-tunnel.service ]]; then
    QURL="\$(journalctl -u alphacode-tunnel --no-pager -n 300 2>/dev/null | grep -oE 'https://[a-z0-9-]+[.]trycloudflare[.]com' | tail -1)"
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
# Show the current quick-tunnel public URL.
journalctl -u alphacode-tunnel --no-pager -n 300 \
  | grep -oE 'https://[a-z0-9-]+[.]trycloudflare[.]com' | tail -1
EOF
  chmod 755 "$TUNNEL_HELPER"
fi

cat > "$VERIFY_HELPER" <<EOF
#!/usr/bin/env bash
# AlphaCode end-to-end health check.
set -uo pipefail
PORT="\$(sed -n 's/^BRIDGE_PORT=//p' ${WEB_CONF} 2>/dev/null | head -1)"
PORT="\${PORT:-${PORT}}"
fail=0

echo "AlphaCode health check"
echo "  --- services ---"
for s in alphacode-daemon alphacode-api-bridge alphacode-web; do
  st="\$(systemctl is-active \$s.service 2>/dev/null || true)"
  printf '  %-24s %s\n' "\$s" "\$st"
  [[ "\$st" == "active" ]] || fail=1
done

echo "  --- bridge ---"
code="\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:\$PORT/healthz 2>/dev/null || echo 000)"
printf '  %-24s %s\n' "/healthz" "\$code"
[[ "\$code" == "200" ]] || fail=1

echo "  --- harness socket ---"
if [[ "\$(id -u)" -eq 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    RUN_AS="sudo -u ${ALPHACODE_USER}"
  else
    RUN_AS="runuser -u ${ALPHACODE_USER} --"
  fi
  hs="\$(\$RUN_AS ${VENV_DIR}/bin/python ${WEB_DIR}/harness_probe.py 2>&1 | tail -1)"
else
  hs="\$(${VENV_DIR}/bin/python ${WEB_DIR}/harness_probe.py 2>&1 | tail -1)"
fi
printf '  %-24s %s\n' "alphacode-api.sock" "\$hs"
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
ok "helpers installed: alphacode-web · alphacode-verify · alphacode-tunnel"

# Install a copy of this installer for re-use
install -m 755 "$SELF" /usr/local/bin/deploy_alphacode.sh 2>/dev/null || true

# ════════════════════════════════════════════════════════════════════════════
#  Grand Finale
# ════════════════════════════════════════════════════════════════════════════
SERVICES_LINE="$(systemctl is-active alphacode-daemon alphacode-api-bridge alphacode-web 2>/dev/null | tr '\n' ' ')"
case "$MODE" in
  quick-tunnel) MODE_DESC="cloudflare quick tunnel (account-free HTTPS)" ;;
  direct-ip)    MODE_DESC="direct IP over HTTP (token-gated)" ;;
  *)            MODE_DESC="loopback (pair with a reverse proxy or tunnel)" ;;
esac

if [[ -n "$TUNNEL_URL" ]]; then
  URL="${TUNNEL_URL}/?token=${TOKEN}"
elif [[ "$MODE" == "direct-ip" ]]; then
  IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}' | head -1)"
  URL="http://${IP:-<SERVER_IP>}:${PORT}/?token=${TOKEN}"
else
  URL="http://127.0.0.1:${PORT}/?token=${TOKEN}"
fi

printf '\n'
card "AlphaCode Web is live"
card_line "services"  "${SERVICES_LINE:-active active active}"
card_line "mode"      "$MODE_DESC"
card_line "bridge"    "127.0.0.1:${PORT} | 0600 sockets (UMask 0077)"
card_line "user"      "${ALPHACODE_USER} (unprivileged)"
card_close
printf '\n  %bOpen your workspace:%b\n\n' "$B" "$R"
printf '  '; link "$URL" "$URL"
if [[ "$MODE" == "quick-tunnel" ]]; then
  IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}' | head -1)"
  printf '\n  %bdirect-ip alternative:%b rerun with --mode direct-ip to expose\n' "$B" "$R"
  printf '  %bhttp://%s:%s/?token=<TOKEN> over plain HTTP (LAN/public).%b\n' "$GRAY" "${IP:-<SERVER_IP>}" "$PORT" "$R"
fi
printf '\n  %bmanage:%b    alphacode-web      print this summary\n' "$GRAY" "$R"
printf '  %b            alphacode-verify   health check\n' "$GRAY"
if [[ "$MODE" == "quick-tunnel" ]]; then
  printf '  %b            alphacode-tunnel   current tunnel URL\n' "$GRAY"
fi
printf '  %blogs:%b     journalctl -u alphacode-web -f\n\n' "$GRAY" "$R"
