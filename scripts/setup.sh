#!/bin/bash
# ===== ModelHub 一键部署脚本 =====
# 用法: sudo bash scripts/setup.sh
set -euo pipefail

echo "========================================="
echo "  ModelHub — AI 模型 API 中转站 部署"
echo "========================================="

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
  echo "错误：请使用 sudo 运行此脚本"
  exit 1
fi

# 检查 Docker（验证 GPG 签名，不直接 pipe to bash）
if ! command -v docker &>/dev/null; then
  echo "正在安装 Docker..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker
  systemctl start docker
  echo "Docker 安装完成"
fi

# 检查 Docker Compose
if ! docker compose version &>/dev/null; then
  echo "错误：需要 Docker Compose V2（docker compose 命令）"
  echo "请更新 Docker 到最新版本"
  exit 1
fi

# 检查 Nginx
if ! command -v nginx &>/dev/null; then
  echo "正在安装 Nginx..."
  apt-get update -y && apt-get install -y nginx
  systemctl enable nginx
fi

# 创建数据目录（限制权限）
echo "创建数据目录..."
mkdir -p data/newapi data/mysql data/redis data/backups
chmod 700 data/mysql data/redis data/backups
chmod 755 data/newapi

# 生成 .env（如果不存在）
if [ ! -f .env ]; then
  echo "生成 .env 配置文件..."
  MYSQL_ROOT_PW=$(openssl rand -hex 16)
  MYSQL_APP_PW=$(openssl rand -hex 16)
  REDIS_PW=$(openssl rand -hex 16)
  SESSION_KEY=$(openssl rand -hex 32)

  cat > .env << EOF
# ModelHub 环境变量 — 自动生成于 $(date +%Y-%m-%d)
# 安全提示：此文件包含敏感密码，不要提交到 git

# --- MySQL ---
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PW}
MYSQL_USER=newapi
MYSQL_PASSWORD=${MYSQL_APP_PW}

# --- Redis ---
REDIS_PASSWORD=${REDIS_PW}

# --- NewAPI ---
SESSION_SECRET=${SESSION_KEY}
INITIAL_ROOT_TOKEN=

# --- 域名 ---
DOMAIN=api.modelhub.cn

# --- COS 备份（可选） ---
COS_SECRET_ID=
COS_SECRET_KEY=
COS_BUCKET=
COS_REGION=ap-shanghai

# --- 飞书告警（可选） ---
FEISHU_WEBHOOK_URL=
EOF

  # 限制 .env 文件权限（只有 root 可读）
  chmod 600 .env

  echo "✅ .env 已生成（密码已随机生成并保存在 .env 中）"
  echo "⚠️  请修改 .env 中的 DOMAIN 为你的实际域名"
  echo "⚠️  密码不会在终端显示，请查看 .env 文件"
  echo ""
else
  echo "✅ .env 已存在，跳过生成"
fi

# 启动服务
echo "启动 Docker 服务..."
docker compose up -d

# 等待健康检查
echo "等待服务启动..."
for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1:3000/api/status &>/dev/null; then
    echo "✅ NewAPI 服务已启动"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "❌ 服务启动超时，请检查日志: docker compose logs"
    exit 1
  fi
  sleep 2
done

# 安装 Nginx 配置
echo "配置 Nginx..."
cp nginx/modelhub.conf /etc/nginx/sites-available/modelhub.conf
ln -sf /etc/nginx/sites-available/modelhub.conf /etc/nginx/sites-enabled/modelhub.conf
rm -f /etc/nginx/sites-enabled/default

# 测试 Nginx 配置
nginx -t && systemctl reload nginx
echo "✅ Nginx 配置已加载"

# 安装 fail2ban + 配置 Nginx 防护
if ! command -v fail2ban-client &>/dev/null; then
  echo "安装 fail2ban..."
  apt-get install -y fail2ban
fi

# 创建 fail2ban Nginx 过滤器和 jail
cat > /etc/fail2ban/filter.d/nginx-limit-req.conf << 'FILTER_EOF'
[Definition]
failregex = limiting requests, excess:.* by zone.*client: <HOST>
ignoreregex =
FILTER_EOF

cat > /etc/fail2ban/jail.d/modelhub.conf << 'JAIL_EOF'
[sshd]
enabled = true
maxretry = 5
bantime = 3600

[nginx-limit-req]
enabled = true
filter = nginx-limit-req
logpath = /var/log/nginx/error.log
maxretry = 10
findtime = 60
bantime = 600

[nginx-http-auth]
enabled = true
logpath = /var/log/nginx/error.log
maxretry = 5
bantime = 3600
JAIL_EOF

systemctl enable fail2ban
systemctl restart fail2ban
echo "✅ fail2ban 已配置（SSH + Nginx 防护）"

# 设置备份 crontab
echo "配置每日备份..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
(crontab -l 2>/dev/null; echo "0 3 * * * ${SCRIPT_DIR}/backup.sh >> /var/log/modelhub-backup.log 2>&1") | sort -u | crontab -
echo "✅ 每日凌晨 3 点自动备份已配置"

echo ""
echo "========================================="
echo "  ✅ ModelHub 部署完成！"
echo "========================================="
echo ""
echo "  管理后台: http://127.0.0.1:3000"
echo "  （配置 SSL 证书后改为 https://你的域名）"
echo ""
echo "  下一步："
echo "  1. 修改 .env 中的 DOMAIN 为你的实际域名"
echo "  2. 配置域名 DNS 解析指向此服务器"
echo "  3. 配置 SSL 证书（certbot 或 Cloudflare Origin）"
echo "  4. 修改 nginx/modelhub.conf 中的域名"
echo "  5. nginx -t && systemctl reload nginx"
echo "  6. 登录管理后台，创建渠道和客户"
echo ""
