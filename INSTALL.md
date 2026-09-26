# Installation

This repository is both a **fresh installation** (the full plugin tree) and a
**patch set** (see `patches/`) on top of upstream
[`agneswd/dms-ai-quotas`](https://github.com/agneswd/dms-ai-quotas) at `222184e`.

Requirements: DankMaterialShell >= 1.5.0, `curl`, `jq`.

## TL;DR

```sh
git clone https://github.com/Orpere/dms-ai-quotas-ollama
cd dms-ai-quotas-ollama
./install.sh
dms restart
```

Then in DMS: **Settings > Plugins > Scan for Plugins** → enable **AI Quotas** →
add the widget in **Settings > DankBar Layout**. Detailed flows below.

---

## A. Fresh installation

### Option 1 — installer script

```sh
git clone https://github.com/Orpere/dms-ai-quotas-ollama
cd dms-ai-quotas-ollama
./install.sh
```

`install.sh` copies the plugin into
`${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/aiQuotas`, backs up
any existing installation first, and never uses `sudo` or the network. Use
`./install.sh --dry-run` to preview, or `./install.sh --target DIR` for a custom
location.

### Option 2 — clone straight into the plugins directory

```sh
git clone https://github.com/Orpere/dms-ai-quotas-ollama \
  "${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/aiQuotas"
```

### Then, in DMS

1. **Settings > Plugins > Scan for Plugins**, enable **AI Quotas**
2. **Settings > DankBar Layout** — add the widget to your bar
3. Restart the shell: `dms restart` (or `systemctl --user restart dms`)

---

## B. Patch an existing upstream checkout

If you already have upstream `dms-ai-quotas` installed (or checked out), apply
the patch instead of reinstalling:

```sh
# with the installer
./install.sh --patch /path/to/dms-ai-quotas

# or manually, from the checkout
git apply /path/to/patches/0001-add-ollama-cloud-provider.patch
```

For non-git directories the installer falls back to `patch -p1`. The patch
applies cleanly to upstream `222184e`; if upstream has moved on, `git apply
--3way` may still work.

After patching, copy the checkout into the DMS plugins directory (or run
`./install.sh` from this repository for a fresh install) and restart DMS.

---

## C. Updating

- **This repository:** `git pull && ./install.sh` (the previous install is
  backed up automatically).
- **Patched checkout:** re-apply newer patches, or switch to a fresh install.

## D. Uninstall / rollback

- Disable the plugin in **Settings > Plugins** (keeps files), or
- Restore a backup made by the installer:

```sh
cd "${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins"
ls -d aiQuotas.bak-*                     # pick the backup you want
rm -rf aiQuotas && mv aiQuotas.bak-<timestamp> aiQuotas
dms restart
```

Removing the plugin does not remove your credentials from
`plugin_settings.json` — clear the fields in the plugin settings or delete the
`aiQuotas` section while DMS is stopped.

---

## E. Ollama Cloud credentials

Both are optional; the card degrades gracefully without them.

| Credential | What it shows | Where to get it |
|---|---|---|
| **API key** | Plan name (e.g. `Pro`) | <https://ollama.com/settings/keys> |
| **Session cookie** (`__Secure-session`) | Monthly included usage (`$used of $limit`) + reset time | Your browser after signing in at ollama.com (see below) |

**Getting the session cookie:** sign in at <https://ollama.com> in your browser,
open the developer tools, find the cookie named `__Secure-session` for host
`ollama.com` (e.g. Application/Storage → Cookies), and copy its value into
*Settings > Plugins > AI Quotas > Credentials*.

> **Warning:** this cookie grants **full account access** (API keys, billing,
> settings) and is stored in plain text in `plugin_settings.json` like the
> other provider keys. Read [SECURITY.md](SECURITY.md) before using it, keep the
> file mode `600`, and sign out of ollama.com when you want to revoke it.

**Note for DMS users:** `plugin_settings.json` is owned by DMS and rewritten
from memory. If you edit it manually, stop DMS first
(`systemctl --user stop dms`), edit, then start it again.

---

## F. Troubleshooting

| Symptom | Fix |
|---|---|
| Tab shows "not configured" | Add an API key and/or session cookie (section E) |
| "usage requires a session cookie" | Paste a fresh `__Secure-session` value |
| "session expired" | Sign in again and re-paste the cookie |
| Stale numbers | Data is cached for 55 s at `~/.cache/dms-ai-quotas/usage.json`; delete it to force a refresh |
| Plugin not listed | `dms restart`, then **Scan for Plugins** again |
| No QML errors visible | Check `journalctl --user -u dms` |

## G. Development checks

```sh
./scripts/check.sh
```

Runs `sh -n`, `shellcheck`, manifest validation, and the full test suite
locally. There is intentionally no GitHub Actions workflow (zero-cost policy —
see [CONTRIBUTING.md](CONTRIBUTING.md)).
