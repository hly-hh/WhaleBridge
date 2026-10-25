#!/usr/bin/env bash
# 不登 QQ 的端到端自测：假 SnowLuma + 假大脑。
# 会临时改 config.json，结束后自动还原。
set -uo pipefail
cd "$(dirname "$0")/.."

cp config.json /tmp/qq-bridge-config.bak
[ -f data/sessions.json ] && cp data/sessions.json /tmp/qq-bridge-sessions.bak && HAD_SESSIONS=1 || HAD_SESSIONS=0
cleanup() {
    [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null
    cp /tmp/qq-bridge-config.bak config.json
    if [ "${HAD_SESSIONS:-0}" = "1" ]; then cp /tmp/qq-bridge-sessions.bak data/sessions.json; else rm -f data/sessions.json; fi
}
trap cleanup EXIT

python3 - <<'EOF'
import json
c = json.load(open('config.json'))
c['snowluma'] = {'mode': 'manual', 'host': '127.0.0.1', 'port': 3999, 'accessToken': 'test-token'}
c['dsh'] = {'command': __import__('os').getcwd() + '/tests/fake-dsh.sh', 'profile': 'qq', 'timeoutMs': 20000, 'workspace': './data/workspace'}
c['access'] = {'owner': 10001, 'privateAllow': [], 'groupAllow': ['20001'], 'groupRequireAt': True, 'ownerAlwaysReply': True}
c['reply'] = {'minIntervalMs': 200, 'typingPerCharMs': 2, 'typingMaxMs': 50, 'maxChars': 1200}
json.dump(c, open('config.json', 'w'), indent=2)
EOF

chmod +x tests/fake-dsh.sh
rm -f /tmp/fake-dsh-calls.log data/sessions.json

FAKE_TOKEN=test-token node tests/fake-snowluma.js 3999 > /tmp/qq-bridge-fake.log 2>&1 &
FAKE_PID=$!
sleep 1
timeout 14 node src/index.js > /tmp/qq-bridge-run1.log 2>&1

echo "===== 第一轮（新会话）====="
cat /tmp/qq-bridge-run1.log
echo "===== 假服务端看到的事 ====="
cat /tmp/qq-bridge-fake.log
echo
if grep -q '"text":"嗯，在。"' /tmp/qq-bridge-fake.log; then
    echo "✅ 发出去的是她的话"
else
    echo "❌ 发出去的不是她的话（很可能是把用户原话回显了）"
    exit 1
fi
if grep -q '"text":"在吗"' /tmp/qq-bridge-fake.log || grep -q '"text":"你在干嘛"' /tmp/qq-bridge-fake.log; then
    echo "❌ 把用户的原话发回去了"
    exit 1
else
    echo "✅ 没有回显用户原话"
fi
echo "===== session 映射 ====="
cat data/sessions.json 2>/dev/null

sleep 1
timeout 14 node src/index.js > /tmp/qq-bridge-run2.log 2>&1
echo "===== 第二轮（应该带 --session-id）====="
cat /tmp/qq-bridge-run2.log
echo "===== dsh 收到的参数 ====="
cat /tmp/fake-dsh-calls.log 2>/dev/null
