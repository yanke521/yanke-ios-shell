import WidgetKit
import SwiftUI
import AppIntents

// 桌面小组件（v2.2）：克现在的心情 + 最近几条碎碎念。
//
// 钥匙为什么要她自己粘：小组件是独立进程，拿不到壳里 WebView 的 cookie；
// 两边共享数据要 App Group，而 SideStore 重签时会改 group 的名字，一改就对不上、
// 而且是静默读空。钥匙又不能打进包里（仓库公开）。所以走 iOS 17 的可编辑小组件：
// 长按 → 编辑小组件 → 粘贴登录链接，系统替它记着。
// 拿到钥匙就自己带 `Cookie: yk_auth=<钥匙>` 去敲 /widget，门口 nginx 照常验。
//
// v2.5：样子（背景图/雾/字色/显示哪几块）由她在言言那边改（server 的 widget_style.py），
// 跟数据一起回来，不用重新打包。背景图按 bg_ver 缓存在本机，没换就不重下。

struct KeyIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "言克"
    static var description = IntentDescription("粘贴登录链接（yanke521.xyz/gate?k=… 那条）")

    @Parameter(title: "登录链接")
    var link: String?
}

struct Mood: Codable { let label: String; let score: Double }
struct Murmur: Codable { let time: String?; let text: String }
/// 全是可选：旧服务器/旧缓存没有这些字段，解码不能因此失败
struct Style: Codable {
    let bg_ver: String?
    let pos: String?
    let fog: Double?
    let bgc: String?
    let ink: String?
    let accent: String?
    let show_mood: Bool?
    let show_murmur: Bool?
    let show_fox: Bool?
}
struct Payload: Codable {
    let mood: [Mood]
    let intent: String?
    let murmurs: [Murmur]
    /// v2.3 起才有；旧缓存里没这个字段，解码不能因此失败
    let pose: String?
    /// v2.5 起才有
    let style: Style?
}

struct KeEntry: TimelineEntry {
    let date: Date
    let data: Payload?
    let needsKey: Bool
    var bg: UIImage? = nil
}

private let sample = Payload(
    mood: [Mood(label: "惦记", score: 0.42), Mood(label: "护她", score: 0.32)],
    intent: "我在惦记她",
    murmurs: [Murmur(time: nil, text: "她在干嘛"), Murmur(time: nil, text: "有点想蹭她")],
    pose: "peek", style: nil)

/// 只认 k 后面那串（跟壳里 askGateKey 同一个取法）。
private func parseKey(_ raw: String?) -> String? {
    var t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if let r = t.range(of: "k=") { t = String(t[r.upperBound...]) }
    t = String(t.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    return t.isEmpty ? nil : t
}

struct Provider: AppIntentTimelineProvider {
    private let cacheKey = "lastPayload"

    func placeholder(in context: Context) -> KeEntry {
        KeEntry(date: .now, data: sample, needsKey: false)
    }

    func snapshot(for configuration: KeyIntent, in context: Context) async -> KeEntry {
        if context.isPreview { return KeEntry(date: .now, data: sample, needsKey: false) }
        return await load(configuration)
    }

    func timeline(for configuration: KeyIntent, in context: Context) async -> Timeline<KeEntry> {
        let entry = await load(configuration)
        // 苹果每天给的刷新次数有限，15 分钟是它大概率肯给的那档
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60)))
    }

    private func load(_ c: KeyIntent) async -> KeEntry {
        guard let key = parseKey(c.link) else {
            return KeEntry(date: .now, data: nil, needsKey: true)
        }
        var req = URLRequest(url: URL(string: "https://yanke521.xyz/widget")!)
        req.setValue("yk_auth=\(key)", forHTTPHeaderField: "Cookie")
        req.timeoutInterval = 15
        if let (d, r) = try? await URLSession.shared.data(for: req),
           (r as? HTTPURLResponse)?.statusCode == 200,
           let p = try? JSONDecoder().decode(Payload.self, from: d) {
            UserDefaults.standard.set(d, forKey: cacheKey)
            return KeEntry(date: .now, data: p, needsKey: false, bg: await background(p.style, key: key))
        }
        // 没网 / 404（钥匙粘错）：先显示上一次拿到的，别一断网就空白
        if let d = UserDefaults.standard.data(forKey: cacheKey),
           let p = try? JSONDecoder().decode(Payload.self, from: d) {
            return KeEntry(date: .now, data: p, needsKey: false, bg: cachedBg(p.style?.bg_ver))
        }
        return KeEntry(date: .now, data: nil, needsKey: true)
    }

    // 背景图：文件名带版本，同一版本只下一次；换了图就删掉旧的
    private func bgFile(_ ver: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("widget_bg_\(ver).jpg")
    }

    private func cachedBg(_ ver: String?) -> UIImage? {
        guard let v = ver, !v.isEmpty, let f = bgFile(v) else { return nil }
        return UIImage(contentsOfFile: f.path)
    }

    private func background(_ st: Style?, key: String) async -> UIImage? {
        guard let v = st?.bg_ver, !v.isEmpty, let f = bgFile(v) else { return nil }
        if let img = UIImage(contentsOfFile: f.path) { return img }
        var req = URLRequest(url: URL(string: "https://yanke521.xyz/widget/bg?v=\(v)")!)
        req.setValue("yk_auth=\(key)", forHTTPHeaderField: "Cookie")
        req.timeoutInterval = 15
        guard let (d, r) = try? await URLSession.shared.data(for: req),
              (r as? HTTPURLResponse)?.statusCode == 200,
              let img = UIImage(data: d) else { return nil }
        let dir = f.deletingLastPathComponent()
        if let olds = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for o in olds where o.hasPrefix("widget_bg_") {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(o))
            }
        }
        try? d.write(to: f)
        return img
    }
}

