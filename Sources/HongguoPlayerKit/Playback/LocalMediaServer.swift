import Foundation
import Network

/// 最小的本地 HTTP 文件服务，只做一件事：把 HLS 目录喂给 AVPlayer。
///
/// 为什么需要它：AVPlayer 解不了 cenc，必须由 ffmpeg 解密。而长片（红果的电视频道
/// 有 90 分钟的电影）整集落盘要等一两分钟，所以让 ffmpeg 边解边写 HLS 分片，
/// AVPlayer 通过 http://127.0.0.1 逐段拉取——这就是「边解边播」。
///
/// 只监听回环地址，只读指定目录下的文件，不实现 Range/写操作。
public final class LocalMediaServer: @unchecked Sendable {
    private let listener: NWListener
    private let root: URL
    private let queue = DispatchQueue(label: "hongguo.localmedia")
    private(set) var port: UInt16 = 0

    /// 只放行这些扩展名，避免把缓存目录里的日志之类也吐出去。
    private static let allowedExtensions: Set<String> = ["m3u8", "m4s", "mp4", "ts"]

    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        if let assigned = listener.port {
            self.port = assigned.rawValue
        } else {
            throw NSError(domain: "LocalMediaServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "本地端口未就绪"])
        }
    }

    /// 某个相对路径（例如 "ep123_720p/playlist.m3u8"）的完整 URL。
    public func url(for relativePath: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(relativePath)")!
    }

    public func stop() {
        listener.cancel()
    }

    // MARK: 连接处理

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            let request = String(decoding: data, as: UTF8.self)
            let isHead = request.hasPrefix("HEAD ")
            let path = Self.requestPath(request)
            guard let path, let fileURL = self.resolve(path) else {
                self.respond(connection, status: "404 Not Found", body: Data())
                return
            }
            guard let body = try? Data(contentsOf: fileURL) else {
                self.respond(connection, status: "404 Not Found", body: Data())
                return
            }
            self.respond(
                connection,
                status: "200 OK",
                body: isHead ? Data() : body,
                contentType: Self.contentType(for: fileURL.pathExtension),
                contentLength: body.count,
                headOnly: isHead
            )
        }
    }

    private static func requestPath(_ request: String) -> String? {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var path = String(parts[1])
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        return path.removingPercentEncoding
    }

    /// 只接受 "子目录/文件名" 或 "文件名"，且必须落在 root 里面。
    private func resolve(_ path: String) -> URL? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !trimmed.isEmpty, !trimmed.contains("..") else { return nil }
        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        guard Self.allowedExtensions.contains(candidate.pathExtension.lowercased()) else { return nil }
        // 分片是 ffmpeg 边写边被请求的：还没生成时等一会儿，别直接 404，
        // 否则 AVPlayer 会因为「分片不存在」把播放判死。
        if !FileManager.default.fileExists(atPath: candidate.path) {
            guard candidate.pathExtension.lowercased() == "m4s",
                  waitForFile(candidate, timeout: 8) else { return nil }
        }
        return candidate
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path),
               (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 > 0 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private static func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "m4s", "mp4": return "video/mp4"
        case "ts": return "video/mp2t"
        default: return "application/octet-stream"
        }
    }

    private func respond(
        _ connection: NWConnection,
        status: String,
        body: Data,
        contentType: String = "text/plain; charset=utf-8",
        contentLength: Int? = nil,
        headOnly: Bool = false
    ) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(contentLength ?? body.count)\r\n"
        header += "Accept-Ranges: none\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        if !headOnly { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
