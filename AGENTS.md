# RED APPLE（红果短剧 macOS 播放器）

非官方 macOS 客户端，仅供学习研究，禁止商用。基于 `beilunyang/openhongguo`（Apache-2.0）
匿名接口 SDK。**不开源分发、不上 App Store**（DRM + 审核 5.2）。

SwiftPM 工程，四个产物：`HongguoPlayerKit`（库）+ `HongguoPlayer`（App 可执行）+
`selftest`（自测，机器上没有 XCTest）+ `sidecar/`（Go，真 SDK 桥）。

## 构建 / 验证

```bash
cd ~/Projects/hongguo-player
swift build                      # 编译
swift run selftest               # 81 项断言，改逻辑必跑
./Scripts/make-app.sh release    # → build/RED APPLE.app（含 icns + resource bundle + sidecar）
open "build/RED APPLE.app"
```

Go sidecar（拉真数据必需，App 会自动找 `Contents/Resources/openhongguo-sidecar`）：

```bash
export PATH="$HOME/sdk/go/bin:$HOME/go/bin:$PATH"
GOPROXY=https://goproxy.cn,direct ./Scripts/build-sidecar.sh ~/Projects/openhongguo
```

没有 sidecar 时自动退回 `DemoCatalogService` 演示数据，App 仍能跑（离线可用）。

桌面副本（用户习惯用这个）：`~/Desktop/RED APPLE.app`，更新后 ditto 覆盖一次。

## 结构

```
Sources/HongguoPlayerKit/
  Design/Theme.swift          配色/字号/圆角/间距 + glassPanel + cardSurface + AppMark
  Model/Models.swift          SeriesSummary/SeriesInfo/Episode/MediaStream/PlaybackInfo/RankEntry
  Model/Debug.swift           Debug.log，HONGGUO_DEBUG=1 才输出
  Services/CatalogService     协议 + Demo 实现
  Services/SidecarCatalogService  行 JSON 协议，goroutine-per-request
  Services/SDKCatalogService  in-process 绑定（需 gomobile，未验证）
  Playback/MediaPreparer      ffmpeg 解密 + 校验 + 磁盘缓存 + 预取
  Playback/PlaybackController AVPlayer 编排、切集、自动下一集
  Playback/LocalMediaServer   本地 HLS，边解边播
  Playback/FeedNavigation     无限流队列
  Playback/ProgressStore      进度记忆
  Views/*                     AppModel + RootView(侧栏) + 各页 + PlayerView
sidecar/main.go               行 JSON：search/series/episodes/playback/discover
```

## 关键决策（别推翻，除非有明确理由）

- **ffmpeg 解密到磁盘 + AVPlayer 播**，不用 libmpv（GPL 传染）。ffmpeg 只用 LGPL 组件。
- **Go sidecar 而非 gomobile**：`go build` 只要 Go，不需要完整 Xcode；协议是纯文本行 JSON，能单独跑。
- **解密必须验帧**（`-frames:v 1 -f null -`）：`-c copy` 用错 key 也会"成功"，会缓存坏文件。
- **缓存优先于网络**：已解密过的集不碰网络，限流/断网也能续看。
- **本地 HLS 边解边播**：长片起播 1.2–3.6s，不用等整集下完。
- **集播完靠服务端 `expectedDuration`**（`currentTime >= expectedDuration - 3`）；
  用 AVPlayer 的 `.didPlayToEnd` 会被 HLS 追帧误触发。
- **播放器是主窗口内嵌层**（RootView ZStack 覆盖），不是独立窗口。
- **窗口常驻 `.hiddenTitleBar`**：平时 RootView 顶部 28pt 安全带（左 236 侧栏灰 + 右画布白）
  把红绿灯让开，播放时整窗黑底、画面铺到上沿。
- **不要动 `styleMask` 插 `.fullSizeContentView`**：SwiftUI 会重算内容尺寸，
  窗口 800→832→864 长高且位置偏移，退出也回不来。只改外观（backgroundColor / toolbar）。
