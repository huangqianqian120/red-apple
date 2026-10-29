import SwiftUI

/// App 入口。真正的 main 在可执行 target 的 main.swift 里。
public struct HongguoPlayerApp: App {
    @StateObject private var app = AppModel()

    public init() {}

    public var body: some Scene {
        WindowGroup("红果短剧") {
            RootView()
                .environmentObject(app)
                .tint(Theme.accent)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 1180, height: 800)
        // 常驻无标题栏：播放时画面要铺到最顶。
        // 平时靠 RootView 的 28pt 顶部留白把红绿灯让出来。
        .windowStyle(.hiddenTitleBar)
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
    }
}
