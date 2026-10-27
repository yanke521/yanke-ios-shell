# WebView 套壳指南：没有 Mac 也能把网页变成 iOS App

把任何一个已经跑着的网页，装进一个全屏 WKWebView 壳里，变成手机上一个正经的 app 图标。

**全程不需要 Mac、不需要 Xcode、不需要 $99 开发者账号。**

构建在 GitHub Actions 的 macOS runner 上跑（公开仓库免费），
签名交给全能签/轻松签这类第三方工具，装完跟原生 app 一模一样。

---

## 这东西适合谁

### 最适合的

- **个人项目 / 情侣 app / 小工具**：自己写了个网页，想在手机上有个图标、全屏打开、没有浏览器的地址栏和工具栏
- **已经有一个能跑的 web app**（部署在 VPS / Vercel / Cloudflare Pages 上都行），只是嫌 Safari 里用着不像 app
- **用 PWA 但被 iOS 的限制恶心到了**：底部灰带、顶部状态栏颜色对不上、`viewport-fit=cover` 开了顶上好了底下又冒出来——这些都是浏览器画的，网页够不着，原生壳里根因消失
- **想折腾但没有 Mac 也不想花钱**：你只需要一个 GitHub 账号

### 也能用但要知道代价

- **需要推送通知的**：壳里收不到 Web Push（iOS 只给「加到主屏幕的 PWA」），也拿不到 APNs（需要 $99 开发者账号 + 你自己的签名证书）。解法是壳和 PWA 并存——壳用来看，PWA 收通知
- **多人使用的小团队工具**：分发靠全能签，证书掉签了要重装。用的人多的话这个摩擦会被放大

### 不适合的

- **要上 App Store 的产品**：本方案出的是无签名 IPA，走不了 App Store 审核流程。上架需要 $99 账号 + 正式签名 + 审核合规
- **重度依赖原生能力的**：蓝牙、NFC、后台定位、系统级通知、小组件这些 WKWebView 给不了。需要写原生代码桥接，那已经不是"套壳"了
- **对安全性有严格要求的**：全能签用的是共享企业证书，你的 app 和几千个别人的 app 共用一张证书。这意味着理论上证书持有者能对你的包做手脚。个人项目无所谓，正经产品别这么干

---

## 它解决了什么问题

PWA（加到主屏幕）在 iOS 上有几个绕不过去的毛病，全是 Safari/WebKit 的限制：

| 问题 | 原因 | 原生壳里 |
|---|---|---|
| 底部 47px 灰带 | `viewport-fit=cover` 关了的代价 | WebView 铺满全屏，没有灰带 |
| 顶部状态栏颜色不跟主题走 | Safari 自己画的，`theme-color` 管不到 | 壳里读 `<meta theme-color>` 控制 |
| 重启后重新加载、没有缓存 | PWA 的 Service Worker 在某些条件下会丢 | App-Bound Domains 保证 SW 常驻 |
| `confirm()` 不弹窗直接返回 false | WKWebView 默认不实现 JS 弹窗 | 壳里手动接了三个弹窗方法 |
| 后台切回来白屏 | WebKit 回收了渲染进程 | 壳里检测到就自动重载 |

**核心原理**：那些毛病不是网页的 bug，是浏览器画的 UI 碰到网页产生的缝隙。
原生壳里没有浏览器那层 UI，缝隙的根因就不存在了。

---

## 项目结构

```
├── Sources/
│   ├── AppDelegate.swift        # 起窗口，设启动底色
│   └── WebViewController.swift  # WebView 本体：全屏铺满、主题跟随、外链拦截、断网兜底
├── Resources/
│   ├── Info.plist               # 权限说明、竖屏锁定、App-Bound Domains
│   └── Assets.xcassets/         # 应用图标
├── project.yml                  # XcodeGen 工程描述（代替 .xcodeproj）
└── .github/workflows/
    └── build-ipa.yml            # GitHub Actions 自动构建
```

总共两个 Swift 文件，加起来不到 300 行。

---

## 怎么用（从零开始）

### 第 0 步：你需要准备什么

- 一个能访问的网页 URL（比如 `https://your-app.example.com`）
- 一个 GitHub 账号
- 一个 1024x1024 的 app 图标（PNG，**不能有透明通道**，必须是 RGB）
- 手机上装一个签名工具（全能签 / 轻松签 / 牛蛙助手，任选）

