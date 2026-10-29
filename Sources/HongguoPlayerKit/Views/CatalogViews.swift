import SwiftUI

/// 海报卡片。竖版 2:3，右下角进度条。
struct SeriesCard: View {
    var series: SeriesSummary
    var progress: SeriesProgress?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    CoverImage(url: series.coverURL, title: series.title)
                        .aspectRatio(2.0 / 3.0, contentMode: .fill)
                        .frame(height: 200)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if let progress, progress.progressFraction > 0 {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(.white.opacity(0.9))
                                .frame(width: geo.size.width * progress.progressFraction, height: 3)
                        }
                        .frame(height: 3)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                }
                Text(series.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(series.episodeCount > 0 ? "全 \(series.episodeCount) 集" : series.category)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 136)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(series.title)
    }
}

/// 封面图带渐变占位，加载失败也不留空白。
struct CoverImage: View {
    var url: URL?
    var title: String

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                placeholder
            }
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [.indigo.opacity(0.55), .black.opacity(0.85)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(
            Text(String(title.prefix(6)))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(8)
        )
    }
}

/// 自适应网格。窗口变宽会自动增加列数。
struct SeriesGrid: View {
    var items: [SeriesSummary]
    var progressFor: (String) -> SeriesProgress?
    var onSelect: (SeriesSummary) -> Void

    private let columns = [GridItem(.adaptive(minimum: 136, maximum: 180), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(items) { series in
                SeriesCard(series: series, progress: progressFor(series.id)) {
                    onSelect(series)
                }
            }
        }
    }
}

/// 「推荐」页：加载片库第一页。
struct DiscoverView: View {
    @EnvironmentObject private var app: AppModel
    @State private var items: [SeriesSummary] = []
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !app.isLive {
                    DemoBanner()
                }
                if let error {
                    ErrorBox(message: error) {
                        Task { await load() }
                    }
                }
                if isLoading && items.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    SeriesGrid(items: items, progressFor: { app.progress(for: $0) }) { series in
                        app.path.append(series.id)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("推荐")
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

/// 「继续观看」页。
struct ContinueView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if app.continueWatching.isEmpty {
                    ContentUnavailableView(
                        "还没有观看记录",
                        systemImage: "clock",
                        description: Text("播过一集之后，这里会出现你的连续观看列表。")
                    )
                    .padding(.top, 60)
                } else {
                    ForEach(app.continueWatching) { entry in
                        HStack(spacing: 12) {
                            CoverImage(url: URL(string: entry.coverURL), title: entry.title)
                                .frame(width: 54, height: 76)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title).font(.system(size: 13, weight: .semibold))
                                Text(entry.resumeLabel)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                ProgressView(value: entry.progressFraction)
                                    .progressViewStyle(.linear)
                                    .frame(width: 160)
                            }
                            Spacer()
                            Button("继续") {
                                app.play(
                                    seriesID: entry.seriesID, title: entry.title,
                                    episodeNumber: entry.isFinished ? nil : entry.episodeNumber
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                app.forget(seriesID: entry.seriesID)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("忘记这部剧的进度")
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("继续观看")
        .task { await app.refreshProgress() }
    }
}

struct DemoBanner: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("当前是离线演示数据。运行 Scripts/enable-sdk.sh 接入真 SDK 后这里会显示真实片库。")
                .font(.system(size: 12))
            Spacer()
            if app.ffmpegPath == nil {
                Text("ffmpeg：未找到").font(.system(size: 11)).foregroundStyle(.orange)
            } else {
                Text("ffmpeg：就绪").font(.system(size: 11)).foregroundStyle(.green)
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ErrorBox: View {
    var message: String
    var retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(message).font(.system(size: 12)).textSelection(.enabled)
            Spacer()
            Button("重试", action: retry)
        }
        .padding(10)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
