# ModelHub — Claude Code 项目指令

## 项目概述
AI 模型 API 中转平台。基于 NewAPI (Go + React) 部署，加价 3-5 倍分发给企业客户。

## 技术栈
- API 网关: NewAPI (calciumion/new-api Docker 镜像)
- 数据库: MySQL 8
- 缓存: Redis 7
- 反代: Nginx (SSL + 限流)
- CDN/WAF: Cloudflare
- 容器化: Docker Compose

## 关键文档
- `PRD.md` — 产品需求文档（商业模式、定价、利润模型）
- `SPEC.md` — 技术规格书（架构、安全、部署）

## 安全约束（必须遵守）
- MySQL/Redis 端口不暴露到公网（Docker 内网 only）
- NewAPI 端口只绑 127.0.0.1，Nginx 反代
- 对话内容日志关闭 (LOG_CONTENT=false)
- 客户面板无渠道管理入口
- 源头 API Key 加密存储
- HTTPS 强制

## 部署
```bash
sudo bash scripts/setup.sh
```

## 环境变量
见 `.env.example`
