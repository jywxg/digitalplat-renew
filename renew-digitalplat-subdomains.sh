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
RENEWAL_WINDOW_DAYS=120  # DigitalPlat 政策：120 天内可免费续期

# 检查依赖
if ! python3 -c "import cloudscraper" 2>/dev/null; then
    echo "错误: 缺少 cloudscraper，运行: pip3 install cloudscraper" >&2
    exit 1
fi
command -v jq >/dev/null || { echo "错误: 缺少依赖 jq" >&2; exit 1; }

# API Key 从环境变量读取
API_KEY="${DIGITALPLAT_API_KEY:?错误: 请先设置环境变量 DIGITALPLAT_API_KEY}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?错误: 请先设置环境变量 TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:?错误: 请先设置环境变量 TELEGRAM_CHAT_ID}"

# 获取域名列表 (Cloudflare bypass via cloudscraper Python helper)
echo "正在获取域名列表..."
DEBUG_OUTPUT=$(mktemp)
response=$(python3 "$HELPER" "/domains" "Bearer ${API_KEY}" --debug 2>"$DEBUG_OUTPUT")
cf_debug=$(cat "$DEBUG_OUTPUT")
rm -f "$DEBUG_OUTPUT"

# 输出调试信息到 stderr (方便查看)
if [[ "$cf_debug" == *RAW_RESPONSE* ]]; then
    echo "=== CF Debug Output ===" >&2
    echo "$cf_debug" >&2
fi

# 尝试多种可能的 JSON 结构
# 结构 1: { "success": true, "data": [...] }
# 结构 2: [ {...}, {...} ]  直接数组
# 结构 3: { "data": {...} } 或 { "domains": [...] }

domain_list=""
is_array=0

# 检查是否是数组
if echo "$response" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "API 返回: 直接数组" >&2
    domain_list=$(echo "$response" | jq '.')
    is_array=1
# 检查是否有 .success + .data
elif echo "$response" | jq -e '.success == true and (.data | type == "array")' >/dev/null 2>&1; then
    echo "API 返回: {success:true, data:[]}" >&2
    domain_list=$(echo "$response" | jq '.data')
    is_array=0
# 检查 .data 直接是数组
elif echo "$response" | jq -e '.data | type == "array"' >/dev/null 2>&1; then
    echo "API 返回: {data:[]}" >&2
    domain_list=$(echo "$response" | jq '.data')
    is_array=0
# 检查 .domains
elif echo "$response" | jq -e '.domains | type == "array"' >/dev/null 2>&1; then
    echo "API 返回: {domains:[]}" >&2
    domain_list=$(echo "$response" | jq '.domains')
    is_array=0
else
    echo "错误: 无法解析 API 响应" >&2
    echo "原始响应: $response" >&2
    echo "CF debug: $cf_debug" >&2
    exit 1
fi

# 解析域名数据
jq -r '.[] | [.name, .status, .expiry_date, .slot_type, .lifecycle_type] | @tsv' <<<"$domain_list" | \
    while IFS=$'\t' read -r name status expiry_date slot_type lifecycle_type; do
        echo "$name|$status|$expiry_date|$slot_type|$lifecycle_type"
    done > /tmp/digitalplat_domains_$$

# 如果没有解析到数据，尝试字段名不同的情况
if [[ ! -s /tmp/digitalplat_domains_$$ ]]; then
    echo "警告: 未解析到数据，尝试其他字段名..." >&2
    jq -r '.[] | [.name // .domain, .status // .state, .expiry_date // .expiry // .expire, .slot_type // .slot, .lifecycle_type // .lifecycle // .type] | @tsv' <<<"$domain_list" | \
        while IFS=$'\t' read -r name status expiry_date slot_type lifecycle_type; do
            if [[ -n "$name" && "$name" != "null" ]]; then
                echo "${name}|${status}|${expiry_date}|${slot_type}|${lifecycle_type}"
            fi
        done > /tmp/digitalplat_domains_$$
fi

echo "已解析 $(wc -l < /tmp/digitalplat_domains_$$) 个域名" >&2

