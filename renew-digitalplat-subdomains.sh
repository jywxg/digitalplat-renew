#!/usr/bin/env bash
# DigitalPlat Domain Renewal Checker
# API: https://domain-api.digitalplat.org/api/v1
# 列出所有域名，检查到期时间，发送 Telegram 通知
# 续期需在 dashboard 手动操作（API 未暴露 renewal endpoint）

set -euo pipefail

API_BASE="https://domain-api.digitalplat.org/api/v1"
RENEWAL_WINDOW_DAYS=120  # DigitalPlat 政策：120 天内可免费续期

# 检查依赖
for cmd in curl jq; do
    command -v "$cmd" >/dev/null || { echo "错误: 缺少依赖 $cmd" >&2; exit 1; }
done

# API Key 从环境变量读取
API_KEY="${DIGITALPLAT_API_KEY:?错误: 请先设置环境变量 DIGITALPLAT_API_KEY}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?错误: 请先设置环境变量 TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:?错误: 请先设置环境变量 TELEGRAM_CHAT_ID}"

# 获取域名列表
response=$(curl --fail-with-body --silent --show-error \
    "${API_BASE}/domains" \
    -H "Authorization: Bearer ${API_KEY}")

jq -e '.success == true and (.data | type == "array")' <<<"$response" >/dev/null || {
    echo "错误: 查询域名失败: $(jq -c . <<<"$response" 2>/dev/null || printf '%s' "$response")" >&2
    exit 1
}

# 解析域名数据
jq -r '.data[] | [.name, .status, .expiry_date, .slot_type, .lifecycle_type] | @tsv' <<<"$response" | \
    while IFS=$'\t' read -r name status expiry_date slot_type lifecycle_type; do
        echo "$name|$status|$expiry_date|$slot_type|$lifecycle_type"
    done > /tmp/digitalplat_domains_$$

# 判断是否需要续期
needs_renewal() {
    local expiry="$1"
    if [[ "$expiry" == "null" || -z "$expiry" ]]; then
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
    renew=$(needs_renewal "$expiry_date")
    if [[ "$renew" == "yes" ]]; then
        ((renewal_needed++))
        notification_lines+=("⚠️ <code>${name}</code> - 到期: ${expiry_date} | 需续期")
    fi
    ((renewal_count++))
done < /tmp/digitalplat_domains_$$

notification_lines+=("")
notification_lines+=("📊 共 ${renewal_count} 个域名")
notification_lines+=("⚠️ ${renewal_needed} 个域名需在 120 天内续期")
notification_lines+=("")
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
