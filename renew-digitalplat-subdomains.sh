#!/usr/bin/env bash
set -Eeuo pipefail

DIGITALPLAT_API_URL="${DIGITALPLAT_API_URL:-https://domain.digitalplat.org/api/domain/list}"
RENEWAL_WINDOW_DAYS="${RENEWAL_WINDOW_DAYS:-120}"
TELEGRAM_API="https://api.telegram.org"

TMP_DIR="$(mktemp -d)"
RESPONSE_FILE="$TMP_DIR/response.json"
DOMAIN_FILE="$TMP_DIR/domains.tsv"

cleanup() {
rm -rf "$TMP_DIR"
}
trap cleanup EXIT

for cmd in curl jq date; do
if ! command -v "$cmd" >/dev/null 2>&1; then
echo "错误：未找到命令 $cmd"
exit 1
fi
done

if [[ -z "${DIGITALPLAT_API_KEY:-}" ]]; then
echo "错误：DIGITALPLAT_API_KEY 未设置"
exit 1
fi

is_permanent_domain() {
local expiry_date="${1:-}"
local slot_type="${2:-}"
local lifecycle_type="${3:-}"
expiry_date="${expiry_date,,}"
slot_type="${slot_type,,}"
lifecycle_type="${lifecycle_type,,}"
[[ "$slot_type" == "permanent" ]] && return 0
case "$expiry_date" in
permanent|free|unlimited|never|infinite) return 0 ;;
esac
case "$lifecycle_type" in
permanent|free|unlimited) return 0 ;;
esac
return 1
}

get_domain_info() {
local expiry_date="${1:-}"
local slot_type="${2:-}"
local lifecycle_type="${3:-}"
if is_permanent_domain "$expiry_date" "$slot_type" "$lifecycle_type"; then
echo "PERMANENT|永久|无需续期|永久|无需续期"
return
fi
if [[ -z "$expiry_date" || "$expiry_date" == "null" ]]; then
echo "UNKNOWN|未知|未知|未知|无法判断"
return
fi
local expiry_epoch
expiry_epoch="$(date -d "$expiry_date" +%s 2>/dev/null || true)"
if [[ -z "$expiry_epoch" ]]; then
echo "UNKNOWN|$expiry_date|未知|未知|无法解析"
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
echo "EXPIRED|$actual_expiry|$renewal_date|已过期|已过期"
return
fi
if (( days_left <= RENEWAL_WINDOW_DAYS )); then
echo "RENEWABLE|$actual_expiry|$renewal_date|${days_left}天|可以续期"
return
fi
echo "VALID|$actual_expiry|$renewal_date|${days_left}天|未到续期时间"
}

