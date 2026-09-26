import UIKit
import WebKit
import Network
import AudioToolbox

/// 言克 app 的原生壳。
///
/// 它只做一件事：把 https://yanke521.xyz 全屏铺满，铺到状态栏和 Home 指示条底下去。
/// 前端还是那份 index.html，改完刷新即生效，**壳不用重新打包**。
///
/// 为什么要有这个壳：Safari/PWA 那边「顶上粉白条」和「底下 47px 灰带」是一体两面，
/// viewport-fit=cover 开着消掉顶上的、底下就冒出来，关掉反过来（见记忆
/// project-ios-canvas-safearea-wallpaper）。根因是那两块由浏览器画、网页够不着。
/// 原生壳里那两块归 WKWebView 自己画，所以能两头都干净。
final class WebViewController: UIViewController {

    private static let homeURL = URL(string: "https://yanke521.xyz")!

    private var webView: WKWebView!
    /// 只在网页是旧版（没有 __ykKb）时才用：退回「原生把 WebView 缩到键盘上沿」。
    private var webBottom: NSLayoutConstraint!
    private var themeObservation: NSKeyValueObservation?
    private var statusBarStyle: UIStatusBarStyle = .darkContent
    private lazy var errorView = ErrorView { [weak self] in self?.loadHome() }
    private let netMonitor = NWPathMonitor()
    private let netQueue = DispatchQueue(label: "xyz.yanke521.net")

    // MARK: - 生命周期

