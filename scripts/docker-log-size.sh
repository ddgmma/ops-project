#!/usr/bin/env bash
#
# docker-log-size.sh
# 功能：列出每个 Docker 容器及其容器日志文件（*-json.log）的大小
# 用法：sudo ./docker-log-size.sh
#
set -uo pipefail

CONTAINERS_DIR="${CONTAINERS_DIR:-/var/lib/docker/containers}"

if [ "$(id -u)" -ne 0 ]; then
  echo "错误：读取 ${CONTAINERS_DIR} 需要 root 权限。" >&2
  echo "请改用：sudo $0" >&2
  exit 1
fi

if [ ! -d "${CONTAINERS_DIR}" ]; then
  echo "错误：容器目录不存在：${CONTAINERS_DIR}" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "错误：未找到 docker 命令，请确认 Docker 已安装。" >&2
  exit 1
fi

# 建立 完整容器ID -> 容器名称 的映射
declare -A NAME_MAP=()
while IFS=' ' read -r full_id cname; do
  [ -n "${full_id}" ] || continue
  NAME_MAP["${full_id}"]="${cname}"
done < <(docker ps -a --no-trunc --format '{{.ID}} {{.Names}}' 2>/dev/null || true)

printf '%-14s %-28s %12s %16s\n' 'CONTAINER ID' 'CONTAINER NAME' 'SIZE' 'BYTES'
printf '%s\n' '--------------------------------------------------------------------------'

total=0
while IFS=$'\t' read -r size path; do
  [ -n "${path}" ] || continue
  cdir=$(basename "$(dirname "${path}")")
  short_id="${cdir:0:12}"
  cname="${NAME_MAP[${cdir}]:-<未知容器>}"
  human=$(awk -v s="${size}" 'BEGIN{split("B KB MB GB TB PB",u," ");i=1;while(s>=1024&&i<6){s/=1024;i++};printf "%.1f%s",s,u[i]}')
  printf '%-14s %-28s %12s %16s\n' "${short_id}" "${cname}" "${human}" "${size}"
  total=$((total + size))
done < <(find "${CONTAINERS_DIR}" -maxdepth 2 -type f -name '*-json.log' -printf '%s\t%p\n' 2>/dev/null | sort -rn)

printf '%s\n' '--------------------------------------------------------------------------'
total_human=$(awk -v s="${total}" 'BEGIN{split("B KB MB GB TB PB",u," ");i=1;while(s>=1024&&i<6){s/=1024;i++};printf "%.1f%s",s,u[i]}')
echo "合计日志大小：${total} 字节（${total_human}）"
