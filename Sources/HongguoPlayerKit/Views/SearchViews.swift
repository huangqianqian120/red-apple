import SwiftUI

/// 搜索页：顶部玻璃搜索框 + 结果网格。
struct SearchView: View {
    @EnvironmentObject private var app: AppModel
    @State private var query = ""
    @State private var results: [SeriesSummary] = []
    @State private var error: String?
    @State private var isLoading = false
    @State private var hasSearched = false
    @State private var popular: [SeriesSummary] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                PageHeader(title: "搜索", subtitle: "剧名、演员、题材都能搜") { EmptyView() }

                searchField

                if let error {
                    ErrorBox(message: error) { Task { await search() } }
                }

                if results.isEmpty {
                    if hasSearched && !isLoading {
                        EmptyState(
                            icon: "magnifyingglass",
                            title: "没有找到「\(query)」",
                            detail: "换个关键词试试，或者看看下面的热门标签。"
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("试试这些")
                                .font(Theme.caption(11))
                                .foregroundStyle(Theme.inkTertiary)
                            SuggestionChips(words: ["闪婚", "重生", "末世", "甜宠", "玄学", "复仇"]) { word in
                                query = word
                                Task { await search() }
                            }
                        }

                        if !popular.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("大家都在看")
                                    .font(Theme.heading(14))
                                    .foregroundStyle(Theme.ink)
                                    .padding(.top, 6)
                                SeriesGrid(items: popular, progressFor: { app.progress(for: $0) }) { series in
                                    app.path.append(series.id)
                                }
                            }
                        }
                    }
                } else {
                    SeriesGrid(items: results, progressFor: { app.progress(for: $0) }) { series in
                        app.path.append(series.id)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
        }
        .background(Theme.canvas)
        .navigationTitle("")
        .task { if popular.isEmpty { await loadPopular() } }
    }

    /// 空态不该是白纸：直接铺一屏热门，进来就能点。
    private func loadPopular() async {
        do {
            let entries = try await app.catalog.shortRank()
            popular = entries.prefix(10).map {
                SeriesSummary(
                    id: $0.seriesID, title: $0.title, coverURL: $0.coverURL,
                    episodeCount: $0.episodeCount, author: $0.actor
                )
            }
        } catch {
            // 热门拉不到就不显示，不打断搜索本身。
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkTertiary)
            TextField("搜索短剧", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.body(12.5))
                .foregroundStyle(Theme.ink)
                .onSubmit { Task { await search() } }
            if isLoading {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                    hasSearched = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 380)
        .glassPanel(cornerRadius: 11, interactive: true)
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.75)
        )
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isLoading = true
        hasSearched = true
        error = nil
        defer { isLoading = false }
        do {
            results = try await app.catalog.search(trimmed)
            await app.refreshProgress()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SuggestionChips: View {
    var words: [String]
    var onTap: (String) -> Void

    var body: some View {
        HStack(spacing: 7) {
            ForEach(words, id: \.self) { word in
                Button(word) { onTap(word) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.75))
                    .pressableScale()
            }
        }
    }
}

/// 短剧榜：编号行列表。
struct RankView: View {
    @EnvironmentObject private var app: AppModel
    @State private var entries: [RankEntry] = []
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                PageHeader(title: "短剧榜", subtitle: "红果短剧实时榜单") {
                    if isLoading { ProgressView().controlSize(.small) }
                }

                if let error {
                    ErrorBox(message: error) { Task { await load() } }
                }

                if isLoading && entries.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                .fill(Theme.surface)
                                .frame(height: 56)
                        }
                    }
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            RankRow(entry: entry, position: index + 1)
                        }
                    }
                    .frame(maxWidth: 660, alignment: .leading)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
        }
        .background(Theme.canvas)
        .navigationTitle("")
        .task { if entries.isEmpty { await load() } }
    }

    // 上游的 rank 字段会重复（两条都是 1），所以名次按返回顺序算。

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            entries = try await app.catalog.shortRank()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct RankRow: View {
    @EnvironmentObject private var app: AppModel
    var entry: RankEntry
    var position: Int = 1

    @State private var hovering = false

    var body: some View {
        Button {
            if !entry.seriesID.isEmpty { app.path.append(entry.seriesID) }
        } label: {
            HStack(spacing: 12) {
                Text("\(position)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(position <= 3 ? Theme.accent : Theme.inkTertiary)
                    .frame(width: 22, alignment: .trailing)

                CoverImage(url: entry.coverURL, title: entry.title)
                    .frame(width: 34, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 0.75)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(Theme.body(12.5))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if !entry.actor.isEmpty {
                            Text(entry.actor).font(Theme.caption(10.5)).foregroundStyle(Theme.inkTertiary)
                        }
                        if !entry.score.isEmpty {
                            Text(entry.score).font(Theme.caption(10.5)).foregroundStyle(Theme.inkTertiary)
                        }
                        if entry.episodeCount > 0 {
                            Text("全 \(entry.episodeCount) 集").font(Theme.caption(10.5)).foregroundStyle(Theme.inkTertiary)
                        }
                    }
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(hovering ? Theme.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