send_telegram_message() {
local message="$1"
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
echo "未配置 TELEGRAM_BOT_TOKEN，跳过 Telegram 通知"
return 0
fi
if [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
echo "未配置 TELEGRAM_CHAT_ID，跳过 Telegram 通知"
return 0
fi
local telegram_url
telegram_url="${TELEGRAM_API}/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
local -a telegram_curl_args=(
--silent
--show-error
--max-time
30
-X
POST
"$telegram_url"
-d
"chat_id=${TELEGRAM_CHAT_ID}"
--data-urlencode
"text=${message}"
-d
"disable_web_page_preview=true"
)
local response
response="$(curl "${telegram_curl_args[@]}")" || {
echo "Telegram 通知发送失败"
return 1
}
if echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
echo "Telegram 通知已发送"
else
echo "Telegram API 返回异常："
echo "$response"
return 1
fi
}

echo "正在获取域名列表..."
curl_args=(
--silent
--show-error
--location
--max-time
30
--output
"$RESPONSE_FILE"
--write-out
"%{http_code}"
"$DIGITALPLAT_API_URL"
-H
"Authorization: Bearer ${DIGITALPLAT_API_KEY}"
-H
"Content-Type: application/json"
)
HTTP_CODE="$(curl "${curl_args[@]}" || true)"
echo "HTTP 状态码：${HTTP_CODE}"
if [[ "$HTTP_CODE" != "200" ]]; then
echo "获取域名列表失败"
echo "API 返回："
cat "$RESPONSE_FILE" 2>/dev/null || true
exit 1
fi

if ! jq empty "$RESPONSE_FILE" >/dev/null 2>&1; then
echo "错误：API 返回不是有效 JSON"
cat "$RESPONSE_FILE"
exit 1
fi

API_SUCCESS="$(jq -r '.success // empty' "$RESPONSE_FILE")"
if [[ "$API_SUCCESS" != "true" ]]; then
echo "DigitalPlat API 返回失败"
cat "$RESPONSE_FILE"
exit 1
fi

DOMAIN_COUNT="$(jq '.data | length' "$RESPONSE_FILE")"
echo "API 请求成功"
echo "已解析 ${DOMAIN_COUNT} 个域名"

jq -r '
.data[]
| [
(.name // .domain // ""),
(.status // ""),
(.expiry_date // .expiration_date // .expires_at // ""),
(.slot_type // ""),
(.lifecycle_type // "")
]
| @tsv
' "$RESPONSE_FILE" > "$DOMAIN_FILE"

total_count=0
valid_count=0
renewal_needed=0
expired_count=0
permanent_count=0
unknown_count=0

echo
printf "%-32s %-8s %-15s %-15s %-10s %s\n" "域名" "状态" "实际到期时间" "可续期时间" "距到期" "续期状态"
printf "%s\n" "---------------------------------------------------------------------------------------------------------------"

TELEGRAM_MESSAGE=$'📊 DigitalPlat 域名状态检查\n\n'

while IFS=$'\t' read -r name status expiry_date slot_type lifecycle_type; do
[[ -z "$name" ]] && continue
total_count=$((total_count + 1))
info="$(get_domain_info "$expiry_date" "$slot_type" "$lifecycle_type")"
IFS='|' read -r domain_type actual_expiry renewal_date days_left renewal_status <<< "$info"
printf "%-32s %-8s %-15s %-15s %-10s %s\n" "$name" "$status" "$actual_expiry" "$renewal_date" "$days_left" "$renewal_status"
case "$domain_type" in
PERMANENT)
permanent_count=$((permanent_count + 1))
TELEGRAM_MESSAGE+="♾️ ${name}
状态：${status}
实际到期：永久
可续期时间：无需续期
续期状态：无需续期

"
;;
VALID)
valid_count=$((valid_count + 1))
TELEGRAM_MESSAGE+="✅ ${name}
状态：${status}
实际到期：${actual_expiry}
可续期开始：${renewal_date}
距离到期：${days_left}
续期状态：${renewal_status}

"
;;
RENEWABLE)
renewal_needed=$((renewal_needed + 1))
TELEGRAM_MESSAGE+="⚠️ ${name}
状态：${status}
实际到期：${actual_expiry}
可续期开始：${renewal_date}
距离到期：${days_left}
续期状态：可以续期

"
;;
EXPIRED)
expired_count=$((expired_count + 1))
TELEGRAM_MESSAGE+="❌ ${name}
状态：${status}
实际到期：${actual_expiry}
可续期开始：${renewal_date}
续期状态：已过期

"
;;
*)
unknown_count=$((unknown_count + 1))
TELEGRAM_MESSAGE+="❓ ${name}
状态：${status}
实际到期：${actual_expiry}
可续期时间：${renewal_date}
续期状态：${renewal_status}

"
;;
esac
done < "$DOMAIN_FILE"

echo
echo "域名总数: $total_count"
echo "正常域名: $valid_count"
echo "需要续期: $renewal_needed"
echo "已过期: $expired_count"
echo "永久域名: $permanent_count"
echo "未知状态: $unknown_count"

TELEGRAM_MESSAGE+="────────────────────

📊 域名汇总

域名总数：${total_count}
正常域名：${valid_count}
需要续期：${renewal_needed}
已过期：${expired_count}
永久域名：${permanent_count}
未知状态：${unknown_count}

"

if (( expired_count > 0 )); then
TELEGRAM_MESSAGE+="❌ 存在已过期域名"
elif (( renewal_needed > 0 )); then
TELEGRAM_MESSAGE+="⚠️ 存在可续期域名"
else
TELEGRAM_MESSAGE+="✅ 所有域名状态正常"
fi

send_telegram_message "$TELEGRAM_MESSAGE"
