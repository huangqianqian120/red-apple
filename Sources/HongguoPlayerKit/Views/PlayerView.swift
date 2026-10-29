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

/// 播放器全屏界面。竖屏短剧居中显示，上下滑切集。
struct PlayerView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject var controller: PlaybackController

    @State private var showsControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    @State private var showsEpisodes = false
    @State private var dragOffset: CGFloat = 0
    @State private var fittedAspect: CGFloat?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            video

            // 上下滑切集时的提示层
            if abs(dragOffset) > 40 {
                swipeHint
                    .transition(.opacity)
            }

            if showsControls || controller.phase.isBusy || isFailed {
                controlsOverlay
                    .transition(.opacity)
            }

            statusLayer
        }
        .animation(.easeOut(duration: 0.15), value: showsControls)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                revealControls()
            case .ended:
                scheduleHide()
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
            app.closePlayer()
            dismissWindow()
            return .handled
        }
        .background(
            // 竖屏剧给 9:16 的窄窗，横屏长片给 16:9 的宽窗：
            // 否则横屏内容只能缩在竖窗中间一条，上下全是黑边。
            WindowConfigurator { window in
                let aspect = controller.videoAspectRatio
                    ?? (controller.isVertical ? 9.0 / 16.0 : 16.0 / 9.0)
                guard fittedAspect != aspect else { return }
                DispatchQueue.main.async {
                    guard fittedAspect != aspect else { return }
                    fittedAspect = aspect
                    // 以当前窗口高度为准换算宽度，保持左上角不动。
                    var frame = window.frame
                    let contentHeight = max(window.contentLayoutRect.height, 520)
                    let chrome = frame.height - window.contentLayoutRect.height
                    let newWidth = (contentHeight * aspect).rounded()
                    let newHeight = (contentHeight + chrome).rounded()
                    frame.size = NSSize(width: max(newWidth, 320), height: newHeight)
                    // 别把窗口推出屏幕。
                    if let screen = window.screen ?? NSScreen.main {
                        let visible = screen.visibleFrame
                        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
                        if frame.minX < visible.minX { frame.origin.x = visible.minX }
                        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
                    }
                    window.setFrame(frame, display: true, animate: false)
                }
            }
        )
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel() }
        .onChange(of: controller.index) { _, _ in
            revealControls()
        }
    }

    // MARK: 视频区

    private var video: some View {
        GeometryReader { geo in
            PlayerSurface(player: controller.player)
                .frame(
                    width: controller.isVertical ? min(geo.size.width, geo.size.height * 9 / 16) : geo.size.width,
                    height: controller.isVertical ? min(geo.size.height, geo.size.width * 16 / 9) : geo.size.width * 9 / 16
                )
                .clipShape(RoundedRectangle(cornerRadius: controller.isVertical ? 14 : 0, style: .continuous))
                .offset(y: dragOffset * 0.15)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }

    private var swipeHint: some View {
        VStack(spacing: 6) {
            Image(systemName: dragOffset < 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 34))
            Text(dragOffset < 0 ? "下一集" : "上一集").font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(18)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                // 只认竖直方向的意图，横向留给拖进度条。
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let dy = value.translation.height
                dragOffset = 0
                guard abs(dy) > 70, abs(dy) > abs(value.translation.width) else { return }
                // 向上滑 = 下一集（信息流习惯）
                if dy < 0 { controller.next() } else { controller.previous() }
            }
    }

    // MARK: 覆盖层

    private var controlsOverlay: some View {
        VStack {
            topBar
            Spacer()
            if isFailed {
                failedPanel
            }
            Spacer()
            bottomBar
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.65)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                app.closePlayer()
                dismissWindow()
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("关闭播放窗口（Esc）")

            VStack(alignment: .leading, spacing: 1) {
                Text(controller.series?.title ?? app.presented?.title ?? "播放中")
                    .font(.system(size: 13, weight: .semibold))
                Text(controller.currentEpisode?.displayTitle ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            if let host = Optional(controller.preparedFrom), !host.isEmpty, controller.phase == .ready {
                Text(host).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
            Button {
                showsEpisodes.toggle()
            } label: {
                Label("选集", systemImage: "list.bullet")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsEpisodes, arrowEdge: .bottom) {
                episodeList
            }
            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("全屏")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .padding(.top, 22)   // 让开窗口左上角的红绿灯（无标题栏窗口里它们浮在内容上）
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if controller.phase == .preparing {
                HStack(spacing: 8) {
                    ProgressView(value: controller.prepareProgress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)
                    Text("解密中 \(Int(controller.prepareProgress * 100))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            if controller.phase == .resolving {
                Text("正在获取播放地址…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 12) {
                Text(SeriesProgress.mmss(scrubbing ?? controller.currentTime))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44, alignment: .leading)

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
                .controlSize(.small)

                Text(SeriesProgress.mmss(controller.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44, alignment: .trailing)
            }

            HStack(spacing: 18) {
                iconButton("backward.end.fill", help: "上一集（↑）", disabled: !controller.hasPrevious) {
                    controller.previous()
                }
                iconButton("gobackward.5", help: "后退 5s（←）") { controller.skip(by: -5) }
                Button {
                    controller.togglePlay()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                iconButton("goforward.5", help: "前进 5s（→）") { controller.skip(by: 5) }
                iconButton("forward.end.fill", help: "下一集（↓）", disabled: !controller.hasNext) {
                    controller.next()
                }

                Spacer()

                speedMenu
                qualityMenu
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
        }
    }

    private func iconButton(
        _ name: String, help: String, disabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 15))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(help)
    }

    private var speedMenu: some View {
        Menu {
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
        } label: {
            Text("\(controller.speed, specifier: "%g")×").font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("播放速度")
    }

    private var qualityMenu: some View {
        Menu {
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
        } label: {
            Text(controller.quality.isEmpty ? "清晰度" : controller.quality)
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("切换清晰度（会重新解密，已缓存的清晰度瞬开）")
    }

    private var episodeList: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 46, maximum: 56), spacing: 6)], spacing: 6) {
                ForEach(controller.episodes) { episode in
                    Button {
                        controller.play(episodeNumber: episode.number)
                        showsEpisodes = false
                    } label: {
                        Text("\(episode.number)")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 46, height: 28)
                            .background(
                                episode.id == controller.currentEpisode?.id
                                    ? Color.accentColor.opacity(0.85)
                                    : Color.secondary.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!episode.playable)
                }
            }
            .padding(10)
        }
        .frame(width: 300, height: 280)
    }

    // MARK: 状态层

    private var isFailed: Bool {
        if case .failed = controller.phase { return true }
        return false
    }

    @ViewBuilder
    private var statusLayer: some View {
        switch controller.phase {
        case .resolving, .preparing:
            if !showsControls {
                VStack(spacing: 8) {
                    ProgressView(value: controller.phase == .preparing ? controller.prepareProgress : nil)
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                    Text(controller.phase == .resolving ? "获取播放地址…" : "解密中…")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        case .failed:
            EmptyView()
        case .idle, .ready:
            EmptyView()
        }
    }

    private var failedPanel: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.yellow)
            Text(failureMessage)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Button("重试") { controller.retry() }
                    .buttonStyle(.borderedProminent)
                if controller.needsDeviceReset {
                    Button("换一台匿名设备并重试") { controller.retryWithNewDevice() }
                }
                Button("下一集") { controller.next() }
                    .disabled(!controller.hasNext)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private var failureMessage: String {
        if case .failed(let message) = controller.phase { return message }
        return "播放失败"
    }

    // MARK: 控件显隐

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
