#!/usr/bin/env bash
# 一键重启：先停桥，再起。
#   ./restart.sh          只重启 qq-bridge
#   ./restart.sh --web    重启桥，并确保 dsh web 也在（端口 8080）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGS=()

for arg in "$@"; do
    case "$arg" in
        -h | --help)
            sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --all)
            echo "restart.sh 不支持 --all；要全量重建请：./stop.sh --all && ./start.sh --web" >&2
            exit 1
            ;;
        *) ARGS+=("$arg") ;;
    esac
done

"$ROOT/stop.sh"
exec "$ROOT/start.sh" ${ARGS[@]+"${ARGS[@]}"}
