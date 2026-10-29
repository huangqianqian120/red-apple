import AVFoundation
import Foundation

/// 播放控制器：把「服务端的播放模型」变成「屏幕上会动的画面」。
///
/// 一次播放的完整链路：
///   resolvePlayback → 选清晰度 → (需要时) ffmpeg 解密/拼装 → AVPlayer → 进度记忆
///
/// 控制器只管状态和时序，UI 在 Views/PlayerView.swift。
@MainActor
public final class PlaybackController: ObservableObject {
    public enum Phase: Equatable {
        case idle
        /// 正在请求播放模型
        case resolving
        /// 正在用 ffmpeg 解密/拼装
        case preparing
        case ready
        case failed(String)

        public var isBusy: Bool { self == .resolving || self == .preparing }
    }

    // MARK: 状态

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var prepareProgress: Double = 0
    @Published public private(set) var series: SeriesInfo?
    @Published public private(set) var episodes: [Episode] = []
    @Published public private(set) var index: Int = 0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var availableQualities: [String] = []
    /// 程序内部改写清晰度时置位，避免触发 didSet 里的重新装载。
    private var isAdjustingQuality = false
    @Published public var quality: String = "" {
        didSet {
            guard !isAdjustingQuality, quality != oldValue, series != nil else { return }
            reload()
        }
    }
    @Published public var speed: Double = 1 { didSet { applySpeed() } }
    @Published public var autoplayNext = true
    @Published public private(set) var preparedFrom: String = ""
    /// 真实画面宽高比（来自 AVPlayerItem），用来把播放窗口调成合适的形状。
    @Published public private(set) var videoAspectRatio: CGFloat?
    /// 服务端对这个匿名设备返回了空结果：UI 该给一个「换设备」按钮。
    @Published public private(set) var needsDeviceReset = false

    // MARK: 依赖

    public let player = AVPlayer()
    private let service: CatalogService
    private let preparer: MediaPreparer?
    private let progressStore: ProgressStore
    private let cacheDirectory: URL

    // MARK: 内部

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var lastReportedSecond: Double = -1

    public init(
        service: CatalogService,
        progressStore: ProgressStore,
        cacheDirectory: URL,
        ffmpeg: URL?
    ) {
        self.service = service
        self.progressStore = progressStore
        self.cacheDirectory = cacheDirectory
        self.preparer = ffmpeg.flatMap { try? MediaPreparer(cacheDirectory: cacheDirectory, ffmpeg: $0) }
        player.automaticallyWaitsToMinimizeStalling = true
        installObservers()
    }

    // MARK: 对外属性

    public var currentEpisode: Episode? {
        episodes.indices.contains(index) ? episodes[index] : nil
    }

    public var hasNext: Bool { index + 1 < episodes.count }
    public var hasPrevious: Bool { index > 0 }

    public var title: String {
        guard let episode = currentEpisode else { return series?.title ?? "未在播放" }
        return "\(series?.title ?? "") · \(episode.displayTitle)"
    }

    /// 竖屏短剧按 9:16 显示，横屏长片按 16:9。
    public var isVertical: Bool { currentEpisode?.vertical ?? true }

    // MARK: 装载

