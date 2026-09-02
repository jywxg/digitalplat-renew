#!/usr/bin/env bash

# ============================================================

# DigitalPlat 域名状态检查与续期脚本

#

# 功能：

# 1. 获取 DigitalPlat 域名列表

# 2. 判断永久域名 / 普通域名

# 3. 显示实际到期时间

# 4. 计算可续期开始时间

# 5. 判断是否已进入续期窗口

# 6. 统计永久、待续期、已过期域名

# 7. Telegram 发送通知

# ============================================================

set -Eeuo pipefail

# ------------------------------------------------------------

# 配置

# ------------------------------------------------------------

# API 地址

DIGITALPLAT_API_URL="${DIGITALPLAT_API_URL:-https://domain.digitalplat.org/api/domain/list}"

# 续期窗口（单位：天）

# 例如 120 表示距离到期 120 天以内进入续期窗口

RENEWAL_WINDOW_DAYS="${RENEWAL_WINDOW_DAYS:-120}"

# Telegram API

TELEGRAM_API="https://api.telegram.org"

# ------------------------------------------------------------

# 临时文件

# ------------------------------------------------------------

TMP_DIR="$(mktemp -d)"
DOMAIN_FILE="$TMP_DIR/domains.txt"
RESPONSE_FILE="$TMP_DIR/response.json"

cleanup() {
rm -rf "$TMP_DIR"
}

trap cleanup EXIT

# ------------------------------------------------------------

# 检查依赖

# ------------------------------------------------------------

command -v curl >/dev/null 2>&1 || {
echo "错误：未找到 curl"
exit 1
}

command -v jq >/dev/null 2>&1 || {
echo "错误：未找到 jq"
exit 1
}

command -v date >/dev/null 2>&1 || {
echo "错误：未找到 date"
exit 1
}

# ------------------------------------------------------------

# 检查环境变量

# ------------------------------------------------------------

if [[ -z "${DIGITALPLAT_API_KEY:-}" ]]; then
echo "错误：DIGITALPLAT_API_KEY 未设置"
exit 1
fi

# ------------------------------------------------------------

# 工具函数

# ------------------------------------------------------------

is_permanent_domain() {

```
local expiry_date="${1:-}"
local slot_type="${2:-}"
local lifecycle_type="${3:-}"

expiry_date="${expiry_date,,}"
slot_type="${slot_type,,}"
lifecycle_type="${lifecycle_type,,}"

# slot_type=permanent 明确视为永久域名
if [[ "$slot_type" == "permanent" ]]; then
    return 0
fi

# expiry_date 返回永久类型
case "$expiry_date" in
    permanent|free|unlimited|never|infinite)
        return 0
        ;;
esac

# lifecycle_type 可能存在永久标识
case "$lifecycle_type" in
    permanent|free|unlimited)
        return 0
        ;;
esac

return 1
```

}

format_date() {

```
local value="${1:-}"

if [[ -z "$value" || "$value" == "null" ]]; then
    echo "未知"
    return
fi

local epoch

epoch="$(date -d "$value" +%s 2>/dev/null || true)"

if [[ -z "$epoch" ]]; then
    echo "$value"
    return
fi

date -d "@$epoch" "+%Y-%m-%d"
```

}

