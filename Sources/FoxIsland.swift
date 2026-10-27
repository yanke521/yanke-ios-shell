import UIKit
import WebKit
import ActivityKit

/// 小狐狸住在灵动岛上（v2.3）。
///
/// 免费账号没有 ActivityKit 推送，灵动岛上的东西只能由**活着的 app**来改。
/// 壳本来就靠 KeepAlive（后台放静音）一直活着等电话，顺手每 5 分钟拉一次 /widget
/// 把狐狸的姿势、心情、最新碎碎念推上去。
///
/// iOS 的边界写在这儿：
/// - 实时活动有寿命（系统过几个小时会自己收掉）、她能在锁屏上划掉、重启就没——
///   **这三件都不会通知 app**。所以每次回前台都核对一遍，没了就重新挂。
/// - 她把 app 从后台划掉 = 狐狸停在最后那个样子，直到系统收掉它。
final class FoxIsland {
    static let shared = FoxIsland()

    weak var webView: WKWebView?
    private var timer: Timer?
    private let base = URL(string: "https://yanke521.xyz/widget")!

    func start() {
        guard #available(iOS 16.2, *) else { return }
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// 回前台：核对它还在不在，顺便拉一次新的
    func appDidBecomeActive() { if #available(iOS 16.2, *) { refresh() } }

    @available(iOS 16.2, *)
    private func refresh() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { all in
            let mine = all.filter { $0.domain.hasSuffix("yanke521.xyz") }
            var req = URLRequest(url: self.base)
            req.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: mine)
            req.timeoutInterval = 20
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                let moods = (obj["mood"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                let murmur = (obj["murmurs"] as? [[String: Any]])?.first?["text"] as? String
                let state = FoxAttributes.ContentState(
                    pose: obj["pose"] as? String ?? "idle",
                    mood: moods.isEmpty ? "平静" : moods.prefix(2).joined(separator: " · "),
                    line: murmur ?? (obj["intent"] as? String) ?? "")
                Task { await self.push(state) }
            }.resume()
        }
    }

    @available(iOS 16.2, *)
    private func push(_ state: FoxAttributes.ContentState) async {
        let content = ActivityContent(state: state, staleDate: nil)   // 桌宠没有「过期」这回事，别设 staleDate（会被画灰）
        let live = Activity<FoxAttributes>.activities
        // 多出来的收掉，不然灵动岛上会有两只
        for extra in live.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
        if let a = live.first, a.activityState == .active {
            await a.update(content)
            return
        }
        // 只能在前台起新的（后台 request 会被系统拒）
        let fg = await MainActor.run { UIApplication.shared.applicationState == .active }
        guard fg else { return }
        _ = try? Activity.request(attributes: FoxAttributes(), content: content, pushType: nil)
    }
}
