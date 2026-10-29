// swift-tools-version:5.9
//
// 红果短剧桌面播放器（macOS）。
//
// 工程刻意拆成两个 target：
//   HongguoPlayerKit —— 全部逻辑与视图，可被测试导入
//   HongguoPlayer    —— 只有 main.swift，产出可执行文件
//
// 数据层走 CatalogService 协议：默认用 DemoCatalogService（离线样例），
// 启用真 SDK 后换成 SDKCatalogService（见 Scripts/enable-sdk.sh）。
import PackageDescription

let package = Package(
    name: "HongguoPlayer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HongguoPlayer", targets: ["HongguoPlayer"]),
        .library(name: "HongguoPlayerKit", targets: ["HongguoPlayerKit"]),
        .executable(name: "selftest", targets: ["selftest"]),
    ],
    dependencies: [
        // 启用真 SDK 后，enable-sdk.sh 会在这里插入：
        // .package(path: "../openhongguo/bindings/mobile/ios"),
    ],
    targets: [
        .target(
            name: "HongguoPlayerKit",
            dependencies: [
                // 启用真 SDK 后，enable-sdk.sh 会在这里插入：
                // .product(name: "Openhongguo", package: "ios"),
            ],
            path: "Sources/HongguoPlayerKit",
            // 侧栏左上角的品牌图标。走 SwiftPM 资源包，
            // swift run 和打包成 .app 两种跑法都能找到。
            resources: [.copy("Resources/AppMark.png")]
        ),
        .executableTarget(
            name: "HongguoPlayer",
            dependencies: ["HongguoPlayerKit"],
            path: "Sources/HongguoPlayer"
        ),
        // 这台机器只有 Command Line Tools，没有 XCTest / swift-testing，
        // 所以自测写成一个可执行 target：swift run selftest
        .executableTarget(
            name: "selftest",
            dependencies: ["HongguoPlayerKit"],
            path: "Sources/SelfTest"
        ),
    ]
)
