# 项目结构 / 数据流

本文说明 `qq_dep` 里每个东西是干什么的、消息怎么流动、运行时留下了哪些状态。部署和日常命令看根目录 [`README.md`](../README.md)。

## 1. 顶层结构

```
qq_dep/
├── README.md                  # 给第一次来的人：怎么装、怎么跑
├── start.sh                   # 一键启动：容器 →（可选）dsh web → bridge
├── stop.sh                    # 一键关闭：bridge / 可带 --all
├── restart.sh                 # stop + start
├── status.sh                  # 容器、QQ、bridge、dsh web、日志
├── package.json               # npm scripts 包装上面几个脚本
├── docs/
│   ├── PROJECT_STRUCTURE.md   # 本文件
├── qq-bridge/                 # 本项目的主体，独立的小 Node 项目
└── SnowLuma/                  # 上游 SnowLuma 源码（独立 git clone，被忽略）
```

`SnowLuma/` 不参与本仓库版本管理：它来自 <https://github.com/SnowLuma/SnowLuma>，当前固定在 `v2.2.0`（`3bd74acb`）。运行时用的是 Docker 镜像 `motricseven7/snowluma:latest`，源码主要用于查 API、对照行为。

## 2. qq-bridge

### 2.1 文件职责

| 路径 | 职责 |
| --- | --- |
| `src/index.js` | 主流程：日志、消息解析、准入判断、去重、限速、回复清洗、发送、探活/`--dry` 入口 |
| `src/onebot.js` | 极简 OneBot v11 **正向 WebSocket 客户端**：握手、echo 请求/响应、断线指数退避重连 |
| `src/dsh.js` | 大脑：每次调用起一个 `dsh --profile qq headless --json` 子进程，解析 JSONL，维护 session 映射和超时 |
| `src/config.js` | 读 `config.json` + 默认值深合并；`auto` 模式从容器抠 OneBot 端口和 token |
| `roles/小鲸鱼.md` | 人设，纯文本；`setup-profile.sh` 会把它写进 DSH profile |
| `setup-profile.sh` | 从 `~/.dsh/profiles/headless` 复制出 `qq` profile，写入 `personaPrefix`，关闭 harness 身份提示 |
| `config.example.json` | 配置模板（会进 git） |
| `config.json` | 你的真实配置（**不进 git**，含 owner QQ） |
| `tests/fake-snowluma.js` | 假 OneBot 服务端：发私聊、群未 @、群 @ 三类事件 |
| `tests/fake-dsh.sh` | 假大脑：按关键词回固定台词，顺手记录收到的参数 |
| `tests/e2e.sh` | 无 QQ e2e：临时改造配置，校验回复内容、不回声、session 续接，结束后还原 |
| `data/` | 运行时状态（**不进 git**） |

### 2.2 一次私聊的处理流程

```
QQ 客户端
  │  （小号登录在容器里的 Linux QQ）
  ▼
SnowLuma（Docker）── OneBot 正向 WS 事件 ──▶ onebot.js
                                               │ onEvent
                                               ▼
                                          index.js#handle
                           ┌───────────────────┼───────────────────┐
                           │ 1. post_type=message                  │
                           │ 2. 忽略自己 / 空文本                  │
                           │ 3. message_id 去重（LRU 200）         │
                           │ 4. 提取文本、是否 @ 自己              │
                           │ 5. 准入：owner / privateAllow         │
                           │ 6. 同会话已有请求在跑 → 直接丢弃      │
                           └───────────────────┬───────────────────┘
                                               ▼
                                        dsh.js#Brain.ask
                           ┌───────────────────┼───────────────────┐
                           │ 同会话串行队列                        │
                           │ spawn dsh --profile qq headless       │
                           │   --json [--session-id …] <文本>      │
                           │ 解析 JSONL：session / final / error   │
                           │ 成功后原子写 data/sessions.json       │
                           └───────────────────┬───────────────────┘
                                               ▼
                                    cleanReply() 洗 Markdown
                                               │
                       minIntervalMs 间隔 + 模拟打字 sleep
                                               │
                                               ▼
                              send_private_msg / send_group_msg
                                               │
                                               ▼
                                    SnowLuma → QQ
```

