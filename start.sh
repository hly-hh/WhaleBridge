#!/usr/bin/env bash
# 一键启动（前台）：SnowLuma 容器 ->（可选）dsh web -> qq-bridge
#   ./start.sh            前台跑桥，日志同时进终端和 qq-bridge/data/logs
#   ./start.sh --web      顺便起 dsh web（网页旁观用，端口 8080）
#   ./start.sh --restart  先杀掉旧桥再起
#   Ctrl+C                下线：停桥（和本次起的 dsh web），容器/QQ 保留
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
WEB_STARTED=0
BRIDGE_PID=""

for arg in "$@"; do
    case "$arg" in
        --web) WITH_WEB=1 ;;
        --restart) RESTART=1 ;;
        -h | --help)
            sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
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

LOGIN_HELP_SHOWN=0
VNC_PASS=""

# 容器里的两个网页入口：QQ 登录 / SnowLuma 管理
print_entries() {
    printf '\n\033[1m网页入口\033[0m\n'
    printf '  QQ 登录（noVNC）   http://localhost:6081\n'
    if [ -n "$VNC_PASS" ]; then
        printf '      VNC 密码       %s\n' "$VNC_PASS"
    else
        printf '      VNC 密码       见 docker logs %s | grep "remote desktop password"\n' "$CONTAINER"
    fi
    printf '  SnowLuma 管理      http://localhost:5099\n'
    printf '  （WebUI 密码是你首次启动时设的；忘了就重启容器看日志里的初始凭据）\n'
}

print_login_help() {
    [ "$LOGIN_HELP_SHOWN" = "1" ] && return 0
    LOGIN_HELP_SHOWN=1
    printf '\n  \033[1mQQ 还没登录\033[0m\n'
    printf '    1. 浏览器打开 http://localhost:6081（noVNC）\n'
    if [ -n "$VNC_PASS" ]; then
        printf '    2. VNC 密码：%s\n' "$VNC_PASS"
    else
        printf '    2. VNC 密码：docker logs %s | grep "remote desktop password"\n' "$CONTAINER"
    fi
    printf '    3. 用手机 QQ 扫码登录小号，建议勾选「自动登录」\n'
    printf '    4. 登录后 OneBot 才会监听 3001，桥会在 30 秒内自动重连\n'
    printf '       不用重启 start.sh；扫码后回这里看日志即可\n'
    printf '       确认登录：docker logs %s | grep OneBot.WS-Server\n\n' "$CONTAINER"
}

# 探活：能拿到 QQ 昵称才算真上线
check_qq() {
    local out line
    out="$(cd "$BRIDGE" && timeout 15 node src/index.js --probe 2>&1)"
    line="$(printf '%s\n' "$out" | grep 'QQ 在线' | head -1 | sed 's/^[0-9:]* 信息 //')"
    if [ -n "$line" ]; then
        ok "$line"
        return 0
    fi
    printf '%s\n' "$out" | sed 's/^/  /'
    warn "QQ 还没上线"
    print_login_help
    return 1
}

