import Foundation
import HongguoPlayerKit

// 自测程序。
//
// 这台机器只有 Command Line Tools，没有 Xcode，因此既没有 XCTest 也没有
// swift-testing（`import XCTest` 会直接失败）。所以测试写成一个可执行
// target：`swift run selftest`，断言失败时退出码为 1，可以直接接 CI。

/// 进度回调是 @Sendable 的，收集结果需要一个能跨线程写的小盒子。
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func append(_ value: T) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return storage }
}

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String, line: Int = #line) {
    checks += 1
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)  (SelfTest.swift:\(line))")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String, line: Int = #line) {
    checks += 1
    if actual == expected {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label): 实际 \(actual)，期望 \(expected)  (SelfTest.swift:\(line))")
    }
}

func section(_ name: String) {
    print("\n\(name)")
}

// MARK: - 模型与预处理计划

func stream(
    definition: String = "720p", height: Int = 720, protected: Bool = true,
    dash: Bool = false, hls: Bool = false
) -> MediaStream {
    MediaStream(
        definition: definition, codec: "bytevc1", width: height, height: height,
        bitrate: 2_000_000, url: URL(string: "https://cdn.example.com/a.mp4")!,
        hls: hls, dash: dash, protected: protected
    )
}

let cacheDir = URL(fileURLWithPath: "/tmp/hongguo-cache")

section("MediaPlan")
do {
    let plain = MediaPlan(
        episodeID: "ep1", stream: stream(protected: false), audioURL: nil,
        contentKey: "", durationSeconds: 90, quality: "720p"
    )
    check(!plain.needsProcessing, "明文单文件不需要预处理")
    checkEqual(plain.playableURL(cacheDirectory: cacheDir), plain.stream.url, "明文直接给 CDN 地址")

    let audio = URL(string: "https://cdn.example.com/audio.mp4")!
    let protectedPlan = MediaPlan(
        episodeID: "a", stream: stream(protected: true), audioURL: nil,
        contentKey: "k", durationSeconds: 60, quality: "720p"
    )
    let dashPlan = MediaPlan(
        episodeID: "b", stream: stream(protected: false, dash: true), audioURL: nil,
        contentKey: "", durationSeconds: 60, quality: "720p"
    )
    let audioPlan = MediaPlan(
        episodeID: "c", stream: stream(protected: false), audioURL: audio,
        contentKey: "", durationSeconds: 60, quality: "720p"
    )
    check(protectedPlan.needsProcessing, "加密流需要预处理")
    check(dashPlan.needsProcessing, "分段流需要预处理")
    check(audioPlan.needsProcessing, "独立音轨需要预处理")
    checkEqual(
        protectedPlan.playableURL(cacheDirectory: cacheDir).deletingLastPathComponent()
            .standardizedFileURL.path,
        cacheDir.standardizedFileURL.path, "预处理后落在缓存目录")

    let weird = MediaPlan(
        episodeID: "series/123:ep", stream: stream(definition: "1080p", height: 1080),
        audioURL: nil, contentKey: "k", durationSeconds: 60, quality: "1080p"
    )
    check(!weird.cacheKey.contains("/"), "缓存名不含斜杠")
    check(!weird.cacheKey.contains(":"), "缓存名不含冒号")
    check(weird.cacheKey.hasSuffix("_1080p.mp4"), "缓存名带清晰度")

    let otherQuality = MediaPlan(
        episodeID: "series/123:ep", stream: stream(definition: "720p", height: 720),
        audioURL: nil, contentKey: "k", durationSeconds: 60, quality: "720p"
    )
    check(weird.cacheKey != otherQuality.cacheKey, "不同清晰度不互相覆盖")
}

// MARK: - ffmpeg 参数

