#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin" "$test_dir/opencode"

# Mock curl: routes by URL, counts invocations (optional), records argv (optional).
cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
if [ -n "${CURL_COUNT_FILE:-}" ]; then
    c=0
    [ ! -f "$CURL_COUNT_FILE" ] || c=$(cat "$CURL_COUNT_FILE")
    printf '%s\n' $((c + 1)) > "$CURL_COUNT_FILE"
fi
if [ -n "${RECORD_ARGV:-}" ]; then
    printf '%s\n' "$*" >> "$RECORD_ARGV"
fi
url=""
for a in "$@"; do
    case "$a" in
        https://*) url="$a" ;;
    esac
done
case "$url" in
    *ollama.com/api/me*)
        printf '%s\n%s\n' "${PLAN_RESPONSE:-}" "${PLAN_CODE:-200}" ;;
    *ollama.com/settings*)
        printf '%s\n%s\n' "${USAGE_RESPONSE:-}" "${USAGE_CODE:-200}" ;;
    *)
        printf '%s\n%s\n' "" "000" ;;
esac
EOF
chmod +x "$test_dir/bin/curl"

fixture=$(cat "$repo/tests/fixtures/ollama-settings.html")

run() {
    env PATH="$test_dir/bin:$PATH" \
        OLLAMA_API_KEY="${OLLAMA_API_KEY:-}" \
        OLLAMA_SESSION_COOKIE="${OLLAMA_SESSION_COOKIE:-}" \
        PLAN_RESPONSE="${PLAN_RESPONSE:-}" \
        PLAN_CODE="${PLAN_CODE:-}" \
        USAGE_RESPONSE="${USAGE_RESPONSE:-}" \
        USAGE_CODE="${USAGE_CODE:-}" \
        RECORD_ARGV="${RECORD_ARGV:-}" \
        CURL_COUNT_FILE="${CURL_COUNT_FILE:-}" \
        AIQ_CLAUDE_ENABLED=0 \
        AIQ_CODEX_ENABLED=0 \
        AIQ_OPENCODE_ENABLED=0 \
        AIQ_DEEPSEEK_ENABLED=0 \
        AIQ_OPENROUTER_ENABLED=0 \
        AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=0 \
        AIQ_OLLAMA_ENABLED="${AIQ_OLLAMA_ENABLED:-1}" \
        OPENCODE_DATA_DIR="$test_dir/opencode" \
        AIQ_CACHE_TTL="${AIQ_CACHE_TTL:-0}" \
        CACHE_FILE="$test_dir/usage.json" \
        sh "$repo/fetch-usage.sh"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. thousands separators in the meter -> used 1234.56, limit 5000
OLLAMA_API_KEY=sk-test
OLLAMA_SESSION_COOKIE=sess
PLAN_RESPONSE='{"Plan":"pro"}'
PLAN_CODE=200
USAGE_RESPONSE='<html><body><div aria-label="Monthly usage $1,234.56 of $5,000 used"></div><div data-time="2026-10-26T17:34:27Z"></div></body></html>'
USAGE_CODE=200
run | jq -e \
    '.ollama.status == "ok"
     and .ollama.plan == "pro"
     and .ollama.used == 1234.56
     and .ollama.limit == 5000
     and .ollama.currency == "USD"' >/dev/null \
    || fail "thousands separators"

# 2. meter present but data-time missing -> ok, resetsAt 0
OLLAMA_API_KEY=sk-test
OLLAMA_SESSION_COOKIE=sess
PLAN_RESPONSE='{"Plan":"pro"}'
PLAN_CODE=200
USAGE_RESPONSE='<html><body><div aria-label="Monthly usage $12.34 of $60 used"></div></body></html>'
USAGE_CODE=200
run | jq -e \
    '.ollama.status == "ok"
     and .ollama.used == 12.34
     and .ollama.limit == 60
     and .ollama.resetsAt == 0' >/dev/null \
    || fail "missing data-time -> resetsAt 0"

# 3. cookie normalization: leading space, trailing newline, and a ';' suffix
OLLAMA_API_KEY=sk-test
OLLAMA_SESSION_COOKIE=$(printf ' __Secure-session=abc; other=1\n')
PLAN_RESPONSE='{"Plan":"pro"}'
PLAN_CODE=200
USAGE_RESPONSE="$fixture"
USAGE_CODE=200
RECORD_ARGV="$test_dir/argv.log"
run >/dev/null
grep -Fq -- 'Cookie: __Secure-session=abc' "$test_dir/argv.log" \
    || fail "cookie header not normalized to 'Cookie: __Secure-session=abc'"
if grep -Fq 'other=1' "$test_dir/argv.log"; then
    fail "cookie header leaked '; other=1' suffix"
fi
if grep -Fq 'abc; other=1' "$test_dir/argv.log"; then
    fail "cookie header leaked raw 'abc; other=1'"
fi

# 4. cookie 403 + key ok -> plan_only, reason access_denied
OLLAMA_API_KEY=sk-test
OLLAMA_SESSION_COOKIE=sess
PLAN_RESPONSE='{"Plan":"pro"}'
PLAN_CODE=200
USAGE_RESPONSE=''
USAGE_CODE=403
run | jq -e \
    '.ollama.status == "plan_only"
     and .ollama.plan == "pro"
     and .ollama.reason == "access_denied"' >/dev/null \
    || fail "cookie 403 + key ok -> plan_only access_denied"

# 5. key HTTP 500 + cookie ok -> status ok (key failure ignored)
OLLAMA_API_KEY=sk-test
OLLAMA_SESSION_COOKIE=sess
PLAN_RESPONSE=''
PLAN_CODE=500
USAGE_RESPONSE="$fixture"
USAGE_CODE=200
run | jq -e \
    '.ollama.status == "ok"
     and (.ollama.plan | not)
     and .ollama.used == 12.34
     and .ollama.limit == 60' >/dev/null \
    || fail "key 500 + cookie ok -> status ok"

# 6. AIQ_OLLAMA_ENABLED=0 -> unavailable (no reason), mock curl NOT called
OLLAMA_API_KEY=sk-test
OLLAMA_SESSION_COOKIE=sess
PLAN_RESPONSE='{"Plan":"pro"}'
PLAN_CODE=200
USAGE_RESPONSE="$fixture"
USAGE_CODE=200
CURL_COUNT_FILE="$test_dir/count"
printf '0\n' > "$CURL_COUNT_FILE"
AIQ_OLLAMA_ENABLED=0
run | jq -e \
    '.ollama.status == "unavailable"
     and (.ollama.reason | not)' >/dev/null \
    || fail "disabled -> unavailable (no reason)"
[ "$(cat "$CURL_COUNT_FILE")" = "0" ] || fail "disabled provider still called curl"

# 7. cache hit: second run with TTL > 0 must not call curl again
OLLAMA_API_KEY=sk-test
OLLAMA_SESSION_COOKIE=sess
PLAN_RESPONSE='{"Plan":"pro"}'
PLAN_CODE=200
USAGE_RESPONSE="$fixture"
USAGE_CODE=200
printf '0\n' > "$CURL_COUNT_FILE"
AIQ_OLLAMA_ENABLED=1
AIQ_CACHE_TTL=0
run >/dev/null
c1=$(cat "$CURL_COUNT_FILE")
[ "$c1" = "2" ] || fail "expected 2 curl calls (plan + usage), got $c1"
AIQ_CACHE_TTL=3600
run >/dev/null
c2=$(cat "$CURL_COUNT_FILE")
[ "$c2" = "2" ] || fail "cache hit still called curl: $c1 -> $c2"

# 8. secret leakage: failing scenario must not emit key or cookie markers
OLLAMA_API_KEY='SEKRIT-KEY-42'
OLLAMA_SESSION_COOKIE='__Secure-session=SEKRIT-COOKIE-42'
PLAN_RESPONSE=''
PLAN_CODE=401
USAGE_RESPONSE=''
USAGE_CODE=403
AIQ_OLLAMA_ENABLED=1
AIQ_CACHE_TTL=0
run > "$test_dir/out.json" 2> "$test_dir/err.txt"
if grep -Fq 'SEKRIT-KEY-42' "$test_dir/out.json"; then
    fail "key leaked into stdout JSON"
fi
if grep -Fq 'SEKRIT-COOKIE-42' "$test_dir/out.json"; then
    fail "cookie leaked into stdout JSON"
fi
if grep -Fq 'SEKRIT-KEY-42' "$test_dir/err.txt"; then
    fail "key leaked into stderr"
fi
if grep -Fq 'SEKRIT-COOKIE-42' "$test_dir/err.txt"; then
    fail "cookie leaked into stderr"
fi
if grep -Fq 'SEKRIT' "$test_dir/usage.json"; then
    fail "secret leaked into cache file"
fi

printf '%s\n' "all ollama edge cases passed"
