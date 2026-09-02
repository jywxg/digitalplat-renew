#!/usr/bin/env bash

# DigitalPlat Domain Renewal Checker

# API: https://domain-api.digitalplat.org/api/v1

# 列出所有域名，检查到期时间，发送 Telegram 通知

# 续期需在 Dashboard 手动操作（API 未暴露 renewal endpoint）

# Cloudflare bypass: uses cloudscraper Python helper

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/digitalplat_api_helper.py"
RENEWAL_WINDOW_DAYS="${RENEWAL_WINDOW_DAYS:-120}"
DOMAIN_FILE="/tmp/digitalplat_domains_$$"

cleanup() {
rm -f "$DOMAIN_FILE"
}
trap cleanup EXIT

if ! python3 -c "import cloudscraper" 2>/dev/null; then
echo "错误: 缺少 cloudscraper，运行: pip3 install cloudscraper" >&2
exit 1
fi

command -v jq >/dev/null || {
echo "错误: 缺少依赖 jq" >&2
exit 1
}

command -v curl >/dev/null || {
echo "错误: 缺少依赖 curl" >&2
exit 1
}

API_KEY="${DIGITALPLAT_API_KEY:?错误: 请先设置环境变量 DIGITALPLAT_API_KEY}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?错误: 请先设置环境变量 TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:?错误: 请先设置环境变量 TELEGRAM_CHAT_ID}"

is_permanent_domain() {
local expiry="${1:-}"
local slot_type="${2:-}"
local lifecycle_type="${3:-}"
expiry="${expiry,,}"
slot_type="${slot_type,,}"
lifecycle_type="${lifecycle_type,,}"

```
case "$slot_type" in
    permanent|unlimited) return 0 ;;
esac

case "$expiry" in
    permanent|free|unlimited|never|infinite|null|"") return 0 ;;
esac

case "$lifecycle_type" in
    permanent|unlimited) return 0 ;;
esac

return 1
```

}

get_domain_info() {
local expiry="${1:-}"
local slot_type="${2:-}"
local lifecycle_type="${3:-}"

```
if is_permanent_domain "$expiry" "$slot_type" "$lifecycle_type"; then
    printf '%s\n' "PERMANENT|永久|无需续期|永久|无需续期"
    return
fi

if [[ -z "$expiry" || "$expiry" == "null" ]]; then
    printf '%s\n' "UNKNOWN|未知|未知|未知|无法判断"
    return
fi

local expiry_epoch
expiry_epoch="$(date -d "$expiry" +%s 2>/dev/null || true)"

if [[ -z "$expiry_epoch" ]]; then
    printf '%s\n' "UNKNOWN|$expiry|未知|未知|无法解析"
    return
fi

local now_epoch
now_epoch="$(date +%s)"

local actual_expiry
actual_expiry="$(date -d "@$expiry_epoch" "+%Y-%m-%d")"

local renewal_epoch
renewal_epoch=$((expiry_epoch - RENEWAL_WINDOW_DAYS * 86400))

local renewal_date
renewal_date="$(date -d "@$renewal_epoch" "+%Y-%m-%d")"

local days_left
days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

if (( days_left < 0 )); then
    printf '%s\n' "EXPIRED|$actual_expiry|$renewal_date|已过期|已过期"
    return
fi

if (( days_left <= RENEWAL_WINDOW_DAYS )); then
    printf '%s\n' "RENEWABLE|$actual_expiry|$renewal_date|${days_left}天|可以续期"
    return
fi

printf '%s\n' "VALID|$actual_expiry|$renewal_date|${days_left}天|未到续期时间"
```

}

echo "正在获取域名列表..."

DEBUG_OUTPUT="$(mktemp)"

response="$(
python3 "$HELPER" "/domains" "Bearer ${API_KEY}" --debug 2>"$DEBUG_OUTPUT"
)"

cf_debug="$(cat "$DEBUG_OUTPUT")"
rm -f "$DEBUG_OUTPUT"

if [[ "$cf_debug" == *RAW_RESPONSE* ]]; then
echo "=== CF Debug Output ===" >&2
echo "$cf_debug" >&2
fi

domain_list=""

if echo "$response" | jq -e 'type == "array"' >/dev/null 2>&1; then
echo "API 返回: 直接数组" >&2
domain_list="$(echo "$response" | jq '.')"
elif echo "$response" | jq -e '.success == true and (.data | type == "array")' >/dev/null 2>&1; then
echo "API 返回: {success:true, data:[...]}" >&2
domain_list="$(echo "$response" | jq '.data')"
elif echo "$response" | jq -e '.data | type == "array"' >/dev/null 2>&1; then
echo "API 返回: {data:[...]}" >&2
domain_list="$(echo "$response" | jq '.data')"
elif echo "$response" | jq -e '.domains | type == "array"' >/dev/null 2>&1; then
echo "API 返回: {domains:[...]}" >&2
domain_list="$(echo "$response" | jq '.domains')"
else
echo "错误: 无法解析 API 响应" >&2
echo "原始响应: $response" >&2
echo "CF debug: $cf_debug" >&2
exit 1
fi