群聊分支的差异：

- 必须先命中 `access.groupAllow`（空数组 = 所有群都不理）。
- `groupRequireAt = true` 时必须 @ 她；`ownerAlwaysReply = true` 时 owner 在群里不 @ 也会接。
- 会话键是 `group-<群号>`：**同一个群共用一个 DSH session**，不是每人一个。

私聊会话键是 `private-<QQ号>`。

### 2.3 准入与节奏规则

| 规则 | 位置 | 行为 |
| --- | --- | --- |
| 忽略自己发的消息 | `index.js` | `user_id === self_id` 直接返回 |
| 忽略非文本 | `readMessage` | 图片/表情/语音变成 `[图片]` 等占位符；纯占位符也会被当文本 |
| 去重 | `alreadySeen` | 按 `message_id` 保留最近 200 条，防止 OneBot 重复推送 |
| 会话内互斥 | `inFlight` | 同一会话上一条没回完，新消息直接丢，避免刷屏和并发写 session |
| 会话内串行 | `Brain.ask` | `dsh.js` 里还有一层 Promise 队列兜底 |
| 最小间隔 | `reply.minIntervalMs` | 距上次发送不足就补 sleep |
| 打字延迟 | `typingPerCharMs` / `typingMaxMs` | `min(上限, 字数 × 每字耗时)` |
| 截断 | `reply.maxChars` | 超长时在句号/换行处截，否则加省略号 |
| 出错不回声 | `index.js` catch | 只记日志，绝不把用户原话当回复发回去 |

### 2.4 dsh 调用约定

```
dsh --profile <profile> headless --json [--session-id <id>] <文本>
```

- 工作目录：`dsh.workspace`（默认 `qq-bridge/data/workspace`）。
- stdout 按行解析 JSON：
  - `{"type":"session","sessionId":…}` → 记录本轮 session
  - `{"type":"final","text":…}` → 最终回复
  - `{"type":"error",…}` / `status.reason.error` → 失败原因
- 只有**真的产出文本**才把 session 写回映射，避免把失败的空壳记下来。
- 如果 DSH 报 session `does not exist`（换机器、清过 `~/.dsh`），丢掉映射重开一段，只重试一次。
- 超时 `dsh.timeoutMs` 后先 SIGTERM，3 秒后 SIGKILL。

### 2.5 OneBot 客户端

- 只用 Node 内置 `WebSocket`，没有 npm 依赖。
- 连接 URL 带 `?access_token=…`；日志里会把 token 打码。
- 请求用自增 `echo` 匹配响应；断线时所有 pending 请求立刻 reject。
- 重连退避：2s → 4s → 8s → 16s → 30s 封顶，无限重试。
- `--probe` 模式下 3 秒内连不上就退出并报错，连上后调 `get_login_info` / `get_status`。

### 2.6 SnowLuma 配置自动发现

`config.snowluma.mode = "auto"` 时，优先执行：

```bash
docker exec <container> cat /app/data/config/onebot.json
docker exec <container>-1 cat /app/data/config/onebot.json   # docker compose 命名兜底
```

从 `networks.wsServers` 里挑一个带 `accessToken` 的（否则取第一个），拼出：

```
ws://<host>:<port>/<path>?access_token=<token>
```

`0.0.0.0` / `::` 会自动改成 `127.0.0.1`。都读不到时，再找当前目录的 `onebot.json`；仍然失败就给出 docker 的原始报错。

`mode = "manual"` 则完全使用手填的 `host/port/accessToken`。

> 注意：bridge 按 OneBot **array** 消息格式解析。SnowLuma 若配成 `string`，日志里会有警告，且 @ 判断可能失效。

## 3. 运行时状态

### 3.1 目录

```
qq-bridge/data/                 # 全部不进 git
├── qq-bridge.pid               # bridge 进程号（start.sh 写）
├── dsh-web.pid                 # dsh web 进程号（start.sh --web 写）
├── sessions.json               # 会话键 → DSH sessionId
├── workspace/                  # 她跑 dsh 时的工作目录（可写文件/日记）
└── logs/
    ├── qq-bridge.log           # bridge stdout/stderr，追加写
    └── dsh-web.log             # dsh web stdout/stderr
```

