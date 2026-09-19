import AppKit
import SwiftUI

/// 桌面上悬浮的挂件本体：小鲸鱼 + 气泡 + 菜单按钮。
///
/// 指针输入**全部**由 `WidgetContainerView` 的原生事件处理（见该类型的注释），
/// 这里只负责显示，不再挂 `DragGesture` —— 那种做法会让窗口位移自我反馈、
/// 并在窗口重建时把手势重置，导致拖动抽搐与点击序列推进不下去。
struct WhalePanelView: View {

    @ObservedObject var store: WhaleStore
    @ObservedObject var bubble: BubbleRuntime
    @ObservedObject var interaction: PanelInteraction

    /// 点击右上角的菜单按钮
    var onMenu: () -> Void

    @State private var menuHover = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let unit = width / BubbleShape.viewBox.width   // --dshw-u 等价量

            ZStack(alignment: .topLeading) {
                draggableLayer(width: width, unit: unit)
                    // Q 弹变形：点击时压扁 → 回弹（由控制器在 mouseUp 时触发）。
                    // 不能只靠「按下」状态驱动：一次点击只有几十毫秒，
                    // 纯靠 pressed 翻转时动画会被立刻取消，看起来没有 Q 弹。
                    .scaleEffect(
                        x: interaction.squeezing ? 1.08 : 1.0,
                        y: interaction.squeezing ? 0.92 : 1.0,
                        anchor: .bottom
                    )
                    .animation(.spring(response: 0.3, dampingFraction: 0.5),
                               value: interaction.squeezing)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7),
                               value: store.balance)

                // 菜单按钮：与拖拽层平级、最后绘制 → 命中优先
                if !store.config.menuButtonHidden {
                    menuButton(width: width)
                }
            }
        }
        .frame(width: panelSide, height: panelSide)
        // 贴左吸附时整体水平镜像（文字同步反向）
        .scaleEffect(x: store.config.lastSide == "left" && store.config.mirrorOnLeftSnap ? -1 : 1,
                     y: 1, anchor: .center)
        .animation(.easeInOut(duration: 0.3), value: store.config.lastSide)
    }

    /// 小鲸鱼所在矩形（右下 59.45%）。
    private func whaleRect(width: CGFloat) -> CGRect {
        let side = width * 0.5945
        return CGRect(x: width - side, y: width - side, width: side, height: side)
    }

    /// 气泡所在矩形（左上，宽高比 1026:700）。
    private func bubbleRect(width: CGFloat) -> CGRect {
        CGRect(x: 0, y: 0,
               width: width,
               height: width * BubbleShape.viewBox.height / BubbleShape.viewBox.width)
    }

    /// 视觉层：气泡 + 小鲸鱼。
    @ViewBuilder
    private func draggableLayer(width: CGFloat, unit: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            if bubble.isOpen {
                BubbleLayer(store: store, bubble: bubble, unit: unit)
                    .frame(width: bubbleRect(width: width).width,
                           height: bubbleRect(width: width).height)
                    .transition(.opacity)
            }

            if let image = Assets.whaleImage ?? Assets.whaleFallbackImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width * 0.5945, height: width * 0.5945)
                    .position(x: width - width * 0.5945 / 2,
                              y: width - width * 0.5945 / 2)
            }
        }
    }

    private var panelSide: CGFloat {
        let frame = NSScreen.main?.frame ?? NSScreen.screens.first?.frame
        let size = frame.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: 1440, height: 900)
        return Positioning.panelSide(scale: store.config.scale, screenFrame: size)
    }

    // MARK: - 菜单按钮

    private func menuButton(width: CGFloat) -> some View {
        let side = width * 26 / 320
        // 注意顺序：命中区域 / 手势必须挂在「按钮自身尺寸」上，最后才 .position。
        // 若先 .position 再挂手势，手势会落在 .position 撑满父容器的外层上，
        // 导致整块挂件区域都变成菜单按钮的点击区（点本体也会弹菜单）。
        return VStack(spacing: max(2, side * 0.17)) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white)
                    .frame(width: side * 0.54, height: max(1, side * 0.077))
            }
        }
        .frame(width: side, height: side)
        .background(
            RoundedRectangle(cornerRadius: side * 0.23)
                .fill(Color(red: 0.125, green: 0.192, blue: 0.439).opacity(menuHover ? 1 : 0.9))
        )
        .contentShape(Rectangle())
        .opacity(menuOpacity)
        .animation(.easeInOut(duration: 0.18), value: menuOpacity)
        .onHover { menuHover = $0 }
        .onTapGesture { onMenu() }
        .position(x: width - side / 2 - width * 0.0125,
                  y: width * 0.4055 + side * 0.6)
    }

    /// 菜单按钮默认隐藏：只有鼠标进入挂件的可交互区域时才淡入。
    /// `interaction.hovering` 由容器视图按「是否落在有像素的区域」判定，
    /// 所以移到透明角落不会让它冒出来。
    private var menuOpacity: Double {
        menuHover || (interaction.hovering && !store.config.menuButtonHidden) ? 1 : 0
    }
}

