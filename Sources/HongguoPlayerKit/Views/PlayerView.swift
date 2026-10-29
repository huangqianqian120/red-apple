import AVKit
import SwiftUI

/// AVPlayer 的宿主视图。用 AVPlayerView 而不是 SwiftUI 的 VideoPlayer，
/// 因为要关掉系统控件、自己画覆盖层。
struct PlayerSurface: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = true
        view.showsFrameSteppingButtons = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

/// 播放器界面：画面全幅，控件是浮在上面的玻璃层。
struct PlayerView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var controller: PlaybackController

    @State private var showsControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    @State private var showsEpisodes = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            video

            if abs(dragOffset) > 40 { swipeHint }
            if showsControls || controller.phase.isBusy || isFailed { controlsOverlay }
            statusLayer
        }
        .animation(.easeOut(duration: 0.18), value: showsControls)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active: revealControls()
            case .ended: scheduleHide()
            }
        }
        .gesture(swipeGesture)
        .focusable()
        .onKeyPress(.space) {
            controller.togglePlay()
            revealControls()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            controller.skip(by: -5)
            revealControls()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            controller.skip(by: 5)
            revealControls()
            return .handled
        }
        .onKeyPress(.upArrow) {
            controller.previous()
            return .handled
        }
        .onKeyPress(.downArrow) {
            controller.next()
            return .handled
        }
        .onKeyPress(.escape) {
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else {
                app.closePlayer()
            }
            return .handled
        }
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel() }
        .onChange(of: controller.index) { _, _ in revealControls() }
    }

    // MARK: 画面

    private var video: some View {
        GeometryReader { geo in
            // 竖屏剧按 9:16 居中，两侧留黑；横屏按真实画面比例内接，
            // 都塞进窗口里，不去动窗口大小。
            let aspect = max(controller.videoAspectRatio ?? (controller.isVertical ? 9.0 / 16.0 : 16.0 / 9.0), 0.2)
            let boxWidth = min(geo.size.width, geo.size.height * aspect)
            let boxHeight = boxWidth / aspect

            PlayerSurface(player: controller.player)
                .frame(width: boxWidth, height: boxHeight)
                .clipShape(RoundedRectangle(cornerRadius: controller.isVertical ? 16 : 6, style: .continuous))
                .offset(y: dragOffset * 0.15)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }

    private var swipeHint: some View {
        VStack(spacing: 6) {
            Image(systemName: dragOffset < 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 30, weight: .light))
            Text(dragOffset < 0 ? "下一集" : "上一集")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(16)
        .playerGlass(radius: 16)
        .transition(.opacity)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let dy = value.translation.height
                dragOffset = 0
                guard abs(dy) > 70, abs(dy) > abs(value.translation.width) else { return }
                if dy < 0 { controller.next() } else { controller.previous() }
            }
    }

    // MARK: 覆盖层

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if isFailed { failedPanel }
            bottomBar
        }
        .padding(18)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            GlassIconButton(system: "chevron.left", label: "回到列表（Esc）") {
                app.closePlayer()
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(controller.series?.title ?? app.presented?.title ?? "播放中")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                HStack(spacing: 5) {
                    Text(controller.currentEpisode?.displayTitle ?? "")
                        .font(.system(size: 10))
                        .opacity(0.62)
                    if controller.isFeedMode {
                        Text(controller.feedPosition)
                            .font(.system(size: 9.5))
                            .opacity(0.45)
                        if !controller.hasNext {
                            Text("· 即将换下一部")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Color.yellow.opacity(0.9))
                        }
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .playerGlass(radius: 13)

            Spacer()

            if let host = Optional(controller.preparedFrom), !host.isEmpty, controller.phase == .ready {
                Text(host)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .padding(.trailing, 2)
            }

            HStack(spacing: 6) {
                if controller.isFeedMode, controller.hasNext, controller.index + 1 >= controller.episodes.count {
                    TextButton(title: "下一部", system: "forward.end.alt.fill") {
                        controller.next()
                    }
                }
                GlassIconButton(system: "list.bullet", label: "选集") {
                    showsEpisodes.toggle()
                }
                .popover(isPresented: $showsEpisodes, arrowEdge: .bottom) {
                    episodeList
                }
                GlassIconButton(system: "arrow.up.left.and.arrow.down.right", label: "全屏") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if controller.phase == .preparing {
                HStack(spacing: 8) {
                    ProgressView(value: controller.prepareProgress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(maxWidth: 240)
                    Text("解密中 \(Int(controller.prepareProgress * 100))%")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            if controller.phase == .resolving {
                Text("正在获取播放地址…")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.65))
            }

            HStack(spacing: 10) {
                Text(SeriesProgress.mmss(scrubbing ?? controller.currentTime))
                    .font(.system(size: 10.5, design: .monospaced))
                    .frame(width: 42, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { scrubbing ?? controller.currentTime },
                        set: { scrubbing = $0 }
                    ),
                    in: 0...max(controller.duration, 1)
                ) { editing in
                    if !editing, let target = scrubbing {
                        controller.seek(to: target)
                        scrubbing = nil
                    }
                }
                .controlSize(.mini)
                .tint(.white)

                Text(SeriesProgress.mmss(controller.duration))
                    .font(.system(size: 10.5, design: .monospaced))
                    .frame(width: 42, alignment: .trailing)
            }
            .foregroundStyle(.white.opacity(0.82))
            .shadow(color: .black.opacity(0.3), radius: 2)

            HStack(spacing: 14) {
                GlassIconButton(system: "backward.end.fill", label: "上一集（↑）", disabled: !controller.hasPrevious) {
                    controller.previous()
                }
                GlassIconButton(system: "gobackward.5", label: "后退 5 秒（←）") {
                    controller.skip(by: -5)
                }

                Button {
                    controller.togglePlay()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.black.opacity(0.82))
                        .frame(width: 46, height: 46)
                        .background(.white.opacity(0.92), in: Circle())
                }
                .buttonStyle(.plain)
                .pressableScale()
                .keyboardShortcut(.space, modifiers: [])

                GlassIconButton(system: "goforward.5", label: "前进 5 秒（→）") {
                    controller.skip(by: 5)
                }
                GlassIconButton(system: "forward.end.fill", label: "下一集（↓）", disabled: !controller.hasNext) {
                    controller.next()
                }

                Spacer()

                GlassMenuLabel(text: String(format: "%g×", controller.speed), help: "播放速度") {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0], id: \.self) { value in
                        Button {
                            controller.speed = value
                        } label: {
                            if abs(controller.speed - value) < 0.01 {
                                Label("\(value, specifier: "%g")×", systemImage: "checkmark")
                            } else {
                                Text("\(value, specifier: "%g")×")
                            }
                        }
                    }
                }

                GlassMenuLabel(
                    text: controller.quality.isEmpty ? "清晰度" : controller.quality,
                    help: "切换清晰度（会重新解密，已缓存的清晰度瞬开）"
                ) {
                    if controller.availableQualities.isEmpty {
                        Text("无可用清晰度")
                    } else {
                        ForEach(controller.availableQualities, id: \.self) { label in
                            Button {
                                controller.quality = label
                            } label: {
                                if label == controller.quality {
                                    Label(label, systemImage: "checkmark")
                                } else {
                                    Text(label)
                                }
                            }
                        }
                    }
                }
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .playerGlass(radius: 18)
    }

    private var episodeList: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 52), spacing: 6)], spacing: 6) {
                ForEach(controller.episodes) { episode in
                    Button {
                        controller.play(episodeNumber: episode.number)
                        showsEpisodes = false
                    } label: {
                        Text("\(episode.number)")
                            .font(.system(size: 11, weight: episode.id == controller.currentEpisode?.id ? .semibold : .regular))
                            .foregroundStyle(episode.id == controller.currentEpisode?.id ? .white : Theme.ink)
                            .frame(width: 44, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(episode.id == controller.currentEpisode?.id ? Theme.accent : Theme.surface)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!episode.playable)
                    .opacity(episode.playable ? 1 : 0.4)
                }
            }
            .padding(12)
        }
        .frame(width: 296, height: 268)
    }

    // MARK: 状态

    private var isFailed: Bool {
        if case .failed = controller.phase { return true }
        return false
    }

    @ViewBuilder
    private var statusLayer: some View {
        if controller.phase == .resolving || controller.phase == .preparing, !showsControls {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(controller.phase == .resolving ? "获取播放地址…" : "解密中…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(18)
            .playerGlass(radius: 18)
        }
    }

    private var failedPanel: some View {
        VStack(spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.yellow)
            Text(failureMessage)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button("重试") { controller.retry() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.92), in: Capsule())
                    .pressableScale()
                if controller.needsDeviceReset {
                    Button("换一台匿名设备并重试") { controller.retryWithNewDevice() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .playerGlass(radius: 20, interactive: true)
                }
                Button("下一集") { controller.next() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.8))
                    .disabled(!controller.hasNext)
            }
        }
        .padding(18)
        .playerGlass(radius: 18)
    }

    private var failureMessage: String {
        if case .failed(let message) = controller.phase { return message }
        return "播放失败"
    }

    private func revealControls() {
        showsControls = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard controller.isPlaying, !isFailed else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { showsControls = false }
        }
    }
}

// MARK: - 玻璃控件

/// 圆形玻璃图标按钮。
struct GlassIconButton: View {
    var system: String
    var label: String
    var disabled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .playerGlass(radius: 15, interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.32 : 1)
        .help(label)
        .pressableScale()
    }
}

/// 文字玻璃按钮。
struct TextButton: View {
    var title: String
    var system: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: system).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .playerGlass(radius: 15, interactive: true)
        }
        .buttonStyle(.plain)
        .pressableScale()
    }
}

/// 玻璃下拉菜单（倍速 / 清晰度）。
struct GlassMenuLabel<Content: View>: View {
    var text: String
    var help: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .playerGlass(radius: 15, interactive: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}