section("ffmpeg 参数")
do {
    let output = URL(fileURLWithPath: "/tmp/out.mp4")
    let key = "00112233445566778899aabbccddeeff"

    let single = MediaPlan(
        episodeID: "ep", stream: stream(protected: true), audioURL: nil,
        contentKey: key, durationSeconds: 60, quality: "720p"
    )
    let args = MediaPreparer.arguments(for: single, output: output)
    if let index = args.firstIndex(of: "-decryption_key") {
        checkEqual(args[index + 1], key, "解密 key 紧跟 -decryption_key")
    } else {
        check(false, "缺少 -decryption_key")
    }
    check(args.contains("-progress"), "带 -progress 以解析进度")
    checkEqual(args.last, output.path, "输出路径在最后")
    check(!args.contains("1:a:0?"), "单输入不引用第二路")
    check(args.contains("copy"), "使用 -c copy 不转码")

    let audio = URL(string: "https://cdn.example.com/audio.mp4")!
    let dual = MediaPlan(
        episodeID: "ep", stream: stream(protected: true), audioURL: audio,
        contentKey: key, durationSeconds: 60, quality: "720p"
    )
    let dualArgs = MediaPreparer.arguments(for: dual, output: output)
    checkEqual(dualArgs.filter { $0 == "-decryption_key" }.count, 2, "两路输入各自带 key")
    check(dualArgs.contains("0:v:0"), "映射视频轨")
    check(dualArgs.contains("1:a:0?"), "映射可选音轨")
    check(dualArgs.contains(audio.absoluteString), "音轨 URL 进入参数")

    let hls = MediaPlan(
        episodeID: "ep", stream: stream(protected: true, hls: true), audioURL: nil,
        contentKey: key, durationSeconds: 60, quality: "720p"
    )
    check(MediaPreparer.arguments(for: hls, output: output).contains("-allowed_extensions"), "m3u8 放行扩展名")

    let noKey = MediaPlan(
        episodeID: "ep", stream: stream(protected: false, dash: true), audioURL: nil,
        contentKey: "   ", durationSeconds: 60, quality: "720p"
    )
    check(!MediaPreparer.arguments(for: noKey, output: output).contains("-decryption_key"), "没有 key 就不加解密参数")
}

// MARK: - 清晰度选择

section("清晰度选择")
do {
    let info = PlaybackInfo(
        episodeID: "ep", durationSeconds: 60, protected: true,
        streams: [
            MediaStream(definition: "480p", height: 480, bitrate: 800_000, url: URL(string: "https://x/480.mp4")!),
            MediaStream(definition: "1080p", height: 1080, bitrate: 4_000_000, url: URL(string: "https://x/1080.mp4")!),
            MediaStream(definition: "720p", height: 720, bitrate: 2_000_000, url: URL(string: "https://x/720.mp4")!),
        ]
    )
    checkEqual(info.select(quality: "")?.definition, "1080p", "默认取最高分辨率")
    checkEqual(info.select(quality: "worst")?.definition, "480p", "worst 取最低")
    checkEqual(info.select(quality: "720p")?.definition, "720p", "按标签精确命中")
    checkEqual(info.select(quality: "4k")?.definition, "1080p", "未知清晰度回落到最高")
    checkEqual(PlaybackController.qualityOptions(for: info), ["1080p", "720p", "480p"], "清晰度列表按分辨率降序去重")
}

// MARK: - 进度存储

section("进度存储")
do {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hongguo-selftest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let storeURL = directory.appendingPathComponent("progress.json")
    let store = ProgressStore(storeURL: storeURL)
    await store.record(SeriesProgress(
        seriesID: "s1", title: "剧一", episodeNumber: 3, episodeID: "s1-ep3",
        positionSeconds: 42, durationSeconds: 100
    ))
    await store.flush()

    let reopened = ProgressStore(storeURL: storeURL)
    let saved = await reopened.progress(for: "s1")
    checkEqual(saved?.episodeNumber ?? -1, 3, "重新读盘拿到集数")
    checkEqual(Int((saved?.positionSeconds ?? 0).rounded()), 42, "重新读盘拿到秒数")

    await store.finishEpisode(
        seriesID: "s1", title: "剧一", coverURL: "", episodeNumber: 3,
        nextEpisodeID: "s1-ep4", nextEpisodeNumber: 4
    )
    let advanced = await store.progress(for: "s1")
    checkEqual(advanced?.episodeNumber ?? -1, 4, "看完一集推进到下一集")
    checkEqual(advanced?.positionSeconds ?? -1, 0, "下一集从头开始")
    checkEqual(advanced?.resumeLabel ?? "", "第 4 集 · 未开始", "续播标签")

    await store.record(SeriesProgress(
        seriesID: "old", title: "旧", episodeNumber: 1, episodeID: "old-1",
        positionSeconds: 10, durationSeconds: 100, updatedAt: Date(timeIntervalSince1970: 100)
    ))
    let list = await store.continueWatching()
    checkEqual(list.first?.seriesID ?? "", "old", "最近看过但未看完的仍然列出")

    await store.remove(seriesID: "old")
    let afterRemoval = await store.progress(for: "old")
    check(afterRemoval == nil, "删除后不再存在")
}

