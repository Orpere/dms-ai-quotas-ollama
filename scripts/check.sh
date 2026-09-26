#!/bin/sh
# Local quality gate for this repository.
#
# Why no GitHub Actions? This project follows a zero-cost policy: it does not use
# GitHub's metered or usage-billed features (including CI minutes for private
# repositories). Run this script locally before pushing.
#
# Usage: ./scripts/check.sh
set -eu

unset CDPATH
repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

fail=0
say() { printf '== %s\n' "$*"; }

say "shell syntax (sh -n)"
for f in fetch-usage.sh install.sh scripts/check.sh tests/*.sh; do
    if sh -n "$f"; then
        printf '  ok   %s\n' "$f"
    else
        printf '  FAIL %s\n' "$f"
        fail=1
    fi
done

say "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
    # Production scripts must be spotless.
    if shellcheck -s sh fetch-usage.sh install.sh scripts/check.sh; then
        printf '  ok   production scripts clean\n'
    else
        fail=1
    fi
    # Tests intentionally use the "CDPATH= cd" idiom (SC1007) and literal "$"
    # dollar amounts inside single-quoted mock HTML (SC2016).
    if shellcheck -s sh -e SC1007,SC2016 tests/*.sh; then
        printf '  ok   tests clean (SC1007/SC2016 exempted)\n'
    else
        fail=1
    fi
else
    printf '  skipped: shellcheck not installed\n'
fi

say "plugin manifest"
if jq -e . plugin.json >/dev/null 2>&1; then
    printf '  ok   plugin.json is valid JSON\n'
else
    printf '  FAIL plugin.json is not valid JSON\n'
    fail=1
fi

say "test suite"
for t in tests/test-*.sh; do
    printf '  %-32s ' "$t"
    if sh "$t" >/dev/null 2>&1; then
        printf 'PASS\n'
    else
        printf 'FAIL\n'
        sh "$t" || true
        fail=1
    fi
done

printf '\n'
if [ "$fail" = "0" ]; then
    say "ALL CHECKS PASSED"
else
    say "CHECKS FAILED"
    exit 1
fi