### 第 1 步：Fork 这个仓库

点右上角 Fork。**仓库必须是 Public**——公开仓库的 macOS runner 免费无限用，
私有仓库按 10 倍计费（Free 档 2000 分钟 ÷ 10 = 200 分钟，每次构建 3~5 分钟，也够用几十次，但没必要花这个钱）。

### 第 2 步：改成你的 app

需要改的地方，一共就这几个：

**`Sources/WebViewController.swift`**
```swift
// 把这行改成你的网页地址
private static let homeURL = URL(string: "https://your-app.example.com")!
```

**`project.yml`**
```yaml
options:
  bundleIdPrefix: com.yourname    # 改成你的（格式随意，全能签会覆盖）

targets:
  YourApp:                        # 改成你的 app 名
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.yourname.yourapp
        PRODUCT_NAME: YourApp     # 会显示在手机上的名字
```

**`Resources/Info.plist`**
```xml
<!-- 改显示名 -->
<key>CFBundleDisplayName</key>
<string>你的App名</string>

<!-- 改域名（App-Bound Domains，让 Service Worker 能用） -->
<key>WKAppBoundDomains</key>
<array>
    <string>your-app.example.com</string>
</array>

<!-- 不需要的权限可以删掉。但如果你的网页会用到相机/相册/定位，
     这些说明必须留着——漏了不是弹窗被拒，是点下去直接闪退 -->
```

**`Resources/Assets.xcassets/`**
替换 AppIcon。图标必须是 1024x1024 不透明 PNG。

### 第 3 步：出包

推到 GitHub 之后，Actions 自动跑。也可以去 Actions 页面手动点 "Run workflow"。

跑完（通常 3~5 分钟）在 Artifacts 里下载 `YanKe-unsigned.ipa`。

想要一个**永久直链**（签名工具可以直接填 URL）就打 tag：

```bash
git tag v1.0 && git push --tags
```

Releases 页面会自动挂一个 `.ipa` 文件，链接格式是：
`https://github.com/你的用户名/你的仓库/releases/download/v1.0/YourApp-unsigned.ipa`

### 第 4 步：签名安装

把 `.ipa` 文件喂给全能签（或其他签名工具），签完装到手机上。完事。

以后网页改了**不用重新打包**——壳加载的是远程 URL，刷新就是最新的。
只有改了壳本身（Swift 代码 / 图标 / Info.plist）才需要重新走一遍 Actions。

---

## 踩过的坑（省你几天）

### 构建相关

| 坑 | 现象 | 原因和解法 |
|---|---|---|
| 签名报错 | `requires a development team` | `CODE_SIGN_IDENTITY` / `CODE_SIGNING_REQUIRED` / `CODE_SIGNING_ALLOWED` / `CODE_SIGN_ENTITLEMENTS` 四个必须**全关**，少一个就报 |
| 图标报错 | `The app icon set has an unassigned child` | 源图带了 alpha 通道（透明背景）。用 `sips -s format png --setProperty formatOptions nointerlace -s hasAlpha false icon.png` 去掉 |
| tag 推了但没出 Release | Actions 没跑 | `on.push` 要同时监听 `branches` 和 `tags`；而且 `paths` 过滤**不能和 `tags` 混用**——tag 指向的 commit 已在 main 上，算不出改了什么文件，会静默跳过 |
| 改了代码推了但手机上没变 | 她装的还是旧包 | 推到 main **只编译不发 Release**。必须打 tag 才会更新 Release 附件。`git tag vX.Y && git push --follow-tags` |

### 壳里的行为差异

