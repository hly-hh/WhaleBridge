#!/usr/bin/env bash
# 一键关闭
#   ./stop.sh          只关 qq-bridge（QQ 还挂在容器里）
#   ./stop.sh --all    连容器和 dsh web 一起关
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$ROOT/qq-bridge"
CONTAINER="${SNOWLUMA_CONTAINER:-snowluma}"
PID_FILE="$BRIDGE/data/qq-bridge.pid"
WEB_PID="$BRIDGE/data/dsh-web.pid"

ALL=0
for arg in "$@"; do
    case "$arg" in
        --all) ALL=1 ;;
        -h | --help)
            sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "不认识的参数：$arg（可用：--all）" >&2
            exit 1
            ;;
    esac
done

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

stop_pidfile() {
    local file="$1" name="$2"
    [ -f "$file" ] || {
        warn "$name 没有 pid 文件，跳过"
        return
    }
    local pid
    pid="$(cat "$file" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        for _ in $(seq 1 20); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        ok "$name 已停（pid $pid）"
    else
        warn "$name 已经不在跑了"
    fi
    rm -f "$file"
}

if [ -f "$PID_FILE" ]; then
    stop_pidfile "$PID_FILE" "qq-bridge"
else
    # 手动起过的桥：按命令行找
    pids="$(pgrep -f '^node src/index.js' || true)"
    if [ -n "$pids" ]; then
        echo "$pids" | xargs -r kill 2>/dev/null
        sleep 1
        pgrep -f '^node src/index.js' | xargs -r kill -9 2>/dev/null
        ok "qq-bridge 已停（按进程名找到的）"
    else
        warn "qq-bridge 没在跑"
    fi
fi

if [ "$ALL" = "1" ]; then
    stop_pidfile "$WEB_PID" "dsh web"

    if [ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = "running" ]; then
        docker stop "$CONTAINER" >/dev/null && ok "容器 $CONTAINER 已停"
    else
        warn "容器 $CONTAINER 没在跑"
    fi
else
    warn "QQ 还挂在容器里（要一起关：./stop.sh --all）"
fi
