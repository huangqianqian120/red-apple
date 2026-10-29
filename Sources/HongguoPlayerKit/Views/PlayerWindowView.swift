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
            // 看 presented（AppModel 自己的 @Published）而不是 playback.phase：
            // phase 在另一个 ObservableObject 里，这个视图观察不到它，
            // 用 phase 判断会永远停在初始状态。
            if app.presented != nil {
                PlayerView(controller: app.playback)
            } else {
                ContentUnavailableView(
                    "没有在播放",
                    systemImage: "play.slash",
                    description: Text("从片库或搜索页选一部短剧开始播放。")
                )
                .background(Theme.canvas)
            }
        }
        .ephemeralWindow()
        .frame(minWidth: 300, minHeight: 420)
        .background(Color.black)
        .preferredColorScheme(.dark)   // 播放窗口浮层用深色玻璃
        .tint(.white)
        .onAppear { Debug.log("PlayerWindow onAppear") }
        .task {
            // 启动时被状态恢复出来的空播放窗口：自己关掉，别留个死窗口。
            // 注意要同时看 presented：无限流/点播是先把窗口打开、再去请求数据，
            // 只看 phase 会把正在等数据的窗口误杀。
            try? await Task.sleep(nanoseconds: 400_000_000)
            if app.presented == nil, case .idle = app.playback.phase {
                dismissWindow()
            }
        }
        .onDisappear {
            Debug.log("PlayerWindow onDisappear")
            // 用户关窗就等于停止播放，把进度落盘。
            app.closePlayer()
        }
    }
}
