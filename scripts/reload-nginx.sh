#!/bin/bash

# 证书续签后，自动重载 Nginx 配置
set -euo pipefail

LOG_FILE="/var/log/nginx/reload.log"
echo "[$(date '+%F %T')] 证书已续期，开始重载 nginx" >> "$LOG_FILE"

if docker exec wp_nginx nginx -s reload >> "$LOG_FILE" 2>&1; then
    echo "[$(date '+%F %T')] nginx 重载成功" >> "$LOG_FILE"
else
    echo "[$(date '+%F %T')] nginx 重载失败，请检查配置文件" >> "$LOG_FILE"
    exit 1
fi