测试临时文件在 `/tmp`：`qq-bridge-fake.log`、`qq-bridge-run1.log`、`fake-dsh-calls.log` 等。

### 3.2 session 映射

```json
{
  "private-10001": "01J…",
  "group-123456": "01J…"
}
```

- 由 `dsh.js` 原子写（先写 `.tmp` 再 rename）。
- 删掉某一行 = 让那段对话失忆；重启 bridge 不会清空。
- session 本体在 `~/.dsh/sessions`，`dsh web` 里能看到同一批记录。
- bridge 自己不存聊天内容。

### 3.3 PID 与日志

- `start.sh` 在前台跑 `node src/index.js`，输出通过 `tee` 同时进终端和 `data/logs/qq-bridge.log`；启动时把进程号写入 `qq-bridge.pid`。
- 前台模式下按 Ctrl+C，脚本的 EXIT trap 会停止桥（必要时 SIGKILL）、删除 pid 文件；`--web` 启动的 dsh web 也会一并停掉，容器不动。
- 如果已有桥在跑，前台模式不会静默再起一份：要求先 `./stop.sh` 或 `./start.sh --restart`。
- 手动跑过 `node src/index.js` 的进程没有 pid 文件，`start.sh` / `stop.sh` 会用 `pgrep -f '^node src/index.js'` 认领。
- `stop.sh` 先 SIGTERM，最多等 4 秒，再 SIGKILL，最后删 pid 文件。前台 `start.sh` 会感知到桥退出并打印退出码。
- `status.sh` 的探活是另起一个 `node src/index.js --probe`，和常驻进程无关。

## 4. 端口与地址

| 端口 | 宿主机 | 用途 |
| --- | --- | --- |
| 3000 | `0.0.0.0:3000` | SnowLuma OneBot HTTP（预留/可选） |
| 3001 | `0.0.0.0:3001` | **OneBot 正向 WebSocket**（bridge 连这里） |
| 5099 | `0.0.0.0:5099` | SnowLuma WebUI |
| 6081 | `0.0.0.0:6081` | noVNC，用来操作容器里的 Linux QQ |
| 5900 | 未映射 | 容器内部 VNC |
| 8080 | `127.0.0.1:8080` | `dsh web`（仅 `--web` 时启动，本机旁观会话） |

安全提醒：3000/3001 绑定在 `0.0.0.0`，同一局域网可访问。OneBot 必须设 `access_token`；WSL 里如果不打算给局域网用，可只映射到 `127.0.0.1`。

## 5. 脚本行为

### 5.1 `start.sh`

1. 检查 Node ≥ 22、`qq-bridge/config.json` 存在、`docker` 可用。
2. `docker inspect` 容器：不存在 → 报错并提示 docker run；停止 → `docker start`。
3. 从 `docker logs` 取 VNC 密码，打印网页入口：QQ 登录 noVNC（6081）、SnowLuma 管理页（5099）。
4. 最多等 60 秒，直到能 `docker exec … cat onebot.json`（QQ 登录后才有；volume 里已存在时会立即通过）。
5. 可选 `--web`：用 `setsid nohup dsh web --no-open --port 8080` 起网页，写 `dsh-web.pid`，并记住是本次启动的（退出时一起关）。
6. 处理已有桥：没有 `--restart` 就报错退出，避免前台和后桥抢同一会话；有 `--restart` 先停旧进程。
7. 先跑一次 `--probe` 探活：成功显示 QQ 昵称，失败打印扫码登录步骤（noVNC + VNC 密码）。
8. **前台**启动 `node src/index.js`，输出用 `tee` 同时写终端和 `qq-bridge.log`，pid 写入 `qq-bridge.pid`。
9. 注册 EXIT/INT/TERM trap：Ctrl+C 或桥自己退出时，停桥、删 pid、停本次起的 dsh web，容器保留。

### 5.2 `stop.sh`

- 默认只停 bridge（QQ 继续挂在容器里）。
- `--all`：再停 `dsh web`，最后 `docker stop snowluma`。
- 没有 pid 文件时按进程名兜底。

### 5.3 `status.sh`

