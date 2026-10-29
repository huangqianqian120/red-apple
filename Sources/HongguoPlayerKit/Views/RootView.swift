import SwiftUI

/// 主窗口：左侧分区列表，右侧内容栈，播放时叠加全屏播放器。
public struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selection: AppModel.Section? = .discover

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(AppModel.Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 210)
            .safeAreaInset(edge: .bottom) { statusFooter }
        } detail: {
            NavigationStack(path: $app.path) {
                content
                    .navigationDestination(for: String.self) { seriesID in
                        SeriesDetailView(seriesID: seriesID)
                    }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            app.openPlayerWindow = { openWindow(id: "player") }
            await app.refreshProgress()
            app.autoPlayIfRequested()
            app.feedIfRequested()
            app.openDebugFileIfRequested()
        }
        .onChange(of: selection) { _, newValue in
            if let newValue { app.section = newValue }
            app.path.removeAll()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch app.section {
        case .feed: FeedView()
        case .discover: DiscoverView()
        case .rank: RankView()
        case .search: SearchView()
        case .continuing: ContinueView()
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 5) {
                Circle()
                    .fill(app.isLive ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(app.serviceDescription)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(app.ffmpegPath == nil ? Color.red : Color.green)
                    .frame(width: 6, height: 6)
                Text(app.ffmpegPath == nil ? "未找到 ffmpeg" : "ffmpeg 就绪")
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .help(app.ffmpegPath ?? "加密分集需要 ffmpeg：brew install ffmpeg")
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
