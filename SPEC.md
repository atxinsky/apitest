# ModelHub — 技术规格书 (SPEC)

> 基于 PRD v2 (2026-03-29)
> 技术方案：NewAPI 部署 + 定制化

---

## 一、技术选型

| 组件 | 选型 | 说明 |
|------|------|------|
| API 网关 | NewAPI (Go) | 基于 OneAPI，功能最全 |
| 数据库 | MySQL 8 | NewAPI 默认支持 |
| 缓存 | Redis 7 | 限流/令牌缓存/渠道状态 |
| 反代 | Nginx | SSL 终止 + 限流 + 安全头 |
| CDN/WAF | Cloudflare | DDoS 防护 + WAF + DNS |
| 容器化 | Docker Compose | 一键部署 |
| 备份 | COS | 每日数据库自动备份 |
| 监控 | Uptime Kuma | 服务可用性监控 |
| 告警 | 飞书 Webhook | 配额/故障/异常通知 |

---

## 二、部署架构

### 2.1 服务器配置

| 项目 | 最低配置 | 推荐配置 |
|------|---------|---------|
| CPU | 2 核 | 4 核 |
| 内存 | 4 GB | 8 GB |
| 磁盘 | 40 GB SSD | 80 GB SSD |
| 带宽 | 5 Mbps | 10 Mbps |
| 系统 | Ubuntu 22.04 / Debian 12 | 同左 |

### 2.2 Docker Compose 架构

```yaml
services:
  # NewAPI 主服务
  new-api:
    image: calciumion/new-api:latest
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      - SQL_DSN=root:${MYSQL_ROOT_PASSWORD}@tcp(mysql:3306)/newapi
      - REDIS_CONN_STRING=redis://redis:6379
      - SESSION_SECRET=${SESSION_SECRET}
      - GLOBAL_API_RATE_LIMIT=180        # 全局每分钟限流
      - GLOBAL_WEB_RATE_LIMIT=120        # 管理面板限流
    volumes:
      - ./data/newapi:/data
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
    restart: always

  # MySQL
  mysql:
    image: mysql:8
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: newapi
    volumes:
      - ./data/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 10
    restart: always

  # Redis（限流 + 缓存）
  redis:
    image: redis:7-alpine
    command: redis-server --appendonly yes --maxmemory 256mb --maxmemory-policy allkeys-lru --requirepass ${REDIS_PASSWORD}
    volumes:
      - ./data/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: always
```

### 2.3 Nginx 配置要点

```nginx
server {
    listen 443 ssl http2;
    server_name api.modelhub.cn;

    # SSL (Let's Encrypt / Cloudflare Origin)
    ssl_certificate     /etc/ssl/cert.pem;
    ssl_certificate_key /etc/ssl/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    # 安全头
    add_header X-Content-Type-Options    nosniff always;
    add_header X-Frame-Options           DENY always;
    add_header X-XSS-Protection          "1; mode=block" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header Content-Security-Policy   "default-src 'self'" always;

    # 全局限流 (每 IP 每秒 10 请求，burst 20)
    limit_req zone=api burst=20 nodelay;

    # API 转发
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # SSE 流式响应
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 300s;

        # 请求体限制 (防大 payload)
        client_max_body_size 10m;
    }
}

# HTTP 强制跳转 HTTPS
server {
    listen 80;
    server_name api.modelhub.cn;
    return 301 https://$server_name$request_uri;
}

# 限流 zone 定义
limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
```

### 2.4 Cloudflare 配置

| 配置项 | 值 | 说明 |
|--------|------|------|
| SSL/TLS | Full (Strict) | Cloudflare → Nginx 全加密 |
| WAF | 开启 | 自动拦截常见攻击 |
| Rate Limiting | 1000 req/min per IP | Cloudflare 层限流 |
| Bot Fight Mode | 开启 | 阻止爬虫/扫描器 |
| Under Attack Mode | 备用 | DDoS 时手动开启 |
| 缓存 | 关闭（API 不缓存） | Development Mode |