依次打印：容器状态、`--probe` 结果、bridge PID/运行时长、dsh web PID、日志最后 12 行。探活失败时会附上 noVNC / WebUI 入口和 VNC 密码。

## 6. SnowLuma 上游结构（只读参考）

`SnowLuma/` 是 pnpm monorepo：

```
SnowLuma/
├── packages/
│   ├── core/          # 运行时主体：QQ 会话接入、OneBot 转换、WebUI 后端
│   │   ├── src/bridge/       # OneBot 动作实现（消息、群、好友、空间、文件…）
│   │   ├── src/webui/        # WebUI 服务、鉴权、状态流、备份、更新
│   │   ├── src/notifications/、update/、…
│   │   └── tests/            # vitest
│   ├── onebot/        # OneBot 协议定义/转换
│   ├── protocol/      # QQ 协议层
│   ├── runtime/       # 运行时封装
│   ├── websocket/、bridge/   # 传输与桥接
│   ├── sdk/、mcp/     # 对外 TypeScript SDK / MCP
│   ├── webui/、ui/    # 前端
│   └── sqlite/、common/、proto-defs/、proton/ …
├── compat/            # QQ 兼容数据 + JSON Schema
├── tools/             # 构建、发布、版本、CI 校验
└── assets/            # README 用图
```

bridge 只依赖它的 OneBot WebSocket 接口，**不 import 它的源码**，所以升级 SnowLuma 不会影响 `qq-bridge` 的代码，除非 OneBot 行为/配置格式变了。

## 7. 测试架构

```
tests/e2e.sh
├─ 备份 config.json / sessions.json
├─ 改配置：snowluma=manual:3999，dsh=tests/fake-dsh.sh，白名单固定
├─ tests/fake-snowluma.js 3999
│    └─ 依次发：上线 → owner 私聊 → 群里没 @ → 群里 @
├─ 跑两次 node src/index.js
└─ 校验：
     • 回复来自「大脑」，不是用户原话
     • 群里没 @ 的那条被忽略
     • 第二轮带 --session-id（映射续接）
     • 结束后还原配置和 sessions
```

`fake-dsh.sh` 会把收到的参数写到 `/tmp/fake-dsh-calls.log`，方便断言。

## 8. 设计取舍与已知边界

- **每条消息一个 `dsh` 进程**：隔离简单、不会串 session，但冷启动 + 模型调用导致回复通常要几秒。
- **bridge 零依赖**：只用 Node 内置模块，升级/迁移成本低。
- **默认拒绝**：白名单为空时只有 owner 能私聊，群默认一个都不进。
- **不存聊天记录**：记忆完全交给 DSH session；bridge 只存映射。
- **同会话互斥**：忙时直接丢消息而不是排队，避免机器人刷屏、模型被打爆。
- **单实例假设**：pid 文件 + 端口约定，默认一台机器只跑一份 bridge。
- **群共享上下文**：同一个群的所有人共用一个 session，群里聊过的内容会互相影响。
- **非文本降级**：图片/语音只以占位符进入模型，不做下载/识别。
- **auto 模式依赖本机 docker**：SnowLuma 跑在别的机器上时改 `manual`。
- **不做流式/分段回复**：一次只发一条完整文本。

## 9. 常见改动入口

| 想改什么 | 改哪里 |
| --- | --- |
| 人设/说话风格 | `qq-bridge/roles/小鲸鱼.md`，然后 `bash qq-bridge/setup-profile.sh` |
| 换 DSH profile / 模型 | `config.json` 的 `dsh.profile`（profile 在 `~/.dsh/profiles`） |
| 换容器名 | `config.json` → `snowluma.container`，或 `SNOWLUMA_CONTAINER=xxx ./start.sh` |
| 允许某些群 | `access.groupAllow` 加群号；想不 @ 也回就把 `groupRequireAt` 设 false |
| 允许别人私聊 | `access.privateAllow` 加 QQ 号 |
| 回复更快/更慢 | `reply.minIntervalMs`、`typingPerCharMs`、`typingMaxMs` |
| 换网页端口 | `start.sh --web` 前设 `DSH_WEB_PORT=9090` |
| 换 OneBot 端口/token | SnowLuma WebUI 改完，`./restart.sh` 自动重读 |
