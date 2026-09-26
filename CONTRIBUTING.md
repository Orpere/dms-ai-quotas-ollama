# Contributing

Thanks for taking a look. This repository is a fork of
[`agneswd/dms-ai-quotas`](https://github.com/agneswd/dms-ai-quotas); the
provider framework belongs upstream, so please consider sending generic fixes
(e.g. new providers, parser improvements) to the upstream project as well.

## Ground rules

- **Never commit credentials, tokens, cookies, or captured account pages.**
  Use mocks and sanitized fixtures only (see `tests/fixtures/`, which contains
  placeholder data). Scan your changes before pushing.
- Keep the runtime dependency surface at `curl` + `jq` + POSIX `sh`.
- Follow the existing provider patterns in `fetch-usage.sh` and
  `AiQuotasWidget.qml`.

## Local checks

```sh
./scripts/check.sh
```

This runs shell syntax checks, `shellcheck` (production scripts must be
clean), plugin manifest validation, and the full test suite.

There is intentionally **no GitHub Actions workflow**: this project avoids
GitHub's metered/usage-billed features (including private-repo CI minutes).
Run the checks locally before pushing.

## Adding a provider

1. Add the fetch block in `fetch-usage.sh` with an `AIQ_<PROVIDER>_ENABLED` env
   switch, explicit error reasons, and a merged JSON key.
2. Wire the daemon (`AiQuotasDaemon.qml`): settings properties, env vars, and
   `fetchSignature()`.
3. Add settings fields (`AiQuotasSettings.qml`) and the widget tab/card/pill
   (`AiQuotasWidget.qml`).
4. Add a test in `tests/` modeled on the existing scripts (mock `curl`, no
   network, no real credentials).
5. Update `README.md` and `CHANGELOG.md`.
