#!/bin/bash
# ============================================================
# MySQL 数据库备份脚本
# 用法：./backup_mysql.sh
# 特点：真实失败检测 + 文件完整性校验 + 防并发 + 失败指标上报
# ============================================================

set -euo pipefail

# ★ 显式设置 PATH：cron 的环境变量非常少，
#   不写这行可能出现"手动跑没问题，cron 跑就报 docker: command not found"
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---------- 路径与配置 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
BACKUP_DIR="$PROJECT_DIR/backups"
LOG_FILE="$PROJECT_DIR/logs/backup.log"
METRICS_DIR="/var/lib/node_exporter/textfile"

CONTAINER_NAME="wp_db"
RETENTION_DAYS=7
MIN_FILE_SIZE=10240        # 备份文件小于 10KB 视为异常
# 锁文件放项目目录：普通用户对 /var/lock 没有写权限
LOCK_FILE="$PROJECT_DIR/logs/backup_mysql.lock"

# ---------- 日志函数 ----------
log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

die() {
    log "[ERROR] $*"
    write_metrics 0 "备份失败: $*"
    exit 1
}

# ---------- 上报备份状态给 Prometheus ----------
# 原理：node-exporter 的 textfile collector 会读取这个目录下的 .prom 文件
#       并把里面的指标暴露出去，于是"备份是否成功"也变成一个可告警的指标
write_metrics() {
    local success="$1"
    local message="${2:-}"

    [ -d "$METRICS_DIR" ] || return 0

    local tmp_file="$METRICS_DIR/backup_mysql.prom.tmp.$$"
    cat > "$tmp_file" <<EOF
# HELP backup_last_run_timestamp 上次备份执行的时间戳
# TYPE backup_last_run_timestamp gauge
backup_last_run_timestamp{type="mysql"} $(date +%s)
# HELP backup_success 上次备份是否成功(1=成功 0=失败)
# TYPE backup_success gauge
backup_success{type="mysql"} $success
EOF
    # 先写临时文件再原子替换：避免 node-exporter 读到写了一半的文件
    mv "$tmp_file" "$METRICS_DIR/backup_mysql.prom"

    if [ -n "$message" ]; then
        # 失败原因也写进指标，方便在告警邮件里看到
        printf '# HELP backup_last_error 上次备份失败原因\n# TYPE backup_last_error gauge\nbackup_last_error{type="mysql",message="%s"} 1\n' \
            "$(echo "$message" | tr -d '"' | tr '\n' ' ')" \
            > "$METRICS_DIR/backup_mysql_error.prom"
    else
        rm -f "$METRICS_DIR/backup_mysql_error.prom"
    fi
}

# ---------- 0. 防并发 ----------
# 万一上次备份还没跑完（比如数据量变大），这一次就直接退出，避免两个 mysqldump 打架
mkdir -p "$PROJECT_DIR/logs"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    die "另一个备份进程正在运行，本次跳过"
fi

# ---------- 1. 加载配置 ----------
[ -f "$ENV_FILE" ] || die "找不到 $ENV_FILE"
# set -a 让 source 进来的变量自动变成环境变量
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

DB_NAME="${MYSQL_DATABASE:-wordpress}"
DB_USER="root"
DB_PASS="${MYSQL_ROOT_PASSWORD:?环境变量 MYSQL_ROOT_PASSWORD 未设置}"

# ---------- 2. 检查依赖 ----------
for cmd in docker gzip; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少命令: $cmd"
done

# ---------- 3. 检查容器在跑 ----------
if ! docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep '^true$' > /dev/null; then
    die "容器 $CONTAINER_NAME 未运行，无法备份"
fi

# ---------- 4. 执行备份 ----------
mkdir -p "$BACKUP_DIR" "$PROJECT_DIR/logs"

BACKUP_FILE="$BACKUP_DIR/db_${DB_NAME}_${DATESTAMP:-$(date +%Y%m%d_%H%M%S)}.sql.gz"
TMP_FILE="${BACKUP_FILE}.tmp"

