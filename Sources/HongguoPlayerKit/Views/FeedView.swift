import SwiftUI

/// 「刷剧」页：选一个频道，进播放器一集接一集往下刷。
///
/// 这是无限流模式的入口。播放器里一集播完自动切下一集，一部播完自动切下一部，
/// 队列见底时后台再拉一页——用户可以一直刷下去。
struct FeedView: View {
    @EnvironmentObject private var app: AppModel
    @State private var channel = "推荐"
    @State private var preview: [SeriesSummary] = []
    @State private var isLoading = false
    @State private var error: String?

    private let channels = ["推荐", "电影", "经典", "真人剧", "漫剧", "大视听"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("无限流刷剧")
                        .font(.system(size: 20, weight: .bold))
                    Text("选一个频道，播放器会按顺序自动连播：一集播完接下一集，一部播完接下一部。上下滑也可以手动切。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    ForEach(channels, id: \.self) { name in
                        Button {
                            channel = name
                            Task { await loadPreview() }
                        } label: {
                            Text(name)
                                .font(.system(size: 12, weight: channel == name ? .semibold : .regular))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    channel == name ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }

                HStack(spacing: 10) {
                    Button {
                        app.startFeed(channel: channel)
                    } label: {
                        Label("开始刷「\(channel)」", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if isLoading { ProgressView().controlSize(.small) }
                }

                if let error {
                    ErrorBox(message: error) { Task { await loadPreview() } }
                }

                if !preview.isEmpty {
                    Text("接下来会按这个顺序播（\(preview.count) 部）")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    SeriesGrid(items: preview, progressFor: { app.progress(for: $0) }) { series in
                        app.path.append(series.id)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("刷剧")
        .task { if preview.isEmpty { await loadPreview() } }
    }

    private func loadPreview() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let page = try await app.catalog.discoverPage(channel: channel, cursor: "")
            preview = page.items
            if preview.isEmpty {
                error = "这个频道暂时没有内容"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