get_domain_info() {

```
local expiry_date="${1:-}"
local slot_type="${2:-}"
local lifecycle_type="${3:-}"

# --------------------------------------------------------
# 永久域名
# --------------------------------------------------------

if is_permanent_domain \
    "$expiry_date" \
    "$slot_type" \
    "$lifecycle_type"
then

    echo "PERMANENT|永久|无需续期|永久|无需续期"
    return
fi

# --------------------------------------------------------
# 无有效到期时间
# --------------------------------------------------------

if [[ -z "$expiry_date" || "$expiry_date" == "null" ]]; then

    echo "UNKNOWN|未知|未知|未知|无法判断"
    return
fi

# --------------------------------------------------------
# 解析到期时间
# --------------------------------------------------------

local expiry_epoch

expiry_epoch="$(date -d "$expiry_date" +%s 2>/dev/null || true)"

if [[ -z "$expiry_epoch" ]]; then

    echo "UNKNOWN|$expiry_date|未知|未知|无法解析"
    return
fi

# 当前时间
local now_epoch

now_epoch="$(date +%s)"

# 实际到期日期
local actual_expiry

actual_expiry="$(date -d "@$expiry_epoch" "+%Y-%m-%d")"

# --------------------------------------------------------
# 可续期开始时间
# --------------------------------------------------------

local renewal_epoch

renewal_epoch=$((expiry_epoch - RENEWAL_WINDOW_DAYS * 86400))

local renewal_date

renewal_date="$(date -d "@$renewal_epoch" "+%Y-%m-%d")"

# --------------------------------------------------------
# 剩余天数
# --------------------------------------------------------

local days_left

days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

# --------------------------------------------------------
# 已过期
# --------------------------------------------------------

if (( days_left < 0 )); then

    echo "EXPIRED|$actual_expiry|$renewal_date|已过期|已过期"
    return
fi

# --------------------------------------------------------
# 已进入续期窗口
# --------------------------------------------------------

if (( days_left <= RENEWAL_WINDOW_DAYS )); then

    echo "RENEWABLE|$actual_expiry|$renewal_date|${days_left}天|可以续期"
    return
fi

# --------------------------------------------------------
# 正常，尚未进入续期窗口
# --------------------------------------------------------

echo "VALID|$actual_expiry|$renewal_date|${days_left}天|未到续期时间"
```

}

send_telegram_message() {

```
local message="$1"

# 未配置 Telegram 时跳过
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

local response

response="$(
    curl \
        --silent \
        --show-error \
        --fail \
        --max-time 30 \
        -X POST \
        "$telegram_url" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${message}" \
        -d "disable_web_page_preview=true"
)" || {
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
```

}

# ============================================================

# 获取域名列表

# ============================================================

echo "正在获取域名列表..."

HTTP_CODE="$(
curl 
--silent 
--show-error 
--location 
--max-time 30 
--output "$RESPONSE_FILE" 
--write-out "%{http_code}" 
"$DIGITALPLAT_API_URL" 
-H "Authorization: Bearer ${DIGITALPLAT_API_KEY}" 
-H "Content-Type: application/json"
)"

if [[ "$HTTP_CODE" != "200" ]]; then

```
echo "获取域名列表失败，HTTP 状态码：$HTTP_CODE"

echo "API 返回："

cat "$RESPONSE_FILE" || true

exit 1
```

fi

# ------------------------------------------------------------

# 检查 JSON

# ------------------------------------------------------------

if ! jq empty "$RESPONSE_FILE" >/dev/null 2>&1; then

```
echo "错误：API 返回不是有效 JSON"

cat "$RESPONSE_FILE"

exit 1
```

fi

# ------------------------------------------------------------

# 检查 API success

# ------------------------------------------------------------

API_SUCCESS="$(jq -r '.success // empty' "$RESPONSE_FILE")"

if [[ "$API_SUCCESS" != "true" ]]; then

```
echo "DigitalPlat API 返回失败"

cat "$RESPONSE_FILE"

exit 1
```

fi

# ------------------------------------------------------------

# 检查 data

# ------------------------------------------------------------

DOMAIN_COUNT="$(jq '.data | length' "$RESPONSE_FILE" 2>/dev/null || echo "0")"

if [[ ! "$DOMAIN_COUNT" =~ ^[0-9]+$ ]]; then

```
echo "无法解析域名数量"

cat "$RESPONSE_FILE"

exit 1
```

fi

# ------------------------------------------------------------

# 导出域名

# ------------------------------------------------------------

