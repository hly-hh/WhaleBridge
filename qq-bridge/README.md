# qq-bridge（WSL 版）

把 QQ 消息转给 DeepSeek Harness 的桥。整套东西**全在 WSL 里跑**，Windows 只负责开浏览器看网页。

```
SnowLuma (Docker, 内含 Linux QQ)
        │  OneBot WebSocket :3001
        ▼
   qq-bridge  ← 你在这里
   ├─ 谁可以跟她说话 / 群里要不要 @ 她
   ├─ 限速、打字延迟、把 Markdown 洗干净
   └─ 每个 QQ 会话 → 一个 DSH session（记忆就在这）
        │  dsh --profile qq headless --session-id …
        ▼
DeepSeek Harness → DeepSeek API / 你配的其他模型
```

没有依赖。`dsh`、`node`(≥22)、`docker` 之外什么都不用装。

---

## 跑之前的三件事

1. **SnowLuma 里 QQ 得先登上去**
   - 浏览器开 `http://localhost:5099`，同意 EULA、改密码
   - 浏览器开 `http://localhost:6081`（noVNC），输 VNC 密码，在 Linux QQ 里扫码登录小号
   - 登录成功后日志里会出现 `[Hook] pipe connected` / 账号就绪

2. **大脑得能说话**
   - 现在 `~/.dsh/.credentials.yaml` 里那个 DeepSeek key 是失效的（401）
   - 换法二选一：`dsh web` → 设置里改，或者直接编辑 `~/.dsh/.credentials.yaml` 的 `refs.DEEPSEEK_API_KEY`

3. **填一个 QQ 号**
   - `config.json` 里的 `access.owner`，填你自己的 QQ 号（不是小号）

---

## 跑

```bash
cd ~/qq_dep/qq-bridge

# 第一次：生成 DSH 的 qq profile，并把 roles/小鲸鱼.md 装成人设
bash setup-profile.sh

# 只测大脑，不连 QQ（最快确认 key 和角色卡有没有问题）
node src/index.js --dry 在吗

# 只探活：WS 通不通、QQ 登没登录
node src/index.js --probe

# 正式上线
node src/index.js
```

看到这些就对了：

```
信息 已从容器里读到 OneBot 配置（端口和 token 不用手填）
信息 已连上 SnowLuma，等消息中
信息 账号 123456789 已就绪
信息 小鲸鱼已起航（Ctrl+C 下线）
```

然后去 QQ 里跟她说话。`Ctrl+C` 下线。

---

## 关于 token：不用手抄

`config.json` 里 `snowluma.mode = "auto"` 时，bridge 启动会自己执行：

```bash
docker exec snowluma cat /app/data/config/onebot.json
```

把 WebSocket 端口和 `accessToken` 读出来。所以：

- 你在 WebUI 里重置了 token → 重启 bridge 就自动跟上
- 换了容器名 → 改 `snowluma.container`
- 不想让它碰 docker → 改成 `"mode": "manual"`，自己填 `host/port/accessToken`

---

## 配置

```jsonc
{
  "snowluma": { "mode": "auto", "container": "snowluma" },

  "dsh": {
    "command": "dsh",
    "profile": "qq",            // setup-profile.sh 生成的 profile
    "timeoutMs": 180000,        // 一条消息最多等她多久
    "workspace": "./data/workspace"  // 她的工作目录，以后写日记/存东西就在这
  },

  "access": {
    "owner": 0,                 // 必填：你的 QQ 号
    "privateAllow": [],         // 还允许谁私聊她（QQ 号数组）
    "groupAllow": [],           // 允许她在哪些群说话（群号数组）
    "groupRequireAt": true,     // 群里必须 @ 她才回
    "ownerAlwaysReply": true    // 群里的你，不 @ 也会被接住
  },

  "reply": {
    "minIntervalMs": 1500,      // 两条之间最少隔多久（防风控）
    "typingPerCharMs": 35,      // 模拟打字：每个字等多久
    "typingMaxMs": 4000,        // 打字延迟上限
    "maxChars": 1200            // 太长的回复在句号处截断
  }
}
```

`groupAllow` / `privateAllow` 留空 = 谁都不理（除了 owner）。宁可不理，也别让机器人乱说话。

---

## 她是她：角色卡

人设写在 `roles/小鲸鱼.md`，纯文本，随便改。改完重跑：

```bash
bash setup-profile.sh          # 覆盖 ~/.dsh/profiles/qq/cordis.patch.yml
```

`setup-profile.sh` 做的事：从 `headless` 复制一份 profile 叫 `qq`，然后把角色卡写进 `cordis.patch.yml` 的 `system-prompt.personaPrefix`，同时关掉 `includeHarnessIdentity`（否则每轮开头都有一句 "You are an AI agent powered by DeepSeek Harness"，她会变回客服）。

角色卡里**不能出现 `{{…}}`**：DSH 把双花括号当提示词变量严格解析，认不出来会直接报错。脚本会替你检查。

---

## 记忆在哪

- QQ 会话 → DSH session 的映射存在 `data/sessions.json`
- session 本体存在 `~/.dsh/sessions`（DSH 自己的格式）
- 所以：**删掉 `data/sessions.json` 里某一行 = 让那段对话失忆**，其他记录不受影响
- 反向也成立：`dsh web` 里能翻到同一批对话记录

想让她记得更久，靠的是 DSH 的 session，不是 bridge。bridge 不存聊天记录。

---

## 不登 QQ 也能测

```bash
bash tests/e2e.sh
```

它会临时把 `config.json` 换成假服务端 + 假大脑，跑两轮，然后还原。假服务端依次发：私聊 → 群里没 @（应被忽略）→ 群里 @ 了（应被回复）。

第二轮应该能在日志里看到 `(session-fake-000…)`，说明 session 续接生效了。

想手动来：

```bash
node tests/fake-snowluma.js 3999
# 另开窗口，把 config.json 的 snowluma 改成 manual/3999，dsh.command 改成 tests/fake-dsh.sh 的绝对路径
node src/index.js
```

---

## 会踩的坑

| 现象 | 原因 |
|---|---|
| `读不到 SnowLuma 配置` | 容器没起，或者 QQ 还没登录（HTTP/WS 服务是登录后才开的） |
| `连上就断，一直重连` | 容器重启过、token 变了 → 重启 bridge（auto 模式会自己重读） |
| 不知道哪一层坏了 | `node src/index.js --probe`：能报出 QQ 昵称就说明 SnowLuma 这层没问题 |
| 她回 `作为 AI…` / 写小作文 | 角色卡没装进 profile：确认 `setup-profile.sh` 跑过，且 `node src/index.js --dry 你好` 的回复风格对 |
| `Authentication Fails` | DSH 的 key 失效，跟 bridge 无关 |
| 回复很慢（好几秒） | 每条消息都是一个新 `dsh` 进程 + 一次完整模型调用，正常 |
| 群里她不说话 | 群号没进 `groupAllow`，或者没 @ 她 |

---

## 目录

```
qq-bridge/
├── src/
│   ├── index.js     主流程：收消息、判断该不该回、限速、发出去
│   ├── onebot.js    OneBot WebSocket 客户端（零依赖）
│   ├── dsh.js       调 dsh headless，管 session 映射和超时
│   └── config.js    读配置，从容器里自动抠 OneBot 端口和 token
├── roles/           角色卡（人设）
├── tests/           e2e.sh + 假 SnowLuma + 假大脑
├── setup-profile.sh 把角色卡装进 DSH
├── config.json      你的配置（不进 git）
└── data/            session 映射、工作目录
```
