# Lark 事件订阅配置指南

## 步骤
1. 打开 https://open.larksuite.com/app → 你的应用 cli_aa97755a49b8deef
2. 左侧菜单 → **开发配置** → **事件订阅**
3. 请求网址: `http://47.243.128.122:10086/lark`
4. 添加事件: `im.message.receive_v1` (接收消息)
5. 保存 → 创建版本 → 发布上线

## 验证
服务器已支持 URL verification challenge 自动回复。
配置完成后，在 Lark 给机器人发消息，服务器会在 `/root/.claude/role-cache/webhook-events/lark-inbox.jsonl` 收到事件。
