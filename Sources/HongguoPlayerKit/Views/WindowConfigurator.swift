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
}