/// 气泡内容层：按行渲染模块，带依次展开动画。
struct BubbleLayer: View {

    @ObservedObject var store: WhaleStore
    @ObservedObject var bubble: BubbleRuntime
    let unit: CGFloat

    private var page: BubblePage? { bubble.currentPage }

    /// 气泡内文字的可用区域（由泡泡几何内缩得到，保证文字落在泡泡内部）。
    /// 泡泡本体是 `viewBox 1026×700` 的椭圆（cx≈454, cy≈248, rx≈373, ry≈232），
    /// 描边宽 18，所以再按描边和视觉留白内缩。
    static let textAreaWidthRatio: CGFloat = 0.56
    static let textAreaHeightRatio: CGFloat = 0.52
    static let textAreaCenterX = 0.4425   // 454 / 1026
    static let textAreaCenterY = 0.32     // 224 / 700

    var body: some View {
        ZStack {
            BubbleShape()
                .fill(BubbleShape.fill)
                .overlay(
                    BubbleShape()
                        .stroke(BubbleShape.stroke,
                                style: StrokeStyle(lineWidth: BubbleShape.strokeWidth * unit,
                                                   lineCap: .round, lineJoin: .round))
                )

            if let page {
                // 用 ViewThatFits 做自适应：优先按配置字号渲染，
                // 放不下就整体降级到更小的档位，保证内容始终在气泡内部。
                ViewThatFits(in: .horizontal) {
                    contentRows(for: page)
                        .fontScale(1.00)
                    contentRows(for: page)
                        .fontScale(0.82)
                    contentRows(for: page)
                        .fontScale(0.66)
                    contentRows(for: page)
                        .fontScale(0.52)
                    contentRows(for: page)
                        .fontScale(0.40)
                }
                .frame(width: BubbleShape.viewBox.width * unit * Self.textAreaWidthRatio,
                       height: BubbleShape.viewBox.height * unit * Self.textAreaHeightRatio)
                .position(x: BubbleShape.viewBox.width * unit * Self.textAreaCenterX,
                          y: BubbleShape.viewBox.height * unit * Self.textAreaCenterY)
            }
        }
        .scaleEffect(bubble.isOpen ? 1 : 0.7)
        .opacity(bubble.isOpen ? 1 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: bubble.isOpen)
    }

    private func contentRows(for page: BubblePage) -> some View {
        VStack(spacing: unit * 4) {
            ForEach(bubble.resolvedRows(for: page)) { row in
                HStack(spacing: unit * 8) {
                    ForEach(row.modules) { module in
                        BubbleModuleView(module: module, store: store,
                                         bubble: bubble, unit: unit)
                    }
                }
            }
        }
    }
}

/// 单个模块的渲染。
struct BubbleModuleView: View {

    let module: BubbleModule
    @ObservedObject var store: WhaleStore
    @ObservedObject var bubble: BubbleRuntime
    let unit: CGFloat

    @Environment(\.bubbleFontScale) private var fontScale

    private var fontSize: CGFloat { module.style.unitMultiplier * unit * fontScale }

    var body: some View {
        content
            .modifier(ModuleStyleModifier(style: module.style,
                                          fontSize: module.style.unitMultiplier * unit,
                                          scale: fontScale))
    }

    @ViewBuilder
    private var content: some View {
        switch module.kind {
        case .text:
            Text(module.text)

        case .link:
            Text(module.text)
                .underline(true, color: linkColor)
                .foregroundColor(linkColor)
                .onTapGesture {
                    guard let url = URL(string: module.url) else { return }
                    NSWorkspace.shared.open(url)
                }
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

        case .random:
            Text(bubble.randomText(for: module))

        case .image, .randomImage:
            BubbleImageView(module: module, bubble: bubble, unit: unit)

        case .balance:
            Text(module.prefix + String(format: "%.2f", store.balance) + module.suffix)
                .contentTransition(.numericText())

        case .today:
            Text(module.prefix + String(format: "%.2f", store.todayUsage) + module.suffix)

        case .peak:
            Text(module.prefix + store.peakText + (store.peakCountdown.isEmpty ? "" : " · " + store.peakCountdown) + module.suffix)

        case .model:
            Text(module.prefix + bubble.costText + module.suffix)
        }
    }

