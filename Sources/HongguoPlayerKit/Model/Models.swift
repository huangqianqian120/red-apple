import Foundation

// 本文件是 App 自己的数据模型。它刻意不依赖 SDK 的类型：
// SDK 是可选的（需要本地编译 xcframework），App 必须能独立编译运行。
// SDK 类型到这些模型的映射在 SDKCatalogService 里。

/// 剧集卡片用的短剧摘要。
public struct SeriesSummary: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var coverURL: URL?
    public var episodeCount: Int
    public var author: String
    public var category: String
    public var summary: String

    public init(
        id: String, title: String, coverURL: URL? = nil, episodeCount: Int = 0,
        author: String = "", category: String = "", summary: String = ""
    ) {
        self.id = id
        self.title = title
        self.coverURL = coverURL
        self.episodeCount = episodeCount
        self.author = author
        self.category = category
        self.summary = summary
    }
}

/// 短剧详情页。
public struct SeriesInfo: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var coverURL: URL?
    public var episodeCount: Int
    public var summary: String
    public var author: String
    public var tags: [String]
    public var heat: Int

    public init(
        id: String, title: String, coverURL: URL? = nil, episodeCount: Int = 0,
        summary: String = "", author: String = "", tags: [String] = [], heat: Int = 0
    ) {
        self.id = id
        self.title = title
        self.coverURL = coverURL
        self.episodeCount = episodeCount
        self.summary = summary
        self.author = author
        self.tags = tags
        self.heat = heat
    }
}

/// 一集。
public struct Episode: Identifiable, Hashable, Sendable {
    public var id: String
    public var seriesID: String
    public var number: Int
    public var title: String
    public var playable: Bool
    /// 竖屏短剧为 true，横屏长片为 false。播放器据此决定窗口比例。
    public var vertical: Bool

    public init(
        id: String, seriesID: String, number: Int, title: String,
        playable: Bool = true, vertical: Bool = true
    ) {
        self.id = id
        self.seriesID = seriesID
        self.number = number
        self.title = title
        self.playable = playable
        self.vertical = vertical
    }

    public var displayTitle: String {
        title.isEmpty ? "第 \(number) 集" : title
    }
}

/// 一个清晰度的表示形式。
public struct MediaStream: Identifiable, Hashable, Sendable {
    public var definition: String
    public var codec: String
    public var width: Int
    public var height: Int
    public var bitrate: Int
    public var url: URL
    public var backupURL: URL?
    public var hls: Bool
    public var dash: Bool
    public var protected: Bool
    public var encryption: String

    public init(
        definition: String, codec: String = "", width: Int = 0, height: Int = 0,
        bitrate: Int = 0, url: URL, backupURL: URL? = nil, hls: Bool = false,
        dash: Bool = false, protected: Bool = false, encryption: String = ""
    ) {
        self.definition = definition
        self.codec = codec
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.url = url
        self.backupURL = backupURL
        self.hls = hls
        self.dash = dash
        self.protected = protected
        self.encryption = encryption
    }

    public var id: String { "\(definition)|\(codec)|\(width)x\(height)" }

    public var label: String {
        if !definition.isEmpty { return definition }
        if height > 0 { return "\(height)p" }
        return codec.isEmpty ? "默认" : codec
    }

    /// 分段（byte-range DASH）的表示形式 AVPlayer 读不了，必须先用 ffmpeg 拼。
    public var isFragmented: Bool { dash || hls }
}

/// 服务端给的播放模型。
public struct PlaybackInfo: Sendable {
    public var episodeID: String
    public var durationSeconds: Int
    public var protected: Bool
    public var streams: [MediaStream]
    /// 分段作品的独立音轨（长片、电影）。
    public var audioURL: URL?
    /// 本地从 spade_a 还原出的 CENC 内容密钥（hex）。非加密分集为空。
    public var contentKey: String

    public init(
        episodeID: String, durationSeconds: Int = 0, protected: Bool = false,
        streams: [MediaStream] = [], audioURL: URL? = nil, contentKey: String = ""
    ) {
        self.episodeID = episodeID
        self.durationSeconds = durationSeconds
        self.protected = protected
        self.streams = streams
        self.audioURL = audioURL
        self.contentKey = contentKey
    }

    /// 按清晰度挑一个能播的表示形式。空 quality 取最高分辨率。
    public func select(quality: String = "") -> MediaStream? {
        let usable = streams.filter { !$0.definition.isEmpty || $0.height > 0 }
        guard !usable.isEmpty else { return streams.first }
        if quality.isEmpty || quality == "best" {
            return usable.max { lhs, rhs in
                (lhs.height, lhs.bitrate) < (rhs.height, rhs.bitrate)
            }
        }
        if quality == "worst" {
            return usable.min { lhs, rhs in
                (lhs.height, lhs.bitrate) < (rhs.height, rhs.bitrate)
            }
        }
        return usable.first { $0.definition == quality }
            ?? usable.first { $0.label == quality }
            ?? usable.max { lhs, rhs in (lhs.height, lhs.bitrate) < (rhs.height, rhs.bitrate) }
    }

    /// 需要先用 ffmpeg 解密/拼装才能交给 AVPlayer 的流。
    public func needsPreProcessing(_ stream: MediaStream) -> Bool {
        stream.protected || stream.isFragmented || audioURL != nil
    }
}

/// 短剧榜的一行。
public struct RankEntry: Identifiable, Hashable, Sendable {
    public var rank: Int
    public var seriesID: String
    public var title: String
    public var score: String
    public var actor: String
    public var coverURL: URL?
    public var episodeCount: Int

    public var id: String { "\(rank)|\(seriesID)|\(title)" }

    public init(
        rank: Int, seriesID: String, title: String, score: String = "",
        actor: String = "", coverURL: URL? = nil, episodeCount: Int = 0
    ) {
        self.rank = rank
        self.seriesID = seriesID
        self.title = title
        self.score = score
        self.actor = actor
        self.coverURL = coverURL
        self.episodeCount = episodeCount
    }
}
