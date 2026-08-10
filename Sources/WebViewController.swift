import UIKit
import WebKit

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
    private var themeObservation: NSKeyValueObservation?
    private var statusBarStyle: UIStatusBarStyle = .darkContent
    private lazy var errorView = ErrorView { [weak self] in self?.loadHome() }

    // MARK: - 生命周期

    override func loadView() {
        let config = WKWebViewConfiguration()

        // 默认就是持久化的，但写明白：她的头像、主题、bgSettings 全在 localStorage 里，
        // 换成 nonPersistent 每次冷启动都会白给。
        config.websiteDataStore = .default()

        // TTS 语音、贴纸动图要能自动播，不然每次都得点一下
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // 让前端能认出自己跑在壳里（想针对性调样式的时候用得上，现在没用也留着）
        let flag = WKUserScript(
            source: "window.__YANKE_NATIVE__ = true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true)
        config.userContentController.addUserScript(flag)

        // UA 尾巴加个标识，服务端想区分来源时不用猜（系统 UA 其余部分保留）
        config.applicationNameForUserAgent = "YanKeApp/1.0"

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false

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
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
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
        loadHome()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { statusBarStyle }

    // MARK: - 加载

    private func loadHome() {
        errorView.isHidden = true
        // 用 reloadIgnoringLocalCacheData 语义：她改完前端刷新即生效，
        // 壳这边别把旧 index.html 缓存住，否则会出现"改了没变"的灵异事件。
        var req = URLRequest(url: Self.homeURL)
        req.cachePolicy = .reloadRevalidatingCacheData
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

    private func show(_ error: Error) {
        // -999 是被新的导航取代，不是真失败，弹出来反而莫名其妙
        if (error as NSError).code == NSURLErrorCancelled { return }
        errorView.message = (error as NSError).localizedDescription
        errorView.isHidden = false
    }
}

// MARK: - window.open / 新窗口

extension WebViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank 没有新窗口可开，就地导航；外链会被上面那道策略拦去 Safari
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            if url.host == Self.homeURL.host {
                webView.load(navigationAction.request)
            } else {
                UIApplication.shared.open(url)
            }
        }
        return nil
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
