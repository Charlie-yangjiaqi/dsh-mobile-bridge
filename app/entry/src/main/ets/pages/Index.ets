import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { webview } from '@kit.ArkWeb';
import { BridgeConfig, ConfigStore } from '../common/ConfigStore';
import { BridgeHttp, BridgePoller, ClaimResult, TurnEndEvent } from '../common/BridgeClient';
import { Discovery, FoundHost } from '../common/Discovery';
import { Notifier } from '../common/Notifier';
import { applyPairing, parsePairing, PairResult } from '../common/Pairing';

/**
 * 三段式界面：
 *   scan     —— 没配对过：只放一个「扫码连接电脑」和备用入口
 *   main     —— 已配对：全屏 DSH，右上角只有一枚设置按钮
 *   settings —— 手动改地址 / 重新扫码 / 看连接测试结果
 *   about    —— 版本号与 APP 备案号（备案号必须可点击查证，见 FILING_QUERY_URL）
 * 连接状态、隧道、令牌这些细节都不在主界面出现，出错才回到设置页显示原因。
 */

/** 工信部备案查询系统：备案号必须能点进来，审核会查。 */
const FILING_QUERY_URL: string = 'https://beian.miit.gov.cn/';

/**
 * APP 备案号。
 *
 * 空字符串表示还没备案下来，此时「关于」页显示「备案办理中」而不是留一片空白——
 * 审核看到空白会当成漏填。拿到号后只改这一行，不用动界面代码。
 */
const APP_FILING_NUMBER: string = '';

@Entry
@Component
struct Index {
  @State stage: string = 'loading';
  @State hostInput: string = '';
  @State portInput: string = '3088';
  @State tokenInput: string = '';
  @State tunnelInput: string = '';
  @State testResult: string = '';
  @State busy: boolean = false;
  @State webUrl: string = '';
  @State webReady: boolean = false;
  @State foundName: string = '';
  @State hasFound: boolean = false;
  @StorageLink('pairUri') @Watch('onPairUriChanged') pairUri: string = '';

