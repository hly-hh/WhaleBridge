# 小鲸鱼 · QQ × DeepSeek Harness

把 QQ 消息接到 [DeepSeek Harness](https://github.com/deepseek-ai/dsh)（下称 DSH）上，让她用一个固定人设在 QQ 里跟你聊天。

整条链路都跑在 WSL / Linux 里，Windows 只负责开浏览器看页面：

```
┌──────────────────────────────────────────────────────────────┐
│  Docker: snowluma                                            │
│  ├─ Linux QQ（noVNC 里扫码登录）                              │
│  ├─ WebUI        http://localhost:5099                       │
│  └─ OneBot v11   ws://127.0.0.1:3001                         │
└───────────────────────────┬──────────────────────────────────┘
                            │ WebSocket + access_token
┌───────────────────────────▼──────────────────────────────────┐
│  qq-bridge（本项目，零依赖 Node 脚本）                         │
│  ├─ 准入：owner / 私聊白名单 / 群白名单 / 群里是否必须 @       │
│  ├─ 节奏：同会话串行、最小间隔、模拟打字、超长截断             │
│  ├─ 清洗：去掉 Markdown，只发适合 QQ 的短句                    │
│  └─ 每个 QQ 会话 ↔ 一个 DSH session（记忆）                    │
└───────────────────────────┬──────────────────────────────────┘
                            │ dsh --profile qq headless --json
┌───────────────────────────▼──────────────────────────────────┐
│  DeepSeek Harness（本机 ~/.dsh）                              │
│  └─ profile `qq`：人设来自 roles/小鲸鱼.md                     │
└───────────────────────────┬──────────────────────────────────┘
                            ▼
                    DeepSeek API / 其他模型
```

## 目录速览

```
qq_dep/
├── start.sh              # 一键启动
├── stop.sh               # 一键关闭
├── restart.sh            # 一键重启
├── status.sh             # 全链路状态
├── package.json          # npm run start / stop / ...
├── README.md             # 本文件
├── docs/
│   └── PROJECT_STRUCTURE.md   # 项目结构、数据流、运行时状态
├── qq-bridge/            # 桥：收 QQ 消息 → 问 DSH → 回 QQ
│   ├── src/              # index / onebot / dsh / config
│   ├── roles/小鲸鱼.md    # 人设
│   ├── tests/            # 假 SnowLuma + 假大脑的 e2e
│   ├── setup-profile.sh  # 把人设装进 DSH profile
│   ├── config.example.json
│   └── data/             # 运行时：PID、日志、session 映射（不进 git）
└── SnowLuma/             # 上游 SnowLuma v2.2.0 源码（独立 git clone，不进本仓库）
```

更细的模块职责、数据流和端口说明见 [`docs/PROJECT_STRUCTURE.md`](docs/PROJECT_STRUCTURE.md)。

## 环境要求

| 依赖 | 要求 | 说明 |
| --- | --- | --- |
| Node.js | ≥ 22（当前用 v24） | bridge 只用内置模块，无需 `npm install` |
| Docker | 能 `docker exec` | 跑 SnowLuma 容器 |
| DeepSeek Harness | 已安装 `dsh` | 已登录/配置 API key，`~/.dsh` 可写 |
| bash | 4+ | 跑脚本 |
| python3 | 仅测试需要 | `tests/e2e.sh` 改配置用 |

## 第一次跑

### 1. 起 SnowLuma 容器

```bash
docker run -d --name snowluma \
  --restart unless-stopped \
  -p 3000:3000 -p 3001:3001 \
  -p 5099:5099 -p 6081:6081 \
  -v qq-gateway-data:/app/data \
  -v qq-client-config:/app/.config \
  -v qq-client-data:/app/.local/share \
  -e TZ=Asia/Shanghai \
  motricseven7/snowluma:latest
```

已存在同名容器就跳过。容器名不是 `snowluma` 也没关系，后面用环境变量 `SNOWLUMA_CONTAINER` 或 `config.json` 里 `snowluma.container` 指定。

### 2. 登录 QQ

1. 浏览器打开 `http://localhost:5099`，同意 EULA、设置 WebUI 密码。
2. 浏览器打开 `http://localhost:6081`（noVNC），输入 VNC 密码，在 Linux QQ 里扫码登录**小号**。
3. 日志里出现 `[Hook] pipe connected` / 账号就绪，说明 QQ 这层通了。

> OneBot 的 HTTP/WS 服务是 QQ 登录成功后才真正可用的。

### 3. 配 OneBot

在 SnowLuma WebUI 里加一个 **WebSocket 服务端**（正向 WS），端口 `3001`，设置 `access_token`。

`qq-bridge` 默认 `snowluma.mode = "auto"`，启动时会自己执行：

```bash
docker exec snowluma cat /app/data/config/onebot.json
```

读出端口和 token，所以**不需要手抄 token**。改过 token 只要重启桥。

### 4. 装人设

```bash
cd qq-bridge
bash setup-profile.sh
```

脚本会从 DSH 的 `headless` profile 复制出 `qq`，把 `roles/小鲸鱼.md` 写进 `system-prompt.personaPrefix`，并关闭 `includeHarnessIdentity`。

验证（不调用模型）：

```bash
dsh --profile qq --dump-config | grep -A5 personaPrefix
```

### 5. 填自己的 QQ 号

```bash
cp qq-bridge/config.example.json qq-bridge/config.json   # start.sh 也会自动生成
```

编辑 `qq-bridge/config.json`：

```jsonc
{
  "access": {
    "owner": 123456789,     // 必填：你自己的 QQ 号
    "privateAllow": [],     // 还允许谁私聊她；留空 = 都不理
    "groupAllow": [],       // 允许她在哪些群说话；留空 = 都不理
    "groupRequireAt": true, // 群里必须 @ 她
    "ownerAlwaysReply": true
  }
}
```

## 日常使用

```bash
./start.sh              # 前台起容器 + 桥，日志直接打在终端
./start.sh --web        # 顺便起 dsh web（http://localhost:8080）
./start.sh --restart    # 先停旧桥，再前台起
./stop.sh               # 只停 qq-bridge，QQ 还挂在容器里
./stop.sh --all         # 连 dsh web 和容器一起停
./restart.sh            # = stop.sh + start.sh（前台）
./status.sh             # 容器 / QQ / 桥 / dsh web / 最近日志
```

`start.sh` 会一直占着终端：**Ctrl+C 自动停桥并清理 pid**（`--web` 起的 dsh web 也一起停）；容器和 QQ 不动，下次启动不用重新扫码。

`start.sh` 和 `status.sh` 会直接打印网页入口（QQ 登录用的 noVNC、SnowLuma 管理页，以及当前容器的 VNC 密码）；QQ 没登录时会额外给出扫码步骤。

等价的 npm 脚本：

```bash
npm start        # ./start.sh
npm run start:web
npm run stop
npm run stop:all
npm run status
npm run probe    # 只探活
npm run dry -- 在吗
```

日志会同时写到终端和文件：

```bash
tail -f qq-bridge/data/logs/qq-bridge.log
```

看到下面几行就说明上线了：

```
已从容器里读到 OneBot 配置（端口和 token 不用手填）
已连上 SnowLuma，等消息中
账号 123456789 已就绪
小鲸鱼已起航（Ctrl+C 下线）
```

然后用自己的 QQ 给小号发消息即可。

## 不用 QQ 也能测

```bash
cd qq-bridge

node src/index.js --dry 在吗   # 只测大脑 + 人设
node src/index.js --probe      # 只测 OneBot 连接和 QQ 登录状态
bash tests/e2e.sh              # 假 SnowLuma + 假大脑的端到端测试
```

`tests/e2e.sh` 会临时改 `config.json`，结束后自动还原；覆盖「私聊 → 群里没 @（忽略）→ 群里 @（回复）→ 第二轮续接 session」。

调试原始 OneBot 事件：

```bash
QQ_BRIDGE_DEBUG=1 node src/index.js
```

## 配置要点

完整字段见 [`qq-bridge/README.md`](qq-bridge/README.md) 和 [`docs/PROJECT_STRUCTURE.md`](docs/PROJECT_STRUCTURE.md)。

| 字段 | 作用 |
| --- | --- |
| `snowluma.mode` | `auto` 从容器读 OneBot 配置；`manual` 用手填的 host/port/token |
| `dsh.profile` | 用哪个 DSH profile（默认 `qq`） |
| `dsh.workspace` | 她运行 dsh 时的工作目录（默认 `qq-bridge/data/workspace`） |
| `dsh.timeoutMs` | 单条消息最多等多久，超时掐掉 |
| `access.owner` | 管理员 QQ；私聊永远回，群里默认也回 |
| `access.groupAllow` | 允许说话的群号数组，空数组 = 不在任何群说话 |
| `reply.*` | 最小间隔、模拟打字速度、单条最大字数 |

## 常见问题

| 现象 | 排查 |
| --- | --- |
| `读不到 SnowLuma 配置` | 容器没起，或 QQ 还没登录；先 `docker logs snowluma` |
| 连上就断、一直重连 | 容器重启过 / token 变了 → `./restart.sh`（auto 模式会重读） |
| `QQ 还没上线` | 去 `http://localhost:6081` 看 QQ 是否掉线 |
| 她回「作为 AI…」 | 人设没装进 profile → 重跑 `setup-profile.sh`，再 `--dry` 验证 |
| `Authentication Fails` | DSH 的 API key 失效，和 bridge 无关 |
| 群里不说话 | 群号没进 `groupAllow`，或没 @ 她 |
| 回复很慢 | 每条消息都会起一个 `dsh` 进程 + 一次完整模型调用，属正常 |

更多坑位说明见 [`qq-bridge/README.md`](qq-bridge/README.md)。

## 安全与边界

- `qq-bridge/config.json` 和 `qq-bridge/data/` **不进 git**（含 owner QQ、session 映射、日志）。
- OneBot token 默认从容器读取，不落盘到本仓库。
- 默认白名单为空：除了 owner，谁都不理。宁可沉默，也别乱说话。
- bridge 不保存聊天记录；记忆在 `~/.dsh/sessions`，映射在 `qq-bridge/data/sessions.json`。删掉映射里某一行 = 让那段对话失忆。
- 这是个人玩具项目，请遵守 QQ 用户协议，别拿去做骚扰/群发。

## 上游与版本

| 组件 | 版本 | 位置 |
| --- | --- | --- |
| SnowLuma | v2.2.0（`3bd74acb`） | `SnowLuma/`，来自 <https://github.com/SnowLuma/SnowLuma> |
| SnowLuma 镜像 | `motricseven7/snowluma:latest` | Docker Hub |
| DeepSeek Harness | 当前 `0.2.0-rc.2` | 本机 `~/.dsh` |
| qq-bridge | 0.1.0 | 本仓库，无第三方依赖 |

SnowLuma 是按上游单独 clone 的，本仓库不跟踪它：

```bash
git clone https://github.com/SnowLuma/SnowLuma.git SnowLuma
cd SnowLuma && git checkout v2.2.0
```
