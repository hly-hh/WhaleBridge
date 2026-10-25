#!/usr/bin/env bash
# 一键启动：SnowLuma 容器 -> （可选）dsh web -> qq-bridge
#   ./start.sh            只起容器 + 桥
#   ./start.sh --web      顺便起 dsh web（网页旁观用，端口 8080）
#   ./start.sh --restart  先杀掉旧桥再起
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$ROOT/qq-bridge"
CONTAINER="${SNOWLUMA_CONTAINER:-snowluma}"
PID_FILE="$BRIDGE/data/qq-bridge.pid"
LOG_DIR="$BRIDGE/data/logs"
LOG="$LOG_DIR/qq-bridge.log"
WEB_PID="$BRIDGE/data/dsh-web.pid"
WEB_LOG="$LOG_DIR/dsh-web.log"
WEB_PORT="${DSH_WEB_PORT:-8080}"

WITH_WEB=0
RESTART=0
for arg in "$@"; do
    case "$arg" in
        --web) WITH_WEB=1 ;;
        --restart) RESTART=1 ;;
        -h | --help)
            sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "不认识的参数：$arg（可用：--web --restart）" >&2
            exit 1
            ;;
    esac
done

say() { printf '  %s\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die() {
    printf '  \033[31m✗\033[0m %s\n' "$*" >&2
    exit 1
}

# ---------- 0. 环境 ----------
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
[ "$NODE_MAJOR" -ge 22 ] 2>/dev/null || die "需要 Node 22 以上（现在是 $(node -v 2>/dev/null || echo 没装)）"
if [ ! -f "$BRIDGE/config.json" ]; then
    cp "$BRIDGE/config.example.json" "$BRIDGE/config.json"
    warn "已生成 qq-bridge/config.json"
    die "先填里面的 access.owner（你自己的 QQ 号），再重新运行 ./start.sh"
fi
command -v docker >/dev/null || die "找不到 docker"

mkdir -p "$LOG_DIR"

# ---------- 1. 容器 ----------
state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
if [ "$state" = "missing" ]; then
    die "没有叫 $CONTAINER 的容器。先按 README 里的 docker run 起一个。"
elif [ "$state" != "running" ]; then
    say "容器 $state，正在启动…"
    docker start "$CONTAINER" >/dev/null || die "docker start 失败"
else
    ok "容器 $CONTAINER 在跑"
fi

# 等 OneBot 配置能被读到（QQ 登录后才会生成/刷新）
say "等 SnowLuma 就绪…"
READY=0
for _ in $(seq 1 40); do
    if docker exec "$CONTAINER" cat /app/data/config/onebot.json >/dev/null 2>&1; then
        ok "OneBot 配置可读"
        READY=1
        break
    fi
    sleep 1.5
done
if [ "$READY" = "0" ]; then
    warn "等不到 OneBot 配置（QQ 可能还没登录）"
    warn "去 http://localhost:6081 登录后，再执行 ./start.sh --restart"
fi

# ---------- 2. dsh web（可选） ----------
if [ "$WITH_WEB" = "1" ]; then
    if [ -f "$WEB_PID" ] && kill -0 "$(cat "$WEB_PID" 2>/dev/null)" 2>/dev/null; then
        ok "dsh web 已经在跑（pid $(cat "$WEB_PID")）"
    else
        say "启动 dsh web（127.0.0.1:$WEB_PORT）"
        (cd "$BRIDGE" && setsid nohup dsh web --no-open --port "$WEB_PORT" >>"$WEB_LOG" 2>&1 </dev/null & echo $! >"$WEB_PID")
        sleep 3
        if kill -0 "$(cat "$WEB_PID")" 2>/dev/null; then
            ok "dsh web → http://localhost:$WEB_PORT"
        else
            warn "dsh web 没起来，看 $WEB_LOG"
        fi
    fi
fi

# ---------- 3. 桥 ----------
# 手动起过的桥没有 pid 文件，先认领它，别起第二份
if [ ! -f "$PID_FILE" ]; then
    found="$(pgrep -f '^node src/index.js' | head -1)"
    [ -n "$found" ] && echo "$found" >"$PID_FILE"
fi

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    if [ "$RESTART" = "1" ]; then
        say "重启桥…"
        kill "$(cat "$PID_FILE")" 2>/dev/null
        sleep 1
    else
        ok "qq-bridge 已经在跑（pid $(cat "$PID_FILE")）"
        say "看日志：tail -f $LOG"
        exit 0
    fi
fi

printf '\n===== 启动 %s =====\n' "$(date '+%F %T')" >>"$LOG"
(cd "$BRIDGE" && setsid nohup node src/index.js >>"$LOG" 2>&1 </dev/null & echo $! >"$PID_FILE")
sleep 2

if ! kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    tail -20 "$LOG"
    die "qq-bridge 没起来（日志在上面）"
fi
ok "qq-bridge 起来了（pid $(cat "$PID_FILE")）"

# ---------- 4. 探活 ----------
if (cd "$BRIDGE" && timeout 15 node src/index.js --probe 2>&1 | grep -q 'QQ 在线'); then
    ok "QQ 在线，可以说话了"
else
    warn "桥在跑，但 QQ 还没上线（去 http://localhost:6081 登录）"
fi

cat <<EOF

  接下来：
    QQ         用你的号给 $(node -p "require('$BRIDGE/config.json').access.owner" 2>/dev/null || echo '小号') 发消息
    看日志     tail -f $LOG
    看状态     ./status.sh
    关掉       ./stop.sh

EOF
