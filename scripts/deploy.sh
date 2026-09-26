#!/bin/bash
# ============================================================
# 自动化部署脚本
#
# 由 GitHub Actions 通过 SSH 调用，也可以手动执行：
#   bash /home/ddgmms/ops-project/scripts/deploy.sh
#
# 流程：记录版本 → 拉代码 → 预检配置 → 部署 → 健康检查 → 失败自动回滚
# ============================================================

set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROJECT_DIR="/home/ddgmms/ops-project"
BRANCH="main"
HEALTH_URL="https://blog.ddgmm.top"
HEALTH_RETRY=24          # 最多检查 24 次
HEALTH_INTERVAL=5        # 每次间隔 5 秒 → 最长等 120 秒
LOG_FILE="$PROJECT_DIR/logs/deploy.log"
LOCK_FILE="$PROJECT_DIR/logs/deploy.lock"
LAST_GOOD_FILE="$PROJECT_DIR/logs/last_good_commit"   # 记录最近一次健康成功的版本

mkdir -p "$PROJECT_DIR/logs"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

# 部署失败时的统一出口（不做回滚，回滚在最后单独处理）
fail() { log "[ERROR] $*"; exit 1; }

# ---------- 0. 防止两次部署同时进行 ----------
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    fail "另一个部署正在进行，本次终止"
fi

cd "$PROJECT_DIR"

log "=================================================="
log "开始部署（触发者：${GITHUB_ACTOR:-手动执行}，提交：${GITHUB_SHA:-未知}）"

# ---------- 1. 环境检查 ----------
[ -f .env ] || fail ".env 不存在，无法部署（这是不入库的敏感文件）"
for cmd in git docker curl; do
    command -v "$cmd" >/dev/null 2>&1 || fail "缺少命令: $cmd"
done

# ---------- 2. 记录当前版本（回滚的"锚点"）----------
OLD_COMMIT=$(git rev-parse HEAD)
log "当前版本：$OLD_COMMIT"

# ---------- 3. 保存服务器上的手工改动（防止被覆盖后无从追溯）----------
if ! git diff --quiet 2>/dev/null; then
    log "[WARN] 检测到工作区有未提交的改动，正在自动 stash 保存"
    git stash push -m "auto-stash-before-deploy-$(date +%s)" >> "$LOG_FILE" 2>&1 || true
    log "已 stash。如需找回：git stash list / git stash show -p stash@{0}"
fi

# ---------- 4. 拉取最新代码 ----------
log "拉取 origin/$BRANCH ..."
git fetch --prune origin >> "$LOG_FILE" 2>&1 || fail "git fetch 失败（检查网络或 Deploy Key 权限）"

TARGET_COMMIT=$(git rev-parse "origin/$BRANCH")
log "目标版本：$TARGET_COMMIT"

if [ "$OLD_COMMIT" = "$TARGET_COMMIT" ]; then
    log "[INFO] 代码版本没有变化，仍继续执行以确保配置生效"
fi

# 用 reset --hard 而不是 pull：避免"本地改动导致 merge 冲突"这类自动化场景下的意外
# 注意：不要用 git clean -fd，那会删掉 .env 等未跟踪的敏感文件！
git reset --hard "$TARGET_COMMIT" >> "$LOG_FILE" 2>&1 || fail "git reset 失败"

# ---------- 5. 预校验：把错误挡在"上线之前" ----------
# 这是本章最有价值的一段：配置有错时，直接终止，线上服务一秒都不受影响
log "===== 预校验配置 ====="

log "[1/3] 校验 docker-compose.yml"
docker compose config >/dev/null 2>>"$LOG_FILE" \
    || fail "docker-compose.yml 语法错误，部署已终止（线上服务未受影响）"

log "[2/3] 校验 nginx 配置"
# 前置检查：.htpasswd 不存在的话，docker 会把它当成目录挂载，报错信息会很误导
[ -f "$PROJECT_DIR/nginx/.htpasswd" ] \
    || fail "nginx/.htpasswd 不存在（见第 3 章 3.8.2），无法校验 nginx 配置"
# 用临时容器做语法检查，挂载参数与运行环境保持一致
# （不挂证书和 htpasswd 的话，nginx -t 会因为找不到文件而报错）
if ! docker run --rm --network ops-net \
        -v "$PROJECT_DIR/nginx/conf.d:/etc/nginx/conf.d:ro" \
        -v "$PROJECT_DIR/nginx/.htpasswd:/etc/nginx/.htpasswd:ro" \
        -v /etc/letsencrypt:/etc/letsencrypt:ro \
        nginx:stable nginx -t >> "$LOG_FILE" 2>&1
then
    fail "nginx 配置校验失败，部署已终止（线上服务未受影响）"
fi

log "[3/3] 校验 Prometheus 配置与告警规则"
if ! docker run --rm \
        -v "$PROJECT_DIR/prometheus:/etc/prometheus:ro" \
        --entrypoint promtool \
        prom/prometheus:v3.5.0 check config /etc/prometheus/prometheus.yml >> "$LOG_FILE" 2>&1
