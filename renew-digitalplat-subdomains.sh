#!/usr/bin/env bash
# DigitalPlat Domain Renewal Checker (多账号版)
# API: https://domain-api.digitalplat.org/api/v1
# 列出所有账号的域名，检查到期时间，按账号发送 Telegram 通知
# 续期需在 dashboard 手动操作（API 未暴露 renewal endpoint）
# Cloudflare bypass: uses cloudscraper Python helper (digitalplat_api_helper.py)
#
# 多账号配置：
#   DIGITALPLAT_ACCOUNTS="账号A,KEY_A
#   账号B,KEY_B;账号C,KEY_C"     # 每行一个账号，换行或分号分隔，格式：名称,API_KEY
# 兼容旧配置：
#   DIGITALPLAT_API_KEY="KEY"     # 单账号，名称默认为 DigitalPlat

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

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?错误: 请先设置环境变量 TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:?错误: 请先设置环境变量 TELEGRAM_CHAT_ID}"

# 发送 Telegram 通知（支持长消息分片，3800 字符/条）
# 返回 0 = 成功，1 = 失败（由调用方决定是否中断）
send_tg() {
    local message="$1"
    local chunk=""
    local ok=0
    while IFS= read -r line; do
        if (( ${#chunk} + ${#line} > 3800 )); then
            if ! curl --fail-with-body --silent --show-error \
                "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
                --data-urlencode 'parse_mode=HTML' \
                --data-urlencode "text=$chunk" >/dev/null; then
                ok=1
            fi
            chunk='<b>DigitalPlat 域名检查（续）</b>'
        fi
        chunk+="${chunk:+$'\n'}$line"
    done <<< "$message"
    if ! curl --fail-with-body --silent --show-error \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode 'parse_mode=HTML' \
        --data-urlencode "text=$chunk" >/dev/null; then
        ok=1
    fi
    return "$ok"
}

# 将 API 的 YYYYMMDD 到期时间转换为 YYYY-MM-DD（如 20271225 -> 2027-12-25）
normalize_expiry() {
    local v="$1"
    if [[ "$v" =~ ^[0-9]{8}$ ]]; then
        echo "${v:0:4}-${v:4:2}-${v:6:2}"
    else
        echo "$v"
    fi
}

# 计算续期状态，输出: 剩余天数|续期状态
# 状态: 可续期(窗口内, 到期前120天) / 未到窗口(还需等N天) / 已过期 / 永久 / 未知
calc_status() {
    local expiry="$1"
    if [[ "$expiry" == "null" || -z "$expiry" ]]; then
        echo "-|未知"
        return
    fi
    if [[ "$expiry" == "permanent" || "$expiry" == "PERMANENT" ]]; then
        echo "-|永久"
        return
    fi
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null) || { echo "-|未知"; return; }
    local now_epoch
    now_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    if (( days_left < 0 )); then
        echo "${days_left}|已过期"
    elif (( days_left <= RENEWAL_WINDOW_DAYS )); then
        echo "${days_left}|可续期"
    else
        local wait=$(( days_left - RENEWAL_WINDOW_DAYS ))
        echo "${days_left}|未到窗口(还需${wait}天)"
    fi
}

# 生成 TG 显示用的天数文案
days_display() {
    local days="$1" status="$2"
    if [[ "$status" == "已过期" ]]; then
        echo "已过期 $(( -days )) 天"
    elif [[ "$status" == "永久" ]]; then
        echo "永久"
    elif [[ "$status" == "未知" ]]; then
        echo "未知"
    else
        echo "剩余: ${days} 天"
    fi
}

# 判断是否需要续期（已过期或在 120 天窗口内）
needs_renewal() {
    local expiry="$1"
    IFS='|' read -r _days_left renew_status <<< "$(calc_status "$expiry")"
    if [[ "$renew_status" == "可续期" || "$renew_status" == "已过期" ]]; then
        echo "yes"
    else
        echo "no"
    fi
}

# 检查单个账号：获取域名 → 解析 → 统计 → 通知
# 返回 0 = 成功，1 = 失败（不影响其他账号继续处理）
check_account() {
    local account_name="$1"
    local api_key="$2"
    local domains_tmp
    local renewal_needed=0
    local renewal_count=0
    local notification_lines=()
    local detail_lines=()
    local message=""

    echo "==================== 账号: ${account_name} ====================" >&2

    # 获取域名列表 (Cloudflare bypass via cloudscraper Python helper)
    echo "正在获取域名列表..." >&2
    DEBUG_OUTPUT=$(mktemp)
    local response=""
    local fetch_rc=0
    response=$(python3 "$HELPER" "/domains" "Bearer ${api_key}" --debug 2>"$DEBUG_OUTPUT") || fetch_rc=$?
    local cf_debug
    cf_debug=$(cat "$DEBUG_OUTPUT")
    rm -f "$DEBUG_OUTPUT"
    if (( fetch_rc != 0 )); then
        echo "错误: 账号 ${account_name} 获取域名列表失败" >&2
        echo "$cf_debug" >&2
        return 1
    fi

    # 输出调试信息到 stderr (方便查看)
    if [[ "$cf_debug" == *RAW_RESPONSE* ]]; then
        echo "=== CF Debug Output ===" >&2
        echo "$cf_debug" >&2
    fi

    # 尝试多种可能的 JSON 结构
    # 结构 1: { "success": true, "data": [...] }
    # 结构 2: [ {...}, {...} ]  直接数组
    # 结构 3: { "data": {...} } 或 { "domains": [...] }

    local domain_list=""

    # 检查是否是数组
    if echo "$response" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "API 返回: 直接数组" >&2
        domain_list=$(echo "$response" | jq '.')
    # 检查是否有 .success + .data
    elif echo "$response" | jq -e '.success == true and (.data | type == "array")' >/dev/null 2>&1; then
        echo "API 返回: {success:true, data:[]}" >&2
        domain_list=$(echo "$response" | jq '.data')
    # 检查 .data 直接是数组
    elif echo "$response" | jq -e '.data | type == "array"' >/dev/null 2>&1; then
        echo "API 返回: {data:[]}" >&2
        domain_list=$(echo "$response" | jq '.data')
    # 检查 .domains
    elif echo "$response" | jq -e '.domains | type == "array"' >/dev/null 2>&1; then
        echo "API 返回: {domains:[]}" >&2
        domain_list=$(echo "$response" | jq '.domains')
    else
        echo "错误: 无法解析 API 响应" >&2
        echo "原始响应: $response" >&2
        echo "CF debug: $cf_debug" >&2
        return 1
    fi

    # 解析域名数据（真实 API 字段: domain / status / expires_at(YYYYMMDD) / slot_type / lifecycle_type）
    # 注意: 缺失字段输出 "null" 而非空串，避免 bash read 折叠连续 tab 导致列错位
    domains_tmp=$(mktemp)
    jq -r '.[] | [(.domain // "null"), (.status // "null"), (.expires_at // "null"), (.slot_type // "null"), (.lifecycle_type // "null")] | @tsv' <<<"$domain_list" | \
        while IFS=$'\t' read -r name status expiry_date slot_type lifecycle_type; do
            expiry_date=$(normalize_expiry "$expiry_date")
            echo "$name|$status|$expiry_date|$slot_type|$lifecycle_type"
        done > "$domains_tmp"

    # 如果没有解析到数据，尝试字段名不同的情况
    if [[ ! -s "$domains_tmp" ]]; then
        echo "警告: 未解析到数据，尝试其他字段名..." >&2
        jq -r '.[] | [(.domain // .name // "null"), (.status // .state // "null"), (.expires_at // .expiry // .expiration // .expire // "null"), (.slot_type // .slot // "null"), (.lifecycle_type // .lifecycle // .type // "null")] | @tsv' <<<"$domain_list" | \
            while IFS=$'\t' read -r name status expiry_date slot_type lifecycle_type; do
                if [[ -n "$name" && "$name" != "null" ]]; then
                    expiry_date=$(normalize_expiry "$expiry_date")
                    echo "${name}|${status}|${expiry_date}|${slot_type}|${lifecycle_type}"
                fi
            done > "$domains_tmp"
    fi

    echo "已解析 $(wc -l < "$domains_tmp") 个域名" >&2

    # 打印表格
    printf '%-32s %-10s %-12s %-8s %-20s %s\n' \
        "域名" "状态" "到期时间" "剩余天" "续期窗口" "需续期"
    printf '%-32s %-10s %-12s %-8s %-20s %s\n' \
        "------------------------------" "----------" "------------" "--------" "--------------------" "------"

    while IFS='|' read -r name status expiry_date slot_type lifecycle_type; do
        [[ -z "$name" || "$name" == "null" ]] && continue
        IFS='|' read -r days_left renew_status <<< "$(calc_status "$expiry_date")"
        renew=$(needs_renewal "$expiry_date")
        printf '%-32s %-10s %-12s %-8s %-20s %s\n' \
            "$name" "$status" "$expiry_date" "$days_left" "$renew_status" "$renew"
    done < "$domains_tmp"

    # 构建 Telegram 通知
    notification_lines+=("<b>DigitalPlat 域名到期检查 - ${account_name}</b>")
    notification_lines+=("")

    while IFS='|' read -r name status expiry_date slot_type lifecycle_type; do
        [[ -z "$name" || "$name" == "null" ]] && continue
        IFS='|' read -r days_left renew_status <<< "$(calc_status "$expiry_date")"
        renew=$(needs_renewal "$expiry_date")
        if [[ "$renew" == "yes" ]]; then
            ((renewal_needed++)) || true
            notification_lines+=("⚠️ <code>${name}</code> - 到期: ${expiry_date} | $(days_display "$days_left" "$renew_status") | ${renew_status}")
        fi
        ((renewal_count++)) || true
    done < "$domains_tmp"

    detail_lines=()
    while IFS='|' read -r name status expiry_date slot_type lifecycle_type; do
        [[ -z "$name" || "$name" == "null" ]] && continue
        IFS='|' read -r days_left renew_status <<< "$(calc_status "$expiry_date")"
        detail_lines+=("<code>${name}</code> | 到期: ${expiry_date} | $(days_display "$days_left" "$renew_status") | 续期: ${renew_status}")
    done < "$domains_tmp"

    notification_lines+=("")
    if (( renewal_count > 0 )); then
        notification_lines+=("📋 全部域名 (${renewal_count}):")
        for d in "${detail_lines[@]}"; do
            notification_lines+=("${d}")
        done
    fi
    notification_lines+=("")
    notification_lines+=("📊 共 ${renewal_count} 个域名")
    notification_lines+=("")
    notification_lines+=("⚠️ ${renewal_needed} 个域名需在 ${RENEWAL_WINDOW_DAYS} 天内续期")
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
                --data-urlencode "text=$message" >/dev/null || { echo "警告: 账号 ${account_name} 发送 Telegram 失败（分片）" >&2; }
            message='<b>DigitalPlat 域名检查（续）</b>'
        fi
        message+="${message:+$'\n'}$line"
    done

    curl --fail-with-body --silent --show-error \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode 'parse_mode=HTML' \
        --data-urlencode "text=$message" >/dev/null || { echo "警告: 账号 ${account_name} 发送 Telegram 失败" >&2; }

    rm -f "$domains_tmp"
    echo "账号 ${account_name}: 通知已发送 (${renewal_count} 域名, ${renewal_needed} 需续期)" >&2
    return 0
}

# ---- 主流程：解析账号并逐个检查 ----
if [[ -n "${DIGITALPLAT_ACCOUNTS:-}" ]]; then
    ACCOUNT_RAW="$DIGITALPLAT_ACCOUNTS"
else
    ACCOUNT_RAW="${DIGITALPLAT_API_KEY:?错误: 请设置 DIGITALPLAT_ACCOUNTS 或 DIGITALPLAT_API_KEY}"
fi

accounts_file=$(mktemp)
printf '%s\n' "$ACCOUNT_RAW" | tr ';' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' > "$accounts_file"

total_accounts=0
total_fail=0
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == *","* ]]; then
        account_name="${line%%,*}"
        api_key="${line#*,}"
    else
        account_name="DigitalPlat"
        api_key="$line"
    fi
    account_name="${account_name:-DigitalPlat}"
    api_key="$(echo "$api_key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -z "$api_key" ]]; then
        echo "警告: 账号 '${account_name}' 的 API Key 为空，跳过" >&2
        ((total_fail++)) || true
        continue
    fi

    ((total_accounts++)) || true
    if ! check_account "$account_name" "$api_key"; then
        ((total_fail++)) || true
        echo "警告: 账号 ${account_name} 检查失败，继续处理下一个账号" >&2
    fi
done < "$accounts_file"
rm -f "$accounts_file"

echo "==================== 完成 ====================" >&2
echo "账号总数: ${total_accounts}, 失败: ${total_fail}" >&2

if (( total_fail > 0 )); then
    exit 1
fi
