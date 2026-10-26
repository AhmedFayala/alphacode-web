# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is SemVer.

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