jq -r '
.data[]
|
[
(.name // .domain // ""),
(.status // ""),
(.expiry_date // .expiration_date // .expires_at // ""),
(.slot_type // ""),
(.lifecycle_type // "")
]
|
@tsv
' "$RESPONSE_FILE" > "$DOMAIN_FILE"

echo "API 请求成功"
echo "已解析 ${DOMAIN_COUNT} 个域名"
echo

# ============================================================

# 初始化统计

# ============================================================

total_count=0

renewal_needed=0

expired_count=0

permanent_count=0

valid_count=0

unknown_count=0

# ============================================================

# 输出表头

# ============================================================

printf "%-32s %-8s %-15s %-15s %-10s %s\n" 
"域名" 
"状态" 
"实际到期时间" 
"可续期时间" 
"距到期" 
"续期状态"

printf "%s\n" 
"---------------------------------------------------------------------------------------------------------------"

# ============================================================

# Telegram 消息

# ============================================================

TELEGRAM_MESSAGE="📊 DigitalPlat 域名状态检查

"

# ============================================================

# 遍历域名

# ============================================================

while IFS=$'\t' read -r 
name 
status 
expiry_date 
slot_type 
lifecycle_type
do

```
[[ -z "$name" ]] && continue

# --------------------------------------------------------
# 域名总数
# --------------------------------------------------------

total_count=$((total_count + 1))


# --------------------------------------------------------
# 获取域名状态信息
# --------------------------------------------------------

info="$(
    get_domain_info \
        "$expiry_date" \
        "$slot_type" \
        "$lifecycle_type"
)"


IFS='|' read -r \
    domain_type \
    actual_expiry \
    renewal_date \
    days_left \
    renewal_status \
    <<< "$info"


# --------------------------------------------------------
# 控制台表格
# --------------------------------------------------------

printf "%-32s %-8s %-15s %-15s %-10s %s\n" \
    "$name" \
    "$status" \
    "$actual_expiry" \
    "$renewal_date" \
    "$days_left" \
    "$renewal_status"


# --------------------------------------------------------
# Telegram 域名状态
# --------------------------------------------------------

case "$domain_type" in

    PERMANENT)

        permanent_count=$((permanent_count + 1))

        TELEGRAM_MESSAGE+="♾️ ${name}
```

状态：${status}
实际到期：永久
可续期时间：无需续期
续期状态：无需续期

"
;;

```
    VALID)

        valid_count=$((valid_count + 1))

        TELEGRAM_MESSAGE+="✅ ${name}
```

状态：${status}
实际到期：${actual_expiry}
可续期开始：${renewal_date}
距离到期：${days_left}
续期状态：${renewal_status}

"
;;

```
    RENEWABLE)

        renewal_needed=$((renewal_needed + 1))

        TELEGRAM_MESSAGE+="⚠️ ${name}
```

状态：${status}
实际到期：${actual_expiry}
可续期开始：${renewal_date}
距离到期：${days_left}
续期状态：可以续期

"
;;

```
    EXPIRED)

        expired_count=$((expired_count + 1))

        TELEGRAM_MESSAGE+="❌ ${name}
```

状态：${status}
实际到期：${actual_expiry}
可续期开始：${renewal_date}
续期状态：已过期

"
;;

```
    *)

        unknown_count=$((unknown_count + 1))

        TELEGRAM_MESSAGE+="❓ ${name}
```

状态：${status}
实际到期：${actual_expiry}
可续期时间：${renewal_date}
续期状态：${renewal_status}

"
;;
esac

done < "$DOMAIN_FILE"

# ============================================================

# 输出统计

# ============================================================

echo

echo "域名总数: $total_count"

echo "正常域名: $valid_count"

echo "需要续期: $renewal_needed"

echo "已过期: $expired_count"

echo "永久域名: $permanent_count"

echo "未知状态: $unknown_count"

# ============================================================

# Telegram 汇总

# ============================================================

TELEGRAM_MESSAGE+="────────────────────

📊 域名汇总

域名总数：${total_count}
正常域名：${valid_count}
需要续期：${renewal_needed}
已过期：${expired_count}
永久域名：${permanent_count}
未知状态：${unknown_count}

"

# ============================================================

# 最终状态

# ============================================================

if (( expired_count > 0 )); then

```
TELEGRAM_MESSAGE+="❌ 存在已过期域名"
```

elif (( renewal_needed > 0 )); then

```
TELEGRAM_MESSAGE+="⚠️ 存在可续期域名"
```

else

```
TELEGRAM_MESSAGE+="✅ 所有域名状态正常"
```

fi

# ============================================================

# 发送 Telegram

# ============================================================

send_telegram_message "$TELEGRAM_MESSAGE"