- **selftest 是可执行 target**：机器只有 Command Line Tools，没有 XCTest / swift-testing。

## 坑

1. **玻璃只用在浮层**（搜索框、播放器控件、弹层）。白底上铺玻璃会糊；
   播放器里玻璃要 tint 黑 18–42%，否则亮画面上白字不可读。
2. **图标必须透明底**，图形占 ~86%：macOS 26 Dock 会自己垫玻璃托盘，再叠白底变双层。
3. **图标放大小心 alpha**：ffmpeg 缩放会把透明压成黑块，必须走 CoreImage
   （`CILanczosScaleTransform` + `CISharpenLuminance`），见 `Scripts/make-icon.swift`。
4. **SwiftPM 资源包要手动搬**：`$bin/*.bundle` 不拷进 `Contents/Resources/`，
   `Bundle.module` 在 .app 里找不到 `AppMark.png`。
5. **`qlmanage -t` 会卡死**（120s 超时），验图标用 `sips -s format png AppIcon.icns --out /tmp/x.png`。
6. **`toggleFullScreen` 不可靠**（从终端/后台启动时窗口跑到未激活的 Space），
   所以横屏是"铺满屏幕的 frame"而不是原生全屏。
7. **节流**：匿名设备额度会用尽（sidecar 会打「匿名设备额度用尽，换一台重试」），
   大量自动测试前先清 `~/Library/Application Support/HongguoPlayer/anonymous.json` 要谨慎（等于换设备）。
8. **上游 API 小毛病**：`shortRank()` 返回 `[RankEntry]`（没有 `.series`）；`rank` 字段会重复
   （所以列表序号按数组顺序算）；tags 里自带「全1000集」「红果热度值…」（详情页要 dedupe）。

## 调试 / 截图流程

```bash
# 直接开某页 / 某剧 / 某集（省得手点）
HONGGUO_SECTION=rank HONGGUO_OPEN_SERIES=7699823871876156441 \
HONGGUO_AUTO_PLAY=7673415977467382809:1 HONGGUO_PAUSE_ON_OPEN=1 \
"build/RED APPLE.app/Contents/MacOS/HongguoPlayer"

# 列窗口 → 挑 Width = 1180 那个 → 单窗截图
/tmp/winbypid <pid>
screencapture -x -o -l<windowNumber> /tmp/shot.png
```

后台启动的窗口 `onscreen=false` 时，先 `open -b dev.hongguo.player` 激活再截。

## 环境变量

| 变量 | 作用 |
|---|---|
| `HONGGUO_SECTION` | `feed`/`discover`/`rank`/`search`/`continue`，启动直达 |
| `HONGGUO_OPEN_SERIES` | 直接打开某剧详情页（须在 section 同步之后生效） |
| `HONGGUO_AUTO_PLAY` | `<seriesID>[:<集>]` 直接起播 |
| `HONGGUO_OPEN_FILE` | 打开本地视频文件 |
| `HONGGUO_PAUSE_ON_OPEN` | 起播后立刻暂停（截图用） |
| `HONGGUO_FEED` / `HONGGUO_AUTO_NEXT` / `HONGGUO_AUTO_SEEK_END` | 无限流自动化测试 |
| `HONGGUO_FORCE_DEMO` | 强制演示数据 |
| `HONGGUO_DEBUG` | 打印时间线日志 |
| `HONGGUO_SIDECAR` / `HONGGUO_FFMPEG` | 指定二进制路径 |

## 状态

已完成：竖屏全屏上下滑切集、进度记忆续播、搜索+榜单、倍速/清晰度、横屏长片、
无限流刷剧、起播 1.25s、白色极简 + 液体玻璃 UI、真图标与品牌名 RED APPLE、
详情页按钮去重、播放器内嵌主窗口。

未做/待办：真·原生全屏（见坑 6）、批量预取整条 playlist、
in-process Swift 绑定（需完整 Xcode 做 `gomobile bind -target macos`）。