  private found: FoundHost = new FoundHost();
  private discovery: Discovery = new Discovery();
  private controller: webview.WebviewController = new webview.WebviewController();
  private cfg: BridgeConfig = new BridgeConfig();
  private poller: BridgePoller = new BridgePoller();

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    Notifier.enable(context);
    this.discovery.onFound = (host: FoundHost) => {
      this.found = host;
      this.foundName = host.name;
      this.hasFound = true;
      this.testResult = `发现电脑：${host.name}`;
    };
    this.discovery.onError = (message: string) => {
      this.foundName = message;
    };
    ConfigStore.init(context).then(async () => {
      const loaded = await ConfigStore.load();
      this.cfg = loaded;
      this.hostInput = loaded.host;
      this.portInput = `${loaded.port}`;
      this.tokenInput = loaded.token;
      this.tunnelInput = loaded.tunnel;
      // 冷启动时系统相机把 dshremote:// 链接直接交给本应用：@Watch 不会触发，得在这里主动消费。
      const pending = AppStorage.get<string>('pairUri') ?? '';
      if (pending.length > 0) {
        AppStorage.setOrCreate<string>('pairUri', '');
        this.pairUri = '';
        // 冷启动也不能跳过确认：任何网页/应用都能发 dshremote:// 链接。
        this.confirmPair(pending, () => {
          this.stage = loaded.valid() ? 'main' : 'scan';
          if (loaded.valid()) {
            this.enterMain();
          }
        });
        return;
      }
      if (loaded.valid()) {
        this.stage = 'main';
        await this.enterMain();
      } else {
        this.stage = 'scan';
        this.discovery.start();
      }
    });
  }

  aboutToDisappear(): void {
    this.poller.stop();
    this.discovery.stop();
  }

  private readForm(): BridgeConfig {
    const cfg = new BridgeConfig();
    cfg.host = this.hostInput.trim();
    cfg.port = Number(this.portInput.trim());
    if (!Number.isFinite(cfg.port) || cfg.port <= 0) {
      cfg.port = 3088;
    }
    cfg.token = this.tokenInput.trim();
    cfg.proxyPort = 7627;
    cfg.tunnel = this.tunnelInput.trim();
    return cfg;
  }

  /** 设置页里的「测试连接」。 */
  private async testConnection(): Promise<void> {
    this.busy = true;
    const cfg = this.readForm();
    this.cfg = cfg;
    await this.pickTransport();
    this.testResult = await BridgeHttp.health(this.cfg.baseUrl());
    this.busy = false;
  }

  /** 设置页里的「保存并进入」。 */
  private async saveAndEnter(): Promise<void> {
    const cfg = this.readForm();
    if (!cfg.valid()) {
      this.testResult = '地址和令牌都要填，扫码通常会自动填好';
      return;
    }
    this.busy = true;
    this.cfg = cfg;
    await this.pickTransport();
    const health = await BridgeHttp.health(this.cfg.baseUrl());
    hilog.info(0x0000, 'dshremote', '保存并进入 base=%{public}s health=%{public}s', this.cfg.baseUrl(), health);
    if (!health.startsWith('桥')) {
      this.testResult = health;
      this.busy = false;
      this.stage = 'settings';
      return;
    }
    await ConfigStore.save(this.cfg);
    this.busy = false;
    this.stage = 'main';
    await this.enterMain();
  }

  /** 系统相机扫到的配对链接会通过 AppStorage 送进来。 */
  onPairUriChanged(): void {
    if (this.pairUri.length === 0) {
      return;
    }
    const text = this.pairUri;
    this.pairUri = '';
    AppStorage.setOrCreate<string>('pairUri', '');
    this.confirmPair(text, () => { });
  }

  /** 外来的深链不能直接连：先让用户看一眼是不是自己的电脑。取消时走 onCancel。 */
  private confirmPair(text: string, onCancel: () => void): void {
    const preview: PairResult = parsePairing(text);
    AlertDialog.show({
      title: '收到配对请求',
      message: preview.ok
        ? `来自「${preview.name}」的配对链接，确认连接这台电脑吗？`
        : `这个链接不是 DSH Remote 的配对码：${preview.error}`,
      primaryButton: {
        value: '取消',
        action: () => {
          onCancel();
        }
      },
      secondaryButton: {
        value: '连接',
        action: () => {
          this.applyPairText(text);
        }
      }
    });
  }

  private async applyPairText(raw: string): Promise<void> {
    const result: PairResult = parsePairing(raw);
    if (!result.ok) {
      this.testResult = result.error;
      this.stage = 'scan';
      return;
    }
    const cfg = this.readForm();
    applyPairing(cfg, result);
    // v2：二维码里只有 60 秒一次性码，先换真 token 才能连。
    if (result.needsClaim) {
      this.testResult = '正在用一次性码换取访问凭证…';
      const lanBase = result.host.length > 0 ? `http://${result.host}:${result.port}` : '';
      const candidates: string[] = [];
      if (lanBase.length > 0) {
        candidates.push(lanBase);
      }
      if (result.tunnel.length > 0) {
        candidates.push(result.tunnel);
      }
      // 一次性码 60 秒就过期：别一个地址一个地址串行等超时，
      // 手机在 4G 上打局域网地址必然要耗掉一整个 connectTimeout。
      const claimed: ClaimResult | null = await this.claimAny(candidates, result.code);
      if (claimed === null) {
        this.testResult = '配对码已失效（一次性码 60 秒过期），请回电脑刷新二维码';
        this.stage = 'scan';
        return;
      }
      cfg.token = claimed.token;
      if (claimed.tunnel.length > 0) {
        cfg.tunnel = claimed.tunnel;
      }
    }
    this.cfg = cfg;
    this.hostInput = cfg.host;
    this.portInput = `${cfg.port}`;
    this.tokenInput = cfg.token;
    this.tunnelInput = cfg.tunnel;
    this.testResult = `已配对：${result.name}`;
    this.saveAndEnter();
  }

  /** 对多个候选地址同时发 claim，先成功的赢（一次性码本来就只能用一次）。 */
  private async claimAny(candidates: string[], code: string): Promise<ClaimResult | null> {
    if (candidates.length === 0) {
      return null;
    }
    if (candidates.length === 1) {
      return await BridgeHttp.claim(candidates[0], code);
    }
    return new Promise<ClaimResult | null>((resolve: (value: ClaimResult | null) => void) => {
      let settled = false;
      let pending = candidates.length;
      for (const base of candidates) {
        BridgeHttp.claim(base, code).then((found: ClaimResult | null) => {
          if (!settled && found !== null) {
            settled = true;
            resolve(found);
            return;
          }
          pending -= 1;
          if (pending === 0 && !settled) {
            settled = true;
            resolve(null);
          }
        }).catch(() => {
          pending -= 1;
          if (pending === 0 && !settled) {
            settled = true;
            resolve(null);
          }
        });
      }
    });
  }

  private async scanPair(): Promise<void> {
    try {
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.ALL],
        enableMultiMode: false,
        enableAlbum: true,
      };
      const context = getContext(this) as common.UIAbilityContext;
      const result = await scanBarcode.startScanForResult(context, options);
      const text = result.originalValue ?? '';
      if (text.length > 0) {
        this.applyPairText(text);
      }
    } catch (error) {
      this.testResult = '扫码取消或失败';
    }
  }

  private async connectFound(): Promise<void> {
    const cfg = this.readForm();
    cfg.host = this.found.base.replace('http://', '').split(':')[0];
    const basePort = Number(this.found.base.split(':').pop());
    cfg.port = Number.isFinite(basePort) && basePort > 0 ? basePort : 3088;
    const webPort = Number(this.found.web.split(':').pop());
    cfg.proxyPort = Number.isFinite(webPort) && webPort > 0 ? webPort : 7627;
    cfg.token = this.found.token;
    cfg.tunnel = this.found.publicUrl.length > 0 ? this.found.publicUrl : '';
    this.cfg = cfg;
    this.hostInput = cfg.host;
    this.portInput = `${cfg.port}`;
    this.tokenInput = cfg.token;
    this.tunnelInput = cfg.tunnel;
    this.discovery.stop();
    await this.saveAndEnter();
  }

  /**
   * 同时存着局域网和公网地址时，先花 2 秒试一下局域网：
   * 通了就直连（快、不绕公网），不通就自动改走隧道（换个网络也不用重新扫码）。
   */
  private async pickTransport(): Promise<void> {
    if (this.cfg.host.length === 0) {
      return;
    }
    const probe = await BridgeHttp.health(this.cfg.lanBase(), 2000);
    const lanAlive = probe.startsWith('桥 ');
    if (lanAlive) {
      const tunnel = await BridgeHttp.pairInfo(this.cfg.lanBase(), this.cfg.token);
      if (tunnel.length > 0 && tunnel !== this.cfg.tunnel) {
        this.cfg.tunnel = tunnel;
        this.tunnelInput = tunnel;
      }
      this.cfg.preferTunnel = false;
    } else if (this.cfg.tunnelUrl().length > 0) {
      this.cfg.preferTunnel = true;
    }
    await ConfigStore.save(this.cfg);
  }

  private async enterMain(): Promise<void> {
    await this.pickTransport();
    const base = this.cfg.webUrl();
    this.webReady = false;
    this.discovery.stop();
    this.poller.onStatus = () => {
      // 主界面不展示连接细节，状态只留在内部。
    };
    this.poller.onTurnEnd = (event: TurnEndEvent) => {
      const title = event.sessionTitle.length > 0 ? event.sessionTitle : 'DSH';
      const head = event.answerHead.length > 0 ? event.answerHead : event.question;
      Notifier.publish(`${title} · ${event.status}`, head);
    };
    this.poller.start(this.cfg.baseUrl(), this.cfg.token);
    const tunnel = this.cfg.tunnelUrl();
    if (tunnel.length > 0) {
      const authority = tunnel.replace('https://', '').replace('http://', '').split('/')[0];
      await BridgeHttp.trust(this.cfg.baseUrl(), this.cfg.token, authority);
    }
    const cookie = await BridgeHttp.authCookie(this.cfg.baseUrl(), this.cfg.token, base);
    if (cookie.length > 0) {
      try {
        webview.WebCookieManager.configCookieSync(base, cookie);
      } catch (error) {
        hilog.error(0x0000, 'dshremote', '写 cookie 失败');
      }
    }
    this.webUrl = base;
    this.webReady = true;
  }

  private openSettings(): void {
    this.stage = 'settings';
  }

  private closeSettings(): void {
    this.testResult = '';
    this.stage = this.cfg.valid() ? 'main' : 'scan';
    if (this.stage === 'scan') {
      this.discovery.start();
    }
  }

  private openAbout(): void {
    this.stage = 'about';
  }

  /**
   * 打开工信部备案查询页。
   *
   * 审核要求备案号可点击查证，所以这里必须真的跳出浏览器，而不是只显示一串文字。
   * 用 startAbility + ohos.want.action.viewData 走系统默认浏览器；
   * 失败不弹窗打扰，只记日志——「关于」页本身已经把号码显示出来了，不影响审核要点。
   */
  private openFilingPage(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: FILING_QUERY_URL
    };
    context.startAbility(want).catch((err: BusinessError) => {
      hilog.warn(0x0000, 'DSHRemote', '打开备案查询页失败: %{public}s', JSON.stringify(err));
    });
  }

  build() {
    Stack() {
      if (this.stage === 'main') {
        this.mainView()
      } else if (this.stage === 'settings') {
        this.settingsView()
      } else if (this.stage === 'about') {
        this.aboutView()
      } else if (this.stage === 'scan') {
        this.scanView()
      } else {
        this.loadingView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }

  @Builder
  loadingView() {
    Column({ space: 12 }) {
      LoadingProgress().width(48).height(48)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  scanView() {
    Column({ space: 18 }) {
      Blank().layoutWeight(1)
      Text('DSH Remote').fontSize(30).fontWeight(FontWeight.Bold)
      Text('用手机操控电脑上的 DeepSeek Harness')
        .fontSize(14)
        .fontColor('#666666')
      Blank().height(12)
      Button('扫码连接电脑')
        .width(220)
        .height(48)
        .fontSize(16)
        .onClick(() => {
          this.scanPair();
        })
      if (this.hasFound) {
        Button(`连接 ${this.foundName}`)
          .width(220)
          .height(42)
          .fontSize(14)
          .backgroundColor('#EEF2FF')
          .fontColor('#1D4ED8')
          .onClick(() => {
            this.connectFound();
          })
      } else {
        Button('自动发现电脑')
          .width(220)
          .height(42)
          .fontSize(14)
          .backgroundColor('#F3F4F6')
          .fontColor('#374151')
          .onClick(() => {
            this.testResult = '';
            this.discovery.start();
          })
      }
      if (this.testResult.length > 0) {
        Text(this.testResult)
          .fontSize(12)
          .fontColor('#B91C1C')
          .textAlign(TextAlign.Center)
          .padding({ left: 32, right: 32 })
      }
      Button('手动设置地址')
        .backgroundColor(Color.Transparent)
        .fontColor('#6B7280')
        .fontSize(13)
        .onClick(() => {
          this.stage = 'settings';
        })
      Blank().layoutWeight(1)
      Text('在同一 Wi-Fi 或电脑已开隧道时可用')
        .fontSize(11)
        .fontColor('#9CA3AF')
        .margin({ bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  mainView() {
    Stack({ alignContent: Alignment.TopEnd }) {
      if (this.webReady) {
        Web({ src: this.webUrl, controller: this.controller })
          .domStorageAccess(true)
          .fileAccess(false)
          .darkMode(WebDarkMode.Auto)
          .width('100%')
          .height('100%')
      } else {
        Column({ space: 10 }) {
          LoadingProgress().width(40).height(40)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
      Button() {
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(18)
          .fontColor(['#4B5563'])
      }
      .width(34)
      .height(34)
      .backgroundColor('#F2FFFFFF')
      .borderRadius(17)
      .border({ width: 1, color: '#1F000000' })
      .margin({ top: 46, right: 10 })
      .onClick(() => {
        this.openSettings();
      })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  settingsView() {
    Column() {
      Row({ space: 8 }) {
        Button('返回')
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor('#2563EB')
          .onClick(() => {
            this.closeSettings();
          })
        Blank()
        Text('设置').fontSize(17).fontWeight(FontWeight.Medium)
        Blank()
        Button('').width(48).backgroundColor(Color.Transparent)
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8 })

      Scroll() {
        Column({ space: 12 }) {
          Button('扫码重新配对')
            .width('100%')
            .height(44)
            .onClick(() => {
              this.scanPair();
            })

          TextInput({ text: this.hostInput, placeholder: '电脑 IP 或主机名' })
            .height(44)
            .onChange((value: string) => {
              this.hostInput = value;
            })
          TextInput({ text: this.portInput, placeholder: '端口 3088' })
            .height(44)
            .type(InputType.Number)
            .onChange((value: string) => {
              this.portInput = value;
            })
          TextInput({ text: this.tokenInput, placeholder: '配对令牌' })
            .height(44)
            .onChange((value: string) => {
              this.tokenInput = value;
            })
          TextInput({ text: this.tunnelInput, placeholder: '隧道地址（可选，https://…）' })
            .height(44)
            .onChange((value: string) => {
              this.tunnelInput = value;
            })

          Row({ space: 10 }) {
            Button('测试连接')
              .layoutWeight(1)
              .height(44)
              .enabled(!this.busy)
              .backgroundColor('#F3F4F6')
              .fontColor('#111827')
              .onClick(() => {
                this.testConnection();
              })
            Button('保存并进入')
              .layoutWeight(1)
              .height(44)
              .enabled(!this.busy)
              .onClick(() => {
                this.saveAndEnter();
              })
          }

          if (this.testResult.length > 0) {
            Text(this.testResult)
              .fontSize(12)
              .fontColor(this.testResult.startsWith('桥 ') ? '#15803D' : '#B91C1C')
              .width('100%')
          }

          Divider().margin({ top: 4, bottom: 4 })

          Button('关于')
            .width('100%')
            .height(44)
            .backgroundColor('#F3F4F6')
            .fontColor('#111827')
            .onClick(() => {
              this.openAbout();
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 8, bottom: 20 })
      }
      .layoutWeight(1)

      Text('v0.2.2 · 电脑端需要 dshremote-bridge 插件')
        .fontSize(11)
        .fontColor('#9CA3AF')
        .margin({ bottom: 18 })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 「关于」页。
   *
   * 备案号必须显示在这里并可点击查证——这是应用市场审核的硬性要求，
   * 没有这一页会直接驳回。还没拿到备案号时显示「备案办理中」，不留空白。
   */
  @Builder
  aboutView() {
    Column() {
      Row({ space: 8 }) {
        Button('返回')
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor('#2563EB')
          .onClick(() => {
            this.stage = 'settings';
          })
        Blank()
        Text('关于').fontSize(17).fontWeight(FontWeight.Medium)
        Blank()
        Button('').width(48).backgroundColor(Color.Transparent)
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8 })

      Scroll() {
        Column({ space: 20 }) {
          Column({ space: 6 }) {
            Text('DSH 控制台')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
            Text('v0.2.2')
              .fontSize(13)
              .fontColor('#9CA3AF')
          }
          .width('100%')
          .margin({ top: 24 })

          Text('用手机操控电脑上的 DeepSeek Harness：在同一 Wi-Fi 下直连，'
            + '或在电脑开启隧道后跨网络使用。')
            .fontSize(13)
            .fontColor('#6B7280')
            .lineHeight(20)
            .width('100%')

          Divider()

          Column({ space: 8 }) {
            Text('APP 备案号')
              .fontSize(12)
              .fontColor('#9CA3AF')
              .width('100%')
            if (APP_FILING_NUMBER.length > 0) {
              Text(APP_FILING_NUMBER)
                .fontSize(15)
                .fontColor('#2563EB')
                .decoration({ type: TextDecorationType.Underline, color: '#2563EB' })
                .width('100%')
                .onClick(() => {
                  this.openFilingPage();
                })
              Text('点击在浏览器中查证')
                .fontSize(11)
                .fontColor('#9CA3AF')
                .width('100%')
            } else {
              Text('备案办理中')
                .fontSize(15)
                .fontColor('#B45309')
                .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Divider()

          Column({ space: 6 }) {
            Text('权限说明')
              .fontSize(12)
              .fontColor('#9CA3AF')
              .width('100%')
            Text('· 网络：连接你自己的电脑\n'
              + '· 后台运行：留后台时仍能收到回合结束提醒\n'
              + '· 网络状态：判断走局域网直连还是隧道')
              .fontSize(12)
              .fontColor('#6B7280')
              .lineHeight(19)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Divider()

          Text('本应用不收集任何个人数据，配对信息仅保存在本机。')
            .fontSize(12)
            .fontColor('#6B7280')
            .lineHeight(19)
            .width('100%')
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 40 })
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}
