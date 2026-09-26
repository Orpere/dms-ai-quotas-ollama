# Security

## Credentials this plugin can hold

| Credential | Used for | Power |
|---|---|---|
| Ollama Cloud API key | `POST https://ollama.com/api/me` (plan name) | Model access for your Ollama account |
| Ollama Cloud session cookie (`__Secure-session`) | Scraping `https://ollama.com/settings` (monthly usage) | **Full account access** — API keys, billing, account settings |
| DeepSeek / OpenRouter / OpenCode keys | Their respective balance/usage APIs (upstream features) | Provider-scoped API access |

## Where credentials live

- **DMS plugin settings** — `${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugin_settings.json`. DMS creates it with mode `600`; verify with `stat -c '%a'`.
- **Never anywhere else.** `fetch-usage.sh` receives credentials as environment
  variables from the DMS daemon; it does not write them to disk.
- **Cache** — `~/.cache/dms-ai-quotas/usage.json` (mode `600`) contains usage
  numbers only, never credentials.
- **Logs/errors** — scripts never print keys or cookies; error strings contain
  only HTTP status codes and human-readable hints.

## Network behavior

- Only documented provider endpoints are contacted, including
  `https://ollama.com/api/me` and `https://ollama.com/settings` for Ollama Cloud.
- TLS verification is always on (no `curl -k`), with 10–20 s timeouts.
- No telemetry, analytics, or third-party hosts.

## Hardening in this fork

- Ollama API key and session cookie are stripped of CR/LF and surrounding
  whitespace before use — prevents header injection from a tampered settings file.
- Session cookie input is normalized (`__Secure-session=` prefix and `;` suffixes
  accepted, whitespace/CRLF removed).
- Usage values are validated as numbers before being emitted as JSON.
- Reset timestamps tolerate common ISO-8601 variants.
- Tests use mocks and sanitized fixtures only — no real credentials or captured
  account data are committed.

## Recommendations

- Prefer the **API key** when you only need the plan; use the session cookie only
  if you want the monthly usage meter and accept its blast radius.
- Treat the cookie like a password: keep `plugin_settings.json` mode `600`,
  never commit or sync it, never paste it into issues or chat.
- Revoke access by signing out of ollama.com (invalidates the cookie) and/or
  rotating the API key at <https://ollama.com/settings/keys>.
- Remove stored credentials via *Settings > Plugins > AI Quotas > Credentials*
  (or edit the file while DMS is stopped).

## Reporting a vulnerability

Use this repository's **Security → Advisories → Report a vulnerability**
(private channel). Please do not open public issues for security reports.
