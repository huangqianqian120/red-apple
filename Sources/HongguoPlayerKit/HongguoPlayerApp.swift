import SwiftUI

/// App 入口。真正的 main 在可执行 target 的 main.swift 里。
public struct HongguoPlayerApp: App {
    @StateObject private var app = AppModel()

    public init() {}

    public var body: some Scene {
        WindowGroup("红果短剧") {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开视频文件…") { app.openLocalFile() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .sidebar) {
                Button("清理解密缓存") { app.clearMediaCache() }
                Divider()
                Button("返回片库") { app.path.removeAll() }
                    .keyboardShortcut("[", modifiers: .command)
            }
        }

        // 播放窗口：单实例（Window 而不是 WindowGroup），无标题栏，
        // 竖屏 9:16 的默认尺寸，可以随手拉成全屏。
        Window("播放", id: "player") {
            PlayerWindowView()
                .environmentObject(app)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 460, height: 820)
    }
}
