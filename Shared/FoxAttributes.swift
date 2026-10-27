import ActivityKit
import Foundation

/// 灵动岛 / 锁屏上那只小狐狸（v2.3）。**壳和小组件两个 target 都编这一份**——
/// 两边各写一份的话，字段一对不上 ActivityKit 就解不出来，灵动岛上只剩一个转圈，不报错。
@available(iOS 16.1, *)
struct FoxAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 素材名后半截：idle / happy / angry …（Widget/Fox/fox_<pose>.png）
        var pose: String
        /// 心情那一行，比如「惦记 · 得意」
        var mood: String
        /// 最新一条碎碎念（没有就放他心里那句）
        var line: String
    }
}
