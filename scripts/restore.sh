#!/bin/bash
# ============================================================
# 恢复脚本
# 用法：
#   恢复数据库： ./restore.sh db   backups/db_wordpress_20260919_023000.sql.gz
#   恢复文件卷： ./restore.sh files backups/files_wp_data_20260919_030000.tar.gz
#   列出可用备份：./restore.sh list
# ============================================================

set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
BACKUP_DIR="$PROJECT_DIR/backups"
LOG_FILE="$PROJECT_DIR/logs/restore.log"

DB_CONTAINER="wp_db"
WP_CONTAINER="wp_app"
VOLUME_NAME="ops-project_wp_data"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
die() { log "[ERROR] $*"; exit 1; }

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
DB_PASS="${MYSQL_ROOT_PASSWORD:?环境变量 MYSQL_ROOT_PASSWORD 未设置}"

MODE="${1:-}"
BACKUP_FILE="${2:-}"

# ---------- list：列出可用备份 ----------
if [ "$MODE" = "list" ]; then
    echo "=== 数据库备份 ==="
    ls -lh "$BACKUP_DIR"/db_*.sql.gz 2>/dev/null || echo "（无）"
    echo
    echo "=== 文件卷备份 ==="
    ls -lh "$BACKUP_DIR"/files_*.tar.gz 2>/dev/null || echo "（无）"
    exit 0
fi

[ -n "$MODE" ] && [ -n "$BACKUP_FILE" ] || {
    echo "用法："
    echo "  $0 list"
    echo "  $0 db    <备份文件.sql.gz>"
    echo "  $0 files <备份文件.tar.gz>"
    exit 1
}

[ -f "$BACKUP_FILE" ] || die "备份文件不存在：$BACKUP_FILE"

# ---------- 1. 恢复前先给当前状态做一个快照 ----------
#   这一步是"后悔药"：万一恢复的备份比当前还旧、或者恢复过程中出错，你还能退回来
log "===== 恢复前快照 ====="
"$SCRIPT_DIR/backup_mysql.sh" || log "[WARN] 恢复前快照备份失败，继续执行（请谨慎）"
"$SCRIPT_DIR/backup_files.sh" || log "[WARN] 恢复前文件快照失败，继续执行（请谨慎）"

case "$MODE" in
  db)
    log "===== 开始恢复数据库：$BACKUP_FILE ====="

    # 校验备份文件完整性（不能拿一个坏文件去覆盖现有数据！）
    gzip -t "$BACKUP_FILE" || die "备份文件已损坏，拒绝恢复"
    gunzip -c "$BACKUP_FILE" | tail -20 | grep 'Dump completed' > /dev/null \
        || die "备份文件不完整（缺少结束标记），拒绝恢复"

    # 2. 停掉应用，避免恢复过程中还有写入，导致数据不一致
    log "停止 WordPress 容器（避免恢复期间写入）"
    docker stop "$WP_CONTAINER" >/dev/null

    # 3. 执行恢复
    log "执行恢复（可能需要几分钟）..."
    if gunzip -c "$BACKUP_FILE" \
        | docker exec -i -e MYSQL_PWD="$DB_PASS" "$DB_CONTAINER" mysql -uroot
    then
        log "数据库恢复完成"
    else
        log "[ERROR] 恢复失败！WordPress 仍处于停止状态，请人工介入"
        log "提示：可以尝试用刚才的『恢复前快照』回退"
        exit 1
    fi

    # 4. 起回来
    log "启动 WordPress 容器"
    docker start "$WP_CONTAINER" >/dev/null
    ;;

  files)
    log "===== 开始恢复文件卷：$BACKUP_FILE ====="

    tar tzf "$BACKUP_FILE" >/dev/null 2>&1 || die "备份文件已损坏，拒绝恢复"
    # tar tzf 要输出几千行，grep -q 一匹配就退出 → tar 收到 SIGPIPE(141) → 管道非 0 → 误报"内容异常"
    tar tzf "$BACKUP_FILE" | grep 'wp-content' > /dev/null || die "备份内容异常，拒绝恢复"

    log "停止 WordPress 容器"
    docker stop "$WP_CONTAINER" >/dev/null

    # ★ 危险操作：先清空数据卷再解包
    #   这里用了一个独立容器挂载卷来操作，避免误删宿主机文件
    log "清空数据卷并解包（危险操作，请确认备份文件正确）"
    if docker run --rm \
            -v "$VOLUME_NAME":/data \
            -v "$(cd "$(dirname "$BACKUP_FILE")" && pwd)":/backup:ro \
            alpine:3.20 \
            sh -c "rm -rf /data/* /data/.[!.]* 2>/dev/null; tar xzf /backup/$(basename "$BACKUP_FILE") -C /data && ls /data | head"
    then
        log "文件卷恢复完成"
    else
        log "[ERROR] 文件卷恢复失败！"
        exit 1
    fi

    # 修权限（tar 解包后属主可能不对）
    docker run --rm -v "$VOLUME_NAME":/data alpine:3.20 \
        chown -R 33:33 /data/wp-content 2>/dev/null || true

    log "启动 WordPress 容器"
    docker start "$WP_CONTAINER" >/dev/null
    ;;

  *)
    die "未知模式：$MODE（可用：list / db / files）"
    ;;
esac

# ---------- 5. 验证 ----------
sleep 5
log "===== 恢复后的验证 ====="

if curl -sf -o /dev/null -w "%{http_code}\n" https://blog.ddgmm.top -k | grep -E '200|302' > /dev/null; then
    log "网站可访问 ✅"
else
    log "⚠️ 网站访问异常，请检查：docker compose ps / docker compose logs wordpress"
fi

log "===== 恢复流程结束 ====="

