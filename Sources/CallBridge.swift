import UIKit
import WebKit
import CallKit
import AVFoundation

/// 克打电话来 → 系统来电界面（v2.0，2026-10-26）。
///
/// 正经做法是 PushKit 的 VoIP 推送叫醒 app 再弹 CallKit，但那要 $99 开发者账号。
/// 换成七天自签（SideStore）之后，CallKit 本身是能用的，缺的只是「被杀掉之后谁来叫醒」。
/// 所以反过来：**不让它被杀**（KeepAlive 后台放静音），自己挂着 /call/wait 长轮询等电话。
///
/// 代价写在这儿别忘了：
/// - 她从后台把 app 划掉 = 收不到。锁屏、切别的 app 不影响。
/// - 系统内存紧的时候照样可能被回收，没有补救。
///
/// 来电这一程：
///   server `call.ring` → /call/wait 返回 ringing → 这里 reportNewIncomingCall（锁屏整屏来电）
///   她接 → 这里替网页 POST /call/answer（不然 40 秒一到服务器判「没接」、还会去留语音）
///         → 她点开 app 回到前台 → 收掉 CallKit 那通 → 调网页 `YKCall.nativeAnswer(id)` 开麦进通话
///   她挂 → POST /call/decline
/// 通话本身还是网页那套（iOS 后台网页拿不到麦克风，所以必须回到前台才算接通）。
final class CallBridge: NSObject {
    static let shared = CallBridge()

    weak var webView: WKWebView?

    private let base = URL(string: "https://yanke521.xyz")!
    private let provider: CXProvider
    private let session: URLSession
    private var polling = false
    private var ver = -1

    // CallKit 里正在响/正接着的那一通
    private var callID: String?
    private var callUUID: UUID?
    private var answered = false
    /// 系统界面里接了、还没回到 app 进通话的那一通。跟 callID 分开：
    /// 交给网页时 CallKit 那通先收掉（callID 清空），这个还得留着等网页接住。
    private var joinID: String?
    private var lostTimer: Timer?
    /// 弹过的不再弹（长轮询每次变化都会把当前状态再给一遍）
    private var seen = Set<String>()

    private override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic]
        // 不进系统「电话 → 最近通话」：从那儿点回拨会去找一个不存在的拨号流程
        cfg.includesCallsInRecents = false
        provider = CXProvider(configuration: cfg)

        let sc = URLSessionConfiguration.default
        sc.timeoutIntervalForRequest = 40      // 服务端最多挂 25 秒
        sc.httpShouldSetCookies = false        // cookie 每次从 WebView 那份现拿，见 withCookies
        sc.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: sc)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    // MARK: - 外面调的

    func start() {
        guard !polling else { return }
        polling = true
        poll()
    }

    func appDidBecomeActive() {
        // 系统来电还在响、她没接就自己点开了 app：交给网页那份来电界面（它会去问 /call/state）
        if callID != nil && !answered {
            endLocally(.answeredElsewhere)
            webView?.evaluateJavaScript("window.YKCall&&YKCall.check()")
        }
        if joinID != nil {
            if callID != nil { endLocally(.answeredElsewhere) }
            // CallKit 那通收掉后系统要把音频会话还回来，等一下再让网页开麦
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.tryJoin() }
        }
    }

    /// 页面（重新）加载完：进程被回收过的话，前台回调那次网页还没准备好
    func webDidFinish() {
        guard joinID != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.tryJoin() }
    }

    // MARK: - 长轮询

    private func poll() {
        withCookies { headers in
            var req = URLRequest(url: URL(string: "/call/wait?ver=\(self.ver)", relativeTo: self.base)!)
            req.allHTTPHeaderFields = headers
            self.session.dataTask(with: req) { data, resp, _ in
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                DispatchQueue.main.async {
                    if ok, let obj { self.handle(obj) }
                    // 断网 / 没登录（门口回 404 页）：别原地猛刷，歇一会儿再来
                    let delay: Double = (ok && obj != nil) ? 0 : 10
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.poll() }
                }
            }.resume()
        }
    }

    private func handle(_ s: [String: Any]) {
        if let v = s["ver"] as? Int { ver = v }
        let id = s["id"] as? String ?? ""
        let status = s["status"] as? String ?? ""
        let at = s["at"] as? Double ?? 0

        if status == "ringing", s["dir"] as? String == "in", !id.isEmpty, !seen.contains(id),
           Date().timeIntervalSince1970 - at < 45 {
            seen.insert(id)
            // app 开着的时候网页自己会响（/sync 推过去），不再叠一层系统来电
            if UIApplication.shared.applicationState != .active {
                reportIncoming(id: id)
            }
            return
        }
        // 还在响，服务器那头已经不响了（40 秒到了 / 网页里按掉了）
        if let cid = callID, !answered, id != cid || status != "ringing" {
            endLocally(id == cid && status == "missed" ? .unanswered : .remoteEnded)
        }
        // 接了没进 app，这通在服务器上已经结束了（比如 lostTimer、或别处挂了）
        if let j = joinID, id != j || status != "active" {
            joinID = nil
            lostTimer?.invalidate()
            if callID != nil { endLocally(.remoteEnded) }
        }
    }

    // MARK: - CallKit

    private func reportIncoming(id: String) {
        let uuid = UUID()
        let up = CXCallUpdate()
        up.remoteHandle = CXHandle(type: .generic, value: "克")
        up.localizedCallerName = "克"
        up.hasVideo = false
        up.supportsHolding = false
        up.supportsGrouping = false
        up.supportsUngrouping = false
        up.supportsDTMF = false
        callID = id
        callUUID = uuid
        answered = false
        provider.reportNewIncomingCall(with: uuid, update: up) { err in
            guard let err else { return }
            DispatchQueue.main.async {
                if self.callUUID == uuid { self.callID = nil; self.callUUID = nil }
                // 弹不出来（勿扰/专注模式、或者地区限制）：在服务器 access.log 里留个记号，排查时一 grep 就知道
                let code = (err as NSError).code
                self.withCookies { h in
                    var r = URLRequest(url: URL(string: "/call/state?callkit_err=\(code)", relativeTo: self.base)!)
                    r.allHTTPHeaderFields = h
                    self.session.dataTask(with: r).resume()
                }
            }
        }
    }

    /// 自己收掉 CallKit 那通（不经过 delegate，所以不会通知服务器）
    private func endLocally(_ reason: CXCallEndedReason) {
        if let uuid = callUUID { provider.reportCall(with: uuid, endedAt: nil, reason: reason) }
        callID = nil
        callUUID = nil
        answered = false
    }

    private func tryJoin() {
        guard let id = joinID, let web = webView else { return }
        let safe = id.filter { $0.isLetter || $0.isNumber }
        let js = "window.YKCall&&YKCall.nativeAnswer?(YKCall.nativeAnswer('\(safe)'),1):0"
        web.evaluateJavaScript(js) { r, _ in
            if (r as? Int) == 1 {
                self.joinID = nil
                self.lostTimer?.invalidate()
            }
        }
    }

    // MARK: - 网络

    /// 门口那道 yk_auth 是 HttpOnly cookie，存在 WebView 的数据容器里，URLSession 自己那份是空的
    private func withCookies(_ then: @escaping ([String: String]) -> Void) {
        DispatchQueue.main.async {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { all in
                let host = self.base.host ?? ""
                let mine = all.filter {
                    let d = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
                    return host == d || host.hasSuffix("." + d)
                }
                then(HTTPCookie.requestHeaderFields(with: mine))
            }
        }
    }

    private func post(_ path: String, _ body: [String: Any]) {
        withCookies { headers in
            var r = URLRequest(url: URL(string: path, relativeTo: self.base)!)
            r.httpMethod = "POST"
            r.allHTTPHeaderFields = headers
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            self.session.dataTask(with: r).resume()
        }
    }
}

