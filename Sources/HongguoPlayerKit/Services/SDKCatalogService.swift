import Foundation

// 真 SDK 桥接。
//
// 只有在本机编译好 OpenhongguoCore.xcframework、并在 Package.swift 里加了
// Openhongguo 依赖之后，这个文件才会被编译进去（#if canImport 门控）。
// 见 Scripts/enable-sdk.sh。
//
// 注意：SDK 里有一批同名类型（SeriesSummary / Episode / Stream / Page /
// Playback），这里统一用 Openhongguo. 前缀限定，避免和 App 的模型混淆。

#if canImport(Openhongguo)
import Openhongguo

public final class SDKCatalogService: CatalogService, @unchecked Sendable {
    private let client: OpenhongguoClient

    /// profileURL 是匿名设备档案。放在 Application Support 下，
    /// 首次请求时 SDK 会注册一台匿名设备并写进去。
    public init(profileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        self.client = try OpenhongguoClient.create(
            profile: profileURL,
            options: ClientOptions(retryAttempts: 3)
        )
    }

    public var describe: String { "RED APPLE · 匿名设备" }
    public var isLive: Bool { true }

    // MARK: 片库

    public func discover() async throws -> [SeriesSummary] {
        try await map { try await self.client.discover().items }
    }

    public func search(_ query: String) async throws -> [SeriesSummary] {
        try await map { try await self.client.search(query).items }
    }

    public func series(_ seriesID: String) async throws -> SeriesInfo {
        let series = try await call { try await self.client.getSeries(seriesID) }
        return SeriesInfo(
            id: series.id,
            title: series.title,
            coverURL: URL(string: series.coverUrl),
            episodeCount: series.episodeCount,
            summary: series.description,
            author: series.author,
            tags: series.subtitles,
            heat: series.heat
        )
    }

    public func episodes(seriesID: String) async throws -> [Episode] {
        let page = try await call { try await self.client.listEpisodes(seriesID) }
        return page.items.map { episode in
            Episode(
                id: episode.id,
                seriesID: episode.seriesId,
                number: episode.number,
                title: episode.title,
                playable: episode.playable,
                vertical: episode.vertical
            )
        }
    }

    public func playback(episodeID: String) async throws -> PlaybackInfo {
        // resolvePlayback 在分集加密时同时返回 playback 和 contentKey，
        // 所以这里不需要再单独请求密钥。
        let result: PlaybackResult = try await call {
            try await self.client.resolvePlayback(episodeID)
        }
        let playback = result.playback
        let streams: [MediaStream] = playback.streams.compactMap { stream in
            guard let url = URL(string: stream.url) else { return nil }
            return MediaStream(
                definition: stream.definition,
                codec: stream.codec,
                width: stream.width,
                height: stream.height,
                bitrate: stream.bitrate,
                url: url,
                backupURL: URL(string: stream.backupUrl),
                hls: stream.hls,
                dash: stream.dash,
                protected: stream.protected,
                encryption: stream.encryption
            )
        }
        guard !streams.isEmpty else {
            throw CatalogError.rejected("这一集没有可播的清晰度")
        }
        return PlaybackInfo(
            episodeID: playback.episodeId,
            durationSeconds: playback.durationSeconds,
            protected: playback.protected,
            streams: streams,
            audioURL: URL(string: playback.audioUrl),
            contentKey: result.contentKey?.key ?? ""
        )
    }

    public func shortRank() async throws -> [RankEntry] {
        let ranking = try await call { try await self.client.shortRank() }
        return ranking.items.map { item in
            RankEntry(
                rank: item.rank,
                seriesID: item.seriesId,
                title: item.title,
                score: item.score,
                actor: item.actor,
                coverURL: URL(string: item.coverUrl),
                episodeCount: item.episodeCount
            )
        }
    }

    // MARK: 映射

    private func map(
        _ body: @escaping () async throws -> [Openhongguo.SeriesSummary]
    ) async throws -> [SeriesSummary] {
        let items = try await call(body)
        return items.map { item in
            SeriesSummary(
                id: item.id,
                title: item.title,
                coverURL: URL(string: item.coverUrl),
                episodeCount: item.episodeCount,
                author: item.author,
                category: item.category,
                summary: item.description
            )
        }
    }

    /// 把 SDK 的错误翻成 CatalogError，视图层不需要知道 SDK 的错误码。
    private func call<T>(_ body: @escaping () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as OpenhongguoError {
            throw error.retryable
                ? CatalogError.network(error.message)
                : CatalogError.rejected("\(error.code) \(error.message)")
        } catch is CancellationError {
            throw CatalogError.cancelled
        } catch {
            throw CatalogError.network(error.localizedDescription)
        }
    }
}
#endif
