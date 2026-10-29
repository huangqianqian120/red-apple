import SwiftUI

/// 「刷剧」页：选频道，进播放器一集接一集往下刷。
struct FeedView: View {
    @EnvironmentObject private var app: AppModel
    @State private var channel = "推荐"
    @State private var preview: [SeriesSummary] = []
    @State private var isLoading = false
    @State private var error: String?

    private let channels = ["推荐", "电影", "经典", "真人剧", "漫剧", "大视听"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                PageHeader(title: "刷剧", subtitle: "选一个频道，自动连播不打断") {
                    if isLoading { ProgressView().controlSize(.small) }
                }

                heroCard

                VStack(alignment: .leading, spacing: 10) {
                    Text("频道")
                        .font(Theme.caption(11))
                        .foregroundStyle(Theme.inkTertiary)
                    ChannelPicker(channels: channels, selection: $channel) { name in
                        channel = name
                        Task { await loadPreview() }
                    }
                }

                if let error {
                    ErrorBox(message: error) { Task { await loadPreview() } }
                }

                if !preview.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Text("接下来")
                                .font(Theme.heading(14))
                                .foregroundStyle(Theme.ink)
                            Text("\(preview.count) 部，按这个顺序播")
                                .font(Theme.caption(11))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                        SeriesGrid(items: preview, progressFor: { app.progress(for: $0) }) { series in
                            app.path.append(series.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
        }
        .background(Theme.canvas)
        .navigationTitle("")
        .task { if preview.isEmpty { await loadPreview() } }
    }

    private var heroCard: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("一集接一集，一部接一部")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("播放结束自动接下一集；一部播完自动换下一部，队列见底时后台继续拉。上下滑也能手动切。")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineSpacing(2)
                    .frame(maxWidth: 420, alignment: .leading)
                Button {
                    app.startFeed(channel: channel)
                } label: {
                    Label("开始刷「\(channel)」", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .foregroundStyle(.white)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .pressableScale()
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.accentSoft)
                    .frame(width: 116, height: 92)
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.accent.opacity(0.75))
            }
        }
        .padding(20)
        .cardSurface()
    }

    private func loadPreview() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let page = try await app.catalog.discoverPage(channel: channel, cursor: "")
            preview = page.items
            if preview.isEmpty { error = "这个频道暂时没有内容" }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 频道选择：一条圆角药丸组，选中项白底浮起。
struct ChannelPicker: View {
    var channels: [String]
    @Binding var selection: String
    var onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(channels, id: \.self) { name in
                ChannelChip(name: name, isSelected: selection == name) {
                    selection = name
                    onSelect(name)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ChannelChip: View {
    var name: String
    var isSelected: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 11.5, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Theme.ink : Theme.inkSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? Color.white : (hovering ? Theme.hover : Color.clear))
                        .shadow(color: .black.opacity(isSelected ? 0.07 : 0), radius: 3, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
