import AppKit
import HongguoPlayerKit

// `swift run` 产出的可执行文件没有 .app 包，默认不会出现在 Dock 里，
// 也没有正常的菜单栏。这两行让它在裸跑时也像一个正常 App。
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.activate(ignoringOtherApps: true)

HongguoPlayerApp.main()