# 判断是否需要续期
needs_renewal() {
    local expiry="$1"
    if [[ "$expiry" == "null" || -z "$expiry" || "$expiry" == "permanent" || "$expiry" == "PERMANENT" ]]; then
        echo "no"
        return
    fi
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null) || { echo "no"; return; }
    local now_epoch
    now_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    if (( days_left <= RENEWAL_WINDOW_DAYS )); then
        echo "yes"
    else
        echo "no"
    fi
}

# 打印表格
printf '%-30s %-12s %-12s %-12s %-12s %s\n' \
    "域名" "状态" "到期时间" "Slot Type" "Lifecycle" "需续期"
printf '%-30s %-12s %-12s %-12s %-12s %s\n' \
    "------------------------------" "------------" "------------" "------------" "------------" "------"

while IFS='|' read -r name status expiry_date slot_type lifecycle_type; do
    [[ -z "$name" || "$name" == "null" ]] && continue
    renew=$(needs_renewal "$expiry_date")
    printf '%-30s %-12s %-12s %-12s %-12s %s\n' \
        "$name" "$status" "$expiry_date" "$slot_type" "$lifecycle_type" "$renew"
done < /tmp/digitalplat_domains_$$

# 构建 Telegram 通知
notification_lines=()
notification_lines+=("<b>DigitalPlat 域名到期检查</b>")
notification_lines+=("")

renewal_needed=0
renewal_count=0

while IFS='|' read -r name status expiry_date slot_type lifecycle_type; do
    [[ -z "$name" || "$name" == "null" ]] && continue
    renew=$(needs_renewal "$expiry_date")
    if [[ "$renew" == "yes" ]]; then
        ((renewal_needed++)) || true
        notification_lines+=("⚠️ <code>${name}</code> - 到期: ${expiry_date} | 需续期")
    fi
    # 永久到期判断
    if [[ "$expiry_date" == "permanent" || "$expiry_date" == "PERMANENT" || "$expiry_date" == "null" || -z "$expiry_date" ]]; then
        is_permanent="是"
    else
        is_permanent="否"
    fi
    ((renewal_count++)) || true
done < /tmp/digitalplat_domains_$$

# 重新遍历，构建域名详情列表
detail_lines=()
while IFS='|' read -r name status expiry_date slot_type lifecycle_type; do
    [[ -z "$name" || "$name" == "null" ]] && continue
    if [[ "$expiry_date" == "permanent" || "$expiry_date" == "PERMANENT" || "$expiry_date" == "null" || -z "$expiry_date" ]]; then
        is_permanent="是"
    else
        is_permanent="否"
    fi
    detail_lines+=("<code>${name}</code> | 永久: ${is_permanent}")
done < /tmp/digitalplat_domains_$$

notification_lines+=("")
notification_lines+=("📊 共 ${renewal_count} 个域名")
for dl in "${detail_lines[@]}"; do
    notification_lines+=("  ${dl}")
done
notification_lines+=("")
notification_lines+=("⚠️ ${renewal_needed} 个域名需在 120 天内续期")
notification_lines+=("🔗 <a href=\"https://dash.domain.digitalplat.org/dashboard\">前往 Dashboard 续期</a>")
notification_lines+=("")
notification_lines+=("⚠️ API 未暴露 renewal 接口，需手动在 dashboard 操作")

if (( renewal_needed == 0 )); then
    notification_lines+=("✅ 所有域名无需续期")
fi

# 发送 Telegram 通知
message=""
for line in "${notification_lines[@]}"; do
    if (( ${#message} + ${#line} > 3800 )); then
        curl --fail-with-body --silent --show-error \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode 'parse_mode=HTML' \
            --data-urlencode "text=$message" >/dev/null
        message='<b>DigitalPlat 域名检查（续）</b>'
    fi
    message+="${message:+$'\n'}$line"
done

curl --fail-with-body --silent --show-error \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode 'parse_mode=HTML' \
    --data-urlencode "text=$message" >/dev/null

rm -f /tmp/digitalplat_domains_$$

echo "通知已发送"
