#!/usr/bin/env bash
# DigitalPlat Domain Renewal Checker
# API: https://domain-api.digitalplat.org/api/v1
# 列出所有域名，检查到期时间，发送 Telegram 通知
# 续期需在 dashboard 手动操作（API 未暴露 renewal endpoint）
# Cloudflare bypass: uses cloudscraper Python helper (digitalplat_api_helper.py)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/digitalplat_api_helper.py"
API_BASE="https://domain-api.digitalplat.org/api/v1"
RENEWAL_WINDOW_DAYS=120

DOMAIN_FILE="$(mktemp)"
DEBUG_OUTPUT="$(mktemp)"
trap 'rm -f "$DOMAIN_FILE" "$DEBUG_OUTPUT"' EXIT

# 检查依赖
if ! command -v python3 >/dev/null 2>&1; then
    echo "错误: 缺少 python3" >&2
    exit 1
fi

if ! python3 -c "import cloudscraper" 2>/dev/null; then
    echo "错误: 缺少 cloudscraper，运行: pip3 install cloudscraper" >&2
    exit 1
fi

command -v jq >/dev/null 2>&1 || {
    echo "错误: 缺少依赖 jq" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || {
    echo "错误: 缺少依赖 curl" >&2
    exit 1
}

[[ -f "$HELPER" ]] || {
    echo "错误: 找不到 $HELPER" >&2
    exit 1
}

# API Key / Telegram 配置
API_KEY="${DIGITALPLAT_API_KEY:?错误: 请先设置环境变量 DIGITALPLAT_API_KEY}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?错误: 请先设置环境变量 TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:?错误: 请先设置环境变量 TELEGRAM_CHAT_ID}"

# HTML 转义，防止域名中出现特殊字符导致 Telegram HTML 解析失败
html_escape() {
    printf '%s' "$1" |
        sed -e 's/&/\&amp;/g' \
            -e 's/</\&lt;/g' \
            -e 's/>/\&gt;/g'
}

# 判断是否为永久域名
is_permanent() {
    local expiry="$1"

    [[ "$expiry" == "permanent" ||
       "$expiry" == "PERMANENT" ||
       "$expiry" == "null" ||
       -z "$expiry" ]]
}

# 计算剩余天数
# 返回值：
#   0  = 无法解析
#   正数 = 剩余天数
#   负数 = 已过期天数
get_days_left() {
    local expiry="$1"
    local expiry_epoch now_epoch

    if is_permanent "$expiry"; then
        echo "0"
        return
    fi

    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null) || {
        echo "0"
        return
    }

    now_epoch=$(date +%s)
    echo $(( (expiry_epoch - now_epoch) / 86400 ))
}

# 判断是否需要续期
needs_renewal() {
    local expiry="$1"
    local days_left

    if is_permanent "$expiry"; then
        echo "no"
        return
    fi

    days_left="$(get_days_left "$expiry")"

    # 无法解析日期时不自动判断为需要续期
    if [[ "$days_left" == "0" ]] && ! date -d "$expiry" +%s >/dev/null 2>&1; then
        echo "no"
        return
    fi

    # 保持原脚本逻辑：120 天以内（包括已过期）进入处理范围
    if (( days_left <= RENEWAL_WINDOW_DAYS )); then
        echo "yes"
    else
        echo "no"
    fi
}

# 格式化有效期
format_expiry() {
    local expiry="$1"

    if is_permanent "$expiry"; then
        echo "永久"
        return
    fi

    # 尽量统一成 YYYY-MM-DD；失败则保留 API 原值
    date -d "$expiry" '+%Y-%m-%d' 2>/dev/null || printf '%s' "$expiry"
}

# 获取域名列表
echo "正在获取域名列表..."

response=$(python3 "$HELPER" "/domains" "Bearer ${API_KEY}" --debug 2>"$DEBUG_OUTPUT")
cf_debug="$(cat "$DEBUG_OUTPUT")"

if [[ "$cf_debug" == *RAW_RESPONSE* ]]; then
    echo "=== CF Debug Output ===" >&2
    echo "$cf_debug" >&2
fi

# 尝试多种 JSON 结构
domain_list=""