    override func loadView() {
        let config = WKWebViewConfiguration()

        // 默认就是持久化的，但写明白：她的头像、主题、bgSettings 全在 localStorage 里，
        // 换成 nonPersistent 每次冷启动都会白给。
        // ⚠ 也是下面 app-bound 的前提：非持久化 store 里 Service Worker 一样不给用。
        config.websiteDataStore = .default()

        // ★ 打开 Service Worker（2026-08-17）。
        // WKWebView 默认不提供 SW API，所以 index.html 里那句 register('/sw.js')
        // 在壳里从来没成功过 —— 这就是她说的「退出重进要重新加载、还没 PWA 快」：
        // 壳这边每次冷启动都是零缓存，1190KB 全走网络；PWA 那边有 SW 兜着。
        // 配对使用：Info.plist 的 WKAppBoundDomains 列域名，这里把导航锁在那些域上。
        // 只设一个不生效，且不会有任何报错 —— 它是静默失效的。
        config.limitsNavigationsToAppBoundDomains = true

        // TTS 语音、贴纸动图要能自动播，不然每次都得点一下
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // 版本号从 Info.plist 现读，**别再写死**：v1.1 那次写死成 "1.0"，结果装完
        // 没有任何办法从 app 里看出装的是哪一版（网页只拿得到 __YANKE_NATIVE__ 和 UA，
        // 两个都跟版本无关），只能去「设置 → iPhone 储存空间」翻。
        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"

        // 让前端能认出自己跑在壳里，并且知道是哪一版（/geo 探针会把它报出来）
        let flag = WKUserScript(
            source: "window.__YANKE_NATIVE__ = true; window.__YANKE_SHELL_VER__ = '\(ver)';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true)
        config.userContentController.addUserScript(flag)

        /* 震动（v1.7，2026-09-26 言言：「套壳 app 还是做不了手机震动吗」）。
           iOS 的 WebKit 压根没有 navigator.vibrate，前端那 9 处震动（点按钮、长按、
           扭蛋、计时器响…）在壳里一直是哑的，`if(navigator.vibrate)` 直接跳过，不报错。
           这里在 documentStart 给它补一个同名函数，转给原生马达——**前端一行不用改**，
           原来怎么调还怎么调。PWA/Safari 里没有这段，照旧是哑的。 */
        let vibrate = WKUserScript(
            source: """
            if (!navigator.vibrate) navigator.vibrate = function (p) {
              try { window.webkit.messageHandlers.haptic.postMessage(
                      Array.isArray(p) ? p.map(Number) : [Number(p) || 0]); } catch (e) {}
              return true;
            };
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true)
        config.userContentController.addUserScript(vibrate)
        config.userContentController.add(HapticHandler(), name: "haptic")

        // UA 尾巴加个标识，服务端想区分来源时不用猜（系统 UA 其余部分保留）
        config.applicationNameForUserAgent = "YanKeApp/\(ver)"

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        /* Safari 开发者工具能连上这个壳（iOS 16.4+）。
           留着它是因为：她那侧出的毛病（图片白、长按没菜单这类）在服务器上**怎么量都量不出来**
           ——壳的环境只有她手上那一台。关着的话，唯一的排查手段就是我猜、她试。
           只对连着线且信任的电脑开放，不是网页能自己打开的东西。 */
        if #available(iOS 16.4, *) { webView.isInspectable = true }

        /* ⚠ 必须是 true，别再关回去。这一个开关管的不只是链接预览——**长按图片的
           系统菜单（存储图像／拷贝／分享）也归它**，关掉之后壳里长按图片什么都不弹
           （2026-09-21 言言：「套壳app长按就不弹保存」）。PWA 和浏览器那边一直是好的，
           所以这是壳独有的毛病，查网页那侧永远查不出来。
           不用担心它会抢掉聊天气泡的长按菜单：`.msg` 那串带着 -webkit-touch-callout:none，
           气泡照旧走前端自己那套；图片没设，正好交给系统。 */
        webView.allowsLinkPreview = true

        // 侧滑返回关掉：这是个 SPA，浏览器历史跟她的 tab 不是一回事，
        // 侧滑很容易一下退到空白页。她自己那套横滑手势不受影响。
        webView.allowsBackForwardNavigationGestures = false

        // ── 这三行是「两头都干净」的关键 ──
        // 1) 内容不要被系统自动塞 inset，网页自己用 env(safe-area-inset-*) 算
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // 2) 回弹露出来的那块（以前的灰带）跟着页面主题色走，不再是写死的白/灰
        webView.underPageBackgroundColor = Theme.launchBackground
        // 3) webView 自己是透明的，底色由上面那个决定
        webView.isOpaque = false
        webView.backgroundColor = .clear

        let root = UIView()
        root.backgroundColor = Theme.launchBackground
        root.addSubview(webView)
        root.addSubview(errorView)

        // 铺满整个 window，**不避让安全区**——这正是要的效果
        webView.translatesAutoresizingMaskIntoConstraints = false
        errorView.translatesAutoresizingMaskIntoConstraints = false
        webBottom = webView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webBottom,
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            errorView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            errorView.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            errorView.leadingAnchor.constraint(greaterThanOrEqualTo:
                root.leadingAnchor, constant: 32),
        ])
        errorView.isHidden = true

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeThemeColor()
        takeOverKeyboard()
        loadHome()
        startNetworkWatch()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// 信号回来了自己重连，不用她去点那颗「重试」。
    ///
    /// 她报过一次「app 老是打不开」，查到最后根因是**手机当时没信号**
    /// （记忆 project-listen-backlog-app-unreachable）。那种情况下壳停在错误页上，
    /// 就算网络几秒后恢复了，页面也还是那张——得她自己想起来点一下。
    ///
    /// ⚠ 只在**当前正卡在错误页**时才重载。不看这个条件的话，通勤路上 Wi-Fi/蜂窝
    /// 来回切一次就刷一次页面，正打着的字全没了。
    private func startNetworkWatch() {
        netMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async {
                guard let self = self, !self.errorView.isHidden else { return }
                self.loadHome()
            }
        }
        netMonitor.start(queue: netQueue)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { statusBarStyle }

    // MARK: - 键盘（v1.6）

    /// 键盘由网页自己跟着走，WKWebView 那套摘掉。
    ///
    /// 2026-09-26 言言：「输入框跟键盘弹起做的不丝滑」。原来是 WKWebView 自己管键盘：
    /// 键盘一弹它先把**整页往上顶**好露出输入框，等键盘动画走完网页才收到 resize、
    /// 重排、再把页面滚回来——整页一窜、跳一下、归位，三下都不跟键盘同步。
    /// 网页那侧怎么改都够不着：它拿到消息的时候键盘已经弹完了。
    ///
    /// 做法照 Ionic 的 Capacitor Keyboard 插件：把 WKWebView 自己的键盘监听摘掉
    /// （它就不会再顶页面），改成**键盘刚要动**那一刻把「高度 + 动画时长」递给网页，
    /// 网页用同一段时长让输入框跟着走（index.html 里的 `__ykKb`）。
    ///
    /// ⚠ 摘掉之后，别的页面里被键盘挡住的输入框 WebKit 也不会替我们滚出来了——
    ///   那一段网页自己补了（`_kbReveal`）。
    /// ⚠ 网页是旧版、没有 `__ykKb` 的话，退回原生把 WebView 缩到键盘上沿，
    ///   不会出现键盘把输入框盖死还没法打字的情况。
    private func takeOverKeyboard() {
        let nc = NotificationCenter.default
        for name in [UIResponder.keyboardWillShowNotification,
                     UIResponder.keyboardDidShowNotification,
                     UIResponder.keyboardWillHideNotification,
                     UIResponder.keyboardDidHideNotification,
                     UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardDidChangeFrameNotification] {
            nc.removeObserver(webView!, name: name, object: nil)
        }
        nc.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                       name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let info = note.userInfo,
              let endScreen = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 7

        // 键盘帧是屏幕坐标，换成本 view 的再算盖住了底下多少。收起时它在屏幕外 → 0。
        let end: CGRect
        if let screen = view.window?.screen {
            end = view.convert(endScreen, from: screen.coordinateSpace)
        } else {
            end = view.convert(endScreen, from: nil)
        }
        let height = max(0, view.bounds.maxY - end.minY)
        let ms = Int((duration * 1000).rounded())

        let js = "typeof window.__ykKb==='function'?(window.__ykKb(\(Int(height.rounded())),\(ms)),1):0"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            if (result as? Int) == 1 {
                // 网页接住了；万一之前走过兜底，把 WebView 放回全屏
                if self?.webBottom.constant != 0 { self?.webBottom.constant = 0 }
                return
            }
            self?.nativeResize(height, duration: duration, curveRaw: curveRaw)
        }
    }

    /// 兜底：网页不认得 __ykKb（旧缓存 / 加载失败页），就原生缩 WebView。
    private func nativeResize(_ height: CGFloat, duration: Double, curveRaw: Int) {
        webBottom.constant = -height
        let opts = UIView.AnimationOptions(rawValue: UInt(curveRaw) << 16)
        UIView.animate(withDuration: duration, delay: 0, options: [opts, .beginFromCurrentState]) {
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - 加载

    private func loadHome() {
        errorView.isHidden = true
        // 2026-08-17 改回 .useProtocolCachePolicy。
        // 原来写 .reloadRevalidatingCacheData 是为了「她改完前端刷新即生效」，
        // 但那等于每次冷启动都强制回源验一遍首页，而且**这条 cachePolicy 会一路
        // 盖到子资源上**，跟 SW 的 cache-first 打架（SW 装上了照样每个文件一次往返）。
        // index.html 归 server.py 的 `_get_index` 发，带 ETag + Last-Modified + no-cache，
        // 协议缓存自己会 304，「改完即生效」不受影响；静态资源交给 sw.js 管。
        // ⚠ 2026-08-24 订正：这条注释原来写着"本来就是 no-cache + ETag"——**是错的**。
        // 当时实际发的是 `no-store` 且一个 ETag 都没有，等于"连存都不许存"，
        // 所以从打壳起每次冷启动都在全量重下 884KB，一次 304 都没命中过。已修。
        var req = URLRequest(url: Self.homeURL)
        req.cachePolicy = .useProtocolCachePolicy
        webView.load(req)
    }

    @objc private func appDidBecomeActive() {
        // 后台待久了 WebKit 可能把页面回收了，回来会是一片白。
        // 有 URL 说明还活着，什么都不做；没有就重新载。
        if webView.url == nil {
            loadHome()
        }
    }

    // MARK: - 主题色 → 状态栏

    /// 跟着 <meta name="theme-color"> 走。她有 6 个浅色 + 1 个深色「墨」，
    /// 切到墨的时候状态栏文字得跟着变白，否则黑底黑字看不见。
    private func observeThemeColor() {
        themeObservation = webView.observe(\.themeColor, options: [.new]) {
            [weak self] webView, _ in
            self?.applyThemeColor(webView.themeColor)
        }
    }

    private func applyThemeColor(_ color: UIColor?) {
        guard let color else { return }
        webView.underPageBackgroundColor = color   // 回弹露出来的那块跟着走
        view.backgroundColor = color
        let style: UIStatusBarStyle = color.isDark ? .lightContent : .darkContent
        guard style != statusBarStyle else { return }
        statusBarStyle = style
        setNeedsStatusBarAppearanceUpdate()
    }
}

// MARK: - 导航

extension WebViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        // 自己站内的、以及 data:/blob:（artifact 预览、图片下载）留在壳里
        let inApp = url.host == Self.homeURL.host
            || ["data", "blob", "about"].contains(url.scheme ?? "")
        if inApp {
            decisionHandler(.allow)
        } else {
            // 外链、tel:、mailto: 交给系统 —— 别让克发的链接把壳导航走了回不来
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        errorView.isHidden = true
        // KVO 负责「她在 app 里切主题」那种没有导航的变化；这一下负责首屏。
        // 两条都留着：只靠 KVO 的话，万一它对 themeColor 不触发，
        // 首屏状态栏就一直是错的，而这种错很难一眼看出来是哪儿的问题。
        applyThemeColor(webView.themeColor)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        show(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        show(error)
    }

    /// WebKit 的渲染进程被系统回收了（后台挂久了 + 内存紧张时很常见）。
    /// 这时 webView.url 还在、内容已经没了——不接这个回调，切回来就是一片白，
    /// 而且怎么点都不动。必须主动重载。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadHome()
    }

    private func show(_ error: Error) {
        // -999 是被新的导航取代，不是真失败，弹出来反而莫名其妙
        if (error as NSError).code == NSURLErrorCancelled { return }
        errorView.message = (error as NSError).localizedDescription
        errorView.isHidden = false
    }
}

// MARK: - window.open / JS 弹窗

extension WebViewController: WKUIDelegate {
    // 麦克风 / 相机（2026-09-26 v1.8，语音消息）：网页调 getUserMedia 时，WKWebView 默认
    // **每次启动**都再弹一次网页级授权——系统级那次（Info.plist 的 NSMicrophoneUsageDescription）
    // 只问一次，这一层是另外的。自家域名直接放行，外站照旧问。
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host == Self.homeURL.host ? .grant : .prompt)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            if url.host == Self.homeURL.host {
                webView.load(navigationAction.request)
            } else {
                UIApplication.shared.open(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let ac = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(ac, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let ac = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        ac.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(ac, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let ac = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        ac.addTextField { $0.text = defaultText }
        ac.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        ac.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completionHandler(ac.textFields?.first?.text)
        })
        present(ac, animated: true)
    }
}

// MARK: - 震动

/// 把 navigator.vibrate 的毫秒数翻译成 iPhone 的触感。
///
/// iPhone 没有「震 N 毫秒」这种接口，只有几档现成的手感，所以按时长分档：
/// - ≤ 8ms：选择反馈（最轻，像滚轮拨一格）—— 前端给所有按钮挂的就是 6ms
/// - ≤ 20ms：轻击；≤ 60ms：中击；≤ 140ms：重击
/// - 更长的（计时器响那种 200ms）：真马达长震，Taptic 那几档太短表达不了「响了」
/// 数组 [震, 停, 震, 停…] 按偶数位震、奇数位等，照原样排时间。
///
/// ⚠ 单独一个类、不让 WebViewController 自己当 handler：userContentController
///   会强持有 handler，拿 self 就是循环引用，控制器永远不释放。
private final class HapticHandler: NSObject, WKScriptMessageHandler {
    private let selection = UISelectionFeedbackGenerator()
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let raw = message.body as? [Any] else { return }
        let pattern = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
        var at = 0.0
        for (i, ms) in pattern.enumerated() where ms > 0 {
            if i % 2 == 0 {
                let delay = at / 1000
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.buzz(ms)
                }
            }
            at += ms
        }
    }

    private func buzz(_ ms: Double) {
        switch ms {
        case ..<9:    selection.selectionChanged()
        case ..<21:   light.impactOccurred()
        case ..<61:   medium.impactOccurred()
        case ..<141:  heavy.impactOccurred()
        default:      AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }
}

// MARK: - 断网时的兜底页

private final class ErrorView: UIView {
    private let label = UILabel()
    private let button = UIButton(type: .system)
    private let onRetry: () -> Void

    var message: String = "" {
        didSet { label.text = "连不上服务器\n\n\(message)" }
    }

    init(onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        super.init(frame: .zero)

        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabel

        button.setTitle("重试", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        button.addTarget(self, action: #selector(tap), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tap() { onRetry() }
}

private extension UIColor {
    /// 感知亮度，用来决定状态栏文字黑还是白
    var isDark: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        return (0.299 * r + 0.587 * g + 0.114 * b) < 0.6
    }
}
