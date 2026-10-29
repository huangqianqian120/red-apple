import Foundation

/// 一次「把服务端给的流变成 AVPlayer 能播的东西」的计划。
///
/// 服务端的流有三种形态：
///   1. 明文单文件 MP4     → 直接把 URL 交给 AVPlayer，零成本
///   2. 加密单文件（cenc-aes-ctr） → ffmpeg 解密 + 重封装
///   3. 分段（byte-range DASH/HLS）+ 独立音轨 → ffmpeg 解密 + 拼音频 + 重封装
///
/// 2 和 3 都要落盘，所以有缓存和预取。
public struct MediaPlan: Sendable, Hashable {
    public var episodeID: String
    public var stream: MediaStream
    public var audioURL: URL?
    public var contentKey: String
    public var durationSeconds: Int
    /// 清晰度标签参与缓存键：切清晰度会生成另一份文件。
    public var quality: String

    public init(
        episodeID: String, stream: MediaStream, audioURL: URL?, contentKey: String,
        durationSeconds: Int, quality: String
    ) {
        self.episodeID = episodeID
        self.stream = stream
        self.audioURL = audioURL
        self.contentKey = contentKey
        self.durationSeconds = durationSeconds
        self.quality = quality
    }

    /// 明文单文件不需要任何预处理。
    public var needsProcessing: Bool {
        stream.protected || stream.isFragmented || audioURL != nil
    }

    /// 缓存文件名。episodeID 里可能带斜杠等字符，全部转成安全的。
    public var cacheKey: String {
        let safeEpisode = episodeID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression
        )
        let safeQuality = (stream.definition.isEmpty ? stream.label : stream.definition)
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return "\(safeEpisode)_\(safeQuality).mp4"
    }

    /// 交给 AVPlayer 的地址：需要处理时是缓存文件，否则是 CDN 地址。
    public func playableURL(cacheDirectory: URL) -> URL {
        needsProcessing
            ? cacheDirectory.appendingPathComponent(cacheKey)
            : stream.url
    }
}

