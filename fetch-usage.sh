#!/bin/sh
# Fetch Claude, Codex and OpenCode Go usage plus DeepSeek, OpenRouter, Grok and Ollama Cloud balances, merge, cache, and print.
#
# Claude: reads native rate-limit data captured from Claude Code's status line
# Codex: GET https://chatgpt.com/backend-api/wham/usage using the local Codex login
# OpenCode Go: GET https://opencode.ai/zen/go/v1/usage using a Go API key
# DeepSeek: GET https://api.deepseek.com/user/balance
# OpenRouter: GET https://openrouter.ai/api/v1/credits
# Grok: billing usage via ~/.grok/auth.json + cli-chat-proxy billing
# Ollama Cloud: plan via POST https://ollama.com/api/me (API key) + usage via session-cookie scrape of https://ollama.com/settings
#
# Env:
#   AIQ_CLAUDE_ENABLED        "1" to fetch Claude (default: "1")
#   AIQ_CODEX_ENABLED         "1" to fetch Codex (default: "1")
#   CACHE_FILE                cache path (default $XDG_CACHE_HOME/dms-ai-quotas/usage.json)
#   CLAUDE_CONFIG_DIR         Claude Code config directory (default $HOME/.claude)
#   CLAUDE_USAGE_FILE         native Claude usage snapshot
#   CLAUDE_FALLBACK_STATE_FILE fallback poll state
#   CODEX_HOME                Codex home directory (default $HOME/.codex)
#   GROK_HOME                 Grok home directory (default $HOME/.grok)
#   OPENCODE_DATA_DIR         OpenCode data directory (default $XDG_DATA_HOME/opencode)
#   AIQ_OPENCODE_ENABLED      "1" to fetch OpenCode (default: "1")
#   AIQ_DEEPSEEK_ENABLED      "1" to fetch DeepSeek (default: "1")
#   AIQ_OPENROUTER_ENABLED    "1" to fetch OpenRouter (default: "1")
#   AIQ_GROK_ENABLED          "1" to fetch Grok (default: "1")
#   AIQ_OLLAMA_ENABLED        "1" to fetch Ollama Cloud (default: "1")
#   DEEPSEEK_API_KEY          DeepSeek API key
#   OPENROUTER_API_KEY        OpenRouter API key (management key only if credits are denied)
#   OPENCODE_GO_API_KEY       OpenCode Go API key (overrides local auth.json)
#   OPENCODE_API_KEY          fallback OpenCode Go API key
#   OLLAMA_API_KEY            Ollama Cloud API key (for plan lookup)
#   OLLAMA_SESSION_COOKIE     Ollama Cloud __Secure-session cookie (for usage scrape)
#   AIQ_CACHE_TTL             seconds before cache is stale (default: 55)
#   AIQ_FORCE_REFRESH         "1" to bypass the cache
#   AIQ_USAGE_MOCK            file with sample JSON (for tests)
set -u
umask 077

claude_enabled="${AIQ_CLAUDE_ENABLED:-1}"
oc_enabled="${AIQ_OPENCODE_ENABLED:-1}"
ds_enabled="${AIQ_DEEPSEEK_ENABLED:-1}"
or_enabled="${AIQ_OPENROUTER_ENABLED:-1}"
codex_enabled="${AIQ_CODEX_ENABLED:-1}"
agy_enabled="${AIQ_ANTIGRAVITY_ENABLED:-1}"
grok_enabled="${AIQ_GROK_ENABLED:-1}"
ol_enabled="${AIQ_OLLAMA_ENABLED:-1}"
cache="${CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-quotas/usage.json}"
ttl="${AIQ_CACHE_TTL:-55}"
force_refresh="${AIQ_FORCE_REFRESH:-0}"
mkdir -p "$(dirname "$cache")" 2>/dev/null
now=$(date +%s)

if [ "$force_refresh" != "1" ] && [ -s "$cache" ]; then
    prev=$(jq -r '.captured_at // 0' "$cache" 2>/dev/null)
    case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
    if [ "$prev" -gt 0 ] && [ $((now - prev)) -lt "$ttl" ]; then
        cat "$cache"
        exit 0
    fi
fi

if [ -n "${AIQ_USAGE_MOCK:-}" ] && [ -f "$AIQ_USAGE_MOCK" ]; then
    cat "$AIQ_USAGE_MOCK"
    exit 0
fi

