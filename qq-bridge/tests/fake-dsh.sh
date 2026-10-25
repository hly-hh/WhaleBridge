#!/usr/bin/env bash
# 假的大脑：模仿 `dsh --profile qq headless --json` 的输出，用来测 bridge。
# 会把收到的参数记到 /tmp/fake-dsh-calls.log
echo "ARGS: $*" >> /tmp/fake-dsh-calls.log
case "$*" in
    *"你叫什么"*) TEXT="我叫小鲸鱼。你呢。" ;;
    *"你在干嘛"*) TEXT="发呆。你找我干嘛。" ;;
    *) TEXT="嗯，在。" ;;
esac
echo '{"type":"session","sessionId":"session-fake-0001"}'
echo '{"type":"status","phase":"turn_start","turn":1}'
echo "{\"type\":\"final\",\"text\":\"$TEXT\"}"