log "===== 开始备份数据库：$DB_NAME ====="
log "目标文件：$BACKUP_FILE"

# ★★ 这里就是原指南最大的 bug 所在 ★★
# 原写法是：
#   docker exec ... mysqldump ... | gzip > "$FILE"
#   if [ $? -eq 0 ]; then echo "备份成功"
# 问题：$? 取到的是管道中【最后一个命令 gzip】的退出码。
#       mysqldump 因为密码错误/容器没起而失败时，gzip 仍然正常返回 0，
#       于是脚本打印"备份成功"，并留下一个几乎空的 .sql.gz 文件。
#       这就是最危险的"备份静默失败"。
#
# 正确做法有两种，本项目两者都用：
#   ① set -o pipefail（已经在第 4 行设置）：管道中任一命令失败，整个管道就失败
#   ② 即使如此也不够——还要校验"文件本身是不是完整"
if ! docker exec -e MYSQL_PWD="$DB_PASS" "$CONTAINER_NAME" \
        mysqldump \
            -u"$DB_USER" \
            --single-transaction \
            --quick \
            --routines \
            --triggers \
            --events \
            --default-character-set=utf8mb4 \
            --databases "$DB_NAME" \
       | gzip -9 > "$TMP_FILE"
then
    rm -f "$TMP_FILE"
    die "mysqldump 执行失败（常见原因：密码错误、容器未就绪、磁盘空间不足）"
fi

# 说明：用 -e MYSQL_PWD 传递密码，而不是 -p密码
#       这样密码不会出现在 docker exec 的命令行里（ps aux 能看到），也不会打印 warning

# ---------- 5. 校验备份文件（这一步是"能不能恢复"的保证）----------
# 5.1 gzip 文件结构完整吗
if ! gzip -t "$TMP_FILE" 2>/dev/null; then
    rm -f "$TMP_FILE"
    die "备份文件损坏：gzip 完整性校验失败"
fi

# 5.2 文件大小是否合理
FILE_SIZE=$(stat -c%s "$TMP_FILE")
if [ "$FILE_SIZE" -lt "$MIN_FILE_SIZE" ]; then
    rm -f "$TMP_FILE"
    die "备份文件过小（${FILE_SIZE} 字节 < ${MIN_FILE_SIZE}），内容可能不完整"
fi

# 5.3 SQL 内容是否正常结束
#     mysqldump 正常完成时，末尾会输出 "-- Dump completed on ..."
#     如果导出中途被中断（磁盘满、被杀进程），这个标记就不会出现
if ! gunzip -c "$TMP_FILE" | tail -20 | grep 'Dump completed' > /dev/null; then
    rm -f "$TMP_FILE"
    die "备份文件不完整：缺少 'Dump completed' 结束标记，可能被中途截断"
fi

# 校验全部通过，正式改名（临时文件 → 正式文件）
mv "$TMP_FILE" "$BACKUP_FILE"

log "备份成功：$(basename "$BACKUP_FILE")，大小 $(du -h "$BACKUP_FILE" | cut -f1)"

# ---------- 6. 清理过期备份 ----------
log "清理 ${RETENTION_DAYS} 天前的本机备份"
DELETED=$(find "$BACKUP_DIR" -maxdepth 1 -name "db_*.sql.gz" -type f -mtime +"$RETENTION_DAYS" -print -delete | wc -l)
log "本次清理 $DELETED 个过期文件"

# ---------- 7. 可选：同步到对象存储（异地备份）----------
if command -v coscmd >/dev/null 2>&1; then
    log "上传到腾讯云 COS..."
    if coscmd upload "$BACKUP_FILE" "/db/" >> "$LOG_FILE" 2>&1; then
        log "异地备份上传成功"
    else
        log "[WARN] 异地备份上传失败（本地备份仍是成功的，但请尽快排查）"
    fi
else
    log "[INFO] 未安装 coscmd，跳过异地备份"
fi

# ---------- 8. 上报成功状态给 Prometheus ----------
write_metrics 1

log "===== 备份流程完成 ====="
exit 0