---

## 三、安全规格

### 3.1 API Key 防泄露

```
源头 Key 生命周期：
  配置时 → AES-256 加密 → 写入 MySQL
  转发时 → 内存解密 → 发往源头厂商
  面板上 → 不展示源头 Key（管理员也只看脱敏版）

客户 Key 生命周期：
  创建时 → 生成 sk-{客户标识}-{随机32字符}
  分发时 → 客户面板脱敏显示 sk-xxx****xxxx
  使用时 → Authorization: Bearer sk-xxx → 验证 → 转发
  泄露时 → 立即重置 Key + IP 封禁 + 飞书告警
```

### 3.2 限流策略

| 层级 | 限制 | 说明 |
|------|------|------|
| Cloudflare | 1000 req/min per IP | 第一道防线 |
| Nginx | 10 req/s per IP, burst 20 | 第二道防线 |
| NewAPI 全局 | 180 req/min | 保护后端 |
| NewAPI 单令牌 | 60 req/min（可配） | 防单客户滥用 |
| 配额硬限 | 超额返回 429 | 不欠费 |

### 3.3 日志安全

```
记录（元数据）：
  ✅ 令牌 ID
  ✅ 模型名称
  ✅ 输入/输出 token 数
  ✅ 耗时 (ms)
  ✅ HTTP 状态码
  ✅ 来源 IP
  ✅ 时间戳

不记录（隐私）：
  ❌ 对话内容 (prompt / completion)
  ❌ 源头 API Key 明文
  ❌ 用户个人信息
```

NewAPI 配置：`LOG_CONTENT=false`

### 3.4 防攻击 Checklist

- [x] Nginx：`limit_req` 限流
- [x] Nginx：`client_max_body_size 10m` 防大包
- [x] Nginx：安全响应头 (CSP/HSTS/X-Frame-Options)
- [x] Cloudflare：WAF + DDoS 防护
- [x] Cloudflare：Bot Fight Mode
- [x] MySQL：仅 127.0.0.1 监听，不暴露端口
- [x] Redis：requirepass + 仅 127.0.0.1
- [x] Docker：服务端口只绑 127.0.0.1
- [x] fail2ban：SSH 暴力破解防护
- [x] 系统：关闭 root SSH，密钥登录

---

## 四、渠道接入规格

### 4.1 首批渠道

| 厂商 | API 格式 | 接入方式 | 优先级 |
|------|---------|---------|--------|
| DeepSeek | OpenAI 兼容 | `https://api.deepseek.com` | 主力 |
| 智谱 AI | OpenAI 兼容 | `https://open.bigmodel.cn/api/paas/v4` | 备用 |
| OpenAI | 原生 | `https://api.openai.com` | 高端模型 |
| Anthropic | 需转换 | 通过 NewAPI 自动转换 | Claude 模型 |

### 4.2 模型映射表

| 客户调用的模型名 | 实际转发到 | 渠道 |
|-----------------|-----------|------|
| gpt-4o | gpt-4o | OpenAI |
| gpt-4o-mini | gpt-4o-mini | OpenAI |
| deepseek-chat | deepseek-chat | DeepSeek |
| deepseek-reasoner | deepseek-reasoner | DeepSeek |
| claude-sonnet-4-5 | claude-sonnet-4-5-20250514 | Anthropic |
| glm-4-flash | glm-4-flash | 智谱 |
| cogview-4 | cogview-4 | 智谱 |

### 4.3 倍率配置

NewAPI 的倍率系统：`客户付费 = 源头成本 × 模型倍率 × 分组倍率`

| 用户分组 | 分组倍率 | 适用客户 |
|---------|---------|---------|
| default | 4.0 | 按量付费散客 |
| enterprise | 3.0 | 套餐制企业客户 |
| vip | 2.5 | 大客户/长期合作 |

---

## 五、客户面板定制规格

### 5.1 参考 UI

