# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is SemVer.

## [1.1.0] - 2026-10-26

### Added
- **Engine parity in the Web UI** (deep integration with the AlphaCode daemon):
  - **Model & provider switcher** — click the model pill to open a searchable modal fed
    live by the daemon's model catalog (`get_model_catalog`): every route with its
    provider, API method, availability, and price hints; unavailable routes grouped with
    the daemon's own reason ("no credentials", ...). Switching issues `set_model` and
    confirms on the daemon's `model_changed` event.
  - **Reasoning-effort selector** — none / low / medium / high pill backed by
    `set_reasoning_effort` (`reasoning_effort_changed` confirmation).
  - **Engine inspector** — one panel with session state (`state`: message count,
    processing flag), live token telemetry, catalog stats, environment inventory
    (workspace, config settings, provider profile NAMES — credentials are never read),
    and the tools observed this session with call counts, statuses and durations.
  - **Session rename & archive** from the UI (`rename_session`); archive renames to
    `archived · <title>`. Rename buttons also live on sidebar items.
  - **Live token counters** — input/output/cache totals from the daemon's token stream,
    shown next to the context meter.
  - **Tool timing** — per-call duration in the tool badge (`done · 0.3s`).
- **Installer CLI visual overhaul** (`install.sh`):
  - Width-true bordered cards: fixed 60-column interior, left AND right borders on every
    row, values truncated to fit, ANSI-escape-aware padding — identical geometry in the
    ASCII fallback. No more broken pipes or stray boundary glyphs on Windows Terminal,
    Termius or mobile SSH clients.
  - Deeper system profiling: CPU model + architecture + thread count, memory
    used/total, root-disk device with capacity and free space.
  - Quick-tunnel finale now also shows the Direct-IP alternative with the detected
    server IP, so both access paths are visible in every mode.
  - Removed the locale-fragile emoji from progress output; all card row text is ASCII
    by construction.

### Fixed
- **Bridge stream limit**: the model-catalog reply is a single NDJSON line far beyond
  asyncio's 64 KiB default; the engine read loop died on first catalog fetch ("Separator
  is found, but chunk is longer than limit") and closed the client socket. Both socket
  readers now run with a 16 MiB limit.
- Engine reply matching: `model_changed` / `session_renamed` are both daemon replies and
  unsolicited pushes — reply matching now takes precedence over push mirroring, and the
  rename paths update the sidebar immediately instead of waiting for the next poll.
- `scripts/deploy_alphacode.sh` (offline variant) regenerated with the new bridge + UI;
  embedded copies verified byte-identical to `src/`.

## [1.0.2] - 2026-10-26

### Added
- **Premier CLI installation experience** (pure Bash, zero external UI dependencies):
  - System capability card before any mutation: hostname, OS, kernel, CPU/cores,
    memory, root-disk free space, Python runtime, and existing-AlphaCode detection
    (adoption candidate shown with its version).
  - Six named phases (`[1/6] System Profiling` … `[6/6] Ingress & In-flight Tunnel
    Verification`), a block-character progress bar with live byte-count percentage
    for large downloads, ASCII spinner frames for unbounded waits, bordered summary
    cards, and an OSC 8 clickable access URL in the finale.
  - Graceful degradation: non-TTY, `NO_COLOR`, and `TERM=dumb` runs render plain
    ASCII logging; box glyphs additionally require a UTF-8 charset (they use
    hard-coded byte escapes — `$'\uXXXX'` is locale-dependent and emits literal
    text on locale-less systems, which broke minimal containers).
- **Automatic cloudflared provisioning**: when `--mode quick-tunnel` is active and
  `cloudflared` is absent, the installer downloads the official standalone binary
  for the detected architecture directly from Cloudflare's releases (with the
  progress bar) and installs it to `/usr/local/bin/cloudflared`. The generated
  systemd unit embeds the resolved binary path (previously hard-coded
  `/usr/bin/cloudflared`, which broke self-provisioned installs).
