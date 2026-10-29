import SwiftUI

/// 搜索页：输入关键词，回车搜索，结果网格。
struct SearchView: View {
    @EnvironmentObject private var app: AppModel
    @State private var query = ""
    @State private var results: [SeriesSummary] = []
    @State private var error: String?
    @State private var isLoading = false
    @State private var hasSearched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索短剧、演员、题材", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit { Task { await search() } }
                if isLoading { ProgressView().controlSize(.small) }
                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                        hasSearched = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))

            if let error {
                ErrorBox(message: error) { Task { await search() } }
            }

            ScrollView {
                if results.isEmpty {
                    if hasSearched && !isLoading {
                        ContentUnavailableView.search(text: query)
                            .padding(.top, 50)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("试试这些").font(.system(size: 12)).foregroundStyle(.secondary)
                            FlowChips(items: ["闪婚", "重生", "末世", "甜宠", "玄学", "复仇"]) { word in
                                query = word
                                Task { await search() }
                            }
                        }
                        .padding(.top, 20)
                    }
                } else {
                    SeriesGrid(items: results, progressFor: { app.progress(for: $0) }) { series in
                        app.path.append(series.id)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(20)
        .navigationTitle("搜索")
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

/// 短剧榜。
struct RankView: View {
    @EnvironmentObject private var app: AppModel
    @State private var entries: [RankEntry] = []
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let error {
                    ErrorBox(message: error) { Task { await load() } }
                }
                if isLoading && entries.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(entries) { entry in
                    Button {
                        if !entry.seriesID.isEmpty {
                            app.path.append(entry.seriesID)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(entry.rank)")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(entry.rank <= 3 ? Color.orange : Color.secondary)
                                .frame(width: 26, alignment: .trailing)
                            CoverImage(url: entry.coverURL, title: entry.title)
                                .frame(width: 40, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title).font(.system(size: 13, weight: .medium))
                                HStack(spacing: 8) {
                                    if !entry.score.isEmpty {
                                        Text(entry.score).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    if !entry.actor.isEmpty {
                                        Text(entry.actor).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    if entry.episodeCount > 0 {
                                        Text("全 \(entry.episodeCount) 集").font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            if !entry.seriesID.isEmpty {
                                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(entry.rank <= 3 ? Color.orange.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(20)
        }
        .navigationTitle("短剧榜")
        .task { if entries.isEmpty { await load() } }
    }

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

/// 自动换行的小标签组。
struct FlowChips: View {
    var items: [String]
    var onTap: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button(item) { onTap(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}
