# Changelog

All notable changes to this fork are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/), and this
project uses [Semantic Versioning](https://semver.org/). The base is upstream
`agneswd/dms-ai-quotas` at `222184e` (plugin version `1.9.0`).

## [1.10.0] - 2026-09-26

### Added

- **Ollama Cloud provider**
  - Plan name via `POST https://ollama.com/api/me` (API key; falls back to
    `~/.local/share/opencode/auth.json` `ollama-cloud` entry when no key is set).
  - Monthly included usage (`$used of $limit`) and reset time via a
    session-cookie scrape of `https://ollama.com/settings` — Ollama has no usage
    API (upstream issue ollama/ollama#12532).
  - Popout tab with plan badge, usage bar (turns red at ≥90%), reset
    date/countdown, and a pin button; bar-pill entry showing `$used/$limit`.
  - Settings: provider toggle plus optional *API key* and *Session cookie*
    credential fields, with a full-account-access warning.
  - Robust statuses: `ok`, `plan_only`, `unavailable`, `error` with reasons
    (`network`, `auth_expired`, `access_denied`, `rate_limited`, `http_error`,
    `parse_error`, `usage_requires_cookie`, `not_configured`).
- Tests: `tests/test-ollama.sh` (15 cases) and `tests/test-ollama-edge.sh`
  (8 cases), plus a sanitized HTML fixture; all other provider suites updated
  with an explicit `AIQ_OLLAMA_ENABLED=0` for isolation.
- Packaging: `install.sh` (fresh install / update / patch), `scripts/check.sh`
  local quality gate, `INSTALL.md`, `SECURITY.md`, this changelog.

### Security

- Ollama credentials are CRLF/whitespace-scrubbed before use (header-injection
  defense), and the reset timestamp parser tolerates fractional seconds and
  `+00:00` offsets.
- Fixtures are sanitized; no real credentials or account data are committed.