/// 用 ffmpeg 把加密/分段的流变成本地明文 MP4，并管理磁盘缓存与预取。
///
/// 设计约束：
///   - 单集 1～2 分钟、体积几 MB，所以「先落盘再播」的延迟可以接受；
///   - 同一集可能被「用户点播」和「下一集预取」同时请求，用 in-flight 表去重；
///   - 取消要真的杀掉 ffmpeg，不能留下半个文件。
public actor MediaPreparer {
    public struct Failure: LocalizedError, Sendable {
        public var message: String
        public var errorDescription: String? { message }
    }

    private let cacheDirectory: URL
    private let ffmpeg: URL
    private var inFlight: [String: Task<URL, Error>] = [:]

    public init(cacheDirectory: URL, ffmpeg: URL) throws {
        self.cacheDirectory = cacheDirectory
        self.ffmpeg = ffmpeg
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    public var ffmpegPath: String { ffmpeg.path }

    // MARK: 定位 ffmpeg

    /// 按 PATH、常见 Homebrew/MacPorts 位置、`which` 的顺序找 ffmpeg。
    public static func locateFFmpeg(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let fileManager = FileManager.default
        if let override = environment["HONGGUO_FFMPEG"], fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // 最后问一次 shell，覆盖 nix / asdf 之类的布局。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", "command -v ffmpeg"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0, !path.isEmpty,
               fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        } catch {
            return nil
        }
        return nil
    }

    // MARK: 预处理

    /// 准备好一个可以播放的本地文件。已经缓存过的直接返回。
    /// progress 用 0…1 报告进度；明文流不落盘，进度直接给 1。
    public func prepare(
        _ plan: MediaPlan,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        guard plan.needsProcessing else {
            progress(1)
            return plan.stream.url
        }
        let output = plan.playableURL(cacheDirectory: cacheDirectory)
        if FileManager.default.fileExists(atPath: output.path) {
            progress(1)
            return output
        }
        // 同一集已经在准备中（用户点播撞上预取）：等同一个 Task。
        if let existing = inFlight[plan.cacheKey] {
            return try await existing.value
        }
        let task = Task<URL, Error> {
            try await self.runFFmpeg(plan: plan, output: output, progress: progress)
        }
        inFlight[plan.cacheKey] = task
        defer { inFlight[plan.cacheKey] = nil }
        return try await task.value
    }

    /// 后台预取：失败不影响前台，只是下次要等。
    public func prefetch(_ plan: MediaPlan) {
        guard plan.needsProcessing, inFlight[plan.cacheKey] == nil else { return }
        let output = plan.playableURL(cacheDirectory: cacheDirectory)
        guard !FileManager.default.fileExists(atPath: output.path) else { return }
        let task = Task<URL, Error> {
            try await self.runFFmpeg(plan: plan, output: output, progress: { _ in })
        }
        inFlight[plan.cacheKey] = task
        Task {
            _ = try? await task.value
            self.clearInFlight(plan.cacheKey)
        }
    }

    /// 丢掉某一集的缓存文件（切清晰度回来时不需要重下，但换设备档案要清）。
    public func evict(_ plan: MediaPlan) {
        try? FileManager.default.removeItem(at: plan.playableURL(cacheDirectory: cacheDirectory))
    }

    public func clearCache() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func clearInFlight(_ key: String) {
        inFlight[key] = nil
    }

    // MARK: ffmpeg 调用

    /// 组装 ffmpeg 参数。抽成静态方法是给单元测试用的。
    ///
    /// - 视频和音轨各自 `-decryption_key`（`-i` 前的选项只作用于紧跟的输入）；
    /// - `-c copy` 不做转码，CPU 几乎不花；
    /// - `-movflags +faststart` 把 moov 放到文件头，AVPlayer 起播更快。
    public static func arguments(for plan: MediaPlan, output: URL) -> [String] {
        var args = [
            "-hide_banner", "-loglevel", "warning",
            "-nostdin", "-nostats",
            "-progress", "pipe:1",
        ]
        let key = plan.contentKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            args += ["-decryption_key", key]
        }
        if plan.stream.hls {
            args += ["-allowed_extensions", "ALL"]
        }
        args += ["-i", plan.stream.url.absoluteString]
        if let audio = plan.audioURL {
            if !key.isEmpty {
                args += ["-decryption_key", key]
            }
            args += ["-i", audio.absoluteString]
            args += ["-map", "0:v:0", "-map", "1:a:0?"]
        } else {
            args += ["-map", "0:v:0?", "-map", "0:a:0?"]
        }
        args += ["-c", "copy", "-f", "mp4", "-movflags", "+faststart", "-y", output.path]
        return args
    }

    private func runFFmpeg(
        plan: MediaPlan,
        output: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        let partial = output.deletingPathExtension().appendingPathExtension("mp4.part")
        try? FileManager.default.removeItem(at: partial)
        let logURL = partial.appendingPathExtension("log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = Self.arguments(for: plan, output: partial)

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = logHandle

        // ffmpeg 用 -progress pipe:1 输出的 out_time_us 计算进度。
        let total = Double(max(plan.durationSeconds, 0)) * 1_000_000

        let finished = AsyncThrowingStream<Void, Error> { continuation in
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                guard total > 0 else { return }
                for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n") {
                    guard line.hasPrefix("out_time_us=") else { continue }
                    let raw = line.dropFirst("out_time_us=".count)
                    guard let micros = Double(raw) else { continue }
                    progress(min(max(micros / total, 0), 0.99))
                }
            }
            process.terminationHandler = { finished in
                outPipe.fileHandleForReading.readabilityHandler = nil
                if finished.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: Failure(
                        message: Self.tail(of: logURL) ?? "ffmpeg 退出码 \(finished.terminationStatus)"
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: Failure(message: "无法启动 ffmpeg：\(error.localizedDescription)"))
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
        }

        do {
            for try await _ in finished {}
        } catch is CancellationError {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: partial)
            throw CatalogError.cancelled
        } catch {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: partial)
            throw error as? Failure ?? Failure(message: error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: partial.path) else {
            throw Failure(message: "ffmpeg 没有产出文件")
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
        try? FileManager.default.removeItem(at: logURL)

        // 关键的一步：`-c copy` 不重编码，所以错误的 key 也会“成功”产出一个
        // 解不开的文件。只有真解一帧才能确认密钥是对的，否则会把坏文件留进缓存。
        if plan.stream.protected {
            do {
                try runValidation(on: output)
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }
        progress(1)
        return output
    }

    /// 解一帧，验证产物真的能播。上游仓库的每日契约检查也是这么做的。
    private func runValidation(on url: URL) throws {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-v", "error", "-i", url.path, "-frames:v", "1", "-f", "null", "-"]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure(message: "无法启动 ffmpeg 做解密校验：\(error.localizedDescription)")
        }
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: data, as: UTF8.self)
                .split(separator: "\n").prefix(3).joined(separator: "\n")
            throw Failure(
                message: "解密校验失败：内容密钥可能已失效，或这一集换了加密方案。"
                    + (message.isEmpty ? "" : "\n\(message)")
            )
        }
    }

    private static func tail(of logURL: URL, lines: Int = 6) -> String? {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        let kept = text.split(separator: "\n").suffix(lines).joined(separator: "\n")
        return kept.isEmpty ? nil : kept
    }
}
