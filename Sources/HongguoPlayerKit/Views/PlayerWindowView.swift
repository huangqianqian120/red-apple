import SwiftUI

/// 独立的播放窗口。
///
/// 单独开窗而不是在主窗口里叠一层，好处是：无标题栏、可全屏、可以拖到
/// 另一块屏幕，片库窗口还能继续用。
public struct PlayerWindowView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    public init() {}

    public var body: some View {
        Group {
            switch app.playback.phase {
            case .idle:
                ContentUnavailableView(
                    "没有在播放",
                    systemImage: "play.slash",
                    description: Text("从片库或搜索页选一部短剧开始播放。")
                )
            default:
                PlayerView(controller: app.playback)
            }
        }
        .ephemeralWindow()
        .frame(minWidth: 300, minHeight: 420)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .task {
            // 启动时被状态恢复出来的空播放窗口：自己关掉，别留个死窗口。
            if case .idle = app.playback.phase {
                try? await Task.sleep(nanoseconds: 120_000_000)
                if case .idle = app.playback.phase { dismissWindow() }
            }
        }
        .onDisappear {
            // 用户关窗就等于停止播放，把进度落盘。
            app.closePlayer()
        }
    }
}
