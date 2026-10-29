import SwiftUI

/// 主窗口：左侧 Notion 式侧栏，右侧内容栈，播放时另开窗口。
public struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selection: AppModel.Section? = .discover

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $selection)
                .frame(width: 236)
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
                .ignoresSafeArea()
            detail
        }
        .background(Theme.canvas)
        .frame(minWidth: 900, minHeight: 600)
        .task {
            app.openPlayerWindow = { openWindow(id: "player") }
            app.sectionIfRequested()
            selection = app.section
            app.openSeriesIfRequested()
            await app.refreshProgress()
            app.autoPlayIfRequested()
            app.feedIfRequested()
        }
        .onChange(of: selection) { _, newValue in
            if let newValue { app.section = newValue }
            app.path.removeAll()
        }
    }

    private var detail: some View {
        NavigationStack(path: $app.path) {
            content
                .navigationDestination(for: String.self) { seriesID in
                    SeriesDetailView(seriesID: seriesID)
                }
        }
        .background(Theme.canvas)
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
}

// MARK: - 侧栏

private struct Sidebar: View {
    @EnvironmentObject private var app: AppModel
    @Binding var selection: AppModel.Section?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(AppModel.Section.allCases) { section in
                    SidebarRow(
                        section: section,
                        isSelected: selection == section
                    ) {
                        selection = section
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 12)

            statusCard
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
    }

    private var brand: some View {
        HStack(spacing: 9) {
            AppMark()
                .frame(width: 25, height: 25)

            VStack(alignment: .leading, spacing: 0) {
                Text("红果短剧")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(app.isLive ? "匿名设备" : "演示数据")
                    .font(Theme.caption(10))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
        }
    }

    private var statusCard: some View {
        VStack(spacing: 6) {
            statusRow(
                color: app.isLive ? Color(red: 0.25, green: 0.65, blue: 0.35) : Color.orange,
                text: app.serviceDescription
            )
            statusRow(
                color: app.ffmpegPath == nil ? Theme.accent : Color(red: 0.25, green: 0.65, blue: 0.35),
                text: app.ffmpegPath == nil ? "未找到 ffmpeg" : "ffmpeg 就绪"
            )
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Color.white.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.75)
        )
        .help(app.ffmpegPath ?? "加密分集需要 ffmpeg：brew install ffmpeg")
    }

    private func statusRow(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
                .font(Theme.caption(10))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

private struct SidebarRow: View {
    var section: AppModel.Section
    var isSelected: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Theme.ink : Theme.inkSecondary)
                Text(section.rawValue)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Theme.ink : Theme.inkSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(isSelected ? Theme.selected : (hovering ? Theme.hover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}
