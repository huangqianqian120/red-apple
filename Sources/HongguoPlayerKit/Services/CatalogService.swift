import Foundation

/// App 与数据源之间的唯一接口。
///
/// 两个实现：
///   - DemoCatalogService：离线样例数据，没有真流，用于跑 UI 和播放器骨架
///   - SDKCatalogService：真 openhongguo SDK（需要本地构建 xcframework）
///
/// 播放相关的错误统一用 CatalogError 表达，视图层只需要区分「能重试」和「不能」。
public protocol CatalogService: Sendable {
    /// 数据源是人类可读的描述，显示在窗口标题旁边。
    var describe: String { get }
    /// 是否接了真 SDK。
    var isLive: Bool { get }

    func discover() async throws -> [SeriesSummary]
    func search(_ query: String) async throws -> [SeriesSummary]
    func series(_ seriesID: String) async throws -> SeriesInfo
    func episodes(seriesID: String) async throws -> [Episode]
    func playback(episodeID: String) async throws -> PlaybackInfo
    func shortRank() async throws -> [RankEntry]

    /// 丢弃当前匿名设备并重新注册。服务端给匿名设备返回空结果
    /// （ErrAnonymousLimited）时是唯一有效的补救措施。
    func resetDevice() async throws
}

extension CatalogService {
    public func resetDevice() async throws {}
}

public enum CatalogError: LocalizedError, Sendable {
    case unavailable(String)
    case network(String)
    case rejected(String)
    /// 服务端对匿名设备返回了空结果：换一台匿名设备通常就能继续。
    case anonymousLimited
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .network(let message): return "网络请求失败：\(message)"
        case .rejected(let message): return "服务端拒绝：\(message)"
        case .anonymousLimited:
            return "这台匿名设备的额度用完了（服务端返回空结果）。"
                + "重置一台匿名设备通常就能继续，也可以等一段时间再试。"
        case .cancelled: return "已取消"
        }
    }
}

// MARK: - Demo 数据源

/// 离线样例库。刻意让「第 3 集起没有流」——这样不看 SDK 也能验证
/// 播放器的错误处理路径，而不是假装能播。
public struct DemoCatalogService: CatalogService {
    public init() {}

    public var describe: String { "演示数据（未接入 SDK）" }
    public var isLive: Bool { false }

    private static let samples: [(String, String, String, Int)] = [
        ("demo-1", "闪婚后，傅爷他每天都想官宣", "都市·甜宠", 82),
        ("demo-2", "全球死考：开局签到满级", "末世·重生", 96),
        ("demo-3", "我在八十年代当后妈", "年代·家庭", 120),
        ("demo-4", "天降萌宝：爹地别跑", "萌宝·虐恋", 64),
        ("demo-5", "镇北王的掌中珠", "古装·权谋", 108),
        ("demo-6", "重生之影后归来", "复仇·打脸", 74),
        ("demo-7", "开局一座荒岛", "生存·经营", 58),
        ("demo-8", "玄学大佬她爆红了", "玄学·娱乐圈", 90),
    ]

    public func discover() async throws -> [SeriesSummary] {
        try? await Task.sleep(nanoseconds: 150_000_000)
        return Self.samples.map { id, title, category, count in
            SeriesSummary(
                id: id, title: title, coverURL: nil, episodeCount: count,
                author: "演示作者", category: category,
                summary: "这是离线演示数据。接入 openhongguo SDK 后这里会换成真实片库。"
            )
        }
    }

    public func search(_ query: String) async throws -> [SeriesSummary] {
        let all = try await discover()
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return all }
        return all.filter { $0.title.contains(query) || $0.category.contains(query) }
    }

    public func series(_ seriesID: String) async throws -> SeriesInfo {
        guard let sample = Self.samples.first(where: { $0.0 == seriesID }) else {
            throw CatalogError.rejected("演示库没有这部短剧")
        }
        return SeriesInfo(
            id: sample.0, title: sample.1, coverURL: nil, episodeCount: sample.3,
            summary: "离线演示数据。真实模式会显示简介、演员和热度。",
            author: "演示作者", tags: [sample.2], heat: 1_200_000
        )
    }

    public func episodes(seriesID: String) async throws -> [Episode] {
        let info = try await series(seriesID)
        return (1...max(info.episodeCount, 1)).map { number in
            Episode(
                id: "\(seriesID)-ep\(number)", seriesID: seriesID, number: number,
                title: "第 \(number) 集", playable: number <= 2, vertical: true
            )
        }
    }

    public func playback(episodeID: String) async throws -> PlaybackInfo {
        // 演示数据没有真实 CDN 地址：前两集指向本机可选的文件，
        // 其余集返回「没有可播流」，用来验证错误分支。
        throw CatalogError.unavailable(
            "演示数据没有真实流。用「文件 › 打开视频…」可以测试播放器本身，"
                + "或运行 Scripts/enable-sdk.sh 接入真 SDK。"
        )
    }

    public func shortRank() async throws -> [RankEntry] {
        try? await Task.sleep(nanoseconds: 120_000_000)
        return Self.samples.enumerated().map { index, sample in
            RankEntry(
                rank: index + 1, seriesID: sample.0, title: sample.1,
                score: "\(1200 - index * 137)万热度", actor: "演示演员",
                coverURL: nil, episodeCount: sample.3
            )
        }
    }
}
