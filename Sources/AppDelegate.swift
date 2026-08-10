import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                     [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = WebViewController()
        // 窗口底色 = 首屏背景色。壳启动到网页画出来之间有几百毫秒，
        // 这段时间露出来的就是它——留默认白的话深色主题下会闪一下白。
        w.backgroundColor = Theme.launchBackground
        window = w
        w.makeKeyAndVisible()
        return true
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
