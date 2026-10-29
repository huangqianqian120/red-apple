import AppKit
import Foundation
import SwiftUI

/// 应用级状态：数据源、进度库、播放控制器、当前导航位置。
///
/// 所有 @Published 都在主线程更新，视图直接绑定。
@MainActor
public final class AppModel: ObservableObject {
    public enum Section: String, CaseIterable, Identifiable {
        case discover = "推荐"
        case rank = "短剧榜"
        case search = "搜索"
        case continuing = "继续观看"

        public var id: String { rawValue }

        public var systemImage: String {
            switch self {
            case .discover: return "square.grid.2x2"
            case .rank: return "flame"
            case .search: return "magnifyingglass"
            case .continuing: return "clock.arrow.circlepath"
            }
        }
    }

    public struct Presented: Identifiable {
        public var id = UUID()
        public var seriesID: String
        public var title: String
        public var episodeNumber: Int?
    }

    @Published public var section: Section = .discover
    @Published public var path: [String] = []
    @Published public private(set) var progressBySeries: [String: SeriesProgress] = [:]
    @Published public private(set) var continueWatching: [SeriesProgress] = []
    @Published public private(set) var serviceDescription: String = ""
    @Published public private(set) var isLive = false
    @Published public private(set) var ffmpegPath: String?
    @Published public var presented: Presented?

    public let catalog: CatalogService
    public let playback: PlaybackController
    public let cacheDirectory: URL
    private let progressStore: ProgressStore

    public init() {
        let fileManager = FileManager.default
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let appSupport = support.appendingPathComponent("HongguoPlayer", isDirectory: true)
        let cache = (try? fileManager.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let mediaCache = cache.appendingPathComponent("HongguoPlayer/media", isDirectory: true)
        try? fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: mediaCache, withIntermediateDirectories: true)

        let store = ProgressStore(storeURL: appSupport.appendingPathComponent("progress.json"))
        let service: CatalogService = Self.makeService(profileDirectory: appSupport)
        let ffmpeg = MediaPreparer.locateFFmpeg()

        self.cacheDirectory = mediaCache
        self.progressStore = store
        self.catalog = service
        self.ffmpegPath = ffmpeg?.path
        self.serviceDescription = service.describe
        self.isLive = service.isLive
        self.playback = PlaybackController(
            service: service, progressStore: store, cacheDirectory: mediaCache, ffmpeg: ffmpeg
        )

        // 退出时收掉 sidecar 子进程，别留孤儿。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            if let sidecar = service as? SidecarCatalogService {
                Task { await sidecar.shutdown() }
            }
        }
    }

    /// 数据源优先级：
    ///   1. 环境变量 HONGGUO_FORCE_DEMO=1（离线演示，调 UI 用）
    ///   2. Go sidecar 子进程（只需 Go，不需要 Xcode）
    ///   3. in-process Swift 绑定（需要 gomobile + 完整 Xcode）
    ///   4. 离线演示数据
    private static func makeService(profileDirectory: URL) -> CatalogService {
        let environment = ProcessInfo.processInfo.environment
        let profile = profileDirectory.appendingPathComponent("anonymous.json")

        if environment["HONGGUO_FORCE_DEMO"] == nil,
           let sidecar = SidecarCatalogService.locate(environment: environment) {
            if let service = try? SidecarCatalogService(executable: sidecar, profileURL: profile) {
                return service
            }
            FileHandle.standardError.write(Data("sidecar 启动失败，回退\n".utf8))
        }

        #if canImport(Openhongguo)
        if environment["HONGGUO_FORCE_DEMO"] == nil,
           let live = try? SDKCatalogService(profileURL: profile) {
            return live
        }
        #endif
        return DemoCatalogService()
    }

    // MARK: 播放

    public func play(seriesID: String, title: String, episodeNumber: Int? = nil) {
        presented = Presented(seriesID: seriesID, title: title, episodeNumber: episodeNumber)
        openPlayerWindow?()
        playback.open(seriesID: seriesID, fallbackTitle: title, startAt: episodeNumber)
    }

    public func closePlayer() {
        playback.persistProgress()
        playback.pause()
        presented = nil
        Task { await refreshProgress() }
    }

    /// 打开播放窗口的动作。RootView 拿到 openWindow 后注入，
    /// 这样菜单、详情页、继续观看都能用同一个入口。
    public var openPlayerWindow: (@MainActor () -> Void)?

    /// 冒烟测试用：HONGGUO_OPEN_FILE=/path/to/clip.mp4 启动时直接进播放器。
    /// 真机上也可用来验证播放器不依赖 SDK。
    public func openDebugFileIfRequested() {
        guard presented == nil,
              let path = ProcessInfo.processInfo.environment["HONGGUO_OPEN_FILE"],
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        playback.openLocalFile(url)
        presented = Presented(seriesID: "", title: url.lastPathComponent, episodeNumber: nil)
        openPlayerWindow?()
    }

    /// 冒烟测试/深链接：HONGGUO_AUTO_PLAY=<seriesID>[:<集数>] 启动即播放。
    public func autoPlayIfRequested() {
        guard presented == nil,
              let raw = ProcessInfo.processInfo.environment["HONGGUO_AUTO_PLAY"],
              !raw.isEmpty else { return }
        let parts = raw.split(separator: ":", maxSplits: 2)
        let seriesID = String(parts[0])
        let episode = parts.count > 1 ? Int(parts[1]) : nil
        play(seriesID: seriesID, title: seriesID, episodeNumber: episode)
    }

    public func openLocalFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.message = "选择一个本地视频，用来验证播放器本身（不涉及 SDK）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        playback.openLocalFile(url)
        presented = Presented(seriesID: "", title: url.lastPathComponent, episodeNumber: nil)
        openPlayerWindow?()
    }

    // MARK: 进度

    public func refreshProgress() async {
        let list = await progressStore.continueWatching()
        var map: [String: SeriesProgress] = [:]
        for entry in list { map[entry.seriesID] = entry }
        continueWatching = list
        progressBySeries = map
    }

    public func progress(for seriesID: String) -> SeriesProgress? {
        progressBySeries[seriesID]
    }

    public func forget(seriesID: String) {
        Task {
            await progressStore.remove(seriesID: seriesID)
            await refreshProgress()
        }
    }

    public func clearMediaCache() {
        let controller = playback
        controller.pause()
        controller.reset()
        let directory = cacheDirectory
        Task.detached {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