| 坑 | 现象 | 原因和解法 |
|---|---|---|
| confirm() 点了没反应 | 按钮看着正常，点了什么都不发生 | WKWebView **默认不实现** `WKUIDelegate` 的三个 JS 弹窗方法。`alert` 静默丢弃，`confirm` 直接返回 `false`。必须手动实现（本项目已做） |
| 内容钻进刘海 / 状态栏 | 顶部元素被遮挡 | 壳里开了 `viewport-fit=cover` 后，`position:absolute` 的子元素**吃不到父级的 `padding-top`**。每个绝对定位的按钮都要自己加 `env(safe-area-inset-top)` |
| 后台切回来白屏点不动 | 整个页面空白 | WebKit 的渲染进程被系统回收了（后台挂久 + 内存紧张）。`webView.url` 还在但内容没了。必须接 `webViewWebContentProcessDidTerminate` 然后 reload |
| localStorage 跟 PWA 不通 | 壳里设的主题 / 头像 PWA 里看不到 | 壳和 PWA 是两个独立的 WebView 数据容器。如果需要同步，让服务端存一份，两边都去读 |
| 重签 / 掉签重装后设置全丢 | 好不容易设的东西全没了 | 重签会清空整个 app 容器，包括 localStorage。同上：重要的状态存服务端 |
| 冷启动比 PWA 还慢 | 每次打开都重新加载 | 默认 WKWebView 不跑 Service Worker。需要在 Info.plist 声明 `WKAppBoundDomains` + 代码里设 `limitsNavigationsToAppBoundDomains = true`，两个缺一不可，且缺了**不报错**，静默失效 |

### 权限相关

| 坑 | 现象 | 原因和解法 |
|---|---|---|
| 相机/相册/麦克风点了闪退 | 不是弹窗被拒，是直接 crash | Info.plist 里漏了对应的 `UsageDescription`。WKWebView 把网页的权限请求转成 app 的，缺说明 = crash |
| 定位回调不触发 | 没弹授权窗、也没报错 | 同上——漏了 `NSLocationWhenInUseUsageDescription`，是**静默失败**（回调永远不触发）。网页那侧怎么写 `navigator.geolocation` 都没用，权限要从壳这边声明 |

### GitHub Token 权限

如果你用 Fine-Grained Personal Access Token 推代码：

- 推 `.github/workflows/` 下的文件需要 **Workflows: Read and write** 权限（否则报 `refusing to allow a Personal Access Token to create or update workflow`）
- 发 Release 需要 **Contents: Write** 权限（workflow 里 `permissions: contents: write` 只管 `GITHUB_TOKEN`，不管你本地推的那个 token）

---

## 进阶：想让壳做更多

这个壳是**最小可用版本**——只做"全屏打开一个网页"。但 WKWebView 能做的远不止这些：

| 想要 | 怎么做 | 需要 |
|---|---|---|
| 壳里也能收推送 | 接 APNs，前端通过 `window.webkit.messageHandlers` 桥接 | $99 开发者账号 + 自己的签名证书 |
| 原生定位（后台也能跑） | CoreLocation + 后台模式 | $99 开发者账号 |
| 锁屏小组件 | WidgetKit，纯原生新写 | $99 开发者账号 |
| 分发到 TestFlight | 正式签名 + 上传到 App Store Connect | $99 开发者账号 |

注意模式：**所有进阶功能都需要 $99 开发者账号**。但好消息是现有代码不用重写——
它就是一个正经的原生 app，只是换张签名证书。构建仍然可以走 GitHub Actions，不需要 Mac。

---

## 本地开发（如果你有 Mac）

```bash
brew install xcodegen
xcodegen generate
open YanKe.xcodeproj
```

`.xcodeproj` 不进版本库——它是从 `project.yml` 生成的。直接改 `project.yml`，推上去 CI 会自动生成。

---

## 常见问题

**Q: 网页改了要重新打包吗？**
不用。壳加载的是远程 URL，改完网页刷新就是最新的。只有改了 Swift 代码 / 图标 / Info.plist 才需要重新出包。

**Q: 掉签了怎么办？**
重新签一次就行。但 localStorage 会被清空，所以重要数据别只存前端。

**Q: 支持 iPad 吗？**
`project.yml` 里 `TARGETED_DEVICE_FAMILY: "1"` 是只做 iPhone。改成 `"1,2"` 就同时支持 iPad。但 iPad 上的布局你可能要单独适配。

**Q: 支持 Android 吗？**
这个项目只做 iOS。Android 上直接用 PWA 就行——Chrome 对 PWA 的支持比 Safari 好得多，没有上面说的那些毛病。如果一定要壳，用 Android Studio 的 WebView 模板，比 iOS 简单得多（不需要签名工具，adb install 就能装）。

**Q: 为什么用 XcodeGen 而不是直接提交 .xcodeproj？**
`.xcodeproj` 里面是个几百行的 `pbxproj` 文件，手改容易出错，冲突起来没法看。`project.yml` 二十多行，可读可改，CI 上 `xcodegen generate` 一条命令还原。

---

## License

MIT
