# RED APPLE · 红果短剧 macOS 播放器

![license](https://img.shields.io/badge/license-MIT-blue)

基于 [`openhongguo`](https://github.com/beilunyang/openhongguo) SDK 的 macOS 桌面短剧播放器。
竖屏刷剧、上下滑切集、自动连播、进度记忆、倍速与清晰度切换。

界面走「白色极简 + 液体玻璃」：纯白画布、暖黑文字、圆角卡片，玻璃只出现在
浮在内容之上的层级（搜索框、播放器控件、弹层），不当装饰用。

---

## ⚠️ 免责声明（先读这段）

- **非官方项目。** 与红果短剧、字节跳动、番茄小说及其关联方**无任何关联**，未获其授权或认可。
  相关名称与商标归各自权利人所有，本项目仅作技术指代。
- **仅供个人学习与研究**，议题限于 macOS/SwiftUI 应用架构、DASH/HLS 分片处理、
  播放器工程与界面设计。**禁止任何形式的商业使用**，禁止售卖、二次分发、
  部署为对外服务。
- **不提供、不存储、不传播任何片源。** 所有内容、封面、字幕的版权归原权利人。
  本项目不含任何内容文件，也不含任何硬编码的内容密钥——设备注册、签名、
  密钥获取由上游 SDK 在运行时向服务端请求，本仓库只实现「拿到地址和密钥之后
  如何在本地解密落盘并播放」这一段工程管线。
- **请注意**：即使密钥由第三方取得，使用本程序播放加密内容在多数法域仍可能构成
  规避技术措施，属于法律风险行为，与是否开源无关。请自行确认你所在地区的法律
  与平台条款，**由使用者承担全部责任**；作者不对任何使用后果负责。
- 若权利人认为本项目侵权，请通过仓库 Issue 或邮件联系作者，本项目将立即下架。
- 本项目随时可能停止维护或删除。不要把这里的任何代码当作合规指南。

---

## 现状（已在本机跑通）

| 部分 | 状态 |
|---|---|
| 真片库 / 搜索 / 榜单 / 详情 | ✅ 接真 API，封面（含 HEIC）正常 |
| 播放加密分集 | ✅ 播真实剧集，画面/字幕/进度正常 |
| **边解边播（本地 HLS）** | ✅ 首片就播，长片不再等整集落盘 |
| **横屏长片** | ✅ 《僵尸先生》97 分钟、DASH 分片 + 独立音轨，实测可播 |
| **无限流刷剧** | ✅ 一集接一集、一部接一部，队列见底自动补页 |
| 解密缓存 + 下一集预取 | ✅ 二次播放 6 秒内出画面，下一集后台备好 |
| 进度记忆 / 断点续播 | ✅ 自测覆盖，落盘 JSON |
| 横屏/竖屏窗口适配 | ✅ 按真实分辨率自动切换 16:9 / 9:16 |
| 匿名设备被限流 | ✅ sidecar 自动换设备重试一次，UI 也能手动换 |

自测：`swift run selftest` → **81/81 通过**（含真实 ffmpeg cenc 往返、真实 API 往返、
无限流导航边界）。

## 开源发布前 checklist

仓库里已经放好 `LICENSE`（MIT）、`NOTICE`、`LICENSES/Apache-2.0.txt`，
README 顶部有免责声明。真要推到 GitHub 之前，还有几件事必须人工处理：

1. **确认图标授权**。`Resources/AppIcon-source.svg` 来自 iconfont.cn 的第三方图标，
   版权归上传者；放进公开仓库属于再分发，请回原页面确认它标注的许可（可商用 /
   需署名），或者自己重画一个再替换（图形很简单：圆 + 叶柄 + 笑脸弧）。
   `AppIcon-1024.png` 与 `AppMark.png` 都是它的衍生物，同源同许可。
2. **别提交 `sidecar/go.mod` 里的 `replace` 行**。`build-sidecar.sh` 每次构建都会把
   它改写成本机绝对路径（`/Users/xxx/Projects/openhongguo`），换机器就废了。
3. **确认本机状态没进版本库**：`anonymous.json`（设备凭据）、`progress.json`、
   `~/Library/Caches/HongguoPlayer/media/` 下的解密文件，都已加进 `.gitignore`。
4. **不要传 Release 二进制**（`*.app` / `*.dmg`）。分发可执行文件比发源码风险高得多，
   还牵涉签名与公证。
5. **仓库名与描述不要用官方商标**，别用官方 logo 做头像；截图里尽量少带片名封面。
6. 如果你打算长留这个仓库，建议先找律师看一遍上面的免责声明——它降低风险，
   但不构成免责保证。

## 快速开始

```sh
# 1. 编译 App 本体
swift build

# 2. 编译访问真 API 的 Go sidecar（需要 Go，不需要 Xcode）
./Scripts/build-sidecar.sh

# 3. 打包成 .app（会把 sidecar 一起塞进 Resources）
./Scripts/make-app.sh
open "build/RED APPLE.app"

# 自测
swift run selftest
```

没有 Go / 没有 sidecar 时 App 会自动退回**离线演示数据**，播放器本身仍可用
（⌘O 打开本地视频）。

## 为什么要 Go sidecar

上游 SDK 是多语言绑定，官方 macOS 路径是 `gomobile bind -target macos` 产出
`OpenhongguoCore.xcframework`。但 `gomobile` **强制要求完整 Xcode**（这台机器只有
Command Line Tools，直接报 `gomobile: -target="macos" requires Xcode`）。

所以改成子进程：`go build` 不需要 Xcode，纯 Go 就能出原生 arm64 二进制，
App 用一行一 JSON 的协议跟它说话。

```swift
// 一条请求
{"id":1,"method":"playback","args":["7699829153155009598"]}
// 一条响应
{"id":1,"result":{"episodeId":"…","protected":true,"key":"cbe11e49…","streams":[…]}}
```

方法：`ping` `discover` `search` `series` `episodes` `playback` `shortRank` `resetDevice`。
契约定义在 `sidecar/main.go` 的 wire 类型里，Swift 侧在
`Services/SidecarCatalogService.swift` 的 DTO 里，两边都是手写的，改一处要改两处。

好处：不依赖 ABI/codegen，出问题可以脱离 App 复现：

```sh
echo '{"id":1,"method":"search","args":["末世"]}' | ./build/openhongguo-sidecar
```

`Package.swift` 里还留着 in-process 绑定的位置（`#if canImport(Openhongguo)`）：
装上完整 Xcode 后跑 `Scripts/enable-sdk.sh` 就会优先用 in-process 版本。

## 无限流刷剧

侧边栏「刷剧」选频道（推荐 / 电影 / 经典 / 真人剧 / 漫剧 / 大视听），进播放器后：

- 一集播完 → 下一集；**一部播完 → 下一部**（自动装载新剧、从第 1 集开始）
- 队列剩 3 部时后台自动拉下一车内容，可以一直刷
- 上一集解码结束后才预取下一集，避免两个 ffmpeg 抢带宽
- 顶栏显示「第 N/M 部 · 频道」，最后一集时出现「下一部」按钮
- 横屏内容自动铺满屏幕（菜单「显示 › 横屏剧自动铺满屏幕」可关），竖屏保持窄窗

跨集 / 跨剧 / 到头的判定抽成了纯函数 `FeedNavigation`，8 条边界都有测试
（这类 off-by-one 一旦写错就是「连着连着卡住」，很难在 UI 上复现）。

## 播放链路

服务端给的流有三种形态，决定了播放器怎么做：

| 形态 | 处理 |
|---|---|
| 明文单文件 MP4 | 直接把 URL 交给 AVPlayer，不落盘 |
| 加密单文件（cenc-aes-ctr） | ffmpeg `-decryption_key` + `-c copy` → 本地明文 MP4，或直接切 HLS |
| byte-range DASH + 独立音轨 | ffmpeg 双输入各带 key + `-map` 拼成一路 |

解密有两条路，起播优先走第一条：

1. **边解边播（HLS）**：`ffmpeg -f hls -hls_time 4 -hls_playlist_type event` 把解密后的
   数据切成 fMP4 分片，App 起一个 `127.0.0.1` 的最小 HTTP 服务，AVPlayer 逐段拉。
   只等第一片（约 2 秒）就能出画面，播完的分片留在磁盘上，下次直接命中。
2. **整集落盘**：HLS 起不来（或本地服务端口失败）时退回老路——整集 decrypt 成 mp4，
   校验解码一帧后播放。

```
sidecar: resolvePlayback ──▶ 选清晰度 ──▶ MediaPlan（地址 + key + 时长）
                                             │
                              ┌──────────────┴──────────────┐
                        不需要处理                     需要处理
                              │                             │
                    AVPlayer(CDN 直连)        ffmpeg 解密 → 缓存 MP4 → 解码校验一帧
                              └──────────▶ AVPlayer ◀────────┘
                                             │
                                  进度记忆 / 预取下一集
```

关键设计：

- **必须校验解码一帧**。`-c copy` 不重编码，错误密钥也会「成功」产出一个解不开的
  文件；所以解密后额外跑 `-frames:v 1 -f null -`，失败就删缓存并报错。
  上游每天的契约检查也是这么验的。
- **缓存键 = 分集 ID + 清晰度**，位于 `~/Library/Caches/HongguoPlayer/media/`。
  用户点播撞上后台预取时共用同一个 in-flight Task，不会重复解密。
- **默认 720p**：中文短剧 1080p 单集能有 38MB（实测），720p 竖屏只有 5MB 左右，
  起播快一个数量级；用户可以手动切回 1080p。
- **窗口按真实分辨率适配**：竖屏剧 9:16 窄窗，横屏长片 16:9 宽窗，
  以 `AVPlayerItem.presentationSize` 为准。

## 实测数据

| 场景 | 结果 |
|---|---|
| `discover`（推荐页） | 0.3~3.7s（首次含匿名设备注册），封面 HEIC 正常解码 |
| `episodes`（1000 集的剧） | **366ms**（返回 124KB） |
| `playback` | 124~240ms |
| 竖屏短剧 720p 单集 | 4.8MB，整集落盘 12s → **HLS 起播 1.2s** |
| 横屏电影 720p（97 分钟） | DASH + 独立音轨，**HLS 起播 1.3~3.6s**，边看边解 |
| 缓存命中后起播 | **6s**（App 启动 → 出画面，含 API） |
| 下一集 / 下一部预取 | 上一集解完后自动进行，切集基本瞬开 |

**起播从 7.28s 降到 1.25s，靠的不是分页。** 一开始以为瓶颈是 `episodes` 一次返回
1000 集，实测只要 366ms；真正的原因是 sidecar 单管道串行——App 启动时浏览页的
`discover`（3.7s）把播放的三个请求全堵在后面。改成每请求一个 goroutine（响应按 id
乱序回）之后，播放请求立刻并行，起播降到 1.25s。

## 结构

```
Sources/HongguoPlayerKit/
  Design/Theme.swift              设计系统：颜色/字号/圆角/间距 + 玻璃面板 + AppMark
  Model/Models.swift              自有数据模型（不依赖 SDK 类型）
  Services/CatalogService.swift   协议 + DemoCatalogService
  Services/SidecarCatalogService.swift  Go 子进程 + JSON 协议 + 健康检查
  Services/SDKCatalogService.swift      可选 in-process 绑定（需 Xcode）
  Playback/MediaPreparer.swift    ffmpeg 解密/拼装 + 缓存 + 校验 + 预取
  Playback/PlaybackController.swift resolve → 解密 → AVPlayer → 进度
  Playback/ProgressStore.swift    进度 JSON 存储（去抖落盘）
  Views/                          片库 / 详情 / 搜索 / 榜单 / 播放窗口
Sources/HongguoPlayer/main.swift  入口
Sources/SelfTest/                 无框架自测（本机没有 XCTest）
sidecar/main.go                   Go 侧的 JSON 服务
Resources/AppIcon-1024.png        App 图标母版（Scripts/make-icon.swift 生成）
```

为什么不用 XCTest：这台机器只有 Command Line Tools，`import XCTest` 直接编译失败，
`import testing` 同样没有。所以测试写成可执行 target，断言失败退出码 1。

## 界面与图标

- 侧栏 236pt 浅灰、内容区纯白；卡片 2:3 封面、悬停微放大并浮出播放键。
- 搜索框、播放器控件、选集弹层用 Liquid Glass（`glassEffect`，macOS 26+），
  其余层级一律实色——玻璃滥用在白色界面里会糊成一片。
- 播放器控件在亮画面上会看不清，所以玻璃面板统一染 18% 黑，白字仍加投影兜底。
- 榜单名次按返回顺序自己数：上游 `rank` 字段会重复（两条都是 1）。

图标源是 `Resources/AppIcon-source.svg`（矢量，1024 的 viewBox）。`make-icon.swift`
遇到 `.svg` 会先按目标尺寸矢量光栅化、再裁透明边居中，边缘没有放大糊边；
位图源才走 CoreImage Lanczos + 锐化那条路。

```sh
# SVG → 1024 透明底母版 → 侧栏品牌图（256）
swift Scripts/make-icon.swift Resources/AppIcon-source.svg Resources/AppIcon-1024.png
sips -z 256 256 Resources/AppIcon-1024.png --out Sources/HongguoPlayerKit/Resources/AppMark.png
# 加 --panel 才会画 Apple 那套白色圆角底板
./Scripts/make-app.sh release     # 顺带切 iconset、生成 AppIcon.icns
```

透明底是刻意的：macOS 26 的 Dock 会自己给图标铺一层玻璃托盘，图标自带白底
反而会叠成「两层底」。侧栏左上角的品牌图形复用的是同一张图
（`Sources/HongguoPlayerKit/Resources/AppMark.png`，走 SwiftPM 资源包）。

## 快捷键

| 键 | 作用 |
|---|---|
| `空格` | 播放 / 暂停 |
| `←` `→` | 后退 / 前进 5 秒 |
| `↑` `↓` | 上一集 / 下一集 |
| `Esc` | 关闭播放窗口 |
| `⌘O` | 打开本地视频文件 |
| `⌘[` | 返回片库 |

鼠标两指上下滑 = 切集；控件 2.5 秒无操作自动淡出。

## 已知限制

- **不能上 App Store**：涉及绕过签名风控与 DRM 密钥恢复，5.2 与版权条款都不会过。
  只能自用、公证 DMG 或 brew cask 分发。
- **起播有等待**：虽已做成边解边播（本地 HLS），首个分片仍需 1.2–3.6s，
  取决于清晰度和源站速度。
- 服务端协议随时会变。上游有每日 live contract 检查；这里跟着它的错误码走，
  但**流形态变化**（比如换成 Widevine）会让 `MediaPreparer` 失效——那时会明确报
  「解密校验失败」，而不是静默黑屏。
- 匿名设备有额度：被限流时（`anonymous response was empty`）用播放窗口里的
  「换一台匿名设备并重试」。
- `enable-sdk.sh`（in-process 绑定）在本机未验证，因为缺完整 Xcode。

## 调试用的环境变量

| 变量 | 作用 |
|---|---|
| `HONGGUO_AUTO_PLAY=<seriesID>[:<集>]` | 启动即播放指定剧集 |
| `HONGGUO_OPEN_FILE=/path.mp4` | 启动即播放本地文件 |
| `HONGGUO_PAUSE_ON_OPEN=1` | 打开后暂停在第 3 秒（截图/看控件用） |
| `HONGGUO_FORCE_DEMO=1` | 强制离线演示数据 |
| `HONGGUO_FEED=<频道>` | 启动即进无限流（如 `电影`） |
| `HONGGUO_SECTION=feed\|discover\|rank\|search\|continue` | 启动即切到某一页（截图/验收用） |
| `HONGGUO_OPEN_SERIES=<seriesID>` | 启动即打开某部剧的详情页 |
| `HONGGUO_AUTO_NEXT=<秒>` | 起播 N 秒后走一次「下一集/下一部」 |
| `HONGGUO_AUTO_SEEK_END=<秒>` | 起播 N 秒后跳到结尾，验证自动连播 |
| `HONGGUO_DEBUG=1` | 打开诊断日志（默认安静） |
| `HONGGUO_SIDECAR=/path` | 指定 sidecar 二进制 |
| `HONGGUO_FFMPEG=/path/ffmpeg` | 指定 ffmpeg |

## 自己踩到的坑（都是跑起来才暴露的）

1. **HLS 追平分片会被当成「播完」**：边解边播时 AVPlayer 播到已解出的最后一个分片就会发
   `AVPlayerItemDidPlayToEndTime`，一开始直接触发「下一部」，电影 13 秒就跳到第二部。
   现在用服务端给的时长判定：`currentTime >= 总时长 - 3` 才算播完，否则等新分片续播。
2. **观测不到另一个 ObservableObject**：播放窗口用 `app.playback.phase` 判断显示内容，
   但 `playback` 是独立的 `ObservableObject`，视图不会因它变化重绘，于是永远停在
   「没有在播放」。改成看 `presented`（AppModel 自己的 `@Published`）。
3. **默认清晰度必须在选流之前定**：原先在 `select()` 之后才把 quality 改成 720p，
   结果标签写 720p、实际下 1080p（38MB）。
4. **`vertical` 字段不可靠**：`vertical=false` 的剧集实际可能是 16:9 长片，
   窗口尺寸以清晰度自带的分辨率为准（比 `presentationSize` 更早——HLS 流的
   `presentationSize` 要等一阵才有值）。
5. **横屏自动全屏在这个环境不可行**：`toggleFullScreen` 会把窗口搬到一个新的
   Space，而 App 从命令行/后台启动时系统不会切过去，用户看到的是「窗口消失了」。
   改成把窗口铺成屏幕内接的 16:9 矩形（不抢 Space、不动 Dock），需要真全屏时
   点右上角 ⤢。
6. **边解边播时不能立刻 seek 到续播点**：playlist 一开始只有几秒，直接 seek 到
   1:20 会让 AVPlayer 停在等数据上，看起来就是卡住。现在等 `loadedDuration`
   追上目标位置再 seek，等不到（20 秒）就从头播。

## 上游 SDK 踩到的坑

1. `bindings/mobile/ios/OpenhongguoCore.xcframework` 不在仓库里（`/build/` 被
   gitignore），SwiftPM 直接 `path:` 依赖会失败，必须先跑它的 `build.sh ios`。
2. `gomobile bind -target macos` 要完整 Xcode，不是有 Go 就行。
3. SDK 的 Swift 类型名与业务模型重名（`SeriesSummary` / `Episode` / `Playback` /
   `Stream` / `Page`），in-process 桥接必须用 `Openhongguo.` 前缀限定。
4. 分集的 `vertical` 字段**不可靠**：同一部剧里 `vertical=false` 的剧集实际可能是
   16:9 长片（实测「末世第一粮仓」），所以播放窗口最终按 `presentationSize` 适配，
   不信任 `vertical`。