then
    fail "Prometheus 配置校验失败，部署已终止（线上服务未受影响）"
fi
if ! docker run --rm \
        -v "$PROJECT_DIR/prometheus:/etc/prometheus:ro" \
        --entrypoint promtool \
        prom/prometheus:v3.5.0 check rules /etc/prometheus/rules/alerts.yml >> "$LOG_FILE" 2>&1
then
    fail "Prometheus 告警规则校验失败，部署已终止（线上服务未受影响）"
fi

log "预校验全部通过 ✅"

# ---------- 6. 部署前备份 ----------
# 我们的配置改了可能影响数据（比如误改 volumes），先备一份数据是稳妥的做法
log "===== 部署前快速备份 ====="
if bash "$PROJECT_DIR/scripts/backup_mysql.sh" >> "$LOG_FILE" 2>&1; then
    log "数据库备份完成"
else
    log "[WARN] 部署前备份失败，继续部署（可根据情况决定是否终止）"
fi

# ---------- 7. 部署 ----------
log "===== 启动/更新服务 ====="
# --remove-orphans：清理已经从 compose 文件里删掉、但容器还残留的服务
docker compose --profile monitoring up -d --remove-orphans >> "$LOG_FILE" 2>&1 \
    || log "[WARN] docker compose up 返回非零，继续做健康检查"

# ---------- 8. 健康检查 ----------
log "===== 健康检查 ====="
health_ok=0

for i in $(seq 1 "$HEALTH_RETRY"); do
    # 8.1 容器状态：running + healthy
    container_bad=$(docker inspect \
        --format '{{.Name}}={{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' \
        wp_db wp_app wp_nginx 2>/dev/null \
        | grep -cvE 'running/(healthy)$|running$' || true)

    # 8.2 站点可用性（用户视角）
    if curl -sf -o /dev/null --max-time 10 "$HEALTH_URL"; then
        http_ok=1
    else
        http_ok=0
    fi

    log "第 ${i}/${HEALTH_RETRY} 次检查 → 异常容器数=${container_bad}，站点可访问=${http_ok}"

    if [ "$container_bad" -eq 0 ] && [ "$http_ok" -eq 1 ]; then
        health_ok=1
        break
    fi
    sleep "$HEALTH_INTERVAL"
done

# ---------- 9. 成功则结束 ----------
if [ "$health_ok" -eq 1 ]; then
    log "✅ 部署成功，当前运行版本：$TARGET_COMMIT"
    # 写入"最近一次健康成功的版本"，作为以后回滚的可靠锚点
    printf '%s\n' "$TARGET_COMMIT" > "$LAST_GOOD_FILE"
    docker compose --profile monitoring ps --format 'table {{.Name}}\t{{.Status}}' | tee -a "$LOG_FILE"
    log "=================================================="
    exit 0
fi

# ---------- 10. 失败则自动回滚 ----------
log "❌ 健康检查未通过，判定部署失败"

# 选择回滚目标：优先"最近一次健康成功的版本"
# 原因：OLD_COMMIT 只是"本次部署开始前"的版本。如果工作区此前已停留在故障版本上，
# 用它回滚等于原地打转，故障永远无法自愈（这正是之前回滚失效的根因）
ROLLBACK_COMMIT="$OLD_COMMIT"
if [ -f "$LAST_GOOD_FILE" ]; then
    LAST_GOOD=$(tr -d '[:space:]' < "$LAST_GOOD_FILE")
    if [ -n "$LAST_GOOD" ] && git cat-file -e "${LAST_GOOD}^{commit}" 2>/dev/null; then
        ROLLBACK_COMMIT="$LAST_GOOD"
    else
        log "[WARN] 上次成功版本记录无效（$LAST_GOOD），改用本次部署前版本 $OLD_COMMIT"
    fi
else
    log "[WARN] 暂无上次成功版本记录，改用本次部署前版本 $OLD_COMMIT"
fi

log "===== 开始自动回滚到 $ROLLBACK_COMMIT ====="

docker compose --profile monitoring logs --tail 50 --no-color >> "$LOG_FILE" 2>&1 || true

git reset --hard "$ROLLBACK_COMMIT" >> "$LOG_FILE" 2>&1 || log "[ERROR] 回滚时 git reset 失败！"

docker compose --profile monitoring up -d --remove-orphans >> "$LOG_FILE" 2>&1 || true

log "等待服务恢复..."
sleep 20

if curl -sf -o /dev/null --max-time 10 "$HEALTH_URL"; then
    log "✅ 回滚成功，服务已恢复到版本 $ROLLBACK_COMMIT，站点正常"
    log "=================================================="
    exit 1     # 依然返回失败，让 CI 知道"这次部署没成功"
else
    log "❌❌ 回滚后站点仍然不可访问！需要人工介入！"
    log "排查建议："
    log "  - docker compose --profile monitoring ps"
    log "  - docker compose --profile monitoring logs --tail 100"
    log "  - df -h; free -h"
    log "=================================================="
    exit 2
fi