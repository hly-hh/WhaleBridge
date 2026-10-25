#!/usr/bin/env bash
# 把角色卡装进 DSH：复制一个 headless profile，改名 qq，再把人设写进 patch 层。
# 用法：bash setup-profile.sh [profile 名] [角色卡路径]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:-qq}"
ROLE="${2:-$ROOT/roles/小鲸鱼.md}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
SRC="$DSH_HOME/profiles/headless"
DST="$DSH_HOME/profiles/$NAME"

[ -f "$ROLE" ] || { echo "找不到角色卡：$ROLE" >&2; exit 1; }
[ -d "$SRC" ] || { echo "找不到 DSH 的 headless profile：$SRC" >&2; exit 1; }

if grep -q '{{' "$ROLE"; then
    echo "角色卡里有 {{…}}，DSH 会把它当提示词变量严格解析并报错。删掉它们再试。" >&2
    exit 1
fi

if [ -d "$DST" ]; then
    echo "profile '$NAME' 已存在，只更新人设（不动其他设置）"
else
    cp -r "$SRC" "$DST"
    sed -i "s/dsh-profile-headless/dsh-profile-$NAME/" "$DST/package.json"
    echo "已从 headless 复制出 profile '$NAME'"
fi

# 人设缩进 6 格，塞进 system-prompt 这一行的 config 里
{
    echo "# 由 qq-bridge 的 setup-profile.sh 生成：人设来自 $(basename "$ROLE")"
    echo "- id: system-prompt"
    echo "  config:"
    echo "    includeHarnessIdentity: false"
    echo "    personaPrefix: |"
    sed -e 's/^/      /' -e 's/[[:space:]]*$//' "$ROLE"
    echo '    personaSuffix: ""'
} > "$DST/cordis.patch.yml"

echo "人设已写入 $DST/cordis.patch.yml"
echo
echo "验证一下（不会调用模型）："
echo "  dsh --profile $NAME --dump-config | grep -A5 personaPrefix"