# ============================================================
# Claude plan usage from native status data with a five-minute API fallback
# ============================================================
claude_data='{"status":"unavailable"}'
if [ "$claude_enabled" = "1" ]; then
    claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    claude_creds="$claude_home/.credentials.json"
    access_token=$(jq -r '.claudeAiOauth.accessToken // empty' "$claude_creds" 2>/dev/null)
    sub_type=$(jq -r '.claudeAiOauth.subscriptionType // empty' "$claude_creds" 2>/dev/null)
    rate_tier=$(jq -r '.claudeAiOauth.rateLimitTier // empty' "$claude_creds" 2>/dev/null)

    case "$rate_tier" in
        *max_20x*) claude_plan="Max 20x" ;;
        *max_5x*)  claude_plan="Max 5x" ;;
        *)
            case "$sub_type" in
                pro) claude_plan="Pro" ;;
                max) claude_plan="Max" ;;
                team) claude_plan="Team" ;;
                enterprise) claude_plan="Enterprise" ;;
                free) claude_plan="Free" ;;
                '') claude_plan="Claude" ;;
                *) claude_plan="$sub_type" ;;
            esac
            ;;
    esac

    claude_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-quotas"
    claude_usage="${CLAUDE_USAGE_FILE:-$claude_cache_dir/claude-native.json}"
    claude_fallback_state="${CLAUDE_FALLBACK_STATE_FILE:-$claude_cache_dir/claude-fallback.json}"
    mkdir -p "$(dirname "$claude_usage")" "$(dirname "$claude_fallback_state")" 2>/dev/null
    claude_captured=$(jq -r '.captured_at // 0' "$claude_usage" 2>/dev/null)
    claude_checked=$(jq -r '.checked_at // 0' "$claude_fallback_state" 2>/dev/null)
    claude_retry=$(jq -r '.retry_at // 0' "$claude_fallback_state" 2>/dev/null)
    case "$claude_captured" in ''|*[!0-9]*) claude_captured=0 ;; esac
    case "$claude_checked" in ''|*[!0-9]*) claude_checked=0 ;; esac
    case "$claude_retry" in ''|*[!0-9]*) claude_retry=0 ;; esac

    claude_error=""
    if [ -n "$access_token" ] &&
       [ $((now - claude_captured)) -ge 300 ] &&
       [ $((now - claude_checked)) -ge 300 ] &&
       [ "$now" -ge "$claude_retry" ]; then
        claude_headers=$(mktemp "${TMPDIR:-/tmp}/aiq-claude-headers.XXXXXX")
        claude_auth=$(mktemp "${TMPDIR:-/tmp}/aiq-claude-auth.XXXXXX")
        trap 'rm -f "$claude_headers" "$claude_auth"' EXIT HUP INT TERM
        printf 'Authorization: Bearer %s\n' "$access_token" > "$claude_auth"
        claude_response=$(curl -s -m 15 -D "$claude_headers" -w '\n%{http_code}' \
            -H "@$claude_auth" \
            -H "Accept: application/json" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: dms-ai-quotas" \
            https://api.anthropic.com/api/oauth/usage 2>/dev/null)
        claude_http_code=$(printf '%s\n' "$claude_response" | tail -n 1)
        claude_body=$(printf '%s\n' "$claude_response" | sed '$d')
        claude_retry_at=0

        case "$claude_http_code" in
            2??)
                claude_snapshot=$(printf '%s' "$claude_body" | jq -c --argjson now "$now" '
                    def number:
                        if type == "number" then .
                        elif type == "string" then (tonumber? // 0)
                        else 0
                        end;
                    def timestamp:
                        if type == "number" then .
                        elif type == "string" then
                            (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601?) // 0
                        else 0
                        end;
                    [
                        {name: "5h", window: .five_hour},
                        {name: "Weekly", window: .seven_day}
                    ]
                    | map(select(.window.utilization != null))
                    | map({
                        name: .name,
                        percentUsed: ([((.window.utilization | number)), 0] | max | [., 100] | min),
                        resetAt: (.window.resets_at | timestamp)
                    })
                    | if length == 0 then error("no quota windows")
                      else {captured_at: $now, source: "oauth", entries: .}
                      end
                ' 2>/dev/null) || claude_snapshot=""
                if [ -n "$claude_snapshot" ]; then
                    claude_tmp=$(mktemp "$(dirname "$claude_usage")/.claude-usage.XXXXXX")
                    printf '%s\n' "$claude_snapshot" > "$claude_tmp" && mv "$claude_tmp" "$claude_usage"
                else
                    claude_error='{"status":"error","error":"Could not parse Claude usage response"}'
                fi
                ;;
            401)
                claude_error='{"status":"error","reason":"auth_expired","error":"Claude login expired. Start Claude Code to refresh it, then refresh AI Quotas."}'
                ;;
            403)
                claude_error='{"status":"error","reason":"access_denied","error":"Claude usage access was denied for this account."}'
                ;;
            429)
                retry_after=$(sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*//p' "$claude_headers" | tr -d '\r' | tail -n 1)
                case "$retry_after" in
                    '') claude_retry_at=$((now + 3600)) ;;
                    *[!0-9]*) claude_retry_at=$(date -d "$retry_after" +%s 2>/dev/null || printf '%s' $((now + 3600))) ;;
                    *) claude_retry_at=$((now + retry_after)) ;;
                esac
                [ "$claude_retry_at" -gt "$now" ] || claude_retry_at=$((now + 3600))
                ;;
        esac
        rm -f "$claude_headers" "$claude_auth"
        trap - EXIT HUP INT TERM

        fallback_tmp=$(mktemp "$(dirname "$claude_fallback_state")/.claude-fallback.XXXXXX")
        jq -n -c --argjson checked "$now" --argjson retry "$claude_retry_at" \
            '{checked_at: $checked, retry_at: $retry}' > "$fallback_tmp" &&
            mv "$fallback_tmp" "$claude_fallback_state"
    fi

    if [ -s "$claude_usage" ]; then
        claude_data=$(jq -c --arg plan "$claude_plan" --argjson now "$now" '
            select((.entries | type) == "array" and (.entries | length) > 0)
            | ((.captured_at | tonumber?) // 0) as $captured
            | {
                status: "ok",
                plan: $plan,
                source: (.source // "native"),
                capturedAt: ($captured // 0),
                stale: (($now - ($captured // 0)) >= 300),
                entries: .entries
              }
        ' "$claude_usage" 2>/dev/null)
        [ -n "$claude_data" ] || claude_data='{"status":"error","error":"Could not parse Claude usage data"}'
    elif [ -n "$claude_error" ]; then
        claude_data="$claude_error"
    elif [ -n "$access_token" ]; then
        claude_data='{"status":"unavailable","reason":"usage_pending","error":"Claude usage data is not available yet. Send a Claude Code message, then refresh AI Quotas."}'
    else
        claude_data='{"status":"unavailable","reason":"not_authenticated","error":"Claude is not logged in. Run claude in a terminal and sign in, then refresh AI Quotas."}'
    fi
fi

# ============================================================
# Codex
# ============================================================
codex_data='{"status":"unavailable"}'
if [ "$codex_enabled" = "1" ]; then
    codex_home="${CODEX_HOME:-$HOME/.codex}"
    codex_auth="$codex_home/auth.json"
    access_token=$(jq -r '.tokens.access_token // empty' "$codex_auth" 2>/dev/null)
    account_id=$(jq -r '.tokens.account_id // empty' "$codex_auth" 2>/dev/null)

    if [ -n "$access_token" ]; then
        if [ -n "$account_id" ]; then
            codex_response=$(curl -s -m 15 -w '\n%{http_code}' \
                -H "Authorization: Bearer $access_token" \
                -H "ChatGPT-Account-Id: $account_id" \
                -H "Accept: application/json" \
                -H "User-Agent: codex-cli" \
                https://chatgpt.com/backend-api/wham/usage 2>/dev/null)
        else
            codex_response=$(curl -s -m 15 -w '\n%{http_code}' \
                -H "Authorization: Bearer $access_token" \
                -H "Accept: application/json" \
                -H "User-Agent: codex-cli" \
                https://chatgpt.com/backend-api/wham/usage 2>/dev/null)
        fi

        codex_http_code=$(printf '%s\n' "$codex_response" | tail -n 1)
        codex_body=$(printf '%s\n' "$codex_response" | sed '$d')
        case "$codex_http_code" in
            2??)
                codex_data=$(printf '%s' "$codex_body" | jq -c --argjson now "$now" '
                    def number:
                        if type == "number" then .
                        elif type == "string" then (tonumber? // 0)
                        else 0
                        end;
                    def reset_at:
                        if (.reset_at? != null) then (.reset_at | number)
                        elif (.reset_after_seconds? != null) then ($now + (.reset_after_seconds | number))
                        else 0
                        end;
                    def quota_name($fallback; $window):
                        if $fallback == "Code Review" then $fallback
                        elif (($window.limit_window_seconds? | number) >= 604800) then "Weekly"
                        elif (($window.limit_window_seconds? | number) >= 14400) then "5h"
                        else $fallback
                        end;
                    def entry($name; $window):
                        if ($window | type) != "object" then empty
                        else
                            ($window.used_percent? |
                                if . == null then empty else number end) as $used |
                            {
                                name: quota_name($name; $window),
                                percentUsed: (if $used < 0 then 0 elif $used > 100 then 100 else $used end),
                                resetAt: ($window | reset_at)
                            }
                        end;
                    . as $root |
                    [
                        entry("5h"; $root.rate_limit.primary_window),
                        entry("Weekly"; $root.rate_limit.secondary_window),
                        entry("Code Review"; $root.code_review_rate_limit.primary_window)
                    ] as $entries |
                    if ($entries | length) == 0 then
                        error("no quota windows")
                    else
                        {
                            status: "ok",
                            plan: ($root.plan_type // "ChatGPT"),
                            entries: $entries,
                            credits: (if $root.credits == null then null else {
                                hasCredits: ($root.credits.has_credits // false),
                                unlimited: ($root.credits.unlimited // false),
                                balance: ($root.credits.balance // null)
                            } end)
                        }
                    end
                ' 2>/dev/null) || codex_data='{"status":"error","error":"Could not parse Codex usage"}'
                ;;
            401)
                codex_data='{"status":"error","reason":"auth_expired","error":"Codex login expired. Run codex login again, then refresh AI Quotas."}'
                ;;
            403)
                codex_data='{"status":"error","reason":"access_denied","error":"Codex usage access was denied for this account."}'
                ;;
            429)
                codex_data='{"status":"error","reason":"rate_limited","error":"Codex usage is temporarily rate limited. Try again shortly."}'
                ;;
            000)
                codex_data='{"status":"error","reason":"network","error":"Could not reach the Codex usage service. Check your connection and try again."}'
                ;;
            *)
                codex_data="{\"status\":\"error\",\"reason\":\"http_error\",\"error\":\"Codex usage service returned HTTP $codex_http_code. Try again shortly.\"}"
                ;;
        esac
    else
        codex_data='{"status":"unavailable","reason":"not_authenticated","error":"Codex is not logged in. Run codex login in a terminal, then refresh AI Quotas."}'
    fi
fi

# ============================================================
# OpenCode Go
# ============================================================
oc_data='{"status":"unavailable"}'
if [ "$oc_enabled" = "1" ]; then
    oc_key="${OPENCODE_GO_API_KEY:-${OPENCODE_API_KEY:-}}"
    if [ -z "$oc_key" ]; then
        oc_data_dir="${OPENCODE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode}"
        oc_key=$(jq -r '."opencode-go".key // empty' "$oc_data_dir/auth.json" 2>/dev/null)
    fi

    if [ -n "$oc_key" ]; then
        oc_response=$(curl -s -m 15 -w '\n%{http_code}' \
            -H "Authorization: Bearer $oc_key" \
            -H "Accept: application/json" \
            https://opencode.ai/zen/go/v1/usage 2>/dev/null)
        oc_http_code=$(printf '%s\n' "$oc_response" | tail -n 1)
        oc_body=$(printf '%s\n' "$oc_response" | sed '$d')
        case "$oc_http_code" in
            2??)
                oc_data=$(printf '%s' "$oc_body" | TZ=UTC jq -c '
                    def number:
                        if type == "number" then .
                        elif type == "string" then (tonumber? // empty)
                        else empty
                        end;
                    def iso_to_unix:
                        if . == null then 0
                        elif type == "number" then .
                        elif type == "string" then
                            (gsub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0)
                        else 0
                        end;
                    def entry($name; $window):
                        if ($window | type) != "object" then empty
                        elif (($window.status // "ok") != "ok") then empty
                        else
                            ($window.percent | number) as $used |
                            {
                                name: $name,
                                percentUsed: (if $used < 0 then 0 elif $used > 100 then 100 else $used end),
                                resetAt: ($window.resetsAt | iso_to_unix)
                            }
                        end;
                    (.usage // error("no usage data")) as $usage |
                    [
                        entry("Rolling"; $usage.rolling),
                        entry("Weekly"; $usage.weekly),
                        entry("Monthly"; $usage.monthly)
                    ] as $entries |
                    if ($entries | length) == 0 then
                        error("no quota windows")
                    else
                        { status: "ok", entries: $entries }
                    end
                ' 2>/dev/null) || oc_data='{"status":"error","error":"Could not parse OpenCode usage"}'
                ;;
            401)
                oc_data='{"status":"error","reason":"auth_expired","error":"OpenCode Go login expired. Run opencode /connect again, or update the API key in plugin settings."}'
                ;;
            403)
                oc_data='{"status":"error","reason":"access_denied","error":"OpenCode Go usage access was denied for this key."}'
                ;;
            429)
                oc_data='{"status":"error","reason":"rate_limited","error":"OpenCode Go usage is temporarily rate limited. Try again shortly."}'
                ;;
            000)
                oc_data='{"status":"error","reason":"network","error":"Could not reach the OpenCode Go usage service. Check your connection and try again."}'
                ;;
            *)
                oc_data="{\"status\":\"error\",\"reason\":\"http_error\",\"error\":\"OpenCode Go usage service returned HTTP $oc_http_code. Try again shortly.\"}"
                ;;
        esac
    else
        oc_data='{"status":"unavailable","reason":"not_authenticated","error":"OpenCode Go is not connected. Run opencode /connect and choose OpenCode Go, or set an API key in plugin settings."}'
    fi
fi

# ============================================================
# DeepSeek
# ============================================================
ds_data='{"status":"unavailable"}'
if [ "$ds_enabled" = "1" ]; then
    ds_key="${DEEPSEEK_API_KEY:-}"
    if [ -n "$ds_key" ]; then
        ds_resp=$(curl -s -m 10 \
            -H "Authorization: Bearer $ds_key" \
            -H "Accept: application/json" \
            https://api.deepseek.com/user/balance 2>/dev/null)
        if [ -n "$ds_resp" ]; then
            ds_data=$(echo "$ds_resp" | jq -c '{
                status: "ok",
                isAvailable: .is_available,
                balances: [.balance_infos[] | {
                    currency: .currency,
                    total: .total_balance,
                    granted: .granted_balance,
                    toppedUp: .topped_up_balance
                }]
            }' 2>/dev/null) || ds_data="{\"status\":\"error\"}"
        fi
    fi
fi

# ============================================================
# OpenRouter credits (management API key)
# ============================================================
or_data='{"status":"unavailable"}'
if [ "$or_enabled" = "1" ]; then
    or_key="${OPENROUTER_API_KEY:-}"
    if [ -n "$or_key" ]; then
        or_resp=$(curl -s -m 10 -w '\n%{http_code}' \
            -H "Authorization: Bearer $or_key" \
            -H "Accept: application/json" \
            https://openrouter.ai/api/v1/credits 2>/dev/null)
        or_http_code=$(printf '%s\n' "$or_resp" | tail -n 1)
        or_body=$(printf '%s\n' "$or_resp" | sed '$d')
        case "$or_http_code" in
            2??)
                or_data=$(printf '%s' "$or_body" | jq -c '
                    def number:
                        if type == "number" then .
                        elif type == "string" then (tonumber? // 0)
                        else 0
                        end;
                    (.data // error("no credit data")) as $d |
                    ($d.total_credits | number) as $purchased |
                    ($d.total_usage | number) as $used |
                    {
                        status: "ok",
                        balances: [{
                            currency: "USD",
                            total: (($purchased - $used) | tostring),
                            purchased: ($purchased | tostring),
                            used: ($used | tostring)
                        }]
                    }
                ' 2>/dev/null) || or_data='{"status":"error","error":"Could not parse OpenRouter credits response"}'
                ;;
            401)
                or_data='{"status":"error","reason":"auth_expired","error":"OpenRouter rejected this API key. Check the key in plugin settings."}'
                ;;
            403)
                or_data='{"status":"error","reason":"access_denied","error":"OpenRouter denied credit access for this key. Create a management key at openrouter.ai/settings/management-keys and use it in plugin settings."}'
                ;;
            000)
                or_data='{"status":"error","reason":"network","error":"Could not reach the OpenRouter API. Check your connection and try again."}'
                ;;
            *)
                or_data="{\"status\":\"error\",\"reason\":\"http_error\",\"error\":\"OpenRouter API returned HTTP $or_http_code. Try again shortly.\"}"
                ;;
        esac
    fi
fi

# ============================================================
# Grok billing usage (OAuth via grok login, not API key)
# ============================================================
grok_data='{"status":"unavailable"}'
if [ "$grok_enabled" = "1" ]; then
    grok_home="${GROK_HOME:-$HOME/.grok}"
    grok_auth="$grok_home/auth.json"
    access_token=$(jq -r 'to_entries[0].value.key // empty' "$grok_auth" 2>/dev/null)
    email=$(jq -r 'to_entries[0].value.email // empty' "$grok_auth" 2>/dev/null)

    if [ -n "$access_token" ]; then
        grok_response=$(curl -s -m 15 -w '\n%{http_code}' \
            -H "Authorization: Bearer $access_token" \
            -H "Accept: application/json" \
            -H "User-Agent: dms-ai-quotas" \
            -H "x-grok-client-mode: cli" \
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits" 2>/dev/null)
        grok_http_code=$(printf '%s\n' "$grok_response" | tail -n 1)
        grok_body=$(printf '%s\n' "$grok_response" | sed '$d')
        case "$grok_http_code" in
            2??)
                grok_data=$(printf '%s' "$grok_body" | jq -c --arg email "$email" '
                    def number:
                        if type == "number" then .
                        elif type == "string" then (tonumber? // 0)
                        else 0
                        end;
                    def clamp_pct:
                        if . < 0 then 0 elif . > 100 then 100 else . end;
                    def parse_ts:
                        if . == null or . == "" then 0
                        else
                            (tostring
                             | sub("\\.[0-9]+"; "")
                             | sub("\\+00:00$"; "Z")
                             | sub("\\+0000$"; "Z")
                             | fromdateiso8601?) // 0
                        end;
                    def amount:
                        if type == "object" then (.val | number) else number end;
                    .config as $c |
                    ($c.currentPeriod.end // $c.billingPeriodEnd // null | parse_ts) as $reset |
                    ($c.onDemandCap | amount) as $cap |
                    ($c.onDemandUsed | amount) as $used |
                    ($c.currentPeriod != null or $c.billingPeriodEnd != null) as $has_period |
                    (
                        if $c.creditUsagePercent != null then
                            [{
                                name: "Billing",
                                kind: "plan",
                                percentUsed: (($c.creditUsagePercent | number) | clamp_pct),
                                resetAt: $reset
                            }]
                        elif $cap > 0 then
                            [{
                                name: "Billing",
                                kind: "on_demand",
                                percentUsed: ((100 * $used / $cap) | clamp_pct),
                                resetAt: $reset
                            }]
                        elif $has_period then
                            [{
                                name: "Billing",
                                kind: "plan",
                                percentUsed: 0,
                                resetAt: $reset
                            }]
                        else []
                        end
                    ) as $entries |
                    if ($entries | length) == 0 then
                        {
                            status: "unavailable",
                            reason: "no_quota"
                        }
                    else
                        {
                            status: "ok",
                            plan: (if $c.isUnifiedBillingUser == true then "SuperGrok" else "Grok" end),
                            email: (if $email == "" then null else $email end),
                            entries: $entries
                        }
                    end
                ' 2>/dev/null) || grok_data='{"status":"error","error":"Could not parse Grok usage response"}'
                ;;
            401|403)
                grok_data='{"status":"error","reason":"auth_expired","error":"Grok login expired. Run grok login again, then refresh AI Quotas."}'
                ;;
            000)
                grok_data='{"status":"error","reason":"network","error":"Could not reach the Grok usage service. Check your connection and try again."}'
                ;;
            *)
                grok_data="{\"status\":\"error\",\"reason\":\"http_error\",\"error\":\"Grok usage service returned HTTP $grok_http_code. Try again shortly.\"}"
                ;;
        esac
    else
        grok_data='{"status":"unavailable","reason":"not_authenticated","error":"Grok is not logged in. Run grok login in a terminal, then refresh AI Quotas."}'
    fi
fi

# ============================================================
# Antigravity
# ============================================================
agy_data='{"status":"unavailable"}'
if [ "$agy_enabled" = "1" ]; then
    if command -v secret-tool >/dev/null 2>&1; then
        KEYRING_JSON=$(secret-tool lookup service gemini username antigravity 2>/dev/null || true)
        if [ -n "$KEYRING_JSON" ]; then
            ACCESS_TOKEN=$(printf '%s' "$KEYRING_JSON" | jq -r '.token.access_token // empty' 2>/dev/null || true)
            REFRESH_TOKEN=$(printf '%s' "$KEYRING_JSON" | jq -r '.token.refresh_token // empty' 2>/dev/null || true)
            EXPIRY_RAW=$(printf '%s' "$KEYRING_JSON" | jq -r '.token.expiry // empty' 2>/dev/null || true)
            ACCOUNT=$(printf '%s' "$KEYRING_JSON" | jq -r '.account // .email // empty' 2>/dev/null || true)
            [ -z "$ACCOUNT" ] && [ -f "$HOME/.gemini/google_accounts.json" ] && \
                ACCOUNT=$(jq -r '.active // empty' "$HOME/.gemini/google_accounts.json" 2>/dev/null || true)

            token_valid() {
                exp="$1"
                [ -z "$exp" ] && return 1
                exp_epoch=0
                case "$exp" in
                    ''|*[!0-9]*)
                        exp_epoch=$(date -d "$exp" +%s 2>/dev/null || echo 0) ;;
                    *)
                        if [ "${#exp}" -ge 13 ]; then
                            exp_epoch=$(( exp / 1000 ))
                        else
                            exp_epoch="$exp"
                        fi ;;
                esac
                [ "$exp_epoch" -gt "$(( $(date +%s) + 60 ))" ] 2>/dev/null
            }

            CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agy-usage"
            mkdir -p "$CACHE_DIR"
            chmod 700 "$CACHE_DIR" 2>/dev/null || true
            TOKEN_CACHE="$CACHE_DIR/token.json"
            SECRET_CACHE="$CACHE_DIR/client_secret.txt"
            PROJECT_CACHE="$CACHE_DIR/project.txt"
            PLAN_CACHE="$CACHE_DIR/plan.txt"
            chmod 600 "$TOKEN_CACHE" "$SECRET_CACHE" 2>/dev/null || true

            if ! token_valid "$EXPIRY_RAW"; then
                if [ -f "$TOKEN_CACHE" ]; then
                    c_at=$(jq -r '.access_token // empty' "$TOKEN_CACHE" 2>/dev/null || true)
                    c_ex=$(jq -r '.expiry // 0' "$TOKEN_CACHE" 2>/dev/null || echo 0)
                    if [ -n "$c_at" ] && token_valid "$c_ex"; then
                        ACCESS_TOKEN="$c_at"
                        EXPIRY_RAW="$c_ex"
                    fi
                fi
            fi

            if ! token_valid "$EXPIRY_RAW" && [ -n "$REFRESH_TOKEN" ]; then
                secrets=""
                if [ -s "$SECRET_CACHE" ]; then
                    secrets=$(cat "$SECRET_CACHE")
                else
                    bin_path=$(command -v agy 2>/dev/null || true)
                    if [ -n "$bin_path" ] && [ -f "$bin_path" ]; then
                        secrets=$(grep -aoE 'GOCSPX-[A-Za-z0-9_-]{28}' "$bin_path" 2>/dev/null | sort -u || true)
                    fi
                fi

                for secret in $secrets; do
                    resp=$(curl -s --max-time 15 "https://oauth2.googleapis.com/token" \
                        --data-urlencode "client_id=1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com" \
                        --data-urlencode "client_secret=$secret" \
                        --data-urlencode "refresh_token=$REFRESH_TOKEN" \
                        --data-urlencode "grant_type=refresh_token" 2>/dev/null) || continue
                    at=$(printf '%s' "$resp" | jq -r '.access_token // empty' 2>/dev/null || true)
                    if [ -n "$at" ]; then
                        ein=$(printf '%s' "$resp" | jq -r '.expires_in // 3600' 2>/dev/null || echo 3600)
                        ACCESS_TOKEN="$at"
                        EXPIRY_RAW=$(( $(date +%s) + ein ))
                        printf '%s' "$secret" > "$SECRET_CACHE" 2>/dev/null || true
                        jq -n --arg t "$at" --argjson e "$EXPIRY_RAW" '{access_token:$t, expiry:$e}' > "$TOKEN_CACHE" 2>/dev/null || true
                        break
                    fi
                done
            fi

            PROJECT=""
            [ -f "$PROJECT_CACHE" ] && PROJECT=$(cat "$PROJECT_CACHE" 2>/dev/null || true)
            PLAN=""
            if [ -z "$PROJECT" ]; then
                LCA=$(curl -s --max-time 12 \
                    -H "Authorization: Bearer $ACCESS_TOKEN" \
                    -H "Content-Type: application/json" \
                    -H "Accept: application/json" \
                    -H "User-Agent: antigravity/cli/1.0.8 linux/amd64" \
                    -X POST "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist" \
                    --data '{"metadata":{"ideType":"ANTIGRAVITY"}}' 2>/dev/null || true)
                PROJECT=$(printf '%s' "$LCA" | jq -r '.cloudaicompanionProject // empty' 2>/dev/null || true)
                PLAN=$(printf '%s' "$LCA" | jq -r '(.paidTier.name // .currentTier.name) // empty' 2>/dev/null || true)
                if [ -n "$PROJECT" ]; then
                    printf '%s' "$PROJECT" > "$PROJECT_CACHE"
                    [ -n "$PLAN" ] && printf '%s' "$PLAN" > "$PLAN_CACHE"
                fi
            fi

            if [ -z "$PLAN" ] && [ -f "$PLAN_CACHE" ]; then
                PLAN=$(cat "$PLAN_CACHE" 2>/dev/null || true)
            fi

            if [ -n "$PROJECT" ]; then
                resp=$(curl -s --max-time 12 \
                    -H "Authorization: Bearer $ACCESS_TOKEN" \
                    -H "Content-Type: application/json" \
                    -H "Accept: application/json" \
                    -H "User-Agent: antigravity/cli/1.0.8 linux/amd64" \
                    -X POST "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary" \
                    --data "$(jq -n --arg p "$PROJECT" '{project:$p}')" 2>/dev/null || true)
                
                if printf '%s' "$resp" | jq -e '.groups' >/dev/null 2>&1; then
                    agy_data=$(printf '%s' "$resp" | jq -c --arg email "$ACCOUNT" --arg plan "$PLAN" '{
                        status: "ok",
                        email: $email,
                        plan: $plan,
                        entries: [.groups[] | .displayName as $groupName | .buckets[] | {
                            name: ($groupName + " - " + .displayName),
                            percentUsed: ((1 - (.remainingFraction // 1.0)) * 100 | round),
                            resetAt: ((.resetTime | fromdateiso8601) // 0)
                        }]
                    }' 2>/dev/null) || agy_data='{"status":"error","error":"Could not parse Antigravity quota response"}'
                else
                    agy_data='{"status":"error","error":"Failed to retrieve Antigravity quota summary"}'
                fi
            else
                agy_data='{"status":"error","error":"Failed to load Antigravity companion project"}'
            fi
        else
            agy_data='{"status":"error","reason":"not_authenticated","error":"Antigravity is not logged in. Run agy login in a terminal, then refresh AI Quotas."}'
        fi
    else
        agy_data='{"status":"error","error":"secret-tool is not installed. Please install libsecret."}'
    fi
fi

# ============================================================
# Ollama Cloud (plan via API key, usage via session-cookie scrape)
# ============================================================
ol_data='{"status":"unavailable"}'
if [ "$ol_enabled" = "1" ]; then
    ol_key="${OLLAMA_API_KEY:-}"
    if [ -z "$ol_key" ]; then
        ol_data_dir="${OPENCODE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode}"
        ol_key=$(jq -r '."ollama-cloud".key // empty' "$ol_data_dir/auth.json" 2>/dev/null)
    fi
    ol_key=$(printf '%s' "$ol_key" | tr -d '\r\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

    ol_cookie=""
    ol_cookie_attempted=0
    if [ -n "${OLLAMA_SESSION_COOKIE:-}" ]; then
        ol_cookie=$(printf '%s' "$OLLAMA_SESSION_COOKIE" | tr -d '\r\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
        case "$ol_cookie" in
            __Secure-session=*) ol_cookie="${ol_cookie#__Secure-session=}" ;;
        esac
        ol_cookie="${ol_cookie%%;*}"
        ol_cookie=$(printf '%s' "$ol_cookie" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    fi
    [ -n "$ol_cookie" ] && ol_cookie_attempted=1

    ol_is_num() {
        case "$1" in
            ''|*[!0-9.]*) return 1 ;;
            .*|*.) return 1 ;;
            *.*.*) return 1 ;;
        esac
        return 0
    }

    ol_plan=""
    ol_plan_ok=0
    ol_key_reason=""
    ol_key_err=""

    # Plan via API key
    if [ -n "$ol_key" ]; then
        ol_plan_resp=$(curl -s -m 15 -w '\n%{http_code}' \
            -X POST \
            -H "Authorization: Bearer $ol_key" \
            -H "Content-Type: application/json" \
            https://ollama.com/api/me 2>/dev/null)
        ol_plan_code=$(printf '%s\n' "$ol_plan_resp" | tail -n 1)
        ol_plan_body=$(printf '%s\n' "$ol_plan_resp" | sed '$d')
        case "$ol_plan_code" in
            2??)
                ol_plan=$(printf '%s' "$ol_plan_body" | jq -r '.Plan // empty' 2>/dev/null)
                if [ -n "$ol_plan" ]; then
                    ol_plan_ok=1
                else
                    ol_key_reason="parse_error"
                    ol_key_err="Could not parse the Ollama Cloud plan from the API response."
                fi
                ;;
            401)
                ol_key_reason="auth_expired"
                ol_key_err="Ollama Cloud rejected this API key. Check the key in plugin settings."
                ;;
            403)
                ol_key_reason="access_denied"
                ol_key_err="Ollama Cloud denied access for this API key."
                ;;
            429)
                ol_key_reason="rate_limited"
                ol_key_err="Ollama Cloud is temporarily rate limited. Try again shortly."
                ;;
            000)
                ol_key_reason="network"
                ol_key_err="Could not reach Ollama Cloud. Check your connection and try again."
                ;;
            *)
                ol_key_reason="http_error"
                ol_key_err="Ollama Cloud returned HTTP $ol_plan_code. Try again shortly."
                ;;
        esac
    fi

    # Usage via session-cookie scrape
    ol_usage_ok=0
    ol_usage_reason=""
    ol_usage_err=""
    ol_used=""
    ol_limit=""
    ol_reset_epoch=0
    if [ "$ol_cookie_attempted" = "1" ]; then
        ol_usage_resp=$(curl -s -m 20 -w '\n%{http_code}' \
            -H "Cookie: __Secure-session=$ol_cookie" \
            https://ollama.com/settings 2>/dev/null)
        ol_usage_code=$(printf '%s\n' "$ol_usage_resp" | tail -n 1)
        ol_usage_body=$(printf '%s\n' "$ol_usage_resp" | sed '$d')
        case "$ol_usage_code" in
            2??)
                ol_meter=$(printf '%s' "$ol_usage_body" | grep -oE 'aria-label="Monthly usage[^"]*"' | sed -n '1p')
                if [ -n "$ol_meter" ]; then
                    ol_inner=$(printf '%s' "$ol_meter" | sed -E 's/^aria-label="Monthly usage[[:space:]]+//; s/[[:space:]]+used"$//')
                    ol_used_raw=$(printf '%s' "$ol_inner" | sed -E 's/^[[:space:]]*\$//; s/[[:space:]]+of[[:space:]].*//' | tr -d ',')
                    ol_limit_raw=$(printf '%s' "$ol_inner" | sed -E 's/.*[[:space:]]+of[[:space:]]+\$//' | tr -d ',')
                    if ol_is_num "$ol_used_raw" && ol_is_num "$ol_limit_raw"; then
                        ol_used="$ol_used_raw"
                        ol_limit="$ol_limit_raw"
                        ol_usage_ok=1
                    fi
                    ol_iso=$(printf '%s' "$ol_usage_body" | grep -oE 'data-time="[^"]*"' | sed -n '1p' | sed -E 's/^data-time="//; s/"$//')
                    if [ -n "$ol_iso" ]; then
                        ol_iso=$(printf '%s' "$ol_iso" | sed -E 's/\.[0-9]+//; s/\+00:00$/Z/')
                        ol_reset_epoch=$(TZ=UTC jq -n --arg t "$ol_iso" '$t|fromdateiso8601' 2>/dev/null || true)
                        case "$ol_reset_epoch" in ''|*[!0-9]*) ol_reset_epoch=0 ;; esac
                    fi
                fi
                if [ "$ol_usage_ok" != "1" ]; then
                    if printf '%s' "$ol_usage_body" | grep -qi 'Sign in'; then
                        ol_usage_reason="auth_expired"
                        ol_usage_err="Ollama Cloud session expired. Re-paste your session cookie in plugin settings."
                    else
                        ol_usage_reason="parse_error"
                        ol_usage_err="Could not parse Ollama Cloud usage from the settings page."
                    fi
                fi
                ;;
            3??)
                ol_usage_reason="auth_expired"
                ol_usage_err="Ollama Cloud session expired. Re-paste your session cookie in plugin settings."
                ;;
            401)
                ol_usage_reason="auth_expired"
                ol_usage_err="Ollama Cloud session expired. Re-paste your session cookie in plugin settings."
                ;;
            403)
                ol_usage_reason="access_denied"
                ol_usage_err="Ollama Cloud denied access for this session cookie."
                ;;
            429)
                ol_usage_reason="rate_limited"
                ol_usage_err="Ollama Cloud is temporarily rate limited. Try again shortly."
                ;;
            000)
                ol_usage_reason="network"
                ol_usage_err="Could not reach Ollama Cloud. Check your connection and try again."
                ;;
            *)
                ol_usage_reason="http_error"
                ol_usage_err="Ollama Cloud returned HTTP $ol_usage_code. Try again shortly."
                ;;
        esac
    fi

    # Status precedence
    if [ "$ol_usage_ok" = "1" ] && [ "$ol_plan_ok" = "1" ]; then
        ol_data=$(jq -n -c \
            --arg plan "$ol_plan" \
            --arg used "$ol_used" \
            --arg limit "$ol_limit" \
            --argjson reset "$ol_reset_epoch" \
            '{status:"ok", plan:$plan, used:($used|tonumber), limit:($limit|tonumber), currency:"USD", resetsAt:$reset}')
    elif [ "$ol_usage_ok" = "1" ]; then
        ol_data=$(jq -n -c \
            --arg used "$ol_used" \
            --arg limit "$ol_limit" \
            --argjson reset "$ol_reset_epoch" \
            '{status:"ok", used:($used|tonumber), limit:($limit|tonumber), currency:"USD", resetsAt:$reset}')
    elif [ "$ol_plan_ok" = "1" ]; then
        if [ "$ol_cookie_attempted" = "1" ]; then
            ol_reason="$ol_usage_reason"
            ol_err="$ol_usage_err"
        else
            ol_reason="usage_requires_cookie"
            ol_err="Ollama usage requires a session cookie. Paste your __Secure-session cookie in plugin settings."
        fi
        ol_data=$(jq -n -c \
            --arg plan "$ol_plan" \
            --arg reason "$ol_reason" \
            --arg err "$ol_err" \
            '{status:"plan_only", plan:$plan, reason:$reason, error:$err}')
    elif [ -z "$ol_key" ] && [ "$ol_cookie_attempted" = "0" ]; then
        ol_data='{"status":"unavailable","reason":"not_configured","error":"Ollama Cloud is not configured. Set an API key or paste your session cookie in plugin settings."}'
    else
        if [ "$ol_cookie_attempted" = "1" ]; then
            ol_reason="$ol_usage_reason"
            ol_err="$ol_usage_err"
        else
            ol_reason="$ol_key_reason"
            ol_err="$ol_key_err"
        fi
        ol_data=$(jq -n -c \
            --arg reason "$ol_reason" \
            --arg err "$ol_err" \
            '{status:"error", reason:$reason, error:$err}')
    fi
fi

# ============================================================
# Merge and write cache
# ============================================================
out=$(jq -c -n \
    --argjson now "$now" \
    --argjson claude "$claude_data" \
    --argjson codex "$codex_data" \
    --argjson oc "$oc_data" \
    --argjson ds "$ds_data" \
    --argjson or "$or_data" \
    --argjson grok "$grok_data" \
    --argjson agy "$agy_data" \
    --argjson ol "$ol_data" \
    '{captured_at: $now, claude: $claude, codex: $codex, opencode: $oc, deepseek: $ds, openrouter: $or, grok: $grok, antigravity: $agy, ollama: $ol}') || exit 2

tmp="$cache.tmp.$$"
printf '%s' "$out" > "$tmp" && mv -f "$tmp" "$cache"
printf '%s' "$out"
