import SwiftUI

/// 短剧详情：左封面、右信息，下面是选集。
struct SeriesDetailView: View {
    @EnvironmentObject private var app: AppModel
    let seriesID: String

    @State private var info: SeriesInfo?
    @State private var episodes: [Episode] = []
    @State private var error: String?
    @State private var isLoading = true

    private let columns = [GridItem(.adaptive(minimum: 58, maximum: 74), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                if let error {
                    ErrorBox(message: error) { Task { await load() } }
                }

                if let info {
                    header(info)
                    episodesSection
                } else if isLoading {
                    detailSkeleton
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
        }
        .background(Theme.canvas)
        .navigationTitle("")
        .task { await load() }
    }

    // MARK: 头部

    private func header(_ info: SeriesInfo) -> some View {
        HStack(alignment: .top, spacing: 20) {
            CoverImage(url: info.coverURL, title: info.title)
                .frame(width: 148, height: 222)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.10), radius: 14, y: 6)

            VStack(alignment: .leading, spacing: 10) {
                Text(info.title)
                    .font(Theme.title(24))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    ForEach(detailTags(info), id: \.self) { Tag(text: $0) }
                }

                if !info.summary.isEmpty {
                    Text(info.summary)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineSpacing(3)
                        .lineLimit(5)
                        .textSelection(.enabled)
                }

                if let resume = app.progress(for: info.id) {
                    HStack(spacing: 5) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10))
                        Text("上次看到 \(resume.resumeLabel)")
                            .font(Theme.caption(11))
                    }
                    .foregroundStyle(Theme.inkTertiary)
                }

                HStack(spacing: 10) {
                    Button {
                        app.play(
                            seriesID: info.id, title: info.title,
                            episodeNumber: resumeEpisodeNumber ?? 1
                        )
                    } label: {
                        Label(
                            resumeEpisodeNumber == nil ? "从第 1 集开始" : "继续第 \(resumeEpisodeNumber!) 集",
                            systemImage: "play.fill"
                        )
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .foregroundStyle(.white)
                        .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .pressableScale()
                    .keyboardShortcut(.return, modifiers: [])

                    Button {
                        app.play(seriesID: info.id, title: info.title, episodeNumber: 1)
                    } label: {
                        Text("从第 1 集")
                            .font(.system(size: 12))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(Theme.ink)
                            .background(Theme.hover, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .pressableScale()
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private var resumeEpisodeNumber: Int? {
        guard let resume = app.progress(for: seriesID), !resume.isFinished else { return nil }
        return resume.episodeNumber
    }

    // MARK: 选集

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("选集")
                    .font(Theme.heading(14))
                    .foregroundStyle(Theme.ink)
                Text("\(episodes.count) 集")
                    .font(Theme.caption(11))
                    .foregroundStyle(Theme.inkTertiary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(episodes) { episode in
                    EpisodeChip(
                        episode: episode,
                        isCurrent: episode.id == app.progress(for: seriesID)?.episodeID
                    ) {
                        app.play(seriesID: seriesID, title: info?.title ?? "", episodeNumber: episode.number)
                    }
                }
            }
        }
    }

    private var detailSkeleton: some View {
        HStack(alignment: .top, spacing: 20) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
                .frame(width: 148, height: 222)
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 5).fill(Theme.surface).frame(width: 240, height: 22)
                RoundedRectangle(cornerRadius: 5).fill(Theme.surface).frame(width: 160, height: 12)
                RoundedRectangle(cornerRadius: 5).fill(Theme.surface).frame(width: 320, height: 12)
                RoundedRectangle(cornerRadius: 5).fill(Theme.surface).frame(width: 280, height: 12)
            }
            Spacer()
        }
    }

    /// 接口给的 tags 里已经夹着「全1000集」「红果热度值 5442 万」，
    /// 直接再补一遍会出现两套说法，所以先按语义去重再拼。
    private func detailTags(_ info: SeriesInfo) -> [String] {
        let hasEpisodeTag = info.tags.contains { $0.contains("集") }
        let hasHeatTag = info.tags.contains { $0.contains("热度") }
        var out: [String] = []
        if info.episodeCount > 0, !hasEpisodeTag {
            out.append("全 \(info.episodeCount) 集")
        }
        out.append(contentsOf: info.tags.filter { tag in
            !(hasEpisodeTag && tag.contains("集")) || tag.contains("全")
        }.prefix(3))
        if info.heat > 0, !hasHeatTag {
            out.append("热度 \(info.heat)")
        }
        return Array(out.prefix(4))
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

/// 选集按钮。
private struct EpisodeChip: View {
    var episode: Episode
    var isCurrent: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("\(episode.number)")
                .font(.system(size: 11.5, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? .white : (episode.playable ? Theme.ink : Theme.inkTertiary))
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .strokeBorder(isCurrent ? Color.clear : Theme.hairline, lineWidth: 0.75)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!episode.playable)
        .onHover { hovering = $0 }
        .help(episode.displayTitle)

    }

    private var fill: Color {
        if isCurrent { return Theme.accent }
        if !episode.playable { return Theme.surface.opacity(0.5) }
        return hovering ? Theme.hover : Theme.surface
    }
}

/// 小标签。
struct Tag: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.75))
    }
}
