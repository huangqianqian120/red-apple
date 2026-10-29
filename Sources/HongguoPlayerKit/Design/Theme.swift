import SwiftUI
import AppKit

/// 设计系统。
///
/// 底色走 Notion 那套：纯白画布 + 微微发灰的侧栏 + 一根极淡的分隔线，
/// 文字用暖黑而不是纯黑；圆角统一 12/16；只在「浮在内容之上」的地方用
/// Liquid Glass（播放器控件、搜索框、弹层）——玻璃是层级语言，不是装饰。
enum Theme {
    // MARK: 颜色

    /// 主画布
    static let canvas = Color(red: 1.0, green: 1.0, blue: 1.0)
    /// 侧栏 / 次级面
    static let surface = Color(red: 0.972, green: 0.972, blue: 0.960)
    /// 卡片
    static let card = Color.white
    /// 悬停态
    static let hover = Color(red: 0.949, green: 0.949, blue: 0.933)
    /// 选中态
    static let selected = Color(red: 0.917, green: 0.913, blue: 0.894)

    static let hairline = Color.black.opacity(0.08)
    static let hairlineStrong = Color.black.opacity(0.14)

    /// 暖黑：纯黑太硬，Notion 用的是带一点褐的深灰。
    static let ink = Color(red: 0.216, green: 0.208, blue: 0.184)
    static let inkSecondary = Color(red: 0.470, green: 0.462, blue: 0.439)
    static let inkTertiary = Color(red: 0.607, green: 0.600, blue: 0.580)

    /// 品牌色：红果的红，压暗一点避免刺眼。
    static let accent = Color(red: 0.867, green: 0.239, blue: 0.239)
    static let accentSoft = Color(red: 0.867, green: 0.239, blue: 0.239).opacity(0.10)

    // MARK: 圆角与间距

    enum Radius {
        static let chip: CGFloat = 8
        static let card: CGFloat = 12
        static let panel: CGFloat = 16
        static let sheet: CGFloat = 20
    }

    enum Space {
        static let tight: CGFloat = 6
        static let base: CGFloat = 10
        static let loose: CGFloat = 16
        static let section: CGFloat = 28
    }

    // MARK: 字体

    static func title(_ size: CGFloat = 26) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    static func heading(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .semibold)
    }

    static func body(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .regular)
    }

    static func caption(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .regular)
    }

    // MARK: 阴影

    static let cardShadow = Color.black.opacity(0.06)
}

// MARK: - 玻璃层

/// 浮在内容之上的面板：macOS 26 用 Liquid Glass，旧系统退回材质。
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.panel
    var tint: Color?
    var interactive = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
                )
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var effect = Glass.regular
        if let tint { effect = effect.tint(tint) }
        if interactive { effect = effect.interactive() }
        return effect
    }
}

extension View {
    func glassPanel(
        cornerRadius: CGFloat = Theme.Radius.panel,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }
}

// MARK: - 通用修饰

extension View {
    /// 卡片：白底、发丝边、悬停时轻微抬起。
    func cardSurface(hovering: Bool = false, radius: CGFloat = Theme.Radius.card) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.card)
                .shadow(
                    color: Theme.cardShadow,
                    radius: hovering ? 14 : 0,
                    y: hovering ? 6 : 0
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// 点一下有回弹，Notion 那种「轻」的感觉。
    func pressableScale() -> some View {
        buttonStyle(PressableStyle())
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 悬停高亮：鼠标进出的浅灰底。
struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    var radius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hovering ? Theme.hover : Color.clear)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - 品牌图标

/// 侧栏左上角的品牌图形。
///
/// 资源放在 SwiftPM 资源包里（`Resources/AppMark.png`），swift run 和打包成
/// .app 都能加载；万一资源缺失就退回「红」字方块，界面不会开天窗。
public struct AppMark: View {
    public init() {}

    public var body: some View {
        if let image = AppMark.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.accent, Theme.accent.opacity(0.72)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Text("红")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
    }

    private static let image: NSImage? = {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "AppMark", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        #endif
        // 兜底：打包成 .app 后资源被直接拷进 Contents/Resources。
        if let url = Bundle.main.url(forResource: "AppMark", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }()
}

// MARK: - 播放器玻璃

/// 播放器专用玻璃层：素材画面明暗不可控，纯 `glassEffect` 在白色画面上会被
/// 反照成浅灰，白字直接糊掉。这里先用模糊材质打底、再叠一层 42% 黑纱，
/// 保证任何画面上都是深色底，同时保留玻璃的高光描边。
public struct PlayerGlass: ViewModifier {
    var radius: CGFloat
    var interactive: Bool

    public func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.black.opacity(0.42))
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 0.75)
                    )
                    .allowsHitTesting(interactive)
            }
    }
}

extension View {
    public func playerGlass(radius: CGFloat, interactive: Bool = false) -> some View {
        modifier(PlayerGlass(radius: radius, interactive: interactive))
    }
}
