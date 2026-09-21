import UIKit
import AVFoundation

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                     [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        configureAudio()
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = WebViewController()
        // 窗口底色 = 首屏背景色。壳启动到网页画出来之间有几百毫秒，
        // 这段时间露出来的就是它——留默认白的话深色主题下会闪一下白。
        w.backgroundColor = Theme.launchBackground
        window = w
        w.makeKeyAndVisible()
        return true
    }

    /// 侧边那个静音拨杆拨上去之后，壳里的朗读（长按气泡 → 朗读）就一声不吭。
    /// WKWebView 默认走的 audio session 是 `.soloAmbient` —— 那一档的定义就是
    /// 「跟着静音键走」。iPhone 上**只有 `.playback` 这一档不理静音键**。
    /// 网页那侧改不了：JS 够不着 audio session，所以这个只能在壳里修。
    ///
    /// `.mixWithOthers` 不能省：不加的话，她一开言克，正在听的歌／播客会被直接掐断
    /// （`.playback` 默认是独占的）。加上就只是叠着播，她的音乐不受影响。
    private func configureAudio() {
        do {
            try AVAudioSession.sharedInstance()
                .setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // 失败了就维持系统默认（静音键下没声音），不值得为这个崩掉整个 app
        }
    }
}

enum Theme {
    /// manifest.json 里的 background_color。改主题不用动这儿——
    /// 网页一加载出来 underPageBackgroundColor 就接管了。
    static let launchBackground = UIColor(red: 0xFA / 255.0,
                                          green: 0xF8 / 255.0,
                                          blue: 0xF5 / 255.0,
                                          alpha: 1.0)
}