jq -r '
.[] |
[
(.name // .domain // ""),
(.status // .state // ""),
(.expiry_date // .expiration_date // .expires_at // .expiry // .expire // ""),
(.slot_type // .slot // ""),
(.lifecycle_type // .lifecycle // .type // "")
] |
@tsv
' <<<"$domain_list" |
while IFS=$'\t' read -r name status expiry_date slot_type lifecycle_type; do
if [[ -n "$name" && "$name" != "null" ]]; then
printf '%s|%s|%s|%s|%s\n' 
"$name" 
"$status" 
"$expiry_date" 
"$slot_type" 
"$lifecycle_type"
fi
done > "$DOMAIN_FILE"

domain_count="$(wc -l < "$DOMAIN_FILE")"

echo "已解析 ${domain_count} 个域名"

printf '%-32s %-10s %-15s %-15s %-10s %s\n' 
"域名" 
"状态" 
"实际到期时间" 
"可续期时间" 
"距到期" 
"续期状态"

printf '%s\n' 
"----------------------------------------------------------------------------------------------------------"

total_count=0
valid_count=0
renewal_needed=0
expired_count=0
permanent_count=0
unknown_count=0

notification_lines=()
notification_lines+=("<b>DigitalPlat 域名状态检查</b>")
notification_lines+=("")

while IFS='|' read -r name status expiry_date slot_type lifecycle_type; do
[[ -z "$name" || "$name" == "null" ]] && continue

```
total_count=$((total_count + 1))

info="$(get_domain_info "$expiry_date" "$slot_type" "$lifecycle_type")"

IFS='|' read -r \
    domain_type \
    actual_expiry \
    renewal_date \
    days_left \
    renewal_status \
    <<< "$info"

printf '%-32s %-10s %-15s %-15s %-10s %s\n' \
    "$name" \
    "$status" \
    "$actual_expiry" \
    "$renewal_date" \
    "$days_left" \
    "$renewal_status"

case "$domain_type" in
    PERMANENT)
        permanent_count=$((permanent_count + 1))
        notification_lines+=("♾️ <code>${name}</code>")
        notification_lines+=("状态：${status}")
        notification_lines+=("实际到期：永久")
        notification_lines+=("可续期时间：无需续期")
        notification_lines+=("续期状态：无需续期")
        notification_lines+=("")
        ;;
    VALID)
        valid_count=$((valid_count + 1))
        notification_lines+=("✅ <code>${name}</code>")
        notification_lines+=("状态：${status}")
        notification_lines+=("实际到期：${actual_expiry}")
        notification_lines+=("可续期开始：${renewal_date}")
        notification_lines+=("距离到期：${days_left}")
        notification_lines+=("续期状态：${renewal_status}")
        notification_lines+=("")
        ;;
    RENEWABLE)
        renewal_needed=$((renewal_needed + 1))
        notification_lines+=("⚠️ <code>${name}</code>")
        notification_lines+=("状态：${status}")
        notification_lines+=("实际到期：${actual_expiry}")
        notification_lines+=("可续期开始：${renewal_date}")
        notification_lines+=("距离到期：${days_left}")
        notification_lines+=("续期状态：可以续期")
        notification_lines+=("")
        ;;
    EXPIRED)
        expired_count=$((expired_count + 1))
        notification_lines+=("❌ <code>${name}</code>")
        notification_lines+=("状态：${status}")
        notification_lines+=("实际到期：${actual_expiry}")
        notification_lines+=("可续期开始：${renewal_date}")
        notification_lines+=("续期状态：已过期")
        notification_lines+=("")
        ;;
    *)
        unknown_count=$((unknown_count + 1))
        notification_lines+=("❓ <code>${name}</code>")
        notification_lines+=("状态：${status}")
        notification_lines+=("实际到期：${actual_expiry}")
        notification_lines+=("可续期时间：${renewal_date}")
        notification_lines+=("续期状态：${renewal_status}")
        notification_lines+=("")
        ;;
esac
```

done < "$DOMAIN_FILE"

echo
echo "域名总数: $total_count"
echo "正常域名: $valid_count"
echo "需要续期: $renewal_needed"
echo "已过期: $expired_count"
echo "永久域名: $permanent_count"
echo "未知状态: $unknown_count"

notification_lines+=("────────────────────")
notification_lines+=("")
notification_lines+=("<b>📊 域名汇总</b>")
notification_lines+=("")
notification_lines+=("域名总数：${total_count}")
notification_lines+=("正常域名：${valid_count}")
notification_lines+=("需要续期：${renewal_needed}")
notification_lines+=("已过期：${expired_count}")
notification_lines+=("永久域名：${permanent_count}")
notification_lines+=("未知状态：${unknown_count}")
notification_lines+=("")

if (( expired_count > 0 )); then
notification_lines+=("❌ 存在已过期域名")
elif (( renewal_needed > 0 )); then
notification_lines+=("⚠️ 存在可续期域名")
else
notification_lines+=("✅ 所有域名状态正常")
fi

notification_lines+=("")
notification_lines+=("🔗 <a href="https://dash.domain.digitalplat.org/dashboard\">前往 Dashboard</a>")

message=""

for line in "${notification_lines[@]}"; do
if (( ${#message} + ${#line} + 1 > 3800 )); then
curl 
--fail-with-body 
--silent 
--show-error 
"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" 
--data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" 
--data-urlencode "parse_mode=HTML" 
--data-urlencode "text=$message" 
>/dev/null

```
    message="<b>DigitalPlat 域名检查（续）</b>"
fi

if [[ -n "$message" ]]; then
    message+=$'\n'
fi

message+="$line"
```

done

if [[ -n "$message" ]]; then
curl 
--fail-with-body 
--silent 
--show-error 
"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" 
--data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" 
--data-urlencode "parse_mode=HTML" 
--data-urlencode "text=$message" 
>/dev/null
fi

echo "Telegram 通知已发送"
