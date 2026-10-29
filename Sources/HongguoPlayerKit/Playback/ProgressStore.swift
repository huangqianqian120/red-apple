import Foundation

/// 一部剧的观看进度：看到第几集、这一集看到第几秒。
public struct SeriesProgress: Codable, Sendable, Identifiable, Hashable {
    public var seriesID: String
    public var title: String
    public var coverURL: String
    public var episodeNumber: Int
    public var episodeID: String
    public var positionSeconds: Double
    public var durationSeconds: Double
    public var updatedAt: Date

    public var id: String { seriesID }

    public init(
        seriesID: String, title: String, coverURL: String = "", episodeNumber: Int,
        episodeID: String, positionSeconds: Double, durationSeconds: Double, updatedAt: Date = .now
    ) {
        self.seriesID = seriesID
        self.title = title
        self.coverURL = coverURL
        self.episodeNumber = episodeNumber
        self.episodeID = episodeID
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.updatedAt = updatedAt
    }

    /// 看到 98% 以上算看完，下次从下一集开始。
    public var isFinished: Bool {
        durationSeconds > 0 && positionSeconds / durationSeconds >= 0.98
    }

    public var progressFraction: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(max(positionSeconds / durationSeconds, 0), 1)
    }

    public var resumeLabel: String {
        if isFinished { return "已看完第 \(episodeNumber) 集" }
        if positionSeconds < 5 { return "第 \(episodeNumber) 集 · 未开始" }
        return "第 \(episodeNumber) 集 · \(Self.mmss(positionSeconds))"
    }

    public static func mmss(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 观看进度的本地存储。写 JSON 到 Application Support，节流后再落盘。
///
/// 播放器每 5 秒上报一次位置，所以这里不能每次都写文件；
/// 内存里保留最新值，落盘做去抖。
public actor ProgressStore {
    private var entries: [String: SeriesProgress] = [:]
    private var dirty = false
    private var flushTask: Task<Void, Never>?
    private let storeURL: URL

    public init(storeURL: URL) {
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL) {
            let decoder = JSONDecoder()
            // 必须和 writeNow() 的 dateEncodingStrategy 保持一致，
            // 否则整个文件解不出来，进度会静默丢失。
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([String: SeriesProgress].self, from: data) {
                self.entries = decoded
            }
        }
    }

    public func progress(for seriesID: String) -> SeriesProgress? {
        entries[seriesID]
    }

    /// 记录一次播放位置。总是以最新的上报为准（用户拖回去重看是合法行为）。
    public func record(_ progress: SeriesProgress) {
        var record = progress
        record.updatedAt = .now
        entries[progress.seriesID] = record
        scheduleFlush()
    }

    /// 看完一集：直接把续播点挪到下一集开头。
    public func finishEpisode(
        seriesID: String, title: String, coverURL: String,
        episodeNumber: Int, nextEpisodeID: String, nextEpisodeNumber: Int
    ) {
        entries[seriesID] = SeriesProgress(
            seriesID: seriesID, title: title, coverURL: coverURL,
            episodeNumber: nextEpisodeNumber, episodeID: nextEpisodeID,
            positionSeconds: 0, durationSeconds: 0
        )
        scheduleFlush()
    }

    /// 「继续观看」列表，最近看的在前。
    public func continueWatching(limit: Int = 12) -> [SeriesProgress] {
        entries.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }

    public func remove(seriesID: String) {
        entries[seriesID] = nil
        scheduleFlush()
    }

    /// 立刻落盘。退出前调用。
    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard dirty else { return }
        writeNow()
    }

    private func scheduleFlush() {
        dirty = true
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.writeIfNeeded()
        }
    }

    private func writeIfNeeded() {
        flushTask = nil
        guard dirty else { return }
        writeNow()
    }

    private func writeNow() {
        dirty = false
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // 进度写不进去不该让播放崩掉。
            dirty = true
        }
    }
}