- **Live tunnel polling**: the installer waits up to 12 s for the quick tunnel to
  register, showing elapsed time in place, and prints the resulting
  `https://*.trycloudflare.com` URL directly in the finale when observed.

### Fixed
- Palette variables were unassigned on non-TTY runs after the charset refactor,
  crashing piped installs with `SLATE: unbound variable` under `set -u`.
- Step ordering dependency: the binary install referenced the runner user before
  step 3 created it; binary resolution now stages as root and the owned
  installation happens after user provisioning.

## [1.0.1] - 2026-10-26

### Fixed
- **Installer self-recursion**: the `as_user` fallback helper's sudo branch called itself
  instead of `sudo -u`, recursing unboundedly through sudo→bash on every host with sudo
  installed (observed as a bash segfault during the binary-setup phase). Root cause of the
  reported "segfault on modern kernels"; the kernel version was not a factor.
- **Nested upstream installer removed**: AlphaCode is no longer installed by piping
  upstream scripts through `su`/`runuser` subshells.
- **Blind re-install**: the installer now detects and adopts a healthy pre-existing
  `alphacode` from `PATH`, `/usr/local/bin`, `/usr/bin`, `/opt/alphacode/bin`, or the
  invoking user's `~/.local/bin` instead of overwriting it.
- **Unit-template leakage**: `systemd/` templates shipped raw `__USER__`-style
  placeholders; `install.sh` now validates that no placeholder (`__X__` or `{{x}}`)
  survives substitution and that every unit carries `UMask=0077` before writing to
  `/etc/systemd/system/`, and asserts the venv interpreter exists first.

### Added
- `install.sh --verify` — end-to-end sanity check (services, binary version, `/healthz`,
  harness socket handshake) printing the access URL on success.
- Direct archive ingestion: on a clean host the installer downloads the release tarball
  for the detected architecture (x86_64/aarch64) with `curl` or `wget` and verifies
  SHA-256 against the release `SHA256SUMS`.
- Adoption provenance marker at `~/.alphacode/.adopted_from`.

## [1.0.0] - 2026-10-26

First public release.

### Added
- Python asyncio bridge (`src/bridge.py`): authenticated WebSocket ⇄ Unix-socket NDJSON
  relay with static UI serving, `/healthz`, malformed-frame rejection, and graceful
  daemon-restart recovery.
- Single-file chat UI (`src/static/index.html`, zero dependencies):
  - streaming markdown renderer (headings, lists, tables, blockquotes, links, inline code)
  - lightweight syntax highlighter for bash, python, javascript/typescript, rust, go, c, sql, json
  - code blocks with language badge, macOS-style window controls, one-click copy
  - thinking mode: live reasoning stream with shimmer + elapsed timer, auto-collapsing accordion
  - tool execution cards: live argument streaming, running/done/error badges, collapsible output
  - slash-command palette with fuzzy autocomplete
  - session drawer (mobile) / sidebar (desktop), context-usage meter, connection + model pills
  - dark theme by default with light-mode support, CSS-only animations (`prefers-reduced-motion` aware)
- Idempotent installer (`install.sh`): user provisioning, pinned AlphaCode binary with
  SHA-256 verification, Python venv, three hardened systemd units with dependency ordering,
  token generation, provider-profile setup, and helper commands
  (`alphacode-web`, `alphacode-verify`, `alphacode-tunnel`).
- Three access modes: `loopback`, `direct-ip`, `quick-tunnel` (account-free HTTPS).
- Offline installer variant (`scripts/deploy_alphacode.sh`, files embedded).
- Diagnostics: `scripts/harness_probe.py`, `scripts/ws_test.py`.

### Fixed
- Static routes matched the full request target including the query string, so any
  token-bearing URL (`/?token=…`) returned 404 while a bare `/` worked. Paths are now
  split from the query before routing.
- Cloudflare quick tunnels inherited the host's named-tunnel config (catch-all
  `http_status:404`) and answered Cloudflare's own empty 404 for every path.
  Quick tunnels now run with `--config /dev/null`.
- The installer no longer hard-depends on `sudo`; it falls back to `runuser`, then `su`.
