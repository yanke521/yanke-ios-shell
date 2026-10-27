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

struct KeyIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "言克"
    static var description = IntentDescription("粘贴登录链接（yanke521.xyz/gate?k=… 那条）")

    @Parameter(title: "登录链接")
    var link: String?
}

struct Mood: Codable { let label: String; let score: Double }
struct Murmur: Codable { let time: String?; let text: String }
struct Payload: Codable {
    let mood: [Mood]
    let intent: String?
    let murmurs: [Murmur]
}

struct KeEntry: TimelineEntry {
    let date: Date
    let data: Payload?
    let needsKey: Bool
}

private let sample = Payload(
    mood: [Mood(label: "惦记", score: 0.42), Mood(label: "护她", score: 0.32)],
    intent: "我在惦记她",
    murmurs: [Murmur(time: nil, text: "她在干嘛"), Murmur(time: nil, text: "有点想蹭她")])

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
            return KeEntry(date: .now, data: p, needsKey: false)
        }
        // 没网 / 404（钥匙粘错）：先显示上一次拿到的，别一断网就空白
        if let d = UserDefaults.standard.data(forKey: cacheKey),
           let p = try? JSONDecoder().decode(Payload.self, from: d) {
            return KeEntry(date: .now, data: p, needsKey: false)
        }
        return KeEntry(date: .now, data: nil, needsKey: true)
    }
}

// MARK: - 样子

private let accent = Color(red: 0xB8 / 255, green: 0xA0 / 255, blue: 0x88 / 255)

private func clock(_ iso: String?) -> String? {
    guard let s = iso, s.count >= 16 else { return nil }
    let t = s.index(s.startIndex, offsetBy: 11)
    return String(s[t..<s.index(t, offsetBy: 5)])
}

struct MoodLine: View {
    let p: Payload
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("心情")
                .font(.caption2).foregroundStyle(.secondary)
            Text(p.mood.isEmpty ? "平静" : p.mood.prefix(3).map(\.label).joined(separator: " · "))
                .font(.headline).foregroundStyle(accent)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let i = p.intent {
                Text(i).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct MurmurRow: View {
    let m: Murmur
    var lines: Int = 2
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let t = clock(m.time) {
                Text(t).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Text(m.text).font(.footnote).lineLimit(lines)
        }
    }
}

struct KeWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: KeEntry

    var body: some View {
        Group {
            if entry.needsKey || entry.data == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("言克").font(.headline).foregroundStyle(accent)
                    Text("长按 → 编辑小组件，粘贴登录链接")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let p = entry.data {
                content(p)
            }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    @ViewBuilder
    private func content(_ p: Payload) -> some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(p.mood.first?.label ?? "克").font(.headline)
                Text(p.murmurs.first?.text ?? p.intent ?? "").font(.caption).lineLimit(2)
            }
        case .systemSmall:
            VStack(alignment: .leading, spacing: 8) {
                MoodLine(p: p)
                if let m = p.murmurs.first {
                    Text(m.text).font(.footnote).lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            let n = family == .systemLarge ? 3 : 2
            VStack(alignment: .leading, spacing: 10) {
                MoodLine(p: p)
                Divider()
                Text("碎碎念").font(.caption2).foregroundStyle(.secondary)
                ForEach(Array(p.murmurs.prefix(n).enumerated()), id: \.offset) { _, m in
                    MurmurRow(m: m, lines: family == .systemLarge ? 3 : 2)
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
    var body: some Widget { KeWidget() }
}
