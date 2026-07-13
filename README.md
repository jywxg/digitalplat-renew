<p align="center">
  <img src="https://img.shields.io/badge/DigitalPlat-Domain%20Renewal-blue?style=for-the-badge&logo=google-cloud&logoColor=white" alt="DigitalPlat Domain Renewal">
</p>

<h1 align="center">DigitalPlat 域名自动续期检查</h1>

<p align="center">
  <img src="https://img.shields.io/badge/Shell-脚本-5391FE?style=flat-square&logo=gnubash&logoColor=white">
  <img src="https://img.shields.io/badge/API-DigitalPlat%20v1-00ADD8?style=flat-square">
  <img src="https://img.shields.io/badge/通知-Telegram-26A5E4?style=flat-square&logo=telegram&logoColor=white">
  <img src="https://img.shields.io/badge/依赖-curl%20%7C%20jq-ff69b4?style=flat-square">
</p>

<p align="center">
  定期检查 DigitalPlat 托管的 <code>.us.kg</code> / <code>.xx.kg</code> 域名到期时间，<br>
  通过 Telegram 通知提醒在 120 天免费续期窗口内操作。
</p>

---

## 📋 功能

- ✅ 通过 DigitalPlat API v1 获取域名列表
- ✅ 检查每个域名的到期时间
- ✅ 标记 120 天窗口内需续期的域名
- ✅ 打印终端表格概览
- ✅ 通过 Telegram Bot 发送通知
- ✅ 支持 Telegram 长消息分片

## 🚀 快速使用

### 1. 克隆仓库

```bash
git clone https://github.com/GaoZitian/digitalplat-renew.git
cd digitalplat-renew
```

### 2. 设置环境变量

```bash
export DIGITALPLAT_API_KEY="dp_live_xxxxxxxxx"
export TELEGRAM_BOT_TOKEN="your_bot_token"
export TELEGRAM_CHAT_ID="your_chat_id"
```

### 3. 运行

```bash
chmod +x renew-digitalplat-subdomains.sh
./renew-digitalplat-subdomains.sh
```

## ⚙️ GitHub Actions 定时运行

仓库包含 GitHub Actions 工作流，支持定时执行（需要手动创建 `.github/workflows/renew.yml`）。

**所需 Secrets：**

| Secret | 说明 |
|--------|------|
| `DIGITALPLAT_API_KEY` | DigitalPlat API Bearer Token |
| `TELEGRAM_BOT_TOKEN` | Telegram Bot Token |
| `TELEGRAM_CHAT_ID` | 接收通知的 Chat ID |

## 📦 依赖

| 工具 | 用途 |
|------|------|
| `curl` | HTTP 请求 DigitalPlat / Telegram API |
| `jq` | JSON 解析 |
| `date` | 日期计算（GNU date） |

## 🔗 API 参考

| 端点 | 方法 | 说明 |
|------|------|------|
| `domain-api.digitalplat.org/api/v1/domains` | `GET` | 获取所有域名列表 |

**认证：** `Authorization: Bearer dp_live_xxx`（生产）或 `dp_test_xxx`（测试）

## 📄 许可

MIT