    /// 打开一部短剧并播放其中一集。
    ///
    /// 优先用进度记录还原位置；startAt 指定集数时以它为准。
    public func open(
        seriesID: String,
        fallbackTitle: String = "",
        startAt episodeNumber: Int? = nil,
        quality preferredQuality: String? = nil
    ) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            self.phase = .resolving
            do {
                async let infoTask = self.service.series(seriesID)
                async let episodesTask = self.service.episodes(seriesID: seriesID)
                let (info, list) = try await (infoTask, episodesTask)
                guard !list.isEmpty else {
                    self.fail("这部短剧没有可播的分集")
                    return
                }
                let progress = await self.progressStore.progress(for: seriesID)
                self.series = info
                self.episodes = list
                if let preferredQuality, !preferredQuality.isEmpty {
                    self.quality = preferredQuality
                }
                var startIndex = 0
                if let episodeNumber,
                   let found = list.firstIndex(where: { $0.number == episodeNumber }) {
                    startIndex = found
                } else if let progress,
                          let found = list.firstIndex(where: { $0.id == progress.episodeID }) {
                    startIndex = found
                }
                self.index = startIndex
                self.resumePosition = progress?.episodeID == list[startIndex].id
                    ? progress?.positionSeconds ?? 0 : 0
                await self.loadCurrentEpisode()
            } catch is CancellationError {
                // 被新的一次打开覆盖，什么都不做。
            } catch let error as CatalogError {
                if case .anonymousLimited = error { self.needsDeviceReset = true }
                self.fail(error.localizedDescription)
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    /// 直接播一个本地文件。用来在没有 SDK / 没有网络时验证播放器本身。
    public func openLocalFile(_ url: URL) {
        loadTask?.cancel()
        series = nil
        episodes = []
        index = 0
        duration = 0
        currentTime = 0
        preparedFrom = "本地文件"
        phase = .ready
        resumePosition = 0
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        let paused = ProcessInfo.processInfo.environment["HONGGUO_PAUSE_ON_OPEN"] != nil
        if paused {
            // 调试/截图用：停在某一帧，控件不会自动隐藏。
            Task {
                await player.seek(to: CMTime(seconds: 3, preferredTimescale: 600))
                currentTime = 3
                await refreshDuration()
            }
        } else {
            player.play()
            player.rate = Float(speed)
            isPlaying = true
            Task { await refreshDuration() }
        }
    }

    public func retry() {
        guard let series else { return }
        open(seriesID: series.id, startAt: currentEpisode?.number, quality: quality)
    }

    /// 匿名设备被限流时的补救：换一台设备再重试当前这一集。
    public func retryWithNewDevice() {
        let episodeID = currentEpisode?.id
        phase = .resolving
        needsDeviceReset = false
        Task {
            do {
                try await service.resetDevice()
            } catch {
                fail(error.localizedDescription)
                return
            }
            if episodeID != nil {
                await loadCurrentEpisode()
            } else if let series {
                open(seriesID: series.id, startAt: currentEpisode?.number, quality: quality)
            }
        }
    }

    /// 丢掉当前状态（清缓存前调用）。
    public func reset() {
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        series = nil
        episodes = []
        index = 0
        currentTime = 0
        duration = 0
        phase = .idle
        isPlaying = false
        prepareProgress = 0
        availableQualities = []
    }

    // MARK: 集数切换

    public func next() {
        guard hasNext else { return }
        index += 1
        resumePosition = 0
        Task { await loadCurrentEpisode() }
    }

    public func previous() {
        guard hasPrevious else { return }
        index -= 1
        resumePosition = 0
        Task { await loadCurrentEpisode() }
    }

    public func play(episodeNumber: Int) {
        guard let found = episodes.firstIndex(where: { $0.number == episodeNumber }) else { return }
        index = found
        resumePosition = 0
        Task { await loadCurrentEpisode() }
    }

    // MARK: 播放控制

    public func togglePlay() {
        isPlaying ? pause() : play()
    }

    public func play() {
        player.play()
        player.rate = Float(speed)
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration > 0 ? duration - 0.5 : seconds))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
    }

    public func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    public func reload() {
        guard series != nil else { return }
        resumePosition = currentTime
        Task { await loadCurrentEpisode() }
    }

    /// 退出前保存进度。
    public func persistProgress() {
        guard let series, let episode = currentEpisode else { return }
        let store = progressStore
        let value = SeriesProgress(
            seriesID: series.id,
            title: series.title,
            coverURL: series.coverURL?.absoluteString ?? "",
            episodeNumber: episode.number,
            episodeID: episode.id,
            positionSeconds: currentTime,
            durationSeconds: duration
        )
        Task {
            await store.record(value)
            await store.flush()
        }
    }

    // MARK: 单集装载

    private var resumePosition: Double = 0

    private func loadCurrentEpisode() async {
        guard let episode = currentEpisode else { return }
        phase = .resolving
        prepareProgress = 0
        preparedFrom = ""
        player.pause()
        isPlaying = false

        do {
            let playback = try await service.playback(episodeID: episode.id)
            availableQualities = Self.qualityOptions(for: playback)
            // 默认清晰度必须在 select 之前定：起播延迟 ≈ 单集体积 / 带宽，
            // 而中文短剧 1080p 单集能有 40MB。默认 720p，用户可手动切回。
            if quality.isEmpty || !availableQualities.contains(quality) {
                isAdjustingQuality = true
                if !quality.isEmpty, availableQualities.contains("720p") {
                    quality = "720p"
                } else if quality.isEmpty {
                    quality = availableQualities.contains("720p")
                        ? "720p"
                        : (availableQualities.first ?? "")
                }
                isAdjustingQuality = false
            }
            guard let stream = playback.select(quality: quality) else {
                fail("这一集没有可用的清晰度")
                return
            }
            if !quality.isEmpty, stream.definition != quality {
                isAdjustingQuality = true
                quality = stream.definition
                isAdjustingQuality = false
            }
            let plan = MediaPlan(
                episodeID: episode.id,
                stream: stream,
                audioURL: playback.audioURL,
                contentKey: playback.contentKey,
                durationSeconds: playback.durationSeconds,
                quality: stream.definition
            )

            let target: URL
            if plan.needsProcessing {
                guard let preparer else {
                    fail("这一集是加密或分段流，需要 ffmpeg 才能播。"
                         + "安装：brew install ffmpeg（或设置 HONGGUO_FFMPEG 指向二进制）")
                    return
                }
                phase = .preparing
                preparedFrom = plan.stream.url.host() ?? "CDN"
                target = try await preparer.prepare(plan) { [weak self] value in
                    Task { @MainActor in self?.prepareProgress = value }
                }
            } else {
                target = plan.stream.url
                preparedFrom = plan.stream.url.host() ?? "CDN"
            }

            attach(url: target, durationHint: Double(playback.durationSeconds))
            if let preparer {
                self.prefetchNext(using: preparer)
            }
        } catch is CancellationError {
            // 切集时旧任务被取消，正常。
        } catch let error as CatalogError {
            if case .anonymousLimited = error { needsDeviceReset = true }
            fail(error.localizedDescription)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func attach(url: URL, durationHint: Double) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        installEndObserver(for: item)
        player.replaceCurrentItem(with: item)
        phase = .ready
        duration = durationHint
        currentTime = 0
        let start = resumePosition
        resumePosition = 0
        Task { [weak self] in
            guard let self else { return }
            await self.refreshDuration()
            if start > 1 {
                self.seek(to: start)
            }
            if ProcessInfo.processInfo.environment["HONGGUO_PAUSE_ON_OPEN"] != nil {
                // 调试/截图用：不要自动播，控件就不会自动隐藏。
                await self.player.seek(to: CMTime(seconds: max(start, 3), preferredTimescale: 600))
                self.currentTime = max(start, 3)
            } else {
                self.play()
            }
        }
    }

    private func refreshDuration() async {
        guard let item = player.currentItem else { return }
        // 等一帧 ready 之后 presentationSize 才有值。
        for _ in 0..<20 {
            let size = item.presentationSize
            if size.width > 0, size.height > 0 {
                videoAspectRatio = size.width / size.height
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if let value = try? await item.asset.load(.duration) {
            let seconds = value.seconds
            if seconds.isFinite, seconds > 0 { duration = seconds }
        }
    }

    /// 后台把下一集解密好，切集时几乎瞬开。
    private func prefetchNext(using preparer: MediaPreparer) {
        guard autoplayNext, hasNext else { return }
        let next = episodes[index + 1]
        let quality = quality
        Task { [service] in
            guard let playback = try? await service.playback(episodeID: next.id),
                  let stream = playback.select(quality: quality) else { return }
            let plan = MediaPlan(
                episodeID: next.id, stream: stream, audioURL: playback.audioURL,
                contentKey: playback.contentKey, durationSeconds: playback.durationSeconds,
                quality: stream.definition
            )
            await preparer.prefetch(plan)
        }
    }

    // MARK: 观察

    private func installObservers() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.currentTime = seconds
                self.reportProgressIfNeeded(seconds)
                if let item = self.player.currentItem,
                   item.duration.seconds.isFinite, item.duration.seconds > 0 {
                    self.duration = item.duration.seconds
                }
            }
        }
    }

    private func installEndObserver(for item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleEpisodeFinished()
            }
        }
    }

    private func handleEpisodeFinished() {
        guard let series, let episode = currentEpisode else { return }
        let hasNext = self.hasNext
        let nextEpisode = hasNext ? episodes[index + 1] : nil
        let store = progressStore
        Task {
            if let nextEpisode {
                await store.finishEpisode(
                    seriesID: series.id, title: series.title,
                    coverURL: series.coverURL?.absoluteString ?? "",
                    episodeNumber: episode.number,
                    nextEpisodeID: nextEpisode.id, nextEpisodeNumber: nextEpisode.number
                )
            } else {
                await store.record(SeriesProgress(
                    seriesID: series.id, title: series.title,
                    coverURL: series.coverURL?.absoluteString ?? "",
                    episodeNumber: episode.number, episodeID: episode.id,
                    positionSeconds: duration, durationSeconds: duration
                ))
            }
            await store.flush()
        }
        if autoplayNext, self.hasNext {
            next()
        } else {
            isPlaying = false
        }
    }

    /// 每 5 秒上报一次进度，避免频繁写盘。
    private func reportProgressIfNeeded(_ seconds: Double) {
        guard let series, let episode = currentEpisode, duration > 0 else { return }
        guard seconds - lastReportedSecond >= 5 || seconds < lastReportedSecond else { return }
        lastReportedSecond = seconds
        let store = progressStore
        let value = SeriesProgress(
            seriesID: series.id, title: series.title,
            coverURL: series.coverURL?.absoluteString ?? "",
            episodeNumber: episode.number, episodeID: episode.id,
            positionSeconds: seconds, durationSeconds: duration
        )
        Task { await store.record(value) }
    }

    private func applySpeed() {
        if isPlaying || player.rate != 0 {
            player.rate = Float(speed)
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        isPlaying = false
        player.pause()
    }

    // MARK: 工具

    /// 清晰度选项：按分辨率从高到低，去掉重复标签。
    public static func qualityOptions(for playback: PlaybackInfo) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for stream in playback.streams.sorted(by: { $0.height > $1.height }) {
            let label = stream.label
            if seen.insert(label).inserted {
                labels.append(label)
            }
        }
        return labels
    }
}
