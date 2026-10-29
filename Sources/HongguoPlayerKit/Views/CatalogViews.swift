import SwiftUI

// 片库相关的视图：推荐页、继续观看、卡片、网格、提示条。

/// 海报卡片：2:3 封面，悬停时抬起并浮出播放键。
struct SeriesCard: View {
    var series: SeriesSummary
    var progress: SeriesProgress?
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                cover
                VStack(alignment: .leading, spacing: 3) {
                    Text(series.title)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(Theme.caption(10.5))
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 138)
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(series.title)
    }

    private var subtitle: String {
        if let progress, progress.episodeNumber > 1 {
            return progress.isFinished ? "已看完 \(progress.episodeNumber) 集" : "看到第 \(progress.episodeNumber) 集"
        }
        if series.episodeCount > 0 { return "全 \(series.episodeCount) 集" }
        return series.category.isEmpty ? series.author : series.category
    }

    private var cover: some View {
        ZStack(alignment: .bottom) {
            CoverImage(url: series.coverURL, title: series.title)
                .aspectRatio(2.0 / 3.0, contentMode: .fill)
                .frame(height: 206)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(hovering ? 0.14 : 0.05), radius: hovering ? 12 : 3, y: hovering ? 6 : 1)

            if hovering {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.35))
                    .padding(.bottom, 82)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            if let progress, progress.progressFraction > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.35))
                        Capsule()
                            .fill(.white)
                            .frame(width: max(geo.size.width * progress.progressFraction, 3))
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// 封面图：白色骨架占位，加载完淡入。
struct CoverImage: View {
    var url: URL?
    var title: String

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .empty:
                skeleton
            default:
                placeholder
            }
        }
    }

    private var skeleton: some View {
        ZStack {
            Theme.surface
            ProgressView().controlSize(.small).opacity(0.5)
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.05), Color.black.opacity(0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Text(String(title.prefix(4)))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
                .padding(6)
        }
    }
}

/// 自适应网格。
struct SeriesGrid: View {
    var items: [SeriesSummary]
    var progressFor: (String) -> SeriesProgress?
    var onSelect: (SeriesSummary) -> Void

    private let columns = [GridItem(.adaptive(minimum: 138, maximum: 172), spacing: 20)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            ForEach(items) { series in
                SeriesCard(series: series, progress: progressFor(series.id)) {
                    onSelect(series)
                }
            }
        }
    }
}

/// 页头：大标题 + 说明 + 右侧操作。
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(Theme.title())
                    .foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            Spacer()
            trailing()
        }
    }
}

/// 「推荐」页。
struct DiscoverView: View {
    @EnvironmentObject private var app: AppModel
    @State private var items: [SeriesSummary] = []
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                PageHeader(title: "推荐", subtitle: "书城频道「推荐」的短剧") {
                    if isLoading { ProgressView().controlSize(.small) }
                }

                if !app.isLive { DemoBanner() }
                if let error {
                    ErrorBox(message: error) { Task { await load() } }
                }

                if isLoading && items.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 138, maximum: 172), spacing: 20)],
                        alignment: .leading, spacing: 24
                    ) {
                        ForEach(0..<8, id: \.self) { _ in CardSkeleton() }
                    }
                } else {
                    SeriesGrid(items: items, progressFor: { app.progress(for: $0) }) { series in
                        app.path.append(series.id)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
        }
        .background(Theme.canvas)
        .navigationTitle("")
        .task { if items.isEmpty { await load() } }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            items = try await app.catalog.discover()
            await app.refreshProgress()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
                .frame(height: 206)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.surface)
                .frame(height: 11)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.surface)
                .frame(width: 60, height: 9)
        }
        .frame(width: 138)
    }
}

/// 「继续观看」页。
struct ContinueView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                PageHeader(title: "继续观看", subtitle: "上次看到哪儿，接着播") { EmptyView() }

                if app.continueWatching.isEmpty {
                    EmptyState(
                        icon: "clock",
                        title: "还没有观看记录",
                        detail: "播过一集之后，这里会出现你的连续观看列表。"
                    )
                } else {
                    VStack(spacing: 6) {
                        ForEach(app.continueWatching) { entry in
                            ContinueRow(entry: entry)
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
        }
        .background(Theme.canvas)
        .navigationTitle("")
        .task { await app.refreshProgress() }
    }
}

private struct ContinueRow: View {
    @EnvironmentObject private var app: AppModel
    var entry: SeriesProgress

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: URL(string: entry.coverURL), title: entry.title)
                .frame(width: 42, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.75)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(entry.resumeLabel)
                    .font(Theme.caption(10.5))
                    .foregroundStyle(Theme.inkTertiary)
                ProgressBar(fraction: entry.progressFraction)
                    .frame(width: 150)
            }

            Spacer()

            Button {
                app.play(
                    seriesID: entry.seriesID, title: entry.title,
                    episodeNumber: entry.isFinished ? nil : entry.episodeNumber
                )
            } label: {
                Label("继续", systemImage: "play.fill")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Theme.accent, in: Capsule())
            .pressableScale()
            .opacity(hovering ? 1 : 0.85)

            Button {
                app.forget(seriesID: entry.seriesID)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .buttonStyle(.plain)
            .help("忘记这部剧的进度")
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(hovering ? Theme.hover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct ProgressBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairlineStrong)
                Capsule()
                    .fill(Theme.accent.opacity(0.85))
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), 2))
            }
        }
        .frame(height: 3)
    }
}

/// 空状态。
struct EmptyState: View {
    var icon: String
    var title: String
    var detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.inkTertiary)
            Text(title)
                .font(Theme.heading(13))
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(Theme.caption(11.5))
                .foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .fill(Theme.surface.opacity(0.6))
        )
    }
}

/// 演示数据提示条。
struct DemoBanner: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)
            Text("当前是离线演示数据。运行 Scripts/build-sidecar.sh 接入真 SDK 后这里会显示真实片库。")
                .font(Theme.caption(11.5))
                .foregroundStyle(Theme.inkSecondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.75)
        )
    }
}

/// 错误提示。
struct ErrorBox: View {
    var message: String
    var retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
            Text(message)
                .font(Theme.caption(11.5))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
            Spacer()
            Button("重试", action: retry)
                .font(Theme.caption(11.5))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Theme.accentSoft)
        )
    }
}
