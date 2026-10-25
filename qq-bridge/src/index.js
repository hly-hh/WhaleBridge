import process from 'node:process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig, resolveSnowluma } from './config.js';
import { OneBot } from './onebot.js';
import { Brain } from './dsh.js';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const LEVEL_TAG = { info: '信息', warn: '注意', error: '错误' };
function makeLog() {
    const stamp = () => new Date().toTimeString().slice(0, 8);
    const emit = (level) => (...args) => console.log(`${stamp()} ${LEVEL_TAG[level]}`, ...args);
    return { info: emit('info'), warn: emit('warn'), error: emit('error') };
}

/** 从 OneBot 消息段里抠出文字，顺带记住有没有 @ 她。 */
function readMessage(segments, selfId) {
    const parts = [];
    let atMe = false;
    for (const seg of Array.isArray(segments) ? segments : []) {
        if (seg?.type === 'text') parts.push(String(seg.data?.text ?? ''));
        else if (seg?.type === 'at') {
            const qq = String(seg.data?.qq ?? '');
            if (qq === String(selfId)) atMe = true;
        } else if (seg?.type === 'image') parts.push('[图片]');
        else if (seg?.type === 'face') parts.push('[表情]');
        else if (seg?.type === 'record') parts.push('[语音]');
    }
    return { text: parts.join('').trim(), atMe };
}