if echo "$response" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "API 返回: 直接数组" >&2
    domain_list="$(echo "$response" | jq '.')"

elif echo "$response" | jq -e '.success == true and (.data | type == "array")' >/dev/null 2>&1; then
    echo "API 返回: {success:true, data:[]}" >&2
    domain_list="$(echo "$response" | jq '.data')"

elif echo "$response" | jq -e '.data | type == "array"' >/dev/null 2>&1; then
    echo "API 返回: {data:[]}" >&2
    domain_list="$(echo "$response" | jq '.data')"

elif echo "$response" | jq -e '.domains | type == "array"' >/dev/null 2>&1; then
    echo "API 返回: {domains:[]}" >&2
    domain_list="$(echo "$response" | jq '.domains')"

else
    echo "错误: 无法解析 API 响应" >&2
    echo "原始响应: $response" >&2
    echo "CF debug: $cf_debug" >&2
    exit 1
fi

# 解析域名数据
jq -r '
    .[] |
    [
        (.name // .domain // ""),
        (.status // .state // ""),
        (.expiry_date // .expiry // .expire // ""),
        (.slot_type // .slot // ""),
        (.lifecycle_type // .lifecycle // .type // "")
    ] | @tsv
' <<<"$domain_list" |
while IFS=$'\t' read -r name status expiry_date slot_type lifecycle_type; do
    [[ -z "$name" || "$name" == "null" ]] && continue
    printf '%s|%s|%s|%s|%s\n' \
        "$name" "$status" "$expiry_date" "$slot_type" "$lifecycle_type"
done > "$DOMAIN_FILE"

domain_count="$(grep -cve '^$' "$DOMAIN_FILE" || true)"

echo "已解析 ${domain_count} 个域名" >&2

if (( domain_count == 0 )); then
    echo "错误: API 返回 0 个可识别域名" >&2
    exit 1
fi

# 打印本地表格
printf '%-35s %-12s %-22s %-12s %-12s %s\n' \
    "域名" "状态" "有效期" "Slot Type" "Lifecycle" "需续期"

printf '%-35s %-12s %-22s %-12s %-12s %s\n' \
    "-----------------------------------" \
    "------------" \
    "----------------------" \
    "------------" \
    "------------" \
    "------"

while IFS='|' read -r name status expiry_date slot_type lifecycle_type; do
    [[ -z "$name" || "$name" == "null" ]] && continue

    renew="$(needs_renewal "$expiry_date")"
    formatted_expiry="$(format_expiry "$expiry_date")"

    if is_permanent "$expiry_date"; then
        display_status="永久"
    else
        days_left="$(get_days_left "$expiry_date")"

        if (( days_left < 0 )); then
            display_status="已过期"
        elif (( days_left <= RENEWAL_WINDOW_DAYS )); then
            display_status="需续期"
        else
            display_status="正常"
        fi
    fi

    printf '%-35s %-12s %-22s %-12s %-12s %s\n' \
        "$name" \
        "$status" \
        "$formatted_expiry" \
        "$slot_type" \
        "$lifecycle_type" \
        "$renew"
done < "$DOMAIN_FILE"

# ============================================================
# Telegram 通知
# ============================================================

notification_lines=()

notification_lines+=("<b>🌐 DigitalPlat 域名状态</b>")
notification_lines+=("")

renewal_needed=0
expired_count=0
permanent_count=0
normal_count=0
renewal_count=0

# 先统计
while IFS='|' read -r name status expiry_date slot_type lifecycle_type; do
    [[ -z "$name" || "$name" == "null" ]] && continue

    ((renewal_count++)) || true

    if is_permanent "$expiry_date"; then
        ((permanent_count++)) || true
        continue
    fi

    days_left="$(get_days_left "$expiry_date")"

    if (( days_left < 0 )); then
        ((expired_count++)) || true
    elif (( days_left <= RENEWAL_WINDOW_DAYS )); then
        ((renewal_needed++)) || true
    else
        ((normal_count++)) || true
    fi
done < "$DOMAIN_FILE"

notification_lines+=("📊 域名总数：<b>${renewal_count}</b>")
notification_lines+=("⚠️ 待处理：<b>${renewal_needed}</b>")
notification_lines+=("🔴 已过期：<b>${expired_count}</b>")
notification_lines+=("♾️ 永久域名：<b>${permanent_count}</b>")
notification_lines+=("🟢 正常域名：<b>${normal_count}</b>")
notification_lines+=("")
notification_lines+=("━━━━━━━━━━━━━━━━")

# 所有域名完整列表
index=0

while IFS='|' read -r name status expiry_date slot_type lifecycle_type; do
    [[ -z "$name" || "$name" == "null" ]] && continue

    ((index++)) || true

    safe_name="$(html_escape "$name")"
    safe_status="$(html_escape "$status")"
    formatted_expiry="$(format_expiry "$expiry_date")"
    days_left="$(get_days_left "$expiry_date")"

    if is_permanent "$expiry_date"; then
        notification_lines+=("")
        notification_lines+=("<b>${index}️⃣ ${safe_name}</b>")
        notification_lines+=("♾️ 有效期：<b>永久</b>")
        notification_lines+=("🟢 状态：永久")
    else
        safe_expiry="$(html_escape "$formatted_expiry")"

        if (( days_left < 0 )); then
            expired_days=$(( -days_left ))

            notification_lines+=("")
            notification_lines+=("<b>${index}️⃣ ${safe_name}</b>")
            notification_lines+=("📅 有效期：<b>${safe_expiry}</b>")
            notification_lines+=("⏳ 已过期：<b>${expired_days} 天</b>")
            notification_lines+=("🔴 状态：<b>已过期，需处理</b>")

        elif (( days_left <= RENEWAL_WINDOW_DAYS )); then

            notification_lines+=("")
            notification_lines+=("<b>${index}️⃣ ${safe_name}</b>")
            notification_lines+=("📅 有效期：<b>${safe_expiry}</b>")
            notification_lines+=("⏳ 剩余：<b>${days_left} 天</b>")
            notification_lines+=("⚠️ 状态：<b>需要续期</b>")

        else

            notification_lines+=("")
            notification_lines+=("<b>${index}️⃣ ${safe_name}</b>")
            notification_lines+=("📅 有效期：<b>${safe_expiry}</b>")
            notification_lines+=("⏳ 剩余：<b>${days_left} 天</b>")
            notification_lines+=("🟢 状态：正常")
        fi
    fi

done < "$DOMAIN_FILE"

notification_lines+=("")
notification_lines+=("━━━━━━━━━━━━━━━━")
notification_lines+=("")

if (( renewal_needed > 0 || expired_count > 0 )); then
    notification_lines+=("⚠️ 有域名进入续期/处理范围")
    notification_lines+=("📌 续期窗口：${RENEWAL_WINDOW_DAYS} 天")
else
    notification_lines+=("✅ 所有非永久域名均无需续期")
fi

notification_lines+=("")
notification_lines+=("🔗 <a href=\"https://dash.domain.digitalplat.org/dashboard\">前往 DigitalPlat Dashboard</a>")
notification_lines+=("")
notification_lines+=("ℹ️ API 未暴露 renewal 接口，需手动在 Dashboard 操作")

# Telegram 发送函数
send_telegram() {
    local text="$1"

    curl --fail-with-body --silent --show-error \
        --retry 3 \
        --retry-delay 2 \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "disable_web_page_preview=true" \
        --data-urlencode "text=${text}" >/dev/null
}

# Telegram 单条消息建议控制在 3800 字符以内
message=""

for line in "${notification_lines[@]}"; do
    if (( ${#message} + ${#line} + 1 > 3800 )); then
        if [[ -n "$message" ]]; then
            send_telegram "$message"
        fi

        message="<b>🌐 DigitalPlat 域名状态（续）</b>"
    fi

    if [[ -n "$message" ]]; then
        message+=$'\n'
    fi

    message+="$line"
done

if [[ -n "$message" ]]; then
    send_telegram "$message"
fi

echo "Telegram 通知已发送"
echo "域名总数: ${renewal_count}"
echo "需要续期: ${renewal_needed}"
echo "已过期: ${expired_count}"
echo "永久域名: ${permanent_count}"
