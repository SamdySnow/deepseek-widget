import AppKit
import SwiftUI

/// 悬浮面板控制器：创建一个无边框、透明、可拖拽的 NSWindow，
/// 并负责吸附到屏幕四边 / 角落。
@MainActor
final class PanelController {

    private var window: NSWindow!
    private let store: WhaleStore
    private let bubble: BubbleRuntime
    private let interaction = PanelInteraction()
    /// 仅供自检驱动合成事件（`--e2e`）
    private(set) var container: WidgetContainerView!
    private var hosting: NSHostingView<WhalePanelView>!
    private var dragOrigin: NSPoint = .zero
    /// 鼠标按下时的全局坐标（拖动时用它算位移，避免视图坐标系自我反馈）
    private var dragMouseStart: NSPoint = .zero
    /// 全局鼠标移动监听：用来在光标进出「角色本体」时切换 `ignoresMouseEvents`
    private var mouseMonitor: Any?
    private var acceptsEventsNow = true
    /// 当前是否处于「按下」状态（拖动 / 点击期间必须持续接收事件）
    private var isPressing = false
    /// 锁定期间是否已暂停自动吸附，以及暂停前的用户设置（解除锁定时还原）
    private var snapSuspendedByLock = false
    private var lastSnapEnabledBeforeLock = true
    private let sounds = SoundPlayer()

    init(store: WhaleStore, bubble: BubbleRuntime) {
        self.store = store
        self.bubble = bubble
        createWindow()
        wireCallbacks()
        restorePosition()
        observeScreenChanges()
        // 启动时若配置是「已锁定」，立刻进入穿透 + 暂停吸附状态
        applyInteractionState()

        bubble.refreshResolved(page: bubble.currentPage)
    }

    // MARK: - 窗口

    private func createWindow() {
        let side = panelSide()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = false
        window.ignoresMouseEvents = false
        window.hidesOnDeactivate = false
        // 默认 true 时会与我们的强引用重复释放
        window.isReleasedWhenClosed = false

        hosting = NSHostingView(rootView: makeRootView())
        hosting.frame = NSRect(x: 0, y: 0, width: side, height: side)
        hosting.autoresizingMask = [.width, .height]

        // 用容器视图接管指针事件（悬停 / 点击 / 拖动 / 右键）
        container = WidgetContainerView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        container.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        container.onMouseEnter = { [weak self] in
            self?.interaction.hovering = true
            self?.bubble.isHovering = true
        }
        container.onMouseExit = { [weak self] in
            self?.interaction.hovering = false
            self?.bubble.isHovering = false
        }
        container.onRightClick = { [weak self] _ in self?.presentMenu() }
        container.onPress = { [weak self] point in self?.handlePress(point) }
        container.onDrag = { [weak self] point in self?.handleDrag(point) }
        container.onRelease = { [weak self] kind, point in
            self?.handleRelease(kind, at: point)
        }
        window.contentView = container
        rebuildHitMask()

        window.orderFrontRegardless()
    }

    private func makeRootView() -> WhalePanelView {
        WhalePanelView(store: store, bubble: bubble, interaction: interaction,
                       onMenu: { [weak self] in self?.presentMenu() })
    }

    // MARK: - 指针交互

    private func handlePress(_ point: NSPoint) {
        isPressing = true
        dragOrigin = window.frame.origin
        dragMouseStart = point
    }

    private func handleDrag(_ point: NSPoint) {
        let next = PointerIntent.windowOrigin(windowStart: dragOrigin,
                                              mouseStart: dragMouseStart,
                                              mouseNow: point)
        window.setFrameOrigin(next)
    }

    private func handleRelease(_ kind: PointerIntent.Kind, at point: NSPoint) {
        isPressing = false
        switch kind {
        case .drag:
            applySnap()
        case .click:
            // 点击：播放 Q 弹 + 推进气泡序列
            playSqueeze()
            sounds.enabled = store.config.soundOn
            sounds.volume = store.config.volume
            sounds.playRelease(preset: SoundPlayer.Preset(rawValue: store.config.soundSet) ?? .duck)
            bubble.handleTap(menuHidden: store.config.menuButtonHidden)
            bubble.refreshResolved(page: bubble.currentPage)
        }
        // 松开后重新评估：若气泡展开、光标已不在角色本体上，就该恢复穿透
        updateEventAcceptance(at: NSEvent.mouseLocation)
    }

