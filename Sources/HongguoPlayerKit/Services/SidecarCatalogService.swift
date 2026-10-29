import Foundation

/// 通过 Go 子进程（sidecar）访问 openhongguo SDK。
///
/// 为什么不是 in-process 的 Swift 绑定：`gomobile bind -target macos` 需要完整
/// Xcode，而 `go build` 只需要 Go。Sidecar 用一行一 JSON 的协议通信，跨语言
/// 边界只有一个契约，调试时可以手动复现：
///
///     echo '{"id":1,"method":"search","args":["末世"]}' | openhongguo-sidecar
///
/// 协议见 sidecar/main.go。
public actor SidecarCatalogService: CatalogService {
    public nonisolated let describe: String
    public nonisolated let isLive = true
    public nonisolated let executable: URL

    public struct Failure: LocalizedError, Decodable, Sendable {
        public var code: String
        public var message: String
        public var retryable: Bool
        public var retryAfterMs: Int?
        public var errorDescription: String? { message }
    }

    private final class Waiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Data, Error>?
    }

    private let process: Process
    private let stdin: FileHandle
    private var nextID = 1
    private var waiters: [Int: Waiter] = [:]
    private var buffer = Data()
    private var closed = false
    private var lastExitStatus: Int32 = 0

    public init(executable: URL, profileURL: URL, timeout: TimeInterval = 60) throws {
        self.executable = executable
        self.describe = "红果短剧 · 匿名设备"
        self.timeout = timeout

        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = executable
        process.arguments = ["-profile", profileURL.path]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let spawnStart = Date()
        try process.run()
        Debug.log(String(format: "sidecar 启动 %.0fms", Date().timeIntervalSince(spawnStart) * 1000))

        self.process = process
        self.stdin = input.fileHandleForWriting

        output.fileHandleForReading.readabilityHandler = { stream in
            let chunk = stream.availableData
            guard !chunk.isEmpty else { return }
            Task { await self.ingest(chunk) }
        }
        // sidecar 的诊断信息直接转给 App 的 stderr，不参与协议。
        errors.fileHandleForReading.readabilityHandler = { stream in
            let chunk = stream.availableData
            guard !chunk.isEmpty else { return }
            FileHandle.standardError.write(chunk)
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { await self?.processExited(status: status) }
        }
    }

    private let timeout: TimeInterval

    /// 找 sidecar 二进制：环境变量 > .app 内 Resources > 开发目录。
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let override = environment["HONGGUO_SIDECAR"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let bundled = Bundle.main.url(forResource: "openhongguo-sidecar", withExtension: nil) {
            candidates.append(bundled)
        }
        // 开发时从可执行文件所在目录往上找 build/openhongguo-sidecar
        var directory = Bundle.main.bundleURL
        if directory.pathExtension == "app" {
            directory = directory.deletingLastPathComponent()
        }
        for _ in 0..<5 {
            candidates.append(directory.appendingPathComponent("build/openhongguo-sidecar"))
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        candidates.append(URL(fileURLWithPath: "\(home)/Projects/hongguo-player/build/openhongguo-sidecar"))
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    // MARK: CatalogService

    public func discover() async throws -> [SeriesSummary] {
        let page: SeriesPage = try await call("discover")
        return page.items.map(\.summaryModel)
    }

    public func discoverPage(channel: String, cursor: String) async throws -> Page {
        let payload: SeriesPage = try await call("discover", channel, cursor)
        return Page(
            items: payload.items.map(\.summaryModel),
            cursor: payload.cursor ?? "",
            hasMore: payload.hasMore
        )
    }

    public func search(_ query: String) async throws -> [SeriesSummary] {
        let page: SeriesPage = try await call("search", query)
        return page.items.map(\.summaryModel)
    }

    public func series(_ seriesID: String) async throws -> SeriesInfo {
        let payload: SeriesPayload = try await call("series", seriesID)
        return payload.info
    }

    public func episodes(seriesID: String) async throws -> [Episode] {
        let page: EpisodePage = try await call("episodes", seriesID)
        return page.items.map(\.model)
    }

    public func playback(episodeID: String) async throws -> PlaybackInfo {
        let payload: PlaybackPayload = try await call("playback", episodeID)
        return payload.model
    }

    public func shortRank() async throws -> [RankEntry] {
        let page: RankPage = try await call("shortRank")
        return page.items.map(\.model)
    }

    public func resetDevice() async throws {
        let _: ResetAck = try await call("resetDevice")
    }

    public func shutdown() {
        closed = true
        for (_, waiter) in waiters {
            waiter.continuation?.resume(throwing: CatalogError.cancelled)
        }
        waiters.removeAll()
        try? stdin.close()
        if process.isRunning { process.terminate() }
    }

    // MARK: 管道

    private func call<T: Decodable>(_ method: String, _ args: String...) async throws -> T {
        guard !closed, process.isRunning else {
            throw CatalogError.network("sidecar 已退出（\(lastExitStatus)）")
        }
        let id = nextID
        nextID += 1

        let sentAt = Date()
        var line: Data
        do {
            line = try JSONEncoder().encode(Envelope(id: id, method: method, args: args))
        } catch {
            throw CatalogError.network("请求编码失败：\(error.localizedDescription)")
        }
        line.append(0x0A)

        let waiter = Waiter()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            waiter.continuation = continuation
            Task { self.register(id: id, waiter: waiter, line: line) }
        }

        Debug.log(String(format: "sidecar %@ %.0fms", method, Date().timeIntervalSince(sentAt) * 1000))
        let reply = try JSONDecoder().decode(Reply<T>.self, from: data)
        if let error = reply.error {
            switch error.code {
            case "anonymous_limited":
                throw CatalogError.anonymousLimited
            case "rate_limited":
                throw CatalogError.network(error.message)
            default:
                throw error.retryable
                    ? CatalogError.network(error.message)
                    : CatalogError.rejected(error.message)
            }
        }
        guard let result = reply.result else {
            throw CatalogError.network("sidecar 返回空结果")
        }
        return result
    }

    /// 先登记等待者再写 stdin：响应只可能在写入之后出现，顺序反了会丢行。
    private func register(id: Int, waiter: Waiter, line: Data) {
        guard !closed else {
            waiter.continuation?.resume(throwing: CatalogError.network("sidecar 已退出"))
            return
        }
        waiters[id] = waiter
        do {
            try stdin.write(contentsOf: line)
        } catch {
            waiters[id] = nil
            waiter.continuation?.resume(
                throwing: CatalogError.network("写入 sidecar 失败：\(error.localizedDescription)")
            )
            return
        }
        let deadline = timeout
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            await self?.expire(id: id)
        }
    }

    private func expire(id: Int) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation?.resume(throwing: CatalogError.network("sidecar 响应超时"))
    }

    /// 按行切分 stdout，把每行交给对应的等待者。
    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            let payload = Data(line)
            guard let head = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let id = head["id"] as? Int else {
                FileHandle.standardError.write(Data("sidecar: 无法解析的响应行\n".utf8))
                continue
            }
            guard let waiter = waiters.removeValue(forKey: id) else { continue }
            waiter.continuation?.resume(returning: payload)
        }
    }

    private func processExited(status: Int32) {
        lastExitStatus = status
        guard !closed else { return }
        closed = true
        for (_, waiter) in waiters {
            waiter.continuation?.resume(
                throwing: CatalogError.network("sidecar 退出（\(status)）")
            )
        }
        waiters.removeAll()
    }
}

