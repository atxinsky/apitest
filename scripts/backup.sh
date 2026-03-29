#!/bin/bash
# ===== ModelHub 数据库备份脚本 =====
# 用法: bash scripts/backup.sh
# crontab: 0 3 * * * /opt/modelhub/scripts/backup.sh >> /var/log/modelhub-backup.log 2>&1
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${PROJECT_DIR}/data/backups"
BACKUP_FILE="${BACKUP_DIR}/modelhub_${DATE}.sql.gz"
RETENTION_DAYS=30

# 加载环境变量
if [ -f "${PROJECT_DIR}/.env" ]; then
  source "${PROJECT_DIR}/.env"
else
  echo "错误：.env 文件不存在"
  exit 1
fi

MYSQL_PASSWORD="${MYSQL_ROOT_PASSWORD:?ERROR: MYSQL_ROOT_PASSWORD 未设置}"

mkdir -p "${BACKUP_DIR}"

echo "[$(date)] 开始数据库备份..."

# 通过 Docker 执行 mysqldump
docker exec modelhub-mysql mysqldump \
  -uroot \
  -p"${MYSQL_PASSWORD}" \
  --single-transaction \
  --quick \
  --lock-tables=false \
  newapi | gzip > "${BACKUP_FILE}"

# 验证备份
if [ -f "${BACKUP_FILE}" ] && [ -s "${BACKUP_FILE}" ]; then
  FILE_SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
  echo "[$(date)] ✅ 备份成功: ${BACKUP_FILE} (${FILE_SIZE})"
else
  echo "[$(date)] ❌ 备份失败：文件为空"
  exit 1
fi

# 上传到 COS（如果配置了）
if [ -n "${COS_SECRET_ID}" ] && [ -n "${COS_BUCKET}" ]; then
  if command -v coscmd &>/dev/null; then
    coscmd upload "${BACKUP_FILE}" "/modelhub-backups/modelhub_${DATE}.sql.gz"
    echo "[$(date)] ✅ 已上传到 COS"
  else
    echo "[$(date)] ⚠️  coscmd 未安装，跳过 COS 上传"
  fi
fi

# 清理过期备份
echo "[$(date)] 清理 ${RETENTION_DAYS} 天前的备份..."
find "${BACKUP_DIR}" -name "modelhub_*.sql.gz" -mtime +${RETENTION_DAYS} -delete

# 列出当前备份
echo "[$(date)] 当前备份:"
ls -lh "${BACKUP_DIR}"/modelhub_*.sql.gz 2>/dev/null || echo "  无备份文件"

echo "[$(date)] 备份流程完成"