参考 AI火宝 面板（暗色主题），左侧菜单：

```
┌──────────────┐
│ 🔥 ModelHub   │
├──────────────┤
│ 📊 用量信息   │  → 余额、已消费、用量趋势图
│ 🔑 API Keys  │  → 查看 Key（脱敏），不能增删改
│ 💰 充值      │  → 在线充值 / 套餐购买
│ 📋 账单      │  → 消费记录明细
│ 🤖 模型库    │  → 卡片式模型列表（只读）
│ 🎮 演武场    │  → Playground 测试模型
├──────────────┤
│ 🔗 接口文档   │  → API 对接说明
│ 📞 联系我们   │  → 客服/技术支持
└──────────────┘
```

### 5.2 权限矩阵

| 功能 | 管理员 | 企业客户 |
|------|--------|---------|
| 渠道管理 | ✅ | ❌ 不可见 |
| 用户管理 | ✅ | ❌ 不可见 |
| 令牌管理 | ✅ 全部 | 👁 只看自己的，不能改 |
| 模型管理 | ✅ 上下架/定价 | 👁 只看可用模型 |
| 日志查看 | ✅ 全部 | 👁 只看自己的 |
| 倍率设置 | ✅ | ❌ 不可见 |
| 充值 | ✅ 手动加额度 | ✅ 在线充值 |
| 系统设置 | ✅ | ❌ 不可见 |

---

## 六、备份与容灾

### 6.1 数据库备份

```bash
# 每日凌晨 3 点备份到 COS
0 3 * * * /opt/modelhub/scripts/backup.sh
```

备份脚本：mysqldump → gzip → 上传 COS → 清理 30 天前备份

### 6.2 渠道容灾

```
每个常用模型至少配 2 个渠道：
  deepseek-chat → 渠道1: DeepSeek 官方 Key-A (优先级 1)
                → 渠道2: DeepSeek 官方 Key-B (优先级 2)

  gpt-4o       → 渠道1: OpenAI Key-A (优先级 1)
                → 渠道2: OpenAI Key-B (优先级 2)

故障切换逻辑（NewAPI 内置）：
  渠道连续失败 3 次 → 自动禁用 5 分钟
  5 分钟后自动重试 → 恢复则启用
  同时飞书告警通知
```

---

## 七、部署文件清单

```
F:\api中转站\
├── PRD.md                    # 产品需求文档
├── SPEC.md                   # 技术规格书（本文件）
├── docker-compose.yml        # Docker 编排
├── .env                      # 环境变量（不提交 git）
├── .env.example              # 环境变量模板
├── nginx/
│   └── modelhub.conf         # Nginx 配置
├── scripts/
│   ├── setup.sh              # 一键部署脚本
│   ├── backup.sh             # 数据库备份脚本
│   └── ssl-renew.sh          # SSL 证书续期
├── 参考/                      # UI 参考截图
└── CLAUDE.md                 # Claude Code 项目指令
```

---

## 八、验收标准

### Phase 1 验收

- [ ] `curl https://api.modelhub.cn/v1/models` 返回模型列表
- [ ] `curl https://api.modelhub.cn/v1/chat/completions` 带有效 Key 返回 AI 响应
- [ ] 无效 Key 返回 401
- [ ] 超额 Key 返回 429
- [ ] 管理后台可登录，可创建渠道/用户/令牌
- [ ] 日志记录正常（不含对话内容）

### Phase 2 验收

- [ ] 方策系统切换到中转站后正常调用
- [ ] 计费正确（加价倍率生效）
- [ ] 客户面板只看到自己的数据
- [ ] 飞书告警正常推送

### 安全验收

- [ ] 源头 Key 数据库中加密存储
- [ ] 客户面板无渠道管理入口
- [ ] MySQL/Redis 不暴露公网端口
- [ ] HTTPS 强制 + 安全响应头
- [ ] fail2ban SSH 防护生效
- [ ] Nginx 限流生效（ab 压测验证）
