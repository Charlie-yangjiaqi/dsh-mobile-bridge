# dsh-mobile-bridge

让手机远程控制电脑上的 DSH：**电脑端桥插件 + 鸿蒙客户端**。

> 本项目 fork 自 [uchiha086/dshremote](https://github.com/uchiha086/dshremote)（MIT）。
> 上游是混合仓库（鸿蒙 App + 安卓 App + 电脑端插件），这里保留**电脑端插件**（仓库根目录）
> 与**鸿蒙客户端**（[`app/`](app/)），并修复了上游的打包缺陷，便于单独安装和分发。

## 两个部分

| 目录 | 是什么 | 装在哪 |
|---|---|---|
| 仓库根目录 | **电脑端桥插件**（`dshremote-bridge`） | 装进 DSH，提供配对二维码与反代 |
| [`app/`](app/) | **鸿蒙客户端**（DSH 控制台） | 装手机，扫码连电脑 |

**两者缺一不可**：电脑端装了插件才出二维码，手机端装了 App 才能扫码。

- 电脑端安装见下方[安装](#安装)
- 手机端编译见 [`app/README.md`](app/README.md)

## 相对上游的改动

| 改动 | 原因 |
|---|---|
| 补上 `dijkstrajs` 依赖声明 | 上游 `package.json` 只声明了 `ws`，但 `vendor/qr/core/segments.js` 需要 `dijkstrajs`；缺失会在 import 阶段**静默崩溃**，DSH 只跳过插件、控制台无任何报错，极难排查 |
| `files` 补上 `vendor` | 上游没列 `vendor`，从 npm/GitHub 装下来整个二维码实现会丢，`lib/qr.mjs` 的 `require` 直接抛错、扫码功能全废 |
| 去掉硬编码的 Tailscale 域名 | 上游 `cordis.patch.yml` 里写死了作者的 `*.ts.net` 地址，别人装会连到作者机器 |
| 去掉写死的 `cloudflaredPath` | 上游配置里是本机绝对路径，别人机器上必然找不到；改成自动探测（见下） |
| 隧道默认 `auto` | 开箱即用，不需要手动跑 cloudflared |

## 安装

一条命令（会自动写进 `dsh.profile.bundles`，不需要手改配置）：

```powershell
dsh plugin --profile desktop add github:Charlie-yangjiaqi/dsh-mobile-bridge
```

装完**重启 DSH**。验证：

```bash
curl http://127.0.0.1:3088/health
# {"ok":true,"service":"dshremote-bridge","version":"0.2.4",...}
```

> 也可以装本地 checkout：`dsh plugin --profile desktop add -w <本仓库目录>`。
> 早期版本需要手动把包名加进 `dsh.profile.bundles`，**现在不需要了**——DSH 会自动追加
> 声明了 `dsh.bundle` 的包（可用 `dsh --profile desktop --dump-config` 确认有 `# == dshremote-bridge` 那层）。

### 依赖：cloudflared（可选）

只有**手机和电脑不在同一网络**时才需要它。插件会自动按下面顺序找：

1. 配置里的 `cloudflaredPath`
2. 环境变量 `CLOUDFLARED_PATH`
3. `PATH` 里的 `cloudflared`
4. 常见安装位置（`C:\Program Files (x86)\cloudflared\` 等）

找不到不会报错，只是没有公网地址、**局域网直连照常可用**，并且日志只提示一次。

## 跨网络访问

`cordis.patch.yml` 里 `tunnel: auto` 会让插件自己拉起 `cloudflared` 快速隧道，
地址写在 `~/.dsh/dshremote-bridge.public`。**该地址每次重启会变**；要固定地址，
需要一个自己的域名走 Cloudflare 命名隧道，把地址填进 `publicUrl` 并把 `tunnel` 改为 `off`。

## 配对审批（桌面版没有的那块 UI）

别人的设备在 DSH 登录页点「配对此设备」后，会在这台电脑的
**左下角二维码按钮 → 手机遥控 DSH** 面板里显示成待批准列表，点「批准」即可放行；
不需要打开浏览器、也不需要 DSH 有「设置 → 远程连接」那一页（桌面版没有）。

---

DSH Remote 的**电脑端桥插件**。它做两件事：

1. 监听 DSH 宿主的会话事件，在每个**回合结束**时通过 WebSocket 推送一条 `turn_end` 给手机；
2. 把只监听 `127.0.0.1` 的 DSH Web 用裸 TCP 反代到局域网端口，手机浏览器/WebView 才能打开。

手机端不需要理解 DSH 协议，只认这里定义的几十行帧格式。

## 安装

```powershell
# 用 DSH 自带的插件管理器（本地目录会被 link，不复制）
dsh plugin --profile desktop add -w C:\Users\user\Desktop\dshremote\bridge
```

装完**重启 Desktop** 生效。启动日志与 token 位置：

- 日志：`~/.dsh/dshremote-bridge.log`
- token：`~/.dsh/dshremote-bridge.token`（首次启动随机生成，权限 0600）

## 配置

改 `cordis.patch.yml` 里的 `config`（同名覆盖会整体替换，不要只写要改的项）：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `port` | `3088` | 宿主端口（WS `/ws`、`/health`、`/events`） |
| `bind` | `0.0.0.0` | 监听地址；只想本机测就改 `127.0.0.1` |
| `token` | 空 | 空则每次启动随机生成并写入 token 文件 |
| `proxyEnabled` | `true` | 是否启动 DSH Web 反代 |
| `proxyPort` | `7627` | 反代对外端口 |
| `upstreamHost` / `upstreamPort` | `127.0.0.1` / `7626` | DSH Web 实际地址 |
| `answerHeadChars` | `120` | 推送里带多少字回复摘要 |
| `questionChars` | `200` | 推送里带多少字提问 |
| `logFile` | 空 | 空则用 `~/.dsh/dshremote-bridge.log` |

## 协议（v1）

握手子协议固定为 `dshremote-bridge-v1`，连接地址 `ws://<电脑IP>:3088/ws`。

客户端 → 服务端：

```json
{"type":"auth","token":"<token>","deviceName":"HOP-AL10"}
{"type":"ping"}
{"type":"ack","id":"turn-<session>-<seq>"}
```

服务端 → 客户端：

```json
{"type":"hello","protocol":1,"bridgeVersion":"0.1.0","host":"DESKTOP","now":1763...,"proxyPort":7627}
{"type":"turn_end","id":"...","ts":1763...,"sessionId":"...","sessionTitle":"...",
 "question":"用户最后一句","answerHead":"回复前 120 字","status":"done|failed|cancelled","turn":3,"seq":42}
{"type":"pong","ts":1763...}
{"type":"error","code":"bad-token|not-authenticated|auth-timeout"}
```

`status` 由宿主 `turn/end` 的 `reason.kind` 归一而来：含 `error/fail` → `failed`，含 `interrupt/cancel/abort/stop/user` → `cancelled`，其余 → `done`。

## HTTP 调试接口

- `GET /health` —— 不需要 token，返回版本、在线客户端数、会话数、反代端口。
- `GET /events?afterSeq=<seq>`（推荐，头里带 `X-DSH-Token`）—— 拉取 `seq` 之后的事件，响应里带 `latestSeq`；`?token=` 与 `since=<毫秒>` 仍兼容但已弃用。
- `GET /auth/url` / `GET /auth/cookie?base=<手机要访问的地址>` —— 签发免登录地址或 owner 浏览器 cookie，手机 WebView 打开一次即可长期有效。
- `GET /pairing/list` —— 宿主「远程连接」里待批准的配对申请（`{requests:[{id,code,sourceIp,expiresInMs}],pollIntervalMs}`）。
- `GET /pairing/decide?id=<id>&decision=allow|deny` —— 批准或拒绝一条申请（需要 `X-DSH-Token`，或本机面板带 `X-DSH-Panel: 1`）。

## 配对审批（桌面版没有的那块 UI）

DSH 桌面端的 `@deepseek-ai/dsh-client-remote-connection` 在 `if ('dshDesktop' in globalThis)` 处直接
`return`，所以桌面应用里既没有「设置 → 远程连接」页，也没有批准按钮。别的设备在 DSH 登录页点
「配对此设备」后，就永远卡在「正在等待批准…」。

本插件把这块补上：宿主侧的 `remoteConnection` 服务仍在运行，桥以 owner 身份通过 typert 网关调
`remoteConnection/pairingRequests` 与 `remoteConnection/decidePairing`，把待批准列表和批准动作
暴露成上面两个 HTTP 接口；`client.js` 在「手机遥控 DSH」浮层里每 2.5 秒轮询一次并渲染成带
「批准 / 拒绝」的橙色区块。所以在**桌面版自己的面板里**就能完成审批，不需要另开浏览器。

## 安全说明

- token 一律走 `X-DSH-Token`（或 `Authorization: Bearer`）请求头；`?token=` 只为老客户端兼容保留，会进代理日志，**不要用**。
- 二维码里不再有 token：0.2.1 起是 `v=2` 的一次性配对码（60 秒、单次、换完即废），手机扫到后调 `POST/GET /pair/claim` 换回 token。
- `/pair`、`/pair.svg`、`/pair.html`、`/pair/test`、`/pair/claim`、`/pairing/list`、`/pairing/decide`、`/repair`、`/ai-fix`、`/public` 全部要求 token；`/ai-fix` 还要求请求来自回环地址（否则 403），并对每个来源限流。
- `/pairing/decide` 额外接受「回环地址 + `X-DSH-Panel: 1` 自定义头 + 允许的 Origin」这一组证据：自定义头让普通表单 / `<img>` 触发不了（跨源还要先过 CORS 预检，而白名单只放行 `dsh-app://` 与 `127.0.0.1`），所以既方便了桌面面板，又不给 CSRF 留口子。
- UDP 发现广播里**不含 token**，默认关闭（`discovery: false`），只用来告诉手机「电脑在哪」。
- 默认 `bind 0.0.0.0` 只适合**可信局域网**；要跨网请走 Cloudflare Tunnel，并把 ingress 指到 `127.0.0.1:3088`，不要直接把 3088 暴露公网。
- 反代是裸 TCP 透传，不解析内容；DSH Web 自己的鉴权仍然生效。
