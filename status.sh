#!/usr/bin/env bash
# 看一眼现在什么状态：容器、QQ、桥、dsh web、最近日志
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$ROOT/qq-bridge"
CONTAINER="${SNOWLUMA_CONTAINER:-snowluma}"
LOG="$BRIDGE/data/logs/qq-bridge.log"
WEB_PID="$BRIDGE/data/dsh-web.pid"

line() { printf '  %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

head_ "容器 / QQ"
state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)"
if [ -z "$state" ]; then
    line "✗ 没有容器 $CONTAINER"
else
    line "✓ $CONTAINER: $state（$(docker ps --filter "name=^/${CONTAINER}$" --format '{{.Status}}' 2>/dev/null)）"
fi

head_ "SnowLuma（自动探活）"
probe_out="$(cd "$BRIDGE" && timeout 15 node src/index.js --probe 2>&1)"
printf '%s\n' "$probe_out" | sed 's/^/  /'
if ! printf '%s\n' "$probe_out" | grep -q 'QQ 在线'; then
    vnc_pass="$(docker logs "$CONTAINER" 2>&1 | grep -m1 'remote desktop password:' | sed 's/.*remote desktop password:[[:space:]]*//' | tr -d '\r')"
    echo
    line "  提示：QQ 没登录时 OneBot 不会监听 3001，桥会一直重连"
    line "  QQ 登录   http://localhost:6081（noVNC）${vnc_pass:+ · VNC 密码：$vnc_pass}"
    line "  管理      http://localhost:5099（SnowLuma WebUI）"
fi

head_ "qq-bridge"
pid="$(cat "$BRIDGE/data/qq-bridge.pid" 2>/dev/null || pgrep -f '^node src/index.js' | head -1)"
if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    line "✓ 在跑（pid $pid，已运行 $(ps -o etime= -p "$pid" | tr -d ' ')）"
else
    line "✗ 没在跑（./start.sh 起）"
fi

head_ "dsh web"
wpid="$(cat "$WEB_PID" 2>/dev/null || pgrep -f 'dsh web' | head -1)"
if [ -n "${wpid:-}" ] && kill -0 "$wpid" 2>/dev/null; then
    line "✓ 在跑（pid $wpid）→ http://localhost:${DSH_WEB_PORT:-8080}"
else
    line "— 没在跑（需要旁观时：./start.sh --web）"
fi

head_ "最近日志"
if [ -f "$LOG" ]; then
    tail -12 "$LOG" | sed 's/^/  /'
else
    line "（还没有日志）"
fi
echo
