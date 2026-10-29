import AppKit
import SwiftUI

/// 拿到承载当前视图的 NSWindow，做几件 SwiftUI 还没 exposed 的事。
///
/// 主要用途：播放窗口不该参与窗口状态恢复——不然上次开着播放器退出，
/// 下次启动会凭空多出几个「没有在播放」的空窗口。
struct WindowConfigurator: NSViewRepresentable {
    var configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window { configure(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window { configure(window) }
        }
    }
}

extension View {
    /// 让窗口不参与状态恢复，也不出现在「重新打开上次的窗口」里。
    func ephemeralWindow() -> some View {
        background(
            WindowConfigurator { window in
                window.isRestorable = false
                window.animationBehavior = .none
            }
            .frame(width: 0, height: 0)
        )
    }

    /// 播放时把窗口底色切成黑，退出播放再切回系统底色。
    ///
    /// 标题栏本身是常驻隐藏的（见 HongguoPlayerApp 的 `.windowStyle(.hiddenTitleBar)`），
    /// 平时由 RootView 的顶部留白把红绿灯让开；播放时画面直接顶到窗口上沿。
    func playerChrome(_ playing: Bool) -> some View {
        background(
            WindowConfigurator { window in
                window.backgroundColor = playing ? .black : .windowBackgroundColor
                window.titlebarSeparatorStyle = playing ? .none : .automatic
            }
            .frame(width: 0, height: 0)
        )
    }
}
