#!/bin/sh
# AI Quotas (Ollama Cloud edition) — installer / updater / patcher.
#
# Fresh install or update into the DMS plugins directory:
#   ./install.sh
#   ./install.sh --target /path/to/plugins/aiQuotas
#   ./install.sh --dry-run
#
# Apply patches/*.patch to an existing upstream checkout:
#   ./install.sh --patch /path/to/dms-ai-quotas
#
# POSIX sh. No sudo, no network access, no downloads.
# See INSTALL.md for the full guide, SECURITY.md for credential handling.
set -eu

usage() {
    cat <<'EOF'
Usage: ./install.sh [--target DIR] [--patch DIR] [--dry-run] [--help]

Modes:
  (default)      Install or update this tree into the DankMaterialShell plugins
                 directory (default:
                 ${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/aiQuotas).
                 An existing installation is backed up to <target>.bak-<timestamp>.
  --target DIR   Install into DIR instead of the default plugins path.
  --patch DIR    Apply patches/*.patch to an existing upstream checkout at DIR
                 (git apply in git checkouts, patch -p1 otherwise).
  --dry-run      Print what would happen without changing anything.
  --help         Show this help.

The installer never uses sudo and never downloads anything.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }
run() {
    if [ "$dry_run" = "1" ]; then
        printf '  [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

unset CDPATH
repo_root=$(cd -- "$(dirname -- "$0")" && pwd)
target="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/aiQuotas"
patch_dir=""
dry_run=0

while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            [ $# -ge 2 ] || die "--target requires a directory"
            target=$2
            shift 2
            ;;
        --patch)
            [ $# -ge 2 ] || die "--patch requires a directory"
            patch_dir=$2
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1 (try --help)"
            ;;
    esac
done

[ "$(id -u)" = "0" ] && die "run this as your desktop user, not root (DMS plugins are per-user)"

# ---------------------------------------------------------------- patch mode
if [ -n "$patch_dir" ]; then
    [ -d "$patch_dir" ] || die "patch target is not a directory: $patch_dir"
    found=0
    for p in "$repo_root"/patches/*.patch; do
        [ -f "$p" ] || continue
        found=1
        note "Applying $(basename -- "$p") to $patch_dir"
        if [ -d "$patch_dir/.git" ]; then
            if [ "$dry_run" = "1" ]; then
                note "  [dry-run] git -C $patch_dir apply --check $p"
            else
                git -C "$patch_dir" apply --check "$p" \
                    || die "patch does not apply cleanly (already applied?): $p"
                git -C "$patch_dir" apply --whitespace=nowarn "$p"
            fi
        else
            command -v patch >/dev/null 2>&1 || die "'patch' not found; install it or use a git checkout"
            if [ "$dry_run" = "1" ]; then
                note "  [dry-run] patch -d $patch_dir -p1 < $p"
            else
                patch -d "$patch_dir" -p1 --dry-run < "$p" >/dev/null \
                    || die "patch does not apply cleanly (already applied?): $p"
                patch -d "$patch_dir" -p1 < "$p" >/dev/null
            fi
        fi
    done
    [ "$found" = "1" ] || die "no patches found in $repo_root/patches"
    note ""
    note "Patches applied. Next: install the patched checkout (./install.sh for this"
    note "tree, or copy the patched checkout into the DMS plugins directory)."
    exit 0
fi

# -------------------------------------------------------------- install mode
note "AI Quotas (Ollama Cloud edition) installer"
note "Source: $repo_root"
note "Target: $target"
[ "$dry_run" = "1" ] && note "Mode:   dry run (nothing will be changed)"
note ""

command -v curl >/dev/null 2>&1 || note "warning: 'curl' not found — it is required at runtime"
command -v jq >/dev/null 2>&1 || note "warning: 'jq' not found — it is required at runtime"

files="AiQuotasDaemon.qml AiQuotasSettings.qml AiQuotasWidget.qml StartupCheck.qml plugin.json fetch-usage.sh claude-statusline.sh README.md LICENSE assets dms-common tests"
for f in $files; do
    [ -e "$repo_root/$f" ] || die "missing source file or directory: $f"
done

if [ -e "$target" ]; then
    backup="$target.bak-$(date +%Y%m%d-%H%M%S)"
    if [ "$dry_run" = "1" ]; then
        note "Existing installation found; would back up to: $backup"
    else
        note "Existing installation found; backing up to: $backup"
    fi
    run cp -a -- "$target" "$backup"
fi

run mkdir -p -- "$target"
for f in $files; do
    run cp -a -- "$repo_root/$f" "$target/"
done
run chmod 755 -- "$target/fetch-usage.sh" "$target/claude-statusline.sh"

note ""
note "Done. Next steps:"
note "  1. Restart DMS:        dms restart   (or: systemctl --user restart dms)"
note "  2. Enable the plugin:  Settings > Plugins > Scan for Plugins > AI Quotas"
note "  3. Add credentials:    Settings > Plugins > AI Quotas > Credentials"
note "       - Ollama Cloud API key        (optional; shows your plan name)"
note "       - Ollama Cloud session cookie (optional; shows monthly usage; read SECURITY.md first)"
note "  4. Add to the bar:     Settings > DankBar Layout"
