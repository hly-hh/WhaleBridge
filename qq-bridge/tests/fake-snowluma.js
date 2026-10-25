/**
 * 假的 SnowLuma：一个只实现必要部分的 OneBot WebSocket 服务端。
 * 用来在没登 QQ 的时候测 bridge 的逻辑。
 *   node tests/fake-snowluma.js [端口]
 * 它会依次发：上线事件 → 私聊(owner) → 群里没 @ → 群里 @ 了。
 */
import http from 'node:http';
import crypto from 'node:crypto';

const PORT = Number(process.argv[2] ?? 3999);
const TOKEN = process.env.FAKE_TOKEN ?? '';
const SELF = 10000;
const OWNER = Number(process.env.FAKE_OWNER ?? 10001);
const GROUP = Number(process.env.FAKE_GROUP ?? 20001);
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function frame(text) {
    const payload = Buffer.from(text, 'utf8');
    const len = payload.length;
    let head;
    if (len < 126) head = Buffer.from([0x81, len]);
    else if (len < 65536) {
        head = Buffer.alloc(4);
        head[0] = 0x81;
        head[1] = 126;
        head.writeUInt16BE(len, 2);
    } else {
        head = Buffer.alloc(10);
        head[0] = 0x81;
        head[1] = 127;
        head.writeBigUInt64BE(BigInt(len), 2);
    }
    return Buffer.concat([head, payload]);
}

function decode(buf) {
    if (buf.length < 2) return null;
    const opcode = buf[0] & 0x0f;
    const masked = (buf[1] & 0x80) !== 0;
    let len = buf[1] & 0x7f;
    let off = 2;
    if (len === 126) {
        if (buf.length < 4) return null;
        len = buf.readUInt16BE(2);
        off = 4;
    } else if (len === 127) {
        if (buf.length < 10) return null;
        len = Number(buf.readBigUInt64BE(2));
        off = 10;
    }
    const need = off + (masked ? 4 : 0) + len;
    if (buf.length < need) return null;
    const mask = masked ? buf.subarray(off, off + 4) : null;
    off += masked ? 4 : 0;
    const data = Buffer.from(buf.subarray(off, off + len));
    if (mask) for (let i = 0; i < data.length; i++) data[i] ^= mask[i % 4];
    return { opcode, data, size: need };
}

const server = http.createServer((req, res) => {
    res.writeHead(426).end('WebSocket only');
});

server.on('upgrade', (req, socket) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (TOKEN && url.searchParams.get('access_token') !== TOKEN) {
        socket.end('HTTP/1.1 401 Unauthorized\r\n\r\n');
        return;
    }
    const key = req.headers['sec-websocket-key'];
    const accept = crypto.createHash('sha1').update(key + GUID).digest('base64');
    socket.write(
        'HTTP/1.1 101 Switching Protocols\r\n' +
            'Upgrade: websocket\r\n' +
            'Connection: Upgrade\r\n' +
            `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
    );

    const send = (obj) => socket.write(frame(JSON.stringify(obj)));
    let buf = Buffer.alloc(0);

    socket.on('data', (chunk) => {
        buf = Buffer.concat([buf, chunk]);
        let f;
        while ((f = decode(buf))) {
            buf = buf.subarray(f.size);
            if (f.opcode === 8) {
                socket.end();
                return;
            }
            if (f.opcode !== 1) continue;
            let msg;
            try {
                msg = JSON.parse(f.data.toString('utf8'));
            } catch {
                continue;
            }
            if (msg.action) {
                console.log(`[fake] 收到动作 ${msg.action} ${JSON.stringify(msg.params)}`);
                send({ status: 'ok', retcode: 0, data: { message_id: 42 }, echo: msg.echo });
            }
        }
    });

    socket.on('error', () => {});

    send({ post_type: 'meta_event', meta_event_type: 'lifecycle', sub_type: 'connect', self_id: SELF, time: 1 });

    const msg = (extra) => ({
        post_type: 'message',
        time: Math.floor(Date.now() / 1000),
        self_id: SELF,
        font: 0,
        message_id: Math.floor(Math.random() * 1000),
        ...extra,
    });

    setTimeout(() => {
        console.log('[fake] 发：私聊 owner');
        send(msg({ message_type: 'private', sub_type: 'friend', user_id: OWNER, message: [{ type: 'text', data: { text: '在吗' } }], raw_message: '在吗' }));
    }, 600);

    setTimeout(() => {
        console.log('[fake] 发：群里没 @（应该被忽略）');
        send(msg({ message_type: 'group', sub_type: 'normal', group_id: GROUP, user_id: 33333, message: [{ type: 'text', data: { text: '今天吃啥' } }], raw_message: '今天吃啥' }));
    }, 8000);

    setTimeout(() => {
        console.log('[fake] 发：群里 @ 了（应该回）');
        send(
            msg({
                message_type: 'group',
                sub_type: 'normal',
                group_id: GROUP,
                user_id: 33333,
                message: [
                    { type: 'at', data: { qq: String(SELF) } },
                    { type: 'text', data: { text: ' 你在干嘛' } },
                ],
                raw_message: `[CQ:at,qq=${SELF}] 你在干嘛`,
            })
        );
    }, 10000);
});

server.listen(PORT, '127.0.0.1', () => {
    console.log(`[fake] 假 SnowLuma 在 ws://127.0.0.1:${PORT}/ （token ${TOKEN || '无'}）`);
});