/** QQ 不是网页：去掉 Markdown，别让她发一篇小作文。 */
function cleanReply(raw, maxChars) {
    let text = String(raw ?? '')
        .replace(/```[\s\S]*?```/g, (m) => m.replace(/```[a-z]*\n?/gi, '').trim())
        .replace(/^#{1,6}\s*/gm, '')
        .replace(/\*\*(.+?)\*\*/g, '$1')
        .replace(/__(.+?)__/g, '$1')
        .replace(/`([^`]+)`/g, '$1')
        .replace(/^\s*[-*+]\s+/gm, '')
        .replace(/\n{3,}/g, '\n\n')
        .trim();
    if (text.length > maxChars) {
        const cut = text.slice(0, maxChars);
        const stop = Math.max(cut.lastIndexOf('。'), cut.lastIndexOf('！'), cut.lastIndexOf('？'), cut.lastIndexOf('\n'));
        text = stop > maxChars * 0.5 ? cut.slice(0, stop + 1) : `${cut}…`;
    }
    return text.trim();
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const DEBUG = process.env.QQ_BRIDGE_DEBUG === '1';
const clip = (s, n = 40) => (String(s).length > n ? `${String(s).slice(0, n)}…` : String(s));

async function main() {
    const log = makeLog();
    const dryIdx = process.argv.indexOf('--dry');

    let cfg;
    try {
        cfg = loadConfig(ROOT);
    } catch (err) {
        log.error(err.message);
        process.exit(1);
    }

    const brain = new Brain(cfg.dsh, { log, root: ROOT });

    // 只测大脑，不连 QQ：node src/index.js --dry 你好
    if (dryIdx >= 0) {
        const text = process.argv.slice(dryIdx + 1).join(' ') || '在吗';
        try {
            const reply = await brain.ask('dry-run', text);
            console.log('\n--- 小鲸鱼 ---\n' + reply + '\n');
        } catch (err) {
            log.error(err.message);
            process.exit(1);
        }
        return;
    }

    // 只探活：确认 SnowLuma 的 WS 通不通、QQ 登没登录
    if (process.argv.includes('--probe')) {
        let snow;
        try {
            snow = resolveSnowluma(cfg, log);
        } catch (err) {
            log.error(err.message);
            process.exit(1);
        }
        const bot = new OneBot(snow.wsUrl, {
            log,
            onOpen: async () => {
                try {
                    const me = await bot.call('get_login_info');
                    log.info(`QQ 在线：${me.nickname}（${me.user_id}）`);
                    const status = await bot.call('get_status').catch(() => null);
                    if (status) log.info(`状态：${JSON.stringify(status)}`);
                    process.exit(0);
                } catch (err) {
                    log.error(`连上了但拿不到账号信息：${err.message}`);
                    process.exit(1);
                }
            },
            onEvent: () => {},
        });
        bot.connect();
        setTimeout(() => {
            log.error('3 秒内连不上 SnowLuma（QQ 没登录 / 端口不对 / token 变了）');
            process.exit(1);
        }, 3000);
        return;
    }

    const access = cfg.access;
    if (!Number(access.owner)) {
        log.error('config.json 里 access.owner 还是 0，先填上你自己的 QQ 号。');
        process.exit(1);
    }

    let snow;
    try {
        snow = resolveSnowluma(cfg, log);
        log.info(cfg.snowluma.mode === 'auto' ? '已从容器里读到 OneBot 配置（端口和 token 不用手填）' : '使用 config.json 里手填的 OneBot 配置');
    } catch (err) {
        log.error(err.message);
        process.exit(1);
    }

    const lastSent = new Map();
    const inFlight = new Map();
    const seenIds = new Set();
    const seenOrder = [];
    const alreadySeen = (id) => {
        if (id === undefined || id === null) return false;
        const key = String(id);
        if (seenIds.has(key)) return true;
        seenIds.add(key);
        seenOrder.push(key);
        if (seenOrder.length > 200) seenIds.delete(seenOrder.shift());
        return false;
    };

    const bot = new OneBot(snow.wsUrl, {
        log,
        onEvent: (ev) => {
            if (DEBUG) {
                log.info(
                    `[收到] ${ev?.post_type}/${ev?.message_type ?? '-'} id=${ev?.message_id ?? '-'} ` +
                        `from=${ev?.user_id ?? '-'} group=${ev?.group_id ?? '-'} ` +
                        `time=${ev?.time ?? '-'} ${clip(JSON.stringify(ev?.message ?? ''))}`
                );
            }
            handle(ev).catch((err) => log.error('处理消息出错：', err.message));
        },
    });

    async function handle(ev) {
        if (!ev || ev.post_type !== 'message') return;
        if (ev.self_id && bot.selfId !== String(ev.self_id)) bot.selfId = String(ev.self_id);

        const userId = String(ev.user_id ?? '');
        if (!userId || userId === String(bot.selfId)) return;
        if (alreadySeen(ev.message_id)) {
            log.warn(`重复推送 message_id=${ev.message_id}，忽略`);
            return;
        }

        const { text, atMe } = readMessage(ev.message, bot.selfId);
        if (!text) return;

        const isOwner = userId === String(access.owner);
        const isGroup = ev.message_type === 'group';
        let convKey;
        let reply;

        if (isGroup) {
            const groupId = String(ev.group_id ?? '');
            if (!access.groupAllow.map(String).includes(groupId)) return;
            if (access.groupRequireAt && !atMe && !(isOwner && access.ownerAlwaysReply)) return;
            convKey = `group-${groupId}`;
            reply = (out) => bot.sendGroup(groupId, out);
        } else {
            if (!isOwner && !access.privateAllow.map(String).includes(userId)) return;
            convKey = `private-${userId}`;
            reply = (out) => bot.sendPrivate(userId, out);
        }

        // 同一个会话同时只跑一条，堆两条就丢，防止刷屏把模型打爆
        if ((inFlight.get(convKey) ?? 0) >= 1) {
            log.warn(`[${convKey}] 上一条还没回完，这条先不接`);
            return;
        }
        inFlight.set(convKey, 1);

        try {
            const answer = cleanReply(await brain.ask(convKey, text), cfg.reply.maxChars);
            if (!answer) return;

            const idle = cfg.reply.minIntervalMs - (Date.now() - (lastSent.get(convKey) ?? 0));
            if (idle > 0) await sleep(idle);

            const typing = Math.min(cfg.reply.typingMaxMs, answer.length * cfg.reply.typingPerCharMs);
            if (typing > 0) await sleep(typing);

            await reply(answer);
            if (DEBUG) log.info(`[发出] ${clip(answer)}`);
            lastSent.set(convKey, Date.now());
        } catch (err) {
            // 出错就安静地记一笔，绝不把用户的原话当回复发回去
            log.error(`[${convKey}] 回不了：${err.message}`);
        } finally {
            inFlight.delete(convKey);
        }
    }

    bot.connect();
    log.info('小鲸鱼已起航（Ctrl+C 下线）');

    for (const sig of ['SIGINT', 'SIGTERM']) {
        process.on(sig, () => {
            log.info('收工，下线');
            bot.close();
            process.exit(0);
        });
    }
}

main();
