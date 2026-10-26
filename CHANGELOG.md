# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is SemVer.

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
