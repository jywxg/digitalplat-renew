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

- ✅ 通过 DigitalPlat API v1 获取域名列表（自动绕过 Cloudflare 验证）
- ✅ 兼容多种 API 响应格式（`{success,data}` / 直接数组 / `{data}`）
- ✅ 检查每个域名的到期时间，自动识别永久到期
- ✅ 标记 120 天窗口内需续期的域名
- ✅ 打印终端表格概览
- ✅ 通过 Telegram Bot 发送通知（支持长消息分片）
- ✅ 支持 GitHub Actions 定时运行

## 🚀 快速使用

### 1. 克隆仓库

```bash
git clone https://github.com/GaoZitian/digitalplat-renew.git
cd digitalplat-renew
```

### 2. 安装依赖

```bash
pip3 install cloudscraper
```

### 3. 设置环境变量

```bash
export DIGITALPLAT_API_KEY="dp_live_xxxxxxxxx"
export TELEGRAM_BOT_TOKEN="your_bot_token"
export TELEGRAM_CHAT_ID="your_chat_id"
```

### 4. 运行

```bash
chmod +x renew-digitalplat-subdomains.sh
./renew-digitalplat-subdomains.sh
```

## ⚙️ GitHub Actions 定时运行

仓库包含 GitHub Actions 工作流（`.github/workflows/renew-digitalplat-subdomains.yml`）。

**所需 Secrets：**

| Secret | 说明 |
|--------|------|
| `DIGITALPLAT_API_KEY` | DigitalPlat API Bearer Token |
| `TELEGRAM_BOT_TOKEN` | Telegram Bot Token |
| `TELEGRAM_CHAT_ID` | 接收通知的 Chat ID |

**Schedule：** 每天北京时间 09:00（UTC 01:00）

## 📦 依赖

| 工具 / 包 | 用途 |
|------|------|
| `cloudscraper` (Python) | 绕过 Cloudflare challenge，获取 API 数据 |
| `jq` | JSON 解析 |
| `python3` ≥ 3.8 | 脚本运行环境 |

> **注意：** 不再使用 `curl` 直接请求 DigitalPlat API（会被 Cloudflare 拦截），改用 `cloudscraper` 模拟浏览器通过验证。

## 📂 项目结构

```
├── renew-digitalplat-subdomains.sh   # 主脚本
├── digitalplat_api_helper.py         # API 请求代理（Cloudflare bypass）
└── .github/workflows/
    └── renew-digitalplat-subdomains.yml  # GitHub Actions 配置
```

## 🔗 API 参考

| 端点 | 方法 | 说明 |
|------|------|------|
| `domain-api.digitalplat.org/api/v1/domains` | `GET` | 获取所有域名列表 |

**认证：** `Authorization: Bearer dp_live_xxx`（生产）或 `dp_test_xxx`（测试）

## 📄 许可
