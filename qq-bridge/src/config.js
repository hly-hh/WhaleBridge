import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const DEFAULTS = {
    snowluma: {
        mode: 'auto',
        container: 'snowluma',
        configPath: '/app/data/config/onebot.json',
        host: '127.0.0.1',
        port: 3001,
        accessToken: '',
    },
    dsh: {
        command: 'dsh',
        profile: 'qq',
        timeoutMs: 180000,
        workspace: './data/workspace',
    },
    access: {
        owner: 0,
        privateAllow: [],
        groupAllow: [],
        groupRequireAt: true,
        ownerAlwaysReply: true,
    },
    reply: {
        minIntervalMs: 1500,
        typingPerCharMs: 35,
        typingMaxMs: 4000,
        maxChars: 1200,
    },
};

function deepMerge(base, extra) {
    if (!extra || typeof extra !== 'object' || Array.isArray(extra)) return extra ?? base;
    const out = Array.isArray(base) ? [...base] : { ...base };
    for (const [k, v] of Object.entries(extra)) {
        out[k] = v && typeof v === 'object' && !Array.isArray(v) && base?.[k] && typeof base[k] === 'object'
            ? deepMerge(base[k], v)
            : v;
    }
    return out;
}

/** 读 config.json；不存在就写一份出来再退出，避免用户对着空目录发呆。 */
export function loadConfig(root) {
    const file = path.join(root, 'config.json');
    if (!fs.existsSync(file)) {
        const example = path.join(root, 'config.example.json');
        fs.copyFileSync(example, file);
        throw new Error(`已生成 ${file}\n请先填 access.owner（你的 QQ 号），再重新启动。`);
    }
    const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
    const cfg = deepMerge(DEFAULTS, raw);
    cfg.dsh.workspace = path.resolve(root, cfg.dsh.workspace);
    fs.mkdirSync(cfg.dsh.workspace, { recursive: true });
    return cfg;
}

/** 把 0.0.0.0 之类改成能连的地址。 */
function dialHost(host) {
    if (!host || host === '0.0.0.0' || host === '::' || host === '[::]') return '127.0.0.1';
    return host;
}

/**
 * 拿到 SnowLuma 的 OneBot 连接参数。
 * auto 模式直接从容器里读 onebot.json，用户不用手抄 token。
 */
export function resolveSnowluma(cfg, log) {
    const s = cfg.snowluma;

    if (s.mode === 'manual') {
        if (!s.accessToken) throw new Error('snowluma.mode = manual 时必须填 accessToken');
        return { wsUrl: buildUrl(dialHost(s.host), s.port, s.accessToken) };
    }

    const containers = [s.container, `${s.container}-1`].filter(Boolean);
    let lastErr = null;
    for (const name of containers) {
        try {
            const out = execFileSync('docker', ['exec', name, 'cat', s.configPath], {
                encoding: 'utf8',
                stdio: ['ignore', 'pipe', 'pipe'],
            });
            const parsed = readOneBotConfig(out, log);
            if (parsed) return parsed;
        } catch (err) {
            lastErr = err;
        }
    }

    // 退路：容器配置被挂到本地某个目录，或者用户直接把 onebot.json 拷过来了
    const localCandidates = [path.resolve(process.cwd(), 'onebot.json')];
    for (const f of localCandidates) {
        if (fs.existsSync(f)) {
            const parsed = readOneBotConfig(fs.readFileSync(f, 'utf8'), log);
            if (parsed) return parsed;
        }
    }

    const hint = lastErr?.stderr?.toString().trim() || lastErr?.message || '未知错误';
    throw new Error(
        `读不到 SnowLuma 配置（容器 ${s.container}:${s.configPath}）。\n` +
            `docker 说：${hint}\n` +
            `容器还没起来？或者 QQ 还没登录？也可以把 snowluma.mode 改成 manual 手填端口和 token。`
    );
}

function readOneBotConfig(text, log) {
    const cfg = JSON.parse(text);
    const servers = cfg?.networks?.wsServers ?? [];
    const server = servers.find((x) => x.accessToken) ?? servers[0];
    if (!server) return null;
    if (server.messageFormat && server.messageFormat !== 'array') {
        log?.warn(`OneBot messageFormat = ${server.messageFormat}，bridge 按 array 解析，字符串格式可能丢 at。`);
    }
    return {
        wsUrl: buildUrl(dialHost(server.host), server.port ?? 3001, server.accessToken ?? '', server.path),
    };
}

function buildUrl(host, port, token, urlPath = '/') {
    const p = urlPath && urlPath !== '' ? urlPath : '/';
    const u = new URL(`ws://${host}:${port}${p.startsWith('/') ? p : `/${p}`}`);
    if (token) u.searchParams.set('access_token', token);
    return u.toString();
}
