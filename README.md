# 言克 · iOS 原生壳

把 https://yanke521.xyz 装成一个真 app。壳只是个全屏 WKWebView——
**前端还是那份 `index.html`，改完刷新即生效，不用重新打包。**

## 为什么要它

Safari/PWA 那边「顶上粉白条」和「底下 47px 灰带」是一体两面：
`viewport-fit=cover` 开着消掉顶上的、底下就冒出来，关掉反过来。
根因是那两块由浏览器画、网页够不着。原生壳里那两块归 WKWebView 自己画，
所以能两头都干净。

## 代价（先知道再用）

**推送会没。** Web Push 在 iOS 上只给「加到主屏幕的 web app」，
WKWebView 里拿不到；而共享企业证书重签出来的包也拿不到 APNs 权限。
所以装了这个壳之后，克主动找你、早安晚安、天气、vigil 值班的推送**一条都收不到**。

→ **建议主屏幕上的 PWA 别删**，两个并存：PWA 收通知，壳用来看。
指向同一个服务器同一份数据，不冲突。

## 怎么出包（不需要 Mac）

1. 推到 GitHub
2. Actions → 「打包 IPA」→ Run workflow
3. 跑完在下面 Artifacts 里下 `YanKe-unsigned-ipa`
4. 解压得到 `YanKe-unsigned.ipa`，喂给全能签签名安装

想要直链（全能签可以直接填 URL）就打个 tag：

```bash
git tag v1.0 && git push --tags
```

Release 里会挂一个 `YanKe-unsigned.ipa` 直接能下。

## 本地改（有 Mac 的话）

```bash
brew install xcodegen
xcodegen generate
open YanKe.xcodeproj
```

`.xcodeproj` 不进版本库——它是 `project.yml` 生成的，手改容易冲突。

## 文件

| 路径 | 干什么 |
|---|---|
| `Sources/AppDelegate.swift` | 起窗口，设启动底色（防深色主题闪白） |
| `Sources/WebViewController.swift` | WebView 本体：全出血、主题色跟随、外链去 Safari、断网兜底 |
| `Resources/Info.plist` | 竖屏锁定、相机/相册权限说明 |
| `project.yml` | XcodeGen 工程描述 |

## 几个已经踩平的点

- **无签名构建**要把 `CODE_SIGN_IDENTITY` / `CODE_SIGNING_REQUIRED` /
  `CODE_SIGNING_ALLOWED` / `CODE_SIGN_ENTITLEMENTS` 四个一起关，
  少关一个 xcodebuild 就去找 provisioning profile 然后失败
- **AppIcon 不能带 alpha 通道**，源图必须是 RGB
- **相机/相册权限说明漏了会崩**——不是弹窗被拒，是点下去那一刻直接闪退
- `contentInsetAdjustmentBehavior = .never` + `underPageBackgroundColor`
  才是灰带消失的关键，只做前一个回弹时还是会露白
- localStorage 里存着头像/主题/bgSettings，`websiteDataStore` 必须是 `.default()`
  （持久化），换 `.nonPersistent()` 每次冷启动全白给
