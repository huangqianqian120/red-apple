import SwiftUI

/// 短剧详情页：简介 + 分集网格 + 立即播放。
struct SeriesDetailView: View {
    @EnvironmentObject private var app: AppModel
    let seriesID: String

    @State private var info: SeriesInfo?
    @State private var episodes: [Episode] = []
    @State private var error: String?
    @State private var isLoading = true

    private let columns = [GridItem(.adaptive(minimum: 64, maximum: 90), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error {
                    ErrorBox(message: error) { Task { await load() } }
                }
                if let info {
                    header(info)
                    episodeSection
                } else if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .padding(20)
        }
        .navigationTitle(info?.title ?? "加载中")
        .task { await load() }
    }

    private func header(_ info: SeriesInfo) -> some View {
        HStack(alignment: .top, spacing: 16) {
            CoverImage(url: info.coverURL, title: info.title)
                .frame(width: 132, height: 198)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text(info.title).font(.system(size: 20, weight: .bold))
                HStack(spacing: 6) {
                    if info.episodeCount > 0 { Badge(text: "全 \(info.episodeCount) 集") }
                    ForEach(info.tags.prefix(3), id: \.self) { tag in Badge(text: tag) }
                    if info.heat > 0 { Badge(text: "热度 \(info.heat)") }
                }
                if !info.summary.isEmpty {
                    Text(info.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
                if let resume = app.progress(for: info.id) {
                    Text("上次看到 \(resume.resumeLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        app.play(seriesID: info.id, title: info.title, episodeNumber: resumeEpisodeNumber)
                    } label: {
                        Label(resumeEpisodeNumber == nil ? "从第 1 集开始" : "继续第 \(resumeEpisodeNumber!) 集", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                    Button("从第 1 集") {
                        app.play(seriesID: info.id, title: info.title, episodeNumber: 1)
                    }
                }
                .padding(.top, 4)
            }
            Spacer()
        }
    }

    private var resumeEpisodeNumber: Int? {
        guard let resume = app.progress(for: seriesID), !resume.isFinished else { return nil }
        return resume.episodeNumber
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选集").font(.system(size: 14, weight: .semibold))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(episodes) { episode in
                    Button {
                        app.play(seriesID: seriesID, title: info?.title ?? "", episodeNumber: episode.number)
                    } label: {
                        Text("\(episode.number)")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(
                                episode.id == app.progress(for: seriesID)?.episodeID
                                    ? Color.accentColor.opacity(0.25)
                                    : Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .opacity(episode.playable ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .disabled(!episode.playable)
                    .help(episode.displayTitle)
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let infoTask = app.catalog.series(seriesID)
            async let episodesTask = app.catalog.episodes(seriesID: seriesID)
            info = try await infoTask
            episodes = try await episodesTask
            await app.refreshProgress()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct Badge: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.18), in: Capsule())
    }
}
