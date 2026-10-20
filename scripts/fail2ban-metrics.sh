#!/bin/bash
set -euo pipefail
METRICS_DIR="/var/lib/node_exporter/textfile"
[ -d "$METRICS_DIR" ] || exit 0

OUT="$METRICS_DIR/fail2ban.prom.tmp.$$"
{
  echo "# HELP fail2ban_banned_current 当前被封禁的 IP 数"
  echo "# TYPE fail2ban_banned_current gauge"
  echo "# HELP fail2ban_banned_total 累计封禁 IP 数"
  echo "# TYPE fail2ban_banned_total gauge"
  echo "# HELP fail2ban_failed_current 当前失败计数"
  echo "# TYPE fail2ban_failed_current gauge"

  for jail in $(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:\s*//p' | tr ',' ' '); do
    cur=$(fail2ban-client status "$jail" 2>/dev/null | sed -n 's/.*Currently banned:\s*//p' | tr -d ' ')
    tot=$(fail2ban-client status "$jail" 2>/dev/null | sed -n 's/.*Total banned:\s*//p' | tr -d ' ')
    fail=$(fail2ban-client status "$jail" 2>/dev/null | sed -n 's/.*Currently failed:\s*//p' | tr -d ' ')
    echo "fail2ban_banned_current{jail=\"$jail\"} ${cur:-0}"
    echo "fail2ban_banned_total{jail=\"$jail\"} ${tot:-0}"
    echo "fail2ban_failed_current{jail=\"$jail\"} ${fail:-0}"
  done
} > "$OUT"
mv "$OUT" "$METRICS_DIR/fail2ban.prom"
