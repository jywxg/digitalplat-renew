<p align="center">
  <img src="https://img.shields.io/badge/DigitalPlat-Domain%20Renewal-blue?style=for-the-badge&logo=google-cloud&logoColor=white" alt="DigitalPlat Domain Renewal">
</p>

<h1 align="center">DigitalPlat 域名自动续期检查</h1>

<p align="center">
  <img src="https://img.shields.io/badge/Shell-脚本-5391FE?style=flat-square&logo=gnubash&logoColor=white">
  <img src="https://img.shields.io/badge/API-DigitalPlat%20v1-00ADD8?style=flat-square">
  <img src="https://img.shields.io/badge/通知-Telegram-26A5E4?style=flat-square&logo=telegram&logoColor=white">
  <img src="https://img.shields.io/badge/依赖-cloudscraper%20%7C%20jq-ff69b4?style=flat-square">
</p>

<p align="center">
  定期检查 DigitalPlat 托管的 <code>.us.kg</code> / <code>.xx.kg</code> 域名到期时间，<br>
  通过 Telegram 通知提醒在 120 天免费续期窗口内操作。
</p>

---

## 📋 功能

- ✅ 通过 DigitalPlat API v1 获取域名列表（cloudscraper 绕过 Cloudflare 验证）
- ✅ **支持多账号**：多个 DigitalPlat API Key 批量检查，逐账号独立通知（标题带账号名），单个账号失败不影响其他账号
- ✅ 兼容多种 API 响应格式（`{success,data}` / 直接数组 / `{data}`）
- ✅ 检查每个域名的到期时间（API 字段 `expires_at`，自动把 `YYYYMMDD` 转为 `YYYY-MM-DD`）
- ✅ 标记 120 天窗口内需续期的域名
- ✅ 打印终端表格概览
- ✅ 通过 Telegram Bot 发送通知（支持长消息分片）
- ✅ 支持 GitHub Actions 定时运行

---

## 🚀 快速使用

### 通过 GitHub Actions 运行

1. Fork 本仓库到你的 GitHub 账号
2. 进入 **Settings → Secrets and variables → Actions**
3. 添加以下 Secrets：

| Secret | 说明 |
|--------|------|
| `DIGITALPLAT_ACCOUNTS` | **多账号**：每行一个 `名称,API_KEY`（换行或分号分隔），例如 `账号A,key_a` + 换行 + `账号B,key_b` |
| `DIGITALPLAT_API_KEY` | （兼容旧版）单账号 API Bearer Token；名称默认为 `DigitalPlat` |
| `TELEGRAM_BOT_TOKEN` | Telegram Bot Token |
| `TELEGRAM_CHAT_ID` | 接收通知的 Chat ID |

> 💡 同时设置 `DIGITALPLAT_ACCOUNTS` 与 `DIGITALPLAT_API_KEY` 时，优先使用 `DIGITALPLAT_ACCOUNTS`。

4. 到 **Actions** 页面手动触发一次 `renew-digitalplat` 工作流验证配置
5. 成功后，工作流会按 Schedule 定时自动运行

**Schedule：** 每月 10 号北京时间 15:00（UTC 07:00）

---

### 本地运行

```bash
git clone https://github.com/GaoZitian/digitalplat-renew.git
cd digitalplat-renew

# 安装依赖
pip3 install cloudscraper
brew install jq  # macOS

# 多账号：每行一个 名称,API_KEY（换行或分号分隔）
export DIGITALPLAT_ACCOUNTS="账号A,key_a
账号B,key_b;账号C,key_c"
# 或单账号（兼容旧版）
# export DIGITALPLAT_API_KEY="***"

export TELEGRAM_BOT_TOKEN="***"
export TELEGRAM_CHAT_ID="your_chat_id"

# 运行
chmod +x renew-digitalplat-subdomains.sh
./renew-digitalplat-subdomains.sh
```

---

## ⚙️ GitHub Actions 配置

工作流文件：`.github/workflows/renew-digitalplat.yml`

```yaml
name: DigitalPlat Domains Renew
on:
  schedule:
    - cron: '0 7 10 * *'   # 每月10号 UTC 07:00 = 北京时间 15:00
  workflow_dispatch:       # 支持手动触发
```

> 注意： Secrets 在 fork 后需要重新设置，不会从 upstream 继承。

---

## 📦 依赖

| 工具 / 包 | 用途 |
|------|------|
| `cloudscraper` (Python) | 绕过 Cloudflare challenge，获取 API 数据 |
| `jq` | JSON 解析 |
| `python3` ≥ 3.8 | 脚本运行环境 |

脚本内部通过 `cloudscraper` 调用 `digitalplat_api_helper.py` 发起请求，不再直接使用 `curl`（会被 Cloudflare 拦截）。

---

## 📂 项目结构

```
├── renew-digitalplat-subdomains.sh   # 主脚本（域名检查 + Telegram 通知）
├── digitalplat_api_helper.py         # API 请求代理（Cloudflare bypass）
└── .github/workflows/
    └── renew-digitalplat.yml         # GitHub Actions 定时任务
```

---

## 🔗 API 参考

| 端点 | 方法 | 说明 |
|------|------|------|
| `domain-api.digitalplat.org/api/v1/domains` | `GET` | 获取所有域名列表 |

**认证：** `Authorization: Bearer *** `dp_test_xxx`（测试）

> API 未暴露 renewal 端点，续期需在 Dashboard 手动操作。

---

## 📊 输出说明

每个域名显示 **到期时间、剩余天数、续期状态**（表格 + Telegram 通知）：

| 状态 | 含义 |
|------|------|
| `可续期` | 已进入 120 天免费续期窗口，可前往 Dashboard 续期 |
| `未到窗口(还需N天)` | 距到期超过 120 天，暂时还不能续期 |
| `已过期` | 已超过到期日，需尽快处理 |
| `永久` | API 返回的到期值字面为 `permanent`（DigitalPlat 免费域名 `lifecycle_type` 恒为 permanent，**真实到期日请看 `expires_at` 列**，本状态极少出现） |
| `未知` | 到期时间缺失/无法解析 |
