# RED APPLE · hongguo 短剧 macOS 播放器

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