extension CallBridge: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        callID = nil
        callUUID = nil
        answered = false
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let id = callID else { action.fail(); return }
        answered = true
        joinID = id
        action.fulfill()
        post("/call/answer", ["id": id])
        // 接了但一直没回 app（接完手机又扔下了）：90 秒后当断了，别让服务器一直挂着「通话中」
        lostTimer?.invalidate()
        lostTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
            guard let self, self.joinID == id else { return }
            self.joinID = nil
            self.post("/call/end", ["id": id, "sec": 0, "by": "lost"])
            self.endLocally(.failed)
        }
        if UIApplication.shared.applicationState == .active { appDidBecomeActive() }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        guard let id = callID else { return }
        if answered {
            // 系统界面里接了又挂了，没进 app
            joinID = nil
            lostTimer?.invalidate()
            post("/call/end", ["id": id, "sec": 0, "by": "her"])
        } else {
            post("/call/decline", ["id": id, "why": ""])
        }
        callID = nil
        callUUID = nil
        answered = false
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // 电话那套把音频会话收走了，保活的静音得重新放起来，不然过一会儿 app 就被挂起
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { KeepAlive.shared.start() }
    }
}

/// 后台不被挂起：放一段循环的静音。
///
/// 需要 Info.plist 的 UIBackgroundModes = audio。共享企业证书/七天自签都能用，不要 entitlement。
/// `.mixWithOthers`（AppDelegate.configureAudio 设的）让它不打断她自己在听的歌。
/// 会被打断的情况：真电话、别的 app 抢独占音频、网页里的声音把会话关了——
/// 所以打断结束、切后台、回前台都再拉一次。
final class KeepAlive {
    static let shared = KeepAlive()
    private var player: AVAudioPlayer?

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.ended.rawValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start() }
            }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            self.player = nil
            self.start()
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            self.start()
        }
    }

    func start() {
        if player == nil {
            player = try? AVAudioPlayer(data: Self.silence())
            player?.numberOfLoops = -1
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        if player?.isPlaying != true { player?.play() }
    }

    /// 1 秒 8kHz 16bit 单声道的全零 WAV，现做，不往包里塞文件
    private static func silence() -> Data {
        let rate: UInt32 = 8000, bytes = rate * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        d.append(Data(count: Int(bytes)))
        return d
    }
}
