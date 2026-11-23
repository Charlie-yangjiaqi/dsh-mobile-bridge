# 固定域名接入指南（charlie-dshmobile.xyz）

目标：把 `dsh.charlie-dshmobile.xyz` 永久指向本机的 DSH，替代每次重启都会变的
`*.trycloudflare.com` 临时隧道。

## 前置条件（缺一不可）

- [ ] 阿里云域名 `charlie-dshmobile.xyz` 状态 = **正常**（实名审核通过）
- [ ] 全球 DNS 能查到该域名（`nslookup -type=NS charlie-dshmobile.xyz 1.1.1.1` 有 NS 记录）
- [ ] Cloudflare 账号（免费）

## 第一步：阿里云改 DNS 服务器

阿里云控制台 → 域名 → 管理 → **DNS 修改**（有的版本叫「修改 DNS 服务器」）

改成 Cloudflare 给的两个 NS，形如：

```
ada.ns.cloudflare.com
bob.ns.cloudflare.com
```

⚠️ 这一步**只是改 NS，不转移域名**，域名仍归你、仍在阿里云续费。
生效时间：几分钟到 24 小时（通常 1 小时内）。

验证：

```bash
nslookup -type=NS charlie-dshmobile.xyz 1.1.1.1
# 应看到 .ns.cloudflare.com
```

## 第二步：Cloudflare 建隧道

```bash
cd tools
./cloudflared.exe tunnel login          # 浏览器授权，选 charlie-dshmobile.xyz
./cloudflared.exe tunnel create dsh     # 创建隧道，记下 Tunnel ID
./cloudflared.exe tunnel route dns dsh dsh.charlie-dshmobile.xyz
```

生成的凭据在 `~/.cloudflared/<TunnelID>.json`。

## 第三步：写隧道配置文件

`~/.cloudflared/config.yml`：

```yaml
tunnel: <TunnelID>
credentials-file: C:\Users\Yanak\.cloudflared\<TunnelID>.json

ingress:
  - hostname: dsh.charlie-dshmobile.xyz
    service: http://127.0.0.1:3088
  - service: http_status:404
```

⚠️ `service` 指向 **3088**（bridge 端口），不是 7627。bridge 会自己做网页反代。

## 第四步：改 bridge 配置

`bridge/cordis.patch.yml`：

```yaml
publicUrl: 'https://dsh.charlie-dshmobile.xyz'
tunnel: off                                  # 关掉自动临时隧道
extraHosts:
  - dsh.charlie-dshmobile.xyz                # 否则公网访问 403
```

## 第五步：把 cloudflared 做成常驻服务

临时隧道由 bridge 自己拉起，但固定隧道要独立进程常驻：

```bash
# 测试
./cloudflared.exe tunnel --config ~/.cloudflared/config.yml run dsh

# 常驻（推荐用 nssm 或计划任务，开机自启）
```

## 第六步：验证

```bash
curl https://dsh.charlie-dshmobile.xyz/health
# {"ok":true,"service":"dshremote-bridge",...}
```

手机 App 里「隧道地址」填 `https://dsh.charlie-dshmobile.xyz`，token 不变。

## 完成后的效果

- ✅ 地址永久固定，重启 DSH 不用改
- ✅ 自动 HTTPS（Cloudflare 签发证书）
- ✅ 不再需要「隧道地址推送微信」的定时任务（已删除）
- ✅ 家人也能用同一个域名（各自 token 或各自子域）

## 排查

| 现象 | 原因 | 处理 |
|---|---|---|
| 522 / 1033 | cloudflared 没跑或配置错 | 看 cloudflared 日志 |
| 403 | `extraHosts` 没加域名 | 补进 cordis.patch.yml 并重启 |
| 502 | 上游 3088 没监听 | 检查 bridge 是否加载 |
| DNS 查不到 | NS 未生效 | 等，或用 `dig +trace` 追 |