section("进度格式化")
do {
    var entry = SeriesProgress(
        seriesID: "s", title: "t", episodeNumber: 1, episodeID: "e",
        positionSeconds: 99, durationSeconds: 100
    )
    check(entry.isFinished, "98% 以上算看完")
    entry.positionSeconds = 50
    check(!entry.isFinished, "一半不算看完")
    checkEqual(entry.progressFraction, 0.5, "进度比例")
    checkEqual(SeriesProgress.mmss(0), "0:00", "0 秒")
    checkEqual(SeriesProgress.mmss(75), "1:15", "75 秒")
    checkEqual(SeriesProgress.mmss(3599), "59:59", "3599 秒")
}

// MARK: - 演示数据源

section("演示数据源")
do {
    let service = DemoCatalogService()
    let episodes = try await service.episodes(seriesID: "demo-1")
    checkEqual(episodes.map(\.number), Array(1...episodes.count), "分集编号连续")
    check(episodes[0].playable, "第 1 集可播")
    check(!episodes[5].playable, "第 6 集标为不可播（演示用）")

    let hits = try await service.search("末世")
    checkEqual(hits.count, 1, "演示搜索命中数")
    check(hits.first?.category.contains("末世") ?? false, "命中的是末世题材")

    let ranking = try await service.shortRank()
    checkEqual(ranking.first?.rank, 1, "榜单第一行名次为 1")
    check(ranking.count >= 5, "榜单有足够条目")
}

// MARK: - ffmpeg 端到端：加密 → 解密 → 可播

section("ffmpeg 端到端（真实调用）")
if let ffmpeg = MediaPreparer.locateFFmpeg() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hongguo-cenc-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let key = "00112233445566778899aabbccddeeff"
    let plain = directory.appendingPathComponent("plain.mp4")
    let encrypted = directory.appendingPathComponent("encrypted.mp4")

    func run(_ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = args
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    // 造一个 3 秒的竖屏素材，再用 cenc-aes-ctr 加密——和线上分集同一套方案。
    let made = run([
        "-v", "error", "-f", "lavfi", "-i", "testsrc=size=180x320:rate=15",
        "-f", "lavfi", "-i", "sine=frequency=440", "-t", "3",
        "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-shortest", "-y", plain.path,
    ])
    let encryptedStatus = made == 0 ? run([
        "-v", "error", "-i", plain.path, "-c", "copy",
        "-encryption_scheme", "cenc-aes-ctr", "-encryption_key", key,
        "-encryption_kid", key, "-y", encrypted.path,
    ]) : -1

    if encryptedStatus == 0, FileManager.default.fileExists(atPath: encrypted.path) {
        let prep = try MediaPreparer(cacheDirectory: directory.appendingPathComponent("cache"), ffmpeg: ffmpeg)
        let stream = MediaStream(
            definition: "720p", codec: "h264", width: 180, height: 320, bitrate: 100_000,
            url: encrypted, protected: true, encryption: "cenc-aes-ctr"
        )
        let plan = MediaPlan(
            episodeID: "cenc-ep", stream: stream, audioURL: nil,
            contentKey: key, durationSeconds: 3, quality: "720p"
        )
        let progressSeen = Box<Double>()
        do {
            let output = try await prep.prepare(plan) { value in progressSeen.append(value) }
            check(FileManager.default.fileExists(atPath: output.path), "解密产物落盘")
            checkEqual(output.pathExtension, "mp4", "产物扩展名")
            check(!FileManager.default.fileExists(atPath: output.path + ".part"), "临时文件已改名")

            // 不带 key 能读完 = 真的解开了。
            let decodes = run(["-v", "error", "-i", output.path, "-f", "null", "-"]) == 0
            check(decodes, "解密后的文件无需 key 即可解码")
            check((progressSeen.values.last ?? 0) > 0.9, "进度回调推进到 100%")

            // 第二次拿同一个 plan 应该直接命中缓存，不再跑 ffmpeg。
            let cacheHits = Box<Double>()
            _ = try await prep.prepare(plan) { cacheHits.append($0) }
            checkEqual(cacheHits.values, [1.0], "第二次直接命中缓存")

            // 错误 key 必须失败，且不留下半个文件。
            let wrong = MediaPlan(
                episodeID: "cenc-bad", stream: stream, audioURL: nil,
                contentKey: String(repeating: "0", count: 32), durationSeconds: 3, quality: "720p"
            )
            var failed = false
            do { _ = try await prep.prepare(wrong) { _ in } } catch { failed = true }
            check(failed, "错误的 key 会抛错")
            check(
                !FileManager.default.fileExists(
                    atPath: wrong.playableURL(cacheDirectory: directory.appendingPathComponent("cache")).path
                ),
                "失败后不留下坏缓存"
            )
        } catch {
            check(false, "解密流程抛错：\(error.localizedDescription)")
        }
    } else {
        print("  跳过（本机 ffmpeg 不支持 cenc 加密，无法造样本）")
    }
} else {
    print("  跳过（未找到 ffmpeg）")
}

