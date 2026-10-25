/**
 * 极简 OneBot v11 正向 WebSocket 客户端。
 * 只用 Node 自带的 WebSocket，不装任何依赖。
 */

export class OneBot {
    constructor(url, { onEvent, onOpen, log }) {
        this.url = url;
        this.onEvent = onEvent;
        this.onOpen = onOpen;
        this.log = log;
        this.ws = null;
        this.echo = 0;
        this.pending = new Map();
        this.retry = 0;
        this.closed = false;
        this.selfId = null;
    }

    connect() {
        if (this.closed) return;
        this.log.info(`连接 SnowLuma：${this.url.replace(/access_token=[^&]+/, 'access_token=***')}`);
        const ws = new WebSocket(this.url);
        this.ws = ws;

        ws.addEventListener('open', () => {
            this.retry = 0;
            this.log.info('已连上 SnowLuma，等消息中');
            this.onOpen?.();
        });

        ws.addEventListener('message', (ev) => {
            let payload;
            try {
                payload = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data));
            } catch {
                return;
            }
            this._handle(payload);
        });

        ws.addEventListener('close', () => {
            this._failAll('连接断开');
            if (this.closed) return;
            this.retry += 1;
            const delay = Math.min(30000, 2000 * 2 ** Math.min(this.retry, 4));
            this.log.warn(`${Math.round(delay / 1000)} 秒后重连（QQ 掉线或 SnowLuma 没起时会一直重试）`);
            setTimeout(() => this.connect(), delay);
        });

        ws.addEventListener('error', () => {
            /* close 事件会跟着来，这里不刷屏 */
        });
    }

    _handle(payload) {
        if (payload && typeof payload.echo === 'string' && this.pending.has(payload.echo)) {
            const { resolve } = this.pending.get(payload.echo);
            this.pending.delete(payload.echo);
            resolve(payload);
            return;
        }
        if (payload?.post_type === 'meta_event') {
            if (payload.meta_event_type === 'lifecycle' && payload.self_id) {
                this.selfId = String(payload.self_id);
                this.log.info(`账号 ${this.selfId} 已就绪`);
            }
            return;
        }
        if (payload?.self_id) this.selfId = String(payload.self_id);
        this.onEvent?.(payload);
    }

    _failAll(reason) {
        for (const { reject } of this.pending.values()) reject(new Error(reason));
        this.pending.clear();
    }

    /** 调 OneBot 动作，超时/失败都抛错，调用方自己决定要不要说话。 */
    call(action, params = {}, timeoutMs = 15000) {
        return new Promise((resolve, reject) => {
            if (!this.ws || this.ws.readyState !== 1) {
                reject(new Error('还没连上 SnowLuma'));
                return;
            }
            const echo = `qb-${++this.echo}`;
            const timer = setTimeout(() => {
                this.pending.delete(echo);
                reject(new Error(`${action} 超时`));
            }, timeoutMs);
            this.pending.set(echo, {
                resolve: (res) => {
                    clearTimeout(timer);
                    if (res.status === 'failed' || (res.retcode !== undefined && res.retcode !== 0)) {
                        reject(new Error(`${action} 失败：${res.message ?? res.wording ?? res.retcode}`));
                    } else {
                        resolve(res.data ?? res);
                    }
                },
                reject: (err) => {
                    clearTimeout(timer);
                    reject(err);
                },
            });
            this.ws.send(JSON.stringify({ action, params, echo }));
        });
    }

    sendPrivate(userId, text) {
        return this.call('send_private_msg', { user_id: Number(userId), message: [{ type: 'text', data: { text } }] });
    }

    sendGroup(groupId, text) {
        return this.call('send_group_msg', { group_id: Number(groupId), message: [{ type: 'text', data: { text } }] });
    }

    close() {
        this.closed = true;
        try {
            this.ws?.close();
        } catch {
            /* ignore */
        }
        this._failAll('已关闭');
    }
}