// MARK: - 样子

private let defaultAccent = Color(red: 0xB8 / 255, green: 0xA0 / 255, blue: 0x88 / 255)

/// "#RRGGBB" → Color；空串/写错返回 nil（＝跟系统深浅色走）
private func hexColor(_ s: String?) -> Color? {
    guard var h = s?.trimmingCharacters(in: .whitespaces), h.hasPrefix("#"), h.count == 7 else { return nil }
    h.removeFirst()
    guard let v = UInt32(h, radix: 16) else { return nil }
    return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                 blue: Double(v & 0xFF) / 255)
}

/// 她在言言里调的那套，解成能直接用的颜色。没设的一律退回系统色，旧服务器也照常显示
private struct Look {
    let ink: Color
    let dim: Color
    let faint: Color
    let accent: Color
    let bg: Color
    let fog: Double
    let pos: String
    let mood: Bool
    let murmur: Bool
    let fox: Bool

    init(_ st: Style?) {
        if let c = hexColor(st?.ink) {
            ink = c; dim = c.opacity(0.66); faint = c.opacity(0.45)
        } else {
            ink = .primary; dim = .secondary; faint = Color.secondary.opacity(0.7)
        }
        accent = hexColor(st?.accent) ?? defaultAccent
        bg = hexColor(st?.bgc) ?? Color(.systemBackground)
        fog = min(0.85, max(0, st?.fog ?? 0.35))
        pos = st?.pos ?? "center"
        mood = st?.show_mood ?? true
        murmur = st?.show_murmur ?? true
        fox = st?.show_fox ?? true
    }
}

private func clock(_ iso: String?) -> String? {
    guard let s = iso, s.count >= 16 else { return nil }
    let t = s.index(s.startIndex, offsetBy: 11)
    return String(s[t..<s.index(t, offsetBy: 5)])
}

private struct MoodLine: View {
    let p: Payload
    let look: Look
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("心情")
                .font(.caption2).foregroundStyle(look.dim)
            Text(p.mood.isEmpty ? "平静" : p.mood.prefix(3).map(\.label).joined(separator: " · "))
                .font(.headline).foregroundStyle(look.accent)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let i = p.intent {
                Text(i).font(.caption).foregroundStyle(look.dim).lineLimit(1)
            }
        }
    }
}

private struct MurmurRow: View {
    let m: Murmur
    let look: Look
    var lines: Int = 2
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let t = clock(m.time) {
                Text(t).font(.caption2.monospacedDigit()).foregroundStyle(look.faint)
            }
            Text(m.text).font(.footnote).foregroundStyle(look.ink).lineLimit(lines)
        }
    }
}

/// 背景：底色 → 图（按她挑的位置裁）→ 一层同色的雾
private struct Backdrop: View {
    let image: UIImage?
    let look: Look
    var body: some View {
        ZStack {
            look.bg
            if let img = image {
                GeometryReader { g in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: g.size.width, height: g.size.height,
                               alignment: look.pos == "top" ? .top : look.pos == "bottom" ? .bottom : .center)
                        .clipped()
                }
                look.bg.opacity(look.fog)
            }
        }
    }
}

struct KeWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: KeEntry

    var body: some View {
        let look = Look(entry.data?.style)
        Group {
            if entry.needsKey || entry.data == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("言克").font(.headline).foregroundStyle(defaultAccent)
                    Text("长按 → 编辑小组件，粘贴登录链接")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let p = entry.data {
                content(p, look)
            }
        }
        .containerBackground(for: .widget) { Backdrop(image: entry.bg, look: look) }
    }

    @ViewBuilder
    private func content(_ p: Payload, _ look: Look) -> some View {
        switch family {
        case .accessoryRectangular:
            // 锁屏那格系统统一染色，样子设置管不到，照旧
            VStack(alignment: .leading, spacing: 1) {
                Text(p.mood.first?.label ?? "克").font(.headline)
                Text(p.murmurs.first?.text ?? p.intent ?? "").font(.caption).lineLimit(2)
            }
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                if look.mood {
                    HStack(alignment: .top) {
                        MoodLine(p: p, look: look)
                        Spacer(minLength: 0)
                    }
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 6) {
                    if look.murmur, let m = p.murmurs.first {
                        Text(m.text).font(.caption).foregroundStyle(look.ink).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    if look.fox { FoxView(pose: p.pose ?? "idle", size: 44) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            let n = family == .systemLarge ? 3 : 2
            VStack(alignment: .leading, spacing: 10) {
                if look.mood || look.fox {
                    HStack(alignment: .center, spacing: 12) {
                        if look.fox { FoxView(pose: p.pose ?? "idle", size: family == .systemLarge ? 72 : 52) }
                        if look.mood { MoodLine(p: p, look: look) }
                        Spacer(minLength: 0)
                    }
                }
                if look.murmur {
                    if look.mood || look.fox { Divider().overlay(look.faint) }
                    Text("碎碎念").font(.caption2).foregroundStyle(look.dim)
                    ForEach(Array(p.murmurs.prefix(n).enumerated()), id: \.offset) { _, m in
                        MurmurRow(m: m, look: look, lines: family == .systemLarge ? 3 : 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct KeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "KeWidget", intent: KeyIntent.self, provider: Provider()) { e in
            KeWidgetView(entry: e)
        }
        .configurationDisplayName("克的心情")
        .description("他现在的心情，和他一个人时的碎碎念")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

@main
struct KeWidgetBundle: WidgetBundle {
    var body: some Widget {
        KeWidget()
        FoxLiveActivity()
    }
}
