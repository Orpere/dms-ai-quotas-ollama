#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin" "$test_dir/opencode"

# Route mock curl by URL so plan (/api/me) and usage (/settings) are independent.
cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
url=""
for a in "$@"; do
    case "$a" in
        https://*) url="$a" ;;
    esac
done
if [ -n "${RECORD_ARGV:-}" ]; then
    printf '%s\n' "$*" >> "$RECORD_ARGV"
fi
case "$url" in
    *ollama.com/api/me*)
        printf '%s\n%s\n' "$PLAN_RESPONSE" "${PLAN_CODE:-200}" ;;
    *ollama.com/settings*)
        printf '%s\n%s\n' "$USAGE_RESPONSE" "${USAGE_CODE:-200}" ;;
    *)
        printf '%s\n%s\n' "" "000" ;;
esac
EOF
chmod +x "$test_dir/bin/curl"

fixture=$(cat "$repo/tests/fixtures/ollama-settings.html")
expected_reset=$(TZ=UTC jq -n '"2026-10-26T17:34:27Z"|fromdateiso8601')

run() {
    env PATH="$test_dir/bin:$PATH" \
        OLLAMA_API_KEY="${OLLAMA_API_KEY:-}" \
        OLLAMA_SESSION_COOKIE="${OLLAMA_SESSION_COOKIE:-}" \
        PLAN_RESPONSE="${PLAN_RESPONSE:-}" \
        PLAN_CODE="${PLAN_CODE:-}" \
        USAGE_RESPONSE="${USAGE_RESPONSE:-}" \
        USAGE_CODE="${USAGE_CODE:-}" \
        RECORD_ARGV="${RECORD_ARGV:-}" \
        AIQ_CLAUDE_ENABLED=0 \
        AIQ_CODEX_ENABLED=0 \
        AIQ_OPENCODE_ENABLED=0 \
        AIQ_DEEPSEEK_ENABLED=0 \
        AIQ_OPENROUTER_ENABLED=0 \
        AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=0 \
        AIQ_OLLAMA_ENABLED=1 \
        OPENCODE_DATA_DIR="$test_dir/opencode" \
        AIQ_CACHE_TTL=0 \
        CACHE_FILE="$test_dir/usage.json" \
        sh "$repo/fetch-usage.sh"
}

# 1. fixture + key ok -> status ok, used 12.34, limit 60, plan "pro", resetsAt epoch
OLLAMA_API_KEY=sk-ollama-test
OLLAMA_SESSION_COOKIE=session-abc
PLAN_RESPONSE='{"Plan":"pro"}'
PLAN_CODE=200
USAGE_RESPONSE="$fixture"
USAGE_CODE=200
run | jq -e --argjson er "$expected_reset" \
    '.ollama.status == "ok"
     and .ollama.plan == "pro"
     and .ollama.used == 12.34
     and .ollama.limit == 60
     and .ollama.currency == "USD"
     and .ollama.resetsAt == $er' \
    >/dev/null

# 2. fixture, no key -> ok, no plan
OLLAMA_API_KEY=
OLLAMA_SESSION_COOKIE=session-abc
PLAN_RESPONSE=
PLAN_CODE=
USAGE_RESPONSE="$fixture"
USAGE_CODE=200
run | jq -e --argjson er "$expected_reset" \
    '.ollama.status == "ok"
     and (.ollama.plan | not)
     and .ollama.used == 12.34
     and .ollama.limit == 60
     and .ollama.resetsAt == $er' \
    >/dev/null

# 3. no cookie, key ok -> plan_only, plan "pro"
OLLAMA_API_KEY=sk-ollama-test
OLLAMA_SESSION_COOKIE=
PLAN_RESPONSE='{"Plan":"pro"}'
PLAN_CODE=200
USAGE_RESPONSE=
USAGE_CODE=
run | jq -e \
    '.ollama.status == "plan_only"
     and .ollama.plan == "pro"
     and .ollama.reason == "usage_requires_cookie"' \
    >/dev/null

# 4. no cookie, no key, empty auth dir -> unavailable / not_configured
OLLAMA_API_KEY=
OLLAMA_SESSION_COOKIE=
PLAN_RESPONSE=
PLAN_CODE=
USAGE_RESPONSE=
USAGE_CODE=
run | jq -e \
    '.ollama.status == "unavailable"
     and .ollama.reason == "not_configured"' \
    >/dev/null

# 5. cookie returns sign-in page (no meter, contains "Sign in"), key ok -> plan_only, reason auth_expired
OLLAMA_API_KEY=sk-ollama-test
OLLAMA_SESSION_COOKIE=session-abc
PLAN_RESPONSE='{"Plan":"pro"}'
PLAN_CODE=200
USAGE_RESPONSE='<html><body>Sign in to continue</body></html>'
USAGE_CODE=200
run | jq -e \
    '.ollama.status == "plan_only"
     and .ollama.plan == "pro"
     and .ollama.reason == "auth_expired"' \
    >/dev/null

# 6. cookie 302, no key -> error, reason auth_expired
OLLAMA_API_KEY=
OLLAMA_SESSION_COOKIE=session-abc
PLAN_RESPONSE=
PLAN_CODE=
USAGE_RESPONSE=''
USAGE_CODE=302
run | jq -e \
    '.ollama.status == "error"
     and .ollama.reason == "auth_expired"' \
    >/dev/null

