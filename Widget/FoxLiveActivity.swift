import ActivityKit
import SwiftUI
import WidgetKit

/// 灵动岛 + 锁屏横幅上的小狐狸。数据全是壳推过来的（FoxIsland.swift）——
/// 这里的代码不会自己跑、不会自己联网，系统只是拿着那份 state 画一张图。
struct FoxLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FoxAttributes.self) { ctx in
            HStack(spacing: 12) {
                FoxView(pose: ctx.state.pose, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ctx.state.mood).font(.headline).lineLimit(1)
                    Text(ctx.state.line).font(.subheadline)
                        .foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.35))
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    FoxView(pose: ctx.state.pose, size: 44)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(ctx.state.mood).font(.callout.bold()).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(ctx.state.line).font(.footnote).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                FoxView(pose: ctx.state.pose, size: 22)
            } compactTrailing: {
                // 紧凑态放不下心情那句，只放最强那个情绪的头一个字
                Text(String(ctx.state.mood.prefix(2))).font(.caption2.bold())
            } minimal: {
                FoxView(pose: ctx.state.pose, size: 20)
            }
        }
    }
}