# Ctrl+C / 退出时收拾干净：桥、本次起的 dsh web、pid 文件
cleanup() {
    [ "${CLEANED:-0}" = "1" ] && return 0
    CLEANED=1
    trap - EXIT INT TERM

    if [ -n "$BRIDGE_PID" ] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
        kill "$BRIDGE_PID" 2>/dev/null
        for _ in $(seq 1 20); do
            kill -0 "$BRIDGE_PID" 2>/dev/null || break
            sleep 0.2
        done
        kill -0 "$BRIDGE_PID" 2>/dev/null && kill -9 "$BRIDGE_PID" 2>/dev/null
    fi
    rm -f "$PID_FILE"

    if [ "$WEB_STARTED" = "1" ]; then
        local wpid
        wpid="$(cat "$WEB_PID" 2>/dev/null)"
        if [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null; then
            kill "$wpid" 2>/dev/null
            for _ in $(seq 1 20); do
                kill -0 "$wpid" 2>/dev/null || break
                sleep 0.2
            done
            kill -0 "$wpid" 2>/dev/null && kill -9 "$wpid" 2>/dev/null
        fi
        rm -f "$WEB_PID"
    fi

    printf '\n  \033[33m已下线\033[0m（容器 %s 和 QQ 还在后台跑；一起关：./stop.sh --all）\n\n' "$CONTAINER"
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

# 从首次启动日志里取 noVNC 密码（之后重启不再打印，但密码还是这个）
VNC_PASS="$(docker logs "$CONTAINER" 2>&1 | grep -m1 'remote desktop password:' | sed 's/.*remote desktop password:[[:space:]]*//' | tr -d '\r')"
print_entries

# 检查 OneBot 配置（QQ 登录后才会生成/刷新）
say "检查 OneBot 配置…"
READY=0
for _ in $(seq 1 40); do
    if docker exec "$CONTAINER" cat /app/data/config/onebot.json >/dev/null 2>&1; then
        ok "OneBot 配置已读到"
        READY=1
        break
    fi
    sleep 1.5
done
if [ "$READY" = "0" ]; then
    warn "读不到 OneBot 配置（QQ 登录后 OneBot 才会生成）"
    print_login_help
fi

# ---------- 2. dsh web（可选） ----------
if [ "$WITH_WEB" = "1" ]; then
    if [ -f "$WEB_PID" ] && kill -0 "$(cat "$WEB_PID" 2>/dev/null)" 2>/dev/null; then
        ok "dsh web 已经在跑（pid $(cat "$WEB_PID")，退出时不会关它）"
    else
        say "启动 dsh web（127.0.0.1:$WEB_PORT）"
        (cd "$BRIDGE" && setsid nohup dsh web --no-open --port "$WEB_PORT" >>"$WEB_LOG" 2>&1 </dev/null & echo $! >"$WEB_PID")
        WEB_STARTED=1
        sleep 3
        if kill -0 "$(cat "$WEB_PID")" 2>/dev/null; then
            ok "dsh web → http://localhost:$WEB_PORT（Ctrl+C 时一起关）"
        else
            warn "dsh web 没起来，看 $WEB_LOG"
            WEB_STARTED=0
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
    old_pid="$(cat "$PID_FILE")"
    if [ "$RESTART" = "1" ]; then
        say "停掉旧桥（pid $old_pid）…"
        kill "$old_pid" 2>/dev/null
        for _ in $(seq 1 20); do
            kill -0 "$old_pid" 2>/dev/null || break
            sleep 0.2
        done
        kill -0 "$old_pid" 2>/dev/null && kill -9 "$old_pid" 2>/dev/null
        rm -f "$PID_FILE"
    else
        warn "qq-bridge 已经在跑（pid $old_pid）"
        say "start.sh 现在是前台模式，不能接管后台的桥"
        say "先 ./stop.sh，或者用 ./start.sh --restart"
        exit 1
    fi
fi

# 先探活，再前台起桥；这样登录提示不会把终端刷满
printf '\n'
check_qq || true

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT TERM

printf '\n===== 启动 %s =====\n' "$(date '+%F %T')" >>"$LOG"
say "前台启动 qq-bridge（Ctrl+C 下线，日志同时写入 $LOG）"

(
    cd "$BRIDGE" || exit 1
    exec node src/index.js
) > >(tee -a "$LOG") 2>&1 &
BRIDGE_PID=$!
echo "$BRIDGE_PID" >"$PID_FILE"

sleep 2
if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    wait "$BRIDGE_PID"
    tail -20 "$LOG"
    die "qq-bridge 没起来（日志在上面）"
fi
ok "qq-bridge 在前台跑（pid $BRIDGE_PID）"

cat <<EOF

  小鲸鱼在跑了。Ctrl+C 下线（只停桥；容器和 QQ 继续跑）

  接下来：
    QQ         用你的号给 $(node -p "require('$BRIDGE/config.json').access.owner" 2>/dev/null || echo '小号') 发消息
    登录 QQ    http://localhost:6081（noVNC）
    管理        http://localhost:5099（SnowLuma WebUI）
    看状态     ./status.sh（另开一个终端）
    全关       ./stop.sh --all

EOF

wait "$BRIDGE_PID"
printf '\n  qq-bridge 已退出（code %s）\n' "$?"
