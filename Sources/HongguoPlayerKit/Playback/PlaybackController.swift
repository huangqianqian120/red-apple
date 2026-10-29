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
    /// 服务端给的这一集总时长；边解边播时 AVPlayer 只知道自己已加载的部分，
    /// 判断「是否真的播完」要用这个值。
    private var expectedDuration: Double = 0
    /// 起播计时：从点播到出画面，用来定位瓶颈。
    private var startClock: Date?
    private func mark(_ label: String) {
        guard let startClock else { return }
        Debug.log(String(format: "[%6.2fs] %@", Date().timeIntervalSince(startClock), label))
    }
    /// AVPlayer 实际已加载的时长（HLS 边解边播时小于总时长）。
    private var loadedDuration: Double = 0
    /// 真实画面宽高比（来自 AVPlayerItem），用来把播放窗口调成合适的形状。
    @Published public private(set) var videoAspectRatio: CGFloat?
    /// 服务端对这个匿名设备返回了空结果：UI 该给一个「换设备」按钮。
    @Published public private(set) var needsDeviceReset = false

    // MARK: 无限流状态

    /// 刷剧队列：当前频道的短剧列表。
    @Published public private(set) var feedQueue: [SeriesSummary] = []
    @Published public private(set) var feedIndex: Int = 0
    @Published public private(set) var feedChannel: String = ""
    /// 下一页的游标；空表示没有更多。
    @Published public private(set) var feedCursor: String = ""
    private var feedHasMore = false
    private var feedLoading = false

    public var isFeedMode: Bool { !feedQueue.isEmpty }
    public var feedPosition: String {
        guard isFeedMode else { return "" }
        return "第 \(feedIndex + 1)/\(feedQueue.count) 部 · \(feedChannel)"
    }

    // MARK: 依赖

    public let player = AVPlayer()
    private let service: CatalogService
    private let preparer: MediaPreparer?
    private let server: LocalMediaServer?
    /// 当前这一集正在流式解密的计划（切集时用来停掉）。
    private var currentStreamPlan: MediaPlan?
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
        ffmpeg: URL?,
        server: LocalMediaServer? = nil
    ) {
        self.service = service
        self.progressStore = progressStore
        self.cacheDirectory = cacheDirectory
        self.server = server
        self.preparer = ffmpeg.flatMap { try? MediaPreparer(cacheDirectory: cacheDirectory, ffmpeg: $0) }
        player.automaticallyWaitsToMinimizeStalling = true
        installObservers()
    }

    // MARK: 对外属性

    public var currentEpisode: Episode? {
        episodes.indices.contains(index) ? episodes[index] : nil
    }

    public var hasNext: Bool {
        nextStep != .end
    }

    public var hasPrevious: Bool {
        previousStep != .end
    }

    private var nextStep: FeedStep {
        FeedNavigation.next(
            episodeIndex: index, episodeCount: episodes.count,
            feedIndex: feedIndex, feedCount: feedQueue.count, isFeedMode: isFeedMode
        )
    }

    private var previousStep: FeedStep {
        FeedNavigation.previous(episodeIndex: index, feedIndex: feedIndex, isFeedMode: isFeedMode)
    }

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
        // 从片库直接点播：退出无限流。
        feedQueue = []
        feedIndex = 0
        load(
            seriesID: seriesID, fallbackTitle: fallbackTitle, startAt: episodeNumber,
            preferredQuality: preferredQuality, keepFeed: false
        )
    }

    /// 装载一部短剧。`keepFeed` 为 true 时不重置无限流队列（切剧用）。
    private func load(
        seriesID: String,
        fallbackTitle: String,
        startAt episodeNumber: Int?,
        preferredQuality: String?,
        keepFeed: Bool = false
    ) {
        if !keepFeed {
            feedQueue = []
            feedIndex = 0
        }
        loadTask?.cancel()
        startClock = Date()
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
                self.mark("series+episodes 就绪（\(list.count) 集）")
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
                Debug.log("loaded \(info.title) episodes=\(list.count)")
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

    public func openLocalFile(_ url: URL) {
        loadTask?.cancel()
        feedQueue = []
        feedIndex = 0
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

    // MARK: 无限流

    /// 进入刷剧模式：从 items[startIndex] 开始，一集播完自动接下一部。
    public func openFeed(_ items: [SeriesSummary], channel: String, startIndex: Int = 0) {
        Debug.log("openFeed channel=\(channel) items=\(items.count) first=\(items.first?.title ?? "-")")
        feedQueue = items
        feedChannel = channel
        feedIndex = min(max(startIndex, 0), max(items.count - 1, 0))
        feedCursor = ""
        feedHasMore = true
        guard let first = items[safe: feedIndex] else { return }
        load(seriesID: first.id, fallbackTitle: first.title, startAt: nil,
             preferredQuality: nil, keepFeed: true)
    }

    /// 往队列尾部再补一页（滑到末尾时调用）。
    public func requestMoreFeedIfNeeded() {
        guard isFeedMode, !feedLoading, feedHasMore, feedIndex >= feedQueue.count - 3 else { return }
        feedLoading = true
        let channel = feedChannel
        let cursor = feedCursor
        Task { [service] in
            let page = try? await service.discoverPage(channel: channel, cursor: cursor)
            await MainActor.run {
                self.feedLoading = false
                guard let page else { return }
                let known = Set(self.feedQueue.map(\.id))
                let fresh = page.items.filter { !known.contains($0.id) }
                self.feedQueue.append(contentsOf: fresh)
                self.feedCursor = page.cursor
                self.feedHasMore = page.hasMore
            }
        }
    }

    private func advanceFeed(to target: Int) {
        Debug.log("advanceFeed -> \(target)")
        guard isFeedMode, feedQueue.indices.contains(target) else {
            requestMoreFeedIfNeeded()
            return
        }
        stopCurrentStream(except: nil)
        feedIndex = target
        guard let summary = feedQueue[safe: target] else { return }
        load(seriesID: summary.id, fallbackTitle: summary.title, startAt: nil,
             preferredQuality: nil, keepFeed: true)
        requestMoreFeedIfNeeded()
    }

    /// 预取某一部的第一集（无限流切剧用）。
    public func prefetchFirstEpisode(of summary: SeriesSummary, after index: Int) {
        guard let preparer, feedQueue.indices.contains(index) else { return }
        let next = feedQueue[index]
        prefetch(seriesID: next.id, episodeNumber: 1, using: preparer)
    }

    private func prefetch(seriesID: String, episodeNumber: Int, using preparer: MediaPreparer) {
        let quality = quality
        Task { [service] in
            guard let episodes = try? await service.episodes(seriesID: seriesID),
                  let episode = episodes.first(where: { $0.number == episodeNumber }),
                  let playback = try? await service.playback(episodeID: episode.id),
                  let stream = playback.select(quality: quality) else { return }
            let plan = MediaPlan(
                episodeID: episode.id, stream: stream, audioURL: playback.audioURL,
                contentKey: playback.contentKey, durationSeconds: playback.durationSeconds,
                quality: stream.definition
            )
            await preparer.prefetchStream(plan)
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
        switch nextStep {
        case .episode(let target):
            stopCurrentStream(except: nil)
            index = target
            resumePosition = 0
            Task { await loadCurrentEpisode() }
        case .series(let target):
            advanceFeed(to: target)
        case .end:
            break
        }
    }

    public func previous() {
        switch previousStep {
        case .episode(let target):
            stopCurrentStream(except: nil)
            index = target
            resumePosition = 0
            Task { await loadCurrentEpisode() }
        case .series(let target):
            advanceFeed(to: target)
        case .end:
            break
        }
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

        // 缓存优先：已经解密过的集不碰网络。限流、断网、服务端改版都能继续看。
        if let preparer, let cached = preparer.cachedEpisode(episode.id, quality: quality) {
            preparedFrom = "本地缓存"
            needsDeviceReset = false
            Debug.log("命中缓存 \(cached.lastPathComponent)")
            attach(url: cached, durationHint: 0)
            return
        }

        do {
            let playback = try await service.playback(episodeID: episode.id)
            mark("playback 就绪（\(playback.streams.count) 个清晰度）")
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
            // 清晰度自带分辨率：比等 AVPlayer 的 presentationSize 更早、更可靠
            // （HLS 流的 presentationSize 要等一阵才有值）。
            if stream.width > 0, stream.height > 0 {
                videoAspectRatio = CGFloat(stream.width) / CGFloat(stream.height)
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
                stopCurrentStream(except: plan)
                // 先用边解边播（长片只等第一片），本地服务不可用时退回整集落盘。
                if let server,
                   let streaming = try? await preparer.startStream(plan, server: server) {
                    mark("HLS 首片就绪")
                    target = streaming
                    currentStreamPlan = plan
                    configuredStreamHandler(preparer)
                } else {
                    target = try await preparer.prepare(plan) { [weak self] value in
                        Task { @MainActor in self?.prepareProgress = value }
                    }
                    currentStreamPlan = nil
                }
            } else {
                stopCurrentStream(except: plan)
                target = plan.stream.url
                preparedFrom = plan.stream.url.host() ?? "CDN"
            }

            expectedDuration = Double(playback.durationSeconds)
            attach(url: target, durationHint: Double(playback.durationSeconds))
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
        mark("attach（" + (url.scheme == "file" ? "本地文件" : "流") + "）")
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
                await self.seekWhenLoaded(to: start)
            }
            if ProcessInfo.processInfo.environment["HONGGUO_PAUSE_ON_OPEN"] != nil {
                // 调试/截图用：不要自动播，控件就不会自动隐藏。
                await self.player.seek(to: CMTime(seconds: max(start, 3), preferredTimescale: 600))
                self.currentTime = max(start, 3)
            } else {
                self.play()
            self.scheduleSeekToEndIfRequested()
            self.scheduleAutoNextIfRequested()
            }
        }
    }

    /// 调试钩子：HONGGUO_AUTO_NEXT=<秒> 起播后 N 秒走一次 next()。
    private func scheduleAutoNextIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["HONGGUO_AUTO_NEXT"],
              let delay = Double(raw) else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.5) * 1_000_000_000))
            await MainActor.run { self?.next() }
        }
    }

    /// 调试钩子：HONGGUO_AUTO_SEEK_END=<秒> 起播后跳到结尾，验证自动连播。
    private func scheduleSeekToEndIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["HONGGUO_AUTO_SEEK_END"],
              let delay = Double(raw) else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.5) * 1_000_000_000))
            guard let self, self.duration > 0 else { return }
            self.seek(to: max(self.duration - 1.5, 0))
            self.play()
        }
    }

    /// 续播要等媒体真的加载到那个位置。
    ///
    /// 边解边播时 playlist 一开始只有几秒，直接 seek 到 1:20 会让 AVPlayer
    /// 停在「等数据」上，看起来就是卡住不动。
    private func seekWhenLoaded(to target: Double) async {
        for _ in 0..<40 {
            if loadedDuration <= 0 || loadedDuration > target + 1 {
                seek(to: target)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // 等不到就从头播，别把用户按在缓冲圈上。
        seek(to: 0)
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
            // HLS event 播放列表的时长是递增的：只允许变长，不要缩回。
            if seconds.isFinite, seconds > 0 {
                loadedDuration = seconds
                duration = max(duration, seconds)
            }
        }
    }

    /// 某一集的流式解密结束时，顺手预取下一集。
    ///
    /// 只在上一集解完之后开始：两个 ffmpeg 同时跑会抢带宽，反而拖慢起播。
    private func configuredStreamHandler(_ preparer: MediaPreparer) {
        Task { [weak self] in
            await preparer.setStreamFinishedHandler { [weak self] directoryName in
                Task { @MainActor in self?.prefetchNextAfterStream(directoryName) }
            }
        }
    }

    private func prefetchNextAfterStream(_ directoryName: String) {
        guard currentStreamPlan?.streamDirectoryName == directoryName else { return }
        if let feedSeries = feedQueue[safe: feedIndex] {
            // 无限流：这一部快播完了就预取下一部的第一集，切剧不等待。
            if !hasNext {
                prefetchFirstEpisode(of: feedSeries, after: feedIndex + 1)
                return
            }
        }
        guard autoplayNext, hasNext, let preparer else { return }
        let next = episodes[index + 1]
        prefetch(episode: next, using: preparer)
    }

    private func prefetch(episode: Episode, using preparer: MediaPreparer) {
        let quality = quality
        Task { [service] in
            guard let playback = try? await service.playback(episodeID: episode.id),
                  let stream = playback.select(quality: quality) else { return }
            let plan = MediaPlan(
                episodeID: episode.id, stream: stream, audioURL: playback.audioURL,
                contentKey: playback.contentKey, durationSeconds: playback.durationSeconds,
                quality: stream.definition
            )
            await preparer.prefetchStream(plan)
        }
    }

    private func stopCurrentStream(except plan: MediaPlan?) {
        guard let preparer, let previous = currentStreamPlan,
              previous.streamDirectoryName != plan?.streamDirectoryName else { return }
        let stopping = previous
        Task { await preparer.stopStream(stopping) }
        currentStreamPlan = nil
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
        // 边解边播时 AVPlayer 会追平已解出的分片：那不是播完，是等下一片。
        if let plan = currentStreamPlan, let preparer {
            let name = plan.streamDirectoryName
            // 服务端时长已知时以它为准：追平已加载分片 ≠ 播完。
            let reachedEnd = expectedDuration <= 0 || currentTime >= expectedDuration - 3
            if !reachedEnd {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard let self, self.currentStreamPlan?.streamDirectoryName == name else { return }
                    self.seek(to: max(self.currentTime - 0.3, 0))
                    self.play()
                }
                return
            }
            Task { [weak self] in
                let complete = await MainActor.run { preparer.isStreamComplete(name) }
                guard let self else { return }
                if complete {
                    self.finishEpisodeAndAdvance()
                } else {
                    // 等 ffmpeg 再产出至少一片，然后从那一片接着播。
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard self.currentStreamPlan?.streamDirectoryName == name else { return }
                    self.seek(to: max(self.currentTime - 0.3, 0))
                    self.play()
                }
            }
            return
        }
        finishEpisodeAndAdvance()
    }

    private func finishEpisodeAndAdvance() {
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
        Debug.log("fail: \(message)")
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
