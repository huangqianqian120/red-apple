import Foundation

/// 无限流里「下一集」的落点。
///
/// 抽成纯函数是为了能测：跨集、跨剧、到头这三种边界组合很容易写错，
/// 而它们又决定了自动连播会不会卡住。
public enum FeedStep: Equatable, Sendable {
    /// 同一部剧的下一集（episodeIndex 是数组下标）。
    case episode(Int)
    /// 换到队列里的第几部（从第一集开始）。
    case series(Int)
    /// 到头了。
    case end
}

public enum FeedNavigation {
    public static func next(
        episodeIndex: Int, episodeCount: Int, feedIndex: Int, feedCount: Int, isFeedMode: Bool
    ) -> FeedStep {
        if episodeIndex + 1 < episodeCount {
            return .episode(episodeIndex + 1)
        }
        guard isFeedMode else { return .end }
        if feedIndex + 1 < feedCount {
            return .series(feedIndex + 1)
        }
        return .end
    }

    public static func previous(
        episodeIndex: Int, feedIndex: Int, isFeedMode: Bool
    ) -> FeedStep {
        if episodeIndex > 0 {
            return .episode(episodeIndex - 1)
        }
        guard isFeedMode else { return .end }
        if feedIndex > 0 {
            return .series(feedIndex - 1)
        }
        return .end
    }
}