// MARK: - 协议 DTO

private struct Envelope: Encodable {
    var id: Int
    var method: String
    var args: [String]
}

private struct Reply<T: Decodable>: Decodable {
    var id: Int
    var result: T?
    var error: SidecarCatalogService.Failure?
}

private struct ResetAck: Decodable {
    var ok: Bool
}

private struct SeriesPage: Decodable {
    var items: [SeriesPayload]
    var cursor: String?
    var hasMore: Bool
}

private struct EpisodePage: Decodable {
    var items: [EpisodePayload]
    var hasMore: Bool
}

private struct RankPage: Decodable {
    var items: [RankPayload]
}

private struct SeriesPayload: Decodable {
    var id: String
    var title: String
    var coverUrl: String?
    var episodeCount: Int?
    var author: String?
    var category: String?
    var summary: String?
    var tags: [String]?
    var heat: Int64?

    var summaryModel: SeriesSummary {
        SeriesSummary(
            id: id, title: title, coverURL: coverUrl.flatMap(URL.init(string:)),
            episodeCount: episodeCount ?? 0, author: author ?? "",
            category: category ?? "", summary: summary ?? ""
        )
    }

    var info: SeriesInfo {
        SeriesInfo(
            id: id, title: title, coverURL: coverUrl.flatMap(URL.init(string:)),
            episodeCount: episodeCount ?? 0, summary: summary ?? "",
            author: author ?? "", tags: tags ?? [], heat: Int(heat ?? 0)
        )
    }

}

private struct EpisodePayload: Decodable {
    var id: String
    var seriesId: String
    var number: Int
    var title: String?
    var playable: Bool
    var vertical: Bool

    var model: Episode {
        Episode(
            id: id, seriesID: seriesId, number: number, title: title ?? "",
            playable: playable, vertical: vertical
        )
    }
}

private struct PlaybackPayload: Decodable {
    struct StreamPayload: Decodable {
        var definition: String?
        var codec: String?
        var width: Int?
        var height: Int?
        var bitrate: Int?
        var url: String
        var backupUrl: String?
        var hls: Bool?
        var dash: Bool?
        var protected: Bool
        var encryption: String?
    }

    var episodeId: String
    var durationSeconds: Int?
    var protected: Bool
    var audioUrl: String?
    var key: String?
    var keyVersion: String?
    var streams: [StreamPayload]

    var model: PlaybackInfo {
        PlaybackInfo(
            episodeID: episodeId,
            durationSeconds: durationSeconds ?? 0,
            protected: protected,
            streams: streams.compactMap { stream in
                guard let url = URL(string: stream.url) else { return nil }
                return MediaStream(
                    definition: stream.definition ?? "",
                    codec: stream.codec ?? "",
                    width: stream.width ?? 0,
                    height: stream.height ?? 0,
                    bitrate: stream.bitrate ?? 0,
                    url: url,
                    backupURL: stream.backupUrl.flatMap(URL.init(string:)),
                    hls: stream.hls ?? false,
                    dash: stream.dash ?? false,
                    protected: stream.protected,
                    encryption: stream.encryption ?? ""
                )
            },
            audioURL: audioUrl.flatMap(URL.init(string:)),
            contentKey: key ?? ""
        )
    }
}

private struct RankPayload: Decodable {
    var rank: Int
    var seriesId: String?
    var title: String?
    var score: String?
    var actor: String?
    var coverUrl: String?
    var episodeCount: Int?

    var model: RankEntry {
        RankEntry(
            rank: rank, seriesID: seriesId ?? "", title: title ?? "",
            score: score ?? "", actor: actor ?? "",
            coverURL: coverUrl.flatMap(URL.init(string:)),
            episodeCount: episodeCount ?? 0
        )
    }
}
