import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

/**
 * 大脑：每次说话起一个 dsh headless 进程。
 * 记忆靠 --session-id 续接，session 存在 ~/.dsh/sessions，
 * 所以同一段对话在 `dsh web` 里也能翻到。
 */
export class Brain {
    constructor(cfg, { log, root }) {
        this.cfg = cfg;
        this.log = log;
        this.stateFile = path.join(root, 'data', 'sessions.json');
        this.sessions = this._load();
        this.queues = new Map();
    }

    _load() {
        try {
            return JSON.parse(fs.readFileSync(this.stateFile, 'utf8'));
        } catch {
            return {};
        }
    }

    _save() {
        fs.mkdirSync(path.dirname(this.stateFile), { recursive: true });
        const tmp = `${this.stateFile}.tmp`;
        fs.writeFileSync(tmp, JSON.stringify(this.sessions, null, 2));
        fs.renameSync(tmp, this.stateFile);
    }

    /** 同一个会话串行跑，避免两条消息同时往一个 session 里塞。 */
    ask(convKey, text) {
        const prev = this.queues.get(convKey) ?? Promise.resolve();
        const next = prev.catch(() => {}).then(() => this._askOnce(convKey, text));
        this.queues.set(convKey, next.catch(() => {}));
        return next;
    }

    async _askOnce(convKey, text, isRetry = false) {
        const sessionId = this.sessions[convKey];
        const args = ['--profile', this.cfg.profile, 'headless', '--json'];
        if (sessionId) args.push('--session-id', sessionId);
        args.push(text);

        this.log.info(`[${convKey}] → dsh${sessionId ? ` (${sessionId.slice(0, 16)}…)` : ' (新会话)'}`);
        const started = Date.now();
        const res = await this._run(args);
        this.log.info(`[${convKey}] ← ${Date.now() - started}ms${res.text ? ` ${res.text.length} 字` : '（空）'}`);

        // 只在这轮真的说成话了才记 session，别把失败的空壳存下来
        if (res.text && res.sessionId && res.sessionId !== sessionId) {
            this.sessions[convKey] = res.sessionId;
            this._save();
        }

        // session 被删了/换了机器：丢掉映射，重开一段，只重试一次
        if (!res.text && /does not exist/i.test(res.fatal ?? '') && !isRetry) {
            this.log.warn(`[${convKey}] 旧 session 已经不存在，重开一段`);
            delete this.sessions[convKey];
            this._save();
            return this._askOnce(convKey, text, true);
        }

        if (!res.text) {
            const detail = res.fatal || res.error?.message || res.stderr?.trim() || 'DSH 没有返回内容';
            throw new Error(detail);
        }
        return res.text;
    }

    _run(args) {
        return new Promise((resolve) => {
            const child = spawn(this.cfg.command, args, {
                cwd: this.cfg.workspace,
                env: process.env,
                stdio: ['ignore', 'pipe', 'pipe'],
            });

            let sessionId = null;
            let finalText = '';
            let runError = null;
            let fatal = null;
            let stderr = '';
            let buf = '';
            let done = false;

            const finish = (extra = {}) => {
                if (done) return;
                done = true;
                clearTimeout(timer);
                resolve({ sessionId, text: finalText, error: runError, fatal, stderr, ...extra });
            };

            const timer = setTimeout(() => {
                this.log.warn(`dsh 超过 ${this.cfg.timeoutMs}ms 没说完，掐掉`);
                child.kill('SIGTERM');
                setTimeout(() => child.kill('SIGKILL'), 3000);
                finish({ error: { kind: 'timeout', message: `超过 ${this.cfg.timeoutMs}ms 未完成` } });
            }, this.cfg.timeoutMs);

            child.stdout.on('data', (chunk) => {
                buf += chunk.toString('utf8');
                let idx;
                while ((idx = buf.indexOf('\n')) >= 0) {
                    const line = buf.slice(0, idx).trim();
                    buf = buf.slice(idx + 1);
                    if (!line) continue;
                    let ev;
                    try {
                        ev = JSON.parse(line);
                    } catch {
                        continue;
                    }
                    if (ev.type === 'session' && ev.sessionId) sessionId = ev.sessionId;
                    else if (ev.type === 'final') finalText = String(ev.text ?? '').trim();
                    else if (ev.type === 'error') fatal = String(ev.message ?? 'DSH 报错');
                    else if (ev.type === 'status' && ev.reason?.kind === 'error' && ev.reason.error) {
                        runError = ev.reason.error;
                    }
                }
            });

            child.stderr.on('data', (chunk) => {
                stderr += chunk.toString('utf8');
            });

            child.on('error', (err) => {
                finish({ error: { kind: 'spawn', message: `起不了 ${this.cfg.command}：${err.message}` } });
            });

            child.on('close', () => finish());
        });
    }
}