# 7. cookie 429, key ok -> plan_only, reason rate_limited
OLLAMA_API_KEY=sk-ollama-test
OLLAMA_SESSION_COOKIE=session-abc
PLAN_RESPONSE='{"Plan":"pro"}'
PLAN_CODE=200
USAGE_RESPONSE=''
USAGE_CODE=429
run | jq -e \
    '.ollama.status == "plan_only"
     and .ollama.plan == "pro"
     and .ollama.reason == "rate_limited"' \
    >/dev/null

# 8. fixture + key 401 -> ok, no plan
OLLAMA_API_KEY=sk-ollama-test
OLLAMA_SESSION_COOKIE=session-abc
PLAN_RESPONSE=''
PLAN_CODE=401
USAGE_RESPONSE="$fixture"
USAGE_CODE=200
run | jq -e --argjson er "$expected_reset" \
    '.ollama.status == "ok"
     and (.ollama.plan | not)
     and .ollama.used == 12.34
     and .ollama.limit == 60
     and .ollama.resetsAt == $er' \
    >/dev/null

# 9. both 000 -> error, reason network
OLLAMA_API_KEY=sk-ollama-test
OLLAMA_SESSION_COOKIE=session-abc
PLAN_RESPONSE=''
PLAN_CODE=000
USAGE_RESPONSE=''
USAGE_CODE=000
run | jq -e \
    '.ollama.status == "error"
     and .ollama.reason == "network"' \
    >/dev/null

# 10. malformed HTML (no meter, no sign-in), no key -> error, reason parse_error
OLLAMA_API_KEY=
OLLAMA_SESSION_COOKIE=session-abc
PLAN_RESPONSE=
PLAN_CODE=
USAGE_RESPONSE='<html><body>Welcome to settings</body></html>'
USAGE_CODE=200
run | jq -e \
    '.ollama.status == "error"
     and .ollama.reason == "parse_error"' \
    >/dev/null

# 11. header check: cookie input "__Secure-session=abc; x=1" -> mock sees "Cookie: __Secure-session=abc"
OLLAMA_API_KEY=sk-ollama-test
OLLAMA_SESSION_COOKIE='__Secure-session=abc; x=1'
PLAN_RESPONSE='{"Plan":"pro"}'
PLAN_CODE=200
USAGE_RESPONSE="$fixture"
USAGE_CODE=200
RECORD_ARGV="$test_dir/argv.log"
run >/dev/null
grep -q 'Cookie: __Secure-session=abc' "$test_dir/argv.log"
if grep -q 'x=1' "$test_dir/argv.log"; then
    echo "FAIL: cookie header leaked '; x=1' suffix" >&2
    exit 1
fi

# 12. key with trailing CRLF + spaces -> Authorization header trimmed, no CRLF
OLLAMA_API_KEY=$(printf '  sk-ollama-test\r\n  ')
OLLAMA_SESSION_COOKIE=session-abc
PLAN_RESPONSE='{"Plan":"pro"}'
PLAN_CODE=200
USAGE_RESPONSE="$fixture"
USAGE_CODE=200
RECORD_ARGV="$test_dir/argv-key.log"
run >/dev/null
grep -Fq -- 'Authorization: Bearer sk-ollama-test' "$test_dir/argv-key.log"
if grep -Fq "$(printf '\r')" "$test_dir/argv-key.log"; then
    echo "FAIL: CR leaked into request headers" >&2
    exit 1
fi
if [ "$(wc -l < "$test_dir/argv-key.log")" != "2" ]; then
    echo "FAIL: newline leaked into request headers" >&2
    exit 1
fi

# 13. data-time with fractional seconds -> same epoch as non-fractional value
OLLAMA_API_KEY=sk-ollama-test
OLLAMA_SESSION_COOKIE=session-abc
PLAN_RESPONSE='{"Plan":"pro"}'
PLAN_CODE=200
USAGE_RESPONSE='<html><body><div aria-label="Monthly usage $12.34 of $60 used"></div><div data-time="2026-10-26T17:34:27.123Z"></div></body></html>'
USAGE_CODE=200
run | jq -e --argjson er "$expected_reset" \
    '.ollama.status == "ok"
     and .ollama.used == 12.34
     and .ollama.limit == 60
     and .ollama.resetsAt == $er' \
    >/dev/null

# 14. data-time with +00:00 offset -> same epoch
OLLAMA_API_KEY=sk-ollama-test
OLLAMA_SESSION_COOKIE=session-abc
PLAN_RESPONSE='{"Plan":"pro"}'
PLAN_CODE=200
USAGE_RESPONSE='<html><body><div aria-label="Monthly usage $12.34 of $60 used"></div><div data-time="2026-10-26T17:34:27+00:00"></div></body></html>'
USAGE_CODE=200
run | jq -e --argjson er "$expected_reset" \
    '.ollama.status == "ok"
     and .ollama.used == 12.34
     and .ollama.limit == 60
     and .ollama.resetsAt == $er' \
    >/dev/null

# 15. aria-label with double spaces -> used 12.34, limit 60
OLLAMA_API_KEY=sk-ollama-test
OLLAMA_SESSION_COOKIE=session-abc
PLAN_RESPONSE='{"Plan":"pro"}'
PLAN_CODE=200
USAGE_RESPONSE='<html><body><div aria-label="Monthly usage  $12.34  of  $60  used"></div><div data-time="2026-10-26T17:34:27Z"></div></body></html>'
USAGE_CODE=200
run | jq -e \
    '.ollama.status == "ok"
     and .ollama.used == 12.34
     and .ollama.limit == 60' \
    >/dev/null

printf '%s\n' "all ollama cases passed"
