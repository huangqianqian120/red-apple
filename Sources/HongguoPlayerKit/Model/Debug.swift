import Foundation

/// 调试日志。默认安静，HONGGUO_DEBUG=1 时才输出。
enum Debug {
    static let enabled = ProcessInfo.processInfo.environment["HONGGUO_DEBUG"] != nil

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[hongguo] \(message())\n".utf8))
    }
}