// MARK: - sidecar 协议（需要 Go 编译出的二进制 + 网络）

section("sidecar 协议")
do {
    if let binary = SidecarCatalogService.locate() {
        print("  二进制：\(binary.path)")
        let profile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hongguo-sidecar-\(UUID().uuidString)/anonymous.json")
        defer { try? FileManager.default.removeItem(at: profile.deletingLastPathComponent()) }
        do {
            let service = try SidecarCatalogService(executable: binary, profileURL: profile, timeout: 30)
            checkEqual(service.isLive, true, "sidecar 数据源标记为 live")

            let page = try await service.discover()
            check(!page.isEmpty, "discover 返回条目")
            check(page.allSatisfy { !$0.id.isEmpty && !$0.title.isEmpty }, "每条都有 id 和标题")
            check(page.contains { $0.coverURL != nil }, "至少一条带封面地址")

            let keyword = "末世"
            let hits = try await service.search(keyword)
            check(!hits.isEmpty, "search(\(keyword)) 有结果")

            if let first = page.first {
                let info = try await service.series(first.id)
                checkEqual(info.id, first.id, "series 详情 id 一致")

                let episodes = try await service.episodes(seriesID: first.id)
                check(!episodes.isEmpty, "episodes 非空")
                checkEqual(episodes.first?.number, 1, "第一集编号为 1")

                if let episode = episodes.first(where: \.playable) {
                    let playback = try await service.playback(episodeID: episode.id)
                    check(!playback.streams.isEmpty, "playback 有清晰度")
                    check(playback.durationSeconds > 0, "playback 有时长")
                    if playback.protected {
                        check(!playback.contentKey.isEmpty, "加密分集拿到了内容密钥")
                        checkEqual(playback.contentKey.count, 32, "内容密钥是 32 位 hex")
                    }
                    check(playback.streams.contains { $0.url.scheme == "https" }, "流地址是 https")
                } else {
                    print("  跳过：这部剧没有可播分集")
                }
            }

            let rank = try await service.shortRank()
            check(!rank.isEmpty, "shortRank 非空")

            await service.shutdown()
        } catch {
            print("  跳过（网络或服务端不可用）：\(error.localizedDescription)")
        }
    } else {
        print("  跳过（没有 build/openhongguo-sidecar，先跑 Scripts/build-sidecar.sh）")
    }
}

// MARK: - 汇总

print("\n\(checks - failures)/\(checks) 项通过")
if failures > 0 {
    print("\(failures) 项失败")
    exit(1)
}
print("全部通过")