    /// 点击时播放一次 Q 弹（先压扁再回弹）。
    private func playSqueeze() {
        interaction.squeezing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            self?.interaction.squeezing = false
        }
    }

    /// 面板边长（供自检计算取样点）
    var panelSideLength: CGFloat { window.frame.width }

    /// 窗口当前是否忽略鼠标事件（供自检断言「锁定 = 真穿透」）。
    var windowIgnoresMouseEvents: Bool { window.ignoresMouseEvents }

    /// 窗口当前原点（供自检断言「锁定后拖不动」）。
    var windowFrameOrigin: NSPoint { window.frame.origin }

    /// 视图承载层的不透明度（供自检断言）。
    var hostingAlpha: CGFloat { hosting.alphaValue }

    /// 把面板移到屏幕外，避免自检时窗口闪现在用户桌面上。
    func moveOffscreenForTesting() {
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    }

    /// 重建可交互区域遮罩。
    ///
    /// **只包含角色本体的像素**：
    /// - 气泡是纯展示，点它不推进序列，所以不纳入（点气泡会 click-through 到桌面）；
    /// - 菜单按钮由 SwiftUI 自行响应，也不纳入。
    ///
    /// 因此这个遮罩不随气泡开合变化 —— 只在尺寸 / 镜像变化时重建。
    private func rebuildHitMask() {
        let mask = HitMask.bake(panelSide: window.frame.width,
                                whaleImage: Assets.whaleImage ?? Assets.whaleFallbackImage,
                                whaleRect: Positioning.whaleRectNormalized)
        container.hitMask = mask
        container.isMirrored = store.config.lastSide == "left" && store.config.mirrorOnLeftSnap
        // 按钮隐藏时置 nil：否则它周围一块会变成「可点但无反应」的死区
        container.menuButtonRect = store.config.menuButtonHidden
            ? nil : Positioning.menuButtonRectNormalized
        container.locked = store.config.isLocked
        startMouseTracking()
        updateEventAcceptance(at: NSEvent.mouseLocation)
    }

    /// 应用锁定 / 交互开关。
    ///
    /// **不透明度不在这里处理**：它由 `WhalePanelView` 直接读 `store.config.panelOpacity`
    /// 并挂 `.opacity(...)`（视图已观察 store，配置一变自动重绘）。
    /// 若这里再设一次 `window.alphaValue`，两处会相乘 —— 滑到 0.5 会得到 0.25，
    /// 而且离屏渲染校验（`--render`）看不到 `NSWindow` 的属性，等于失去测试覆盖。
    func applyInteractionState() {
        container.locked = store.config.isLocked
        applySnapPolicy()
        updateEventAcceptance(at: NSEvent.mouseLocation)
    }

    /// 锁定状态下要停止自动吸附。
    ///
    /// 理由：吸附会在窗口靠近屏幕边缘**约 24px** 时把它吸过去，而「锁定」
    /// 恰恰常在拖到某个角落之后使用。若此时仍允许吸附，窗口可能被推到
    /// 贴边位置，用户再解锁时就会发现挂件换了地方 —— 锁定应当保证它纹丝不动。
    /// 解锁后恢复：位置没变，因此不会被吸走；用户再拖动时会重新吸附。
    private func applySnapPolicy() {
        if store.config.isLocked {
            if !snapSuspendedByLock {
                snapSuspendedByLock = true
                lastSnapEnabledBeforeLock = store.config.snapEnabled
                store.update { $0.snapEnabled = false }
            }
        } else if snapSuspendedByLock {
            snapSuspendedByLock = false
            store.update { $0.snapEnabled = lastSnapEnabledBeforeLock }
        }
    }

    // MARK: - Click-through

    /// 透明像素要「点得穿」到桌面。
    ///
    /// 只让 `hitTest` 返回 nil 是不够的 —— 事件仍然落在本窗口上，只是没人处理，
    /// 下层窗口收不到。真正穿透靠切换 `ignoresMouseEvents`：
    /// 光标不在角色本体 / 菜单按钮上时置 true，窗口对鼠标完全透明。
    ///
    /// 要动态切换就必须知道光标何时移回来，而窗口此时已忽略鼠标事件、
    /// 收不到 mouseMoved，所以用全局监听（`.listenOnly`，不拦截事件）。
    private func startMouseTracking() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] _ in
                // 回调由事件系统触发，不保证在哪个线程 —— 统一切回主线程处理。
                // 每个事件排一个 block（量级约百/秒）足够便宜，
                // 比赌 `assumeIsolated` 的线程假设安全（猜错就是崩溃）。
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.handleGlobalMouse()
                    }
                }
            }
    }

    /// 全局鼠标事件：松开时先解除「按压中」标记（防止 mouseUp 丢失导致它卡住），
    /// 再按当前光标位置重新评估是否接收事件。
    private func handleGlobalMouse() {
        if isPressing, NSEvent.pressedMouseButtons & 0x1 == 0 {
            isPressing = false
        }
        updateEventAcceptance(at: NSEvent.mouseLocation)
    }

    /// 按光标位置切换窗口是否接收鼠标事件。
    private func updateEventAcceptance(at screenPoint: NSPoint) {
        // 拖动 / 按压过程中必须持续接收事件，否则中途松开就跟丢了
        guard !isPressing else { return }

        // **锁定态：整块窗口一律不接收事件**（含角色本体）。
        // 这里必须先于下面的「快路径」判断 —— 那条路径只在光标离开窗口时才置
        // ignoresMouseEvents，光标停在角色本体上时它什么都不做，锁定会失效。
        guard !store.config.isLocked else {
            guard acceptsEventsNow else { return }
            acceptsEventsNow = false
            window.ignoresMouseEvents = true
            return
        }

        // 快路径：屏幕坐标先粗判是否落在窗口附近，避免每次鼠标移动都做
        // 坐标换算 + 遮罩查表（遮罩是 450×450 的位图）。
        let frame = window.frame
        guard frame.insetBy(dx: -2, dy: -2).contains(screenPoint) else {
            if acceptsEventsNow {
                acceptsEventsNow = false
                window.ignoresMouseEvents = true
            }
            return
        }

        guard let panelPoint = container.panelPoint(screen: screenPoint) else { return }
        let zone = EventRouting.zone(at: panelPoint,
                                     hitMask: container.hitMask,
                                     panelSide: frame.width,
                                     menuButtonRect: container.menuButtonRect,
                                     locked: store.config.isLocked)
        let accepts = EventRouting.acceptsEvents(zone)
        guard accepts != acceptsEventsNow else { return }
        acceptsEventsNow = accepts
        window.ignoresMouseEvents = !accepts
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    private func wireCallbacks() {
        store.onTurnCost = { [weak self] cost in
            guard let self else { return }
            bubble.showTurnCost(cost,
                                closeAfter: max(0, store.config.turnCostCloseMs / 1000),
                                text: nil)
            sounds.enabled = store.config.soundOn
            sounds.volume = store.config.volume
            sounds.playTaskEnd(SoundPlayer.TaskEnd.expOrb)
        }
        store.onAlert = { [weak self] message in
            guard let self else { return }
            bubble.showAlert(message, seconds: max(0, store.config.alertCloseSeconds))
        }
    }

    // MARK: - 尺寸与位置

    private func panelSide() -> CGFloat {
        Positioning.panelSide(scale: store.config.scale,
                              screenFrame: targetScreenSize())
    }

    /// 用于计算尺寸的屏幕尺寸（取主屏；与参考实现一样不随窗口所在屏变化）。
    private func targetScreenSize() -> CGSize {
        let frame = NSScreen.main?.frame ?? NSScreen.screens.first?.frame
        return frame.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: 1440, height: 900)
    }

    func applyScale() {
        let side = panelSide()
        // 保持左下角不动，只改尺寸
        let bottomLeft = NSPoint(x: window.frame.minX, y: window.frame.minY)
        var frame = window.frame
        frame.size = NSSize(width: side, height: side)
        window.setFrame(frame, display: true)
        window.setFrameOrigin(bottomLeft)

        // 只改尺寸，不重建视图树（重建会打断 SwiftUI 状态，且没必要）
        container.frame = NSRect(x: 0, y: 0, width: side, height: side)
        hosting.frame = NSRect(x: 0, y: 0, width: side, height: side)
        rebuildHitMask()
        applySnap()
    }

    private func restorePosition() {
        let screen = targetScreen()
        let side = panelSide()
        if let x = store.config.lastX, let y = store.config.lastY {
            // 窗口变化 / 拔插显示器后不悬空：严格夹回可见区域
            let clamped = clamp(NSPoint(x: x, y: y), side: side, screen: screen)
            window.setFrameOrigin(clamped)
            // 旧位置无效时立即回写，避免每次启动都带着坏坐标
            if clamped != NSPoint(x: x, y: y) { persistPosition() }
        } else {
            let margin = store.config.snapMargin
            window.setFrameOrigin(NSPoint(x: screen.maxX - side - margin,
                                          y: screen.minY + margin))
            applySnap()
        }
    }

    /// 目标屏幕：优先用当前窗口所在屏幕；`NSScreen.main` 在 accessory 应用启动时
    /// 可能为 nil，因此再退回第一块屏幕，避免用错坐标系。
    private func targetScreen() -> NSRect {
        window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// 把窗口原点夹到「整个窗口都留在可见区域内」。
    private func clamp(_ origin: NSPoint, side: CGFloat, screen: NSRect) -> NSPoint {
        let p = Positioning.clamp(origin: origin, side: side, visible: screen)
        return NSPoint(x: p.x, y: p.y)
    }

    // MARK: - 吸附

    private func applySnap() {
        defer { persistPosition() }
        guard store.config.snapEnabled else {
            store.update { $0.lastSide = "none" }
            return
        }
        let screen = targetScreen()
        let frame = window.frame
        let margin = store.config.snapMargin

        let result = Positioning.snapped(origin: frame.origin, side: frame.width,
                                         visible: screen, margin: margin)
        let origin = result.origin
        let side = result.side

        if origin != frame.origin {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                window.animator().setFrameOrigin(origin)
            }
        }
        store.update {
            $0.lastSide = side
            $0.lastX = Double(origin.x)
            $0.lastY = Double(origin.y)
        }
    }

    /// 把窗口移回右下角（位置异常或屏幕变化时的兜底入口）。
    func resetPosition() {
        let screen = targetScreen()
        let side = panelSide()
        let margin = store.config.snapMargin
        window.setFrameOrigin(NSPoint(x: screen.maxX - side - margin,
                                      y: screen.minY + margin))
        applySnap()
    }

    private func persistPosition() {
        let origin = window.frame.origin
        store.update {
            $0.lastX = Double(origin.x)
            $0.lastY = Double(origin.y)
        }
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let clamped = self.clamp(self.window.frame.origin,
                                             side: self.window.frame.width,
                                             screen: self.targetScreen())
                    self.window.setFrameOrigin(clamped)
                    self.persistPosition()
                }
            }
    }

    // MARK: - 菜单

    private func presentMenu() {
        // 菜单由 MenuView 通过独立窗口浮层呈现（同一时刻只保留一个）
        MenuPresenter.shared.show(store: store, bubble: bubble,
                                  soundPlayer: sounds,
                                  anchorWindow: window,
                                  onScaleChange: { [weak self] in self?.applyScale() },
                                  onInteractionChange: { [weak self] in
                                      self?.applyInteractionState()
                                  },
                                  onClose: {})
    }

    func toggleVisibility() {
        if window.isVisible { window.orderOut(nil) } else { window.orderFrontRegardless() }
    }

    func close() {
        window?.close()
    }
}
