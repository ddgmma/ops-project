#!/bin/bash
# ============================================================
# WordPress 文件卷备份脚本
# 备份 wp_data 卷里的全部内容（上传的图片、主题、插件）
# ============================================================

set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$PROJECT_DIR/backups"
LOG_FILE="$PROJECT_DIR/logs/backup.log"
METRICS_DIR="/var/lib/node_exporter/textfile"

VOLUME_NAME="ops-project_wp_data"     # 实际卷名 = compose 项目名 + 卷名
RETENTION_DAYS=7
MIN_FILE_SIZE=10240
# 锁文件放项目目录：普通用户对 /var/lock 没有写权限
LOCK_FILE="$PROJECT_DIR/logs/backup_files.lock"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

write_metrics() {
    local success="$1"
    [ -d "$METRICS_DIR" ] || return 0
    local tmp_file="$METRICS_DIR/backup_files.prom.tmp.$$"
    cat > "$tmp_file" <<EOF
# HELP backup_last_run_timestamp 上次备份执行的时间戳
# TYPE backup_last_run_timestamp gauge
backup_last_run_timestamp{type="files"} $(date +%s)
# HELP backup_success 上次备份是否成功(1=成功 0=失败)
# TYPE backup_success gauge
backup_success{type="files"} $success
EOF
    mv "$tmp_file" "$METRICS_DIR/backup_files.prom"
}

die() {
    log "[ERROR] $*"
    write_metrics 0
    exit 1
}

mkdir -p "$PROJECT_DIR/logs"
exec 9>"$LOCK_FILE"
flock -n 9 || die "另一个文件备份进程正在运行，本次跳过"

for cmd in docker gzip; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少命令: $cmd"
done

# 确认卷存在
if ! docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
    die "数据卷 $VOLUME_NAME 不存在（用 docker volume ls 查看实际卷名）"
fi

mkdir -p "$BACKUP_DIR" "$PROJECT_DIR/logs"

BACKUP_NAME="files_wp_data_$(date +%Y%m%d_%H%M%S).tar.gz"
BACKUP_FILE="$BACKUP_DIR/$BACKUP_NAME"

log "===== 开始备份文件卷：$VOLUME_NAME ====="

# 用一个临时容器把卷挂进来打包
# --rm    用完即删，不留垃圾容器
# :ro     只读挂载，确保备份过程绝对不会修改源数据（重要！）
# alpine  体积小，拉取快
if ! docker run --rm \
        -v "$VOLUME_NAME":/data:ro \
        -v "$BACKUP_DIR":/backup \
        alpine:3.20 \
        tar czf "/backup/$BACKUP_NAME" -C /data .
then
    rm -f "$BACKUP_FILE"
    die "打包文件卷失败"
fi

# 上面那条命令是让容器直接写到宿主机的 $BACKUP_DIR，所以文件已经在最终位置了
if [ ! -f "$BACKUP_FILE" ]; then
    die "备份文件未生成"
fi

# ---------- 校验 ----------
if ! tar tzf "$BACKUP_FILE" >/dev/null 2>&1; then
    rm -f "$BACKUP_FILE"
    die "备份文件损坏：tar 完整性校验失败"
fi

FILE_SIZE=$(stat -c%s "$BACKUP_FILE")
if [ "$FILE_SIZE" -lt "$MIN_FILE_SIZE" ]; then
    rm -f "$BACKUP_FILE"
    die "备份文件过小（${FILE_SIZE} 字节），可能没有内容"
fi

# 确认包里真的有关键文件（而不是打了一个空目录）
if ! tar tzf "$BACKUP_FILE" | grep 'wp-content' > /dev/null; then
    rm -f "$BACKUP_FILE"
    die "备份内容异常：包内找不到 wp-content 目录"
fi

log "备份成功：$BACKUP_NAME，大小 $(du -h "$BACKUP_FILE" | cut -f1)，包含 $(tar tzf "$BACKUP_FILE" | wc -l) 个文件"

# ---------- 清理 ----------
DELETED=$(find "$BACKUP_DIR" -maxdepth 1 -name "files_wp_data_*.tar.gz" -type f -mtime +"$RETENTION_DAYS" -print -delete | wc -l)
log "清理 ${RETENTION_DAYS} 天前的文件备份，共 $DELETED 个"

# ---------- 异地备份 ----------
if command -v coscmd >/dev/null 2>&1; then
    if coscmd upload "$BACKUP_FILE" "/files/" >> "$LOG_FILE" 2>&1; then
        log "异地备份上传成功"
    else
        log "[WARN] 异地备份上传失败"
    fi
fi

write_metrics 1
log "===== 文件卷备份完成 ====="
exit 0