# DSH 控制台（鸿蒙客户端）

用手机操控电脑上的 DeepSeek Harness：扫码配对后，在同一 Wi-Fi 下直连，或在电脑开启隧道后跨网络使用。

与 [`../`](../)（电脑端桥插件）配套使用，**两者缺一不可**。

- 包名：`com.yanak.dshremote`
- 运行平台：HarmonyOS
- 当前版本：`0.2.2`

## 功能

| 能力 | 说明 |
|---|---|
| 扫码配对 | 扫电脑端插件生成的二维码（`dshremote://pair?v=2&…`），一次性码换 token，二维码里不含 token |
| 局域网直连 | 同一 Wi-Fi 下直接访问 `http://<电脑IP>:7627`，无需公网 |
| 跨网络 | 电脑端开 cloudflared 隧道后走 HTTPS，人在外面也能用 |
| 自动发现 | 监听 UDP 广播找到同一局域网里的电脑，免手填 IP |
| 回合结束提醒 | 后台保活 + 系统通知，AI 干完活手机能收到 |
| 手动配置 | 设置页可手填 IP / 端口 / token / 隧道地址，并测试连接 |

## 架构

这是一个**原生外壳 + Web 内容区**的应用，不是纯 WebView 壳：

```
entry/src/main/ets/
├── common/
│   ├── Pairing.ets       配对链接解析与校验（dshremote://）
│   ├── BridgeClient.ets  HTTP 客户端 + /events 轮询 + WebSocket
│   ├── ConfigStore.ets   配对信息持久化（preferences）
│   ├── Discovery.ets     UDP 广播自动发现电脑
│   └── Notifier.ets      系统通知
├── entryability/         应用入口、dshremote:// 协议处理
└── pages/Index.ets       界面：scan / main / settings / about 四态
```

配对、发现、通知、连接管理都是**原生 ArkTS**；只有中间那块 DSH 界面用 `Web` 组件加载，
因为 DSH 的完整交互（diff、终端、文件浏览）不适合在 6 寸屏上重做。

## 编译

需要 **DevEco Studio**（本项目在 `modelVersion 6.1.1`、`compatibleSdkVersion 6.1.0(23)` 下验证通过）。

### 用 DevEco Studio（推荐）

1. 打开 `app/` 目录
2. **File → Project Structure → Signing Configs** → 勾选 **Automatically generate signature**，登录你的华为账号
3. 点 Run / Build → Build Hap(s)

> 第 2 步必不可少：仓库里的 `build-profile.json5` **不含签名配置**，因为 DevEco 自动签名会把
> **明文密码**写进该文件，不能提交。你自己生成一次即可，它只改本地文件。

### 命令行构建

```powershell
# 按你的安装路径调整
$env:DEVECO_SDK_HOME = "D:\harmonyOS\DevEco Studio\sdk"
$env:NODE_HOME       = "D:\harmonyOS\DevEco Studio\tools\node"

& "$env:NODE_HOME\node.exe" `
  "D:\harmonyOS\DevEco Studio\tools\hvigor\bin\hvigorw.js" `
  --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

没有签名配置时会产出**未签名 HAP**（构建仍成功，可用来验证代码能否编译），
但装真机必须签名，出包请走 DevEco。

产物：`entry/build/default/outputs/default/`

## 权限

| 权限 | 用途 |
|---|---|
| `ohos.permission.INTERNET` | 连接用户自己的电脑，收发指令与会话内容 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | 后台保持连接，回合结束时能提醒 |
| `ohos.permission.GET_NETWORK_INFO` | 判断走局域网直连还是隧道 |

没有定位、通讯录、相机、存储等敏感权限。**不收集任何个人数据**，配对信息只存在本机。

## 应用备案

已上架/上架中应用需在应用内展示 APP 备案号，并链接到工信部查询页（审核硬性要求）。

代码位置：`entry/src/main/ets/pages/Index.ets`

```ts
/** APP 备案号。空字符串 = 还没下来，界面显示「备案办理中」。 */
const APP_FILING_NUMBER: string = '';
```

拿到备案号后**只改这一行**，不用动界面。「关于」页在 设置 → 关于。

## 已知限制

- **调试签名有效期约 14 天**，到期后需重新签名；正式发布请用 AGC 发布证书
- 只支持鸿蒙，没有 Android / iOS 版本
- 界面文案仅简体中文
- `getContext` 等 API 有弃用警告（不影响构建，与上游代码保持一致）

## 与上游的关系

本项目基于 [uchiha086/dshremote](https://github.com/uchiha086/dshremote)（MIT）的鸿蒙客户端改造，
主要改动：修复桥插件打包缺陷、配对审批做进 DSH 面板、自签 owner cookie 适配 DSH 0.2.3、
新增「关于」页与备案号展示。