    private var linkColor: Color {
        Color(hex: module.style.color) ?? Color(red: 0.125, green: 0.192, blue: 0.439)
    }
}

/// 图片 / 动图模块：独占一行，最大 560u × 400u。
struct BubbleImageView: View {

    let module: BubbleModule
    @ObservedObject var bubble: BubbleRuntime
    let unit: CGFloat

    private var maxWidth: CGFloat { unit * 560 }
    private var maxHeight: CGFloat { unit * 400 }

    var body: some View {
        Group {
            if let image = bubble.resolvedImage(for: module) {
                AnimatedImageView(image: image, animated: module.kind == .image && module.asset.hasSuffix(".gif"))
                    .aspectRatio(image.size, contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            } else {
                Text("（图片不可用）")
                    .font(.system(size: fontSize))
                    .foregroundColor(.gray)
            }
        }
    }

    private var fontSize: CGFloat { max(9, module.style.unitMultiplier * unit) }
}

/// 支持 GIF 动画的图片视图（NSImageView 原生支持多帧动图）。
struct AnimatedImageView: NSViewRepresentable {

    let image: NSImage
    let animated: Bool

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = animated
        view.isEditable = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = image
        view.animates = animated
    }
}

/// 逐模块样式：字体 / 字号 / 粗斜下划线 / 纯色或渐变文字 / 底色。
///
/// 字号按 `fontScale` 缩放（供 `ViewThatFits` 在放不下时逐级降档），
/// 并限制为单行、可压缩，避免长文本撑破气泡。
struct ModuleStyleModifier: ViewModifier {

    let style: ModuleStyle
    /// 基准字号（未缩放）
    let fontSize: CGFloat
    /// 自适应缩放系数
    var scale: CGFloat = 1

    /// 实际渲染字号（按自适应系数缩放，并保底 6pt）
    private var scaledSize: CGFloat { max(6, fontSize * scale) }

    // 注意：ViewModifier.body(content:) 是 @ViewBuilder，
    // 里面不能出现 `return`，所以把字号算成计算属性。
    func body(content: Content) -> some View {
        content
            .font(.system(size: scaledSize,
                          weight: style.bold ? .bold : .regular,
                          design: .rounded))
            .italic(style.italic)
            .underline(style.underline, color: solidColor)
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, style.background.isEmpty ? 0 : scaledSize * 0.16)
            .padding(.vertical, style.background.isEmpty ? 0 : scaledSize * 0.06)
            .background(
                RoundedRectangle(cornerRadius: scaledSize * 0.2)
                    .fill(style.background.isEmpty ? Color.clear
                          : (Color(hex: style.background) ?? .clear))
            )
            .lineLimit(1)
            .truncationMode(.tail)
            .minimumScaleFactor(0.6)   // 单行过长时先自行压缩
    }

    private var solidColor: Color {
        Color(hex: style.color) ?? Color(red: 0.125, green: 0.192, blue: 0.439)
    }

    private var foregroundStyle: AnyShapeStyle {
        if let from = Color(hex: style.gradientFrom), let to = Color(hex: style.gradientTo) {
            return AnyShapeStyle(LinearGradient(colors: [from, to],
                                                startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(solidColor)
    }
}

/// 把整块气泡内容按比例缩放（供 `ViewThatFits` 逐档试排）。
private struct FontScaleModifier: ViewModifier {

    let scale: CGFloat
    @Environment(\.bubbleFontScale) private var inherited

    func body(content: Content) -> some View {
        content.environment(\.bubbleFontScale, inherited * scale)
    }
}

extension View {
    /// 按比例调整气泡内所有模块的字号。
    func fontScale(_ scale: CGFloat) -> some View {
        modifier(FontScaleModifier(scale: scale))
    }
}

/// 气泡内容当前的字号倍率（由 `ViewThatFits` 选中的档位注入）。
private struct BubbleFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var bubbleFontScale: CGFloat {
        get { self[BubbleFontScaleKey.self] }
        set { self[BubbleFontScaleKey.self] = newValue }
    }
}
