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
    /// 吸附位移动画的定时器（见 `moveWindow(to:)`）
    private var snapAnimTimer: Timer?
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
        // 用户按下即接管：立刻停掉可能还在跑的吸附动画。
        //
        // 这既符合直觉（手抓住挂件了，它不该再自己滑），也是必需的：
        // 动画期间窗口在动，而「按下 / 松开」两次事件里的窗口坐标都在变，
        // 同一个屏幕点位会被换算成不同的视图坐标 → 位移被判成拖动 →
        // **点击被吞掉**（实测：初始化时的吸附动画没跑完就点击，第 1 次点击必失效）。
        cancelSnapAnimation()
        isPressing = true
        dragOrigin = window.frame.origin
        dragMouseStart = point
    }

    func handleDrag(_ point: NSPoint) {
        let raw = PointerIntent.windowOrigin(windowStart: dragOrigin,
                                             mouseStart: dragMouseStart,
                                             mouseNow: point)
        // 拖动过程中也要夹回可见区域。
        // 原来只在「松手」时夹，于是拖动中可以把窗口推出屏幕；若松手时
        // 又恰好触发了吸附动画，夹取结果与动画目标会互相打架 —— 实测表现是
        // 「拖到屏幕左半边，松手后被弹回原位」（`lastSide` 已是 left，窗口却没动）。
        let clamped = clamp(raw, side: window.frame.width, screen: targetScreen())
        window.setFrameOrigin(clamped)
        // 拖动中实时更新朝向（拖到屏幕左半边就即时翻转，不必等松手）
        refreshMirror()
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

    /// 把面板移到屏幕外，避免自检时窗口闪现在用户桌面上。
    func moveOffscreenForTesting() {
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    }

    /// 供自检把面板摆到指定屏幕位置 —— 吸附依赖真实屏幕坐标，
    /// 离屏（-10000）状态下算不出「靠近哪条边」。
    ///
    /// **同时停掉可能还在跑的吸附动画**：否则测试刚摆好位置，
    /// 上一次动画的后续帧又会把窗口挪走，断言就会读到意外坐标。
    func placeForTesting(origin: NSPoint) {
        cancelSnapAnimation()
        window.setFrameOrigin(origin)
    }

    /// 当前屏幕可见区域（供自检计算期望的吸附位置）。
    var visibleFrameForTesting: NSRect { targetScreen() }

    /// 当前是否处于镜像状态（供自检断言「贴左翻转」）。
    var isMirroredForTesting: Bool { container.isMirrored }

    /// 模拟「拖动松手」 —— 走与真人拖动完全相同的分支。
    func simulateDragReleaseForTesting() { applySnap() }

    /// 按当前配置重算镜像（供自检驱动）。
    func refreshMirrorForTesting() { refreshMirror() }

    /// 直接走窗口帧动画（供自检验证「窗口真的会动」，见 `moveWindow` 的说明）。
    func animateToForTesting(_ origin: NSPoint) {
        moveWindow(to: origin)
    }

    /// 重置位置（供自检驱动，等价于菜单里的「重置位置」）。
    func resetPositionForTesting() { resetPosition() }

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
        refreshMirror()
        // 按钮隐藏时置 nil：否则它周围一块会变成「可点但无反应」的死区
        container.menuButtonRect = store.config.menuButtonHidden
            ? nil : Positioning.menuButtonRectNormalized
        container.locked = store.config.isLocked
        startMouseTracking()
        updateEventAcceptance(at: NSEvent.mouseLocation)
    }

    /// 计算当前应当是否镜像（朝屏幕内侧）。对应参考实现的 `refreshFlip()`：
    ///
    /// - **贴左吸附** → 必翻（朝右，朝向屏幕内）
    /// - **贴右吸附** → 不翻（朝左，朝向屏幕内）
    /// - **自由摆放** → 按「图案中心」与屏幕竖直中线判定：
    ///   图案在左半边就翻。注意判断点取的是**图案**中心而非窗口盒中心 ——
    ///   挂件是右下角一只小鲸鱼、左上大片留白，用盒中心会把「视觉上明明在左边」
    ///   的挂件判成右半边。
    ///
    /// 关闭吸附时走的是自由摆放分支（原先直接置 `none` → 永不翻转，
    /// 所以「贴到屏幕左侧也不翻转」）。这里同时兼容「关吸附但停靠在左边」的场景：
    /// 贴边（含 2px 容差）时按吸附边定朝向，否则按图案中心判定。
    private func desiredSide(originOverride: NSPoint? = nil) -> String {
        let screen = targetScreen()
        let boxOrigin = originOverride ?? window.frame.origin
        let boxSide = window.frame.width
        let box = CGRect(origin: boxOrigin, size: CGSize(width: boxSide, height: boxSide))

        // 挂件完全不在屏幕上时，朝向无从谈起 —— 保持现状。
        //
        // 这既是常识（离屏的挂件没有「朝屏幕内」可言），也是必需的护栏：
        // 自检会把窗口挪到 (-10000, -10000) 以免闪现在用户桌面上，而那个坐标
        // 在几何上属于「屏幕左侧」，会被判成 left → 容器进入镜像态 →
        // 之后所有合成点击的 x 都被镜像 → 全部落在透明区，点击一律失效。
        // （这正是加入本方法后 `--e2e` 前段点击断言突然变红的原因。）
        guard box.intersects(screen) else { return store.config.lastSide }

        let strength = store.config.snapEnabled
            ? Positioning.Zones.reference(for: screen)
            : Positioning.Zones.uniform(2)

        // 贴边命中（含「关闭吸附但仍停靠在边上」）时以边为准，保证朝向屏幕内
        let snapped = Positioning.snapped(origin: boxOrigin, side: boxSide,
                                          visible: screen, zones: strength)
        if snapped.side != "none" { return snapped.side }

        // 自由摆放：按图案中心的 x 与屏幕中线比较
        let mirrored = store.config.lastSide == "left" && store.config.mirrorOnLeftSnap
        let art = Positioning.artRect(origin: boxOrigin, side: boxSide, mirrored: mirrored)
        return art.midX < screen.midX ? "left" : "right"
    }

    /// 按当前几何重算朝向，并把镜像状态同步给容器。
    ///
    /// **朝向的来源只有一个：这里算出来的 `lastSide`。**
    /// - 视图层（`WhalePanelView`）按 `lastSide` 决定整机是否镜像；
    /// - 容器（原生命中判定）需要 `container.isMirrored` 才能把点击坐标
    ///   映射回未镜像的遮罩。
    ///
    /// 只在 `rebuildHitMask` 里设一次是不够的：`applySnap` 改了 `lastSide`
    /// 之后不会重建遮罩（尺寸没变），于是「贴左吸附 → 视觉翻转了，
    /// 但容器仍按未镜像算 → 点鲸鱼点不动」。
    ///
    /// - Parameter assumePlacedAtTarget: 吸附动画尚未结束时，用「窗口将要到达的位置」
    ///   参与朝向判定（动画途中若按当前位置算，贴左会被误判成贴右）。
    func refreshMirror(assumePlacedAtTarget: NSPoint? = nil) {
        let want = desiredSide(originOverride: assumePlacedAtTarget)
        if store.config.lastSide != want {
            store.update { $0.lastSide = want }
        }
        // 与视图层用**同一个**判据（`lastSide == "left"` 且开关打开），
        // 否则「视图翻了、命中判定没翻」这类不一致会直接表现为点不动。
        let mirrored = store.config.lastSide == "left" && store.config.mirrorOnLeftSnap
        guard container.isMirrored != mirrored else { return }
        container.isMirrored = mirrored
        // 镜像会改变点击坐标的映射，遮罩判定随之失效，必须重新评估穿透
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

    /// 应用「镜像 / 吸附」等位置外观设置（菜单里改开关后调用）。
    func applyPositionSettings() {
        applySnapPolicy()
        if store.config.snapEnabled {
            applySnap()
        } else {
            // 关掉吸附：位置不动，只重算朝向（贴左仍要翻转，见 desiredSide）
            refreshMirror()
            persistPosition()
        }
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
        snapAnimTimer?.invalidate()
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
        // 余额预警 / 预算提醒由**真实轮询结果**驱动，时机取决于网络与账本状态。
        // 自检下不接这条回调：它会在断言进行中异步插入一个临时提醒泡泡，而
        // `BubbleRuntime.handleTap` 遇到临时提醒时**只关闭、不推进序列** ——
        // 于是「第 1 次点击没反应」这种看起来像 bug 的红灯，其实只是测试
        // 被真实网络事件插了队（本项目已踩：同一段点击断言时红时绿）。
        // 提醒本身的行为改由 `--hitcheck` 里的确定性断言覆盖（直接构造提醒再点击）。
        guard !AppConfig.isTestRun else { return }
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
        // **位置定下来后必须重算朝向**。
        // `createWindow()` 里建窗时原点是 (0,0)，而 (0,0) 正好是屏幕左下角，
        // 会被判成「贴左」→ 容器进入镜像态；若这里不纠正，容器就带着错误的
        // 镜像标记运行，合成/真实点击的 x 坐标全被镜像 → 点击落在透明区 → 一律失效。
        // （这正是加入 `refreshMirror` 后 `--e2e` 首次点击断言变红的原因。）
        refreshMirror()
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
        guard store.config.snapEnabled else {
            // 关闭吸附：位置不变，但要按图案位置重算朝向（见 refreshMirror）
            refreshMirror()
            persistPosition()
            return
        }
        let screen = targetScreen()
        let frame = window.frame
        let zones = Positioning.Zones.reference(for: screen)

        let result = Positioning.snapped(origin: frame.origin, side: frame.width,
                                         visible: screen, zones: zones)
        let origin = result.origin

        if origin != frame.origin {
            moveWindow(to: origin)
        }
        // 朝向按**吸附后的目标位置**判定，不能按当前位置：
        // 贴左边时当前位置可能还在屏幕右半边，用当前位置算会得出 right（不翻转），
        // 这是「贴左不翻转」的成因之一。
        let side = Positioning.snapped(origin: origin, side: frame.width,
                                       visible: screen, zones: zones).side

        // 顺序很重要：先把「窗口将要到达的位置」与朝向写进配置，再 refreshMirror。
        // 反之（先 refreshMirror 后写坐标）会出两个问题：
        //   1. refreshMirror 的 desiredSide() 读的是**当前位置**，而窗口还在动画途中；
        //   2. persistPosition 用当前（尚未移动的）frame 覆盖 lastX/lastY，
        //      把吸附目标从配置里冲掉 —— 重启后位置就丢了。
        store.update {
            $0.lastSide = side
            $0.lastX = Double(origin.x)
            $0.lastY = Double(origin.y)
        }
        // 位置与朝向定下来后再同步镜像给容器（原生命中判定不观察 store）；
        // 传入目标位置，让动画途中也能得出正确的朝向。
        refreshMirror(assumePlacedAtTarget: origin)
    }

    /// 把窗口移回右下角默认位（菜单「重置位置」入口）。
    ///
    /// 「重置」应当**无条件**回到默认位，所以这里显式把 `lastSide` 置为 `right`
    /// （右下角 = 贴右边 → 不翻转），而不是交给 `applySnap` 去推断：
    /// 用户在屏幕中间时 `applySnap` 会算出 `none`，那「重置」就变成「原地不动」了。
    func resetPosition() {
        let screen = targetScreen()
        let side = panelSide()
        let margin = store.config.snapMargin
        let origin = NSPoint(x: screen.maxX - side - margin,
                             y: screen.minY + margin)
        window.setFrameOrigin(origin)
        store.update {
            $0.lastSide = "right"
            $0.lastX = Double(origin.x)
            $0.lastY = Double(origin.y)
        }
        refreshMirror()
        persistPosition()
    }

    /// 立刻停掉吸附动画（若在跑），并把窗口留在当前位置。
    /// 按下 / 拖动开始时调用：动画期间窗口在移动，会让「按下→松开」的
    /// 坐标换算产生虚假位移，把点击误判成拖动。
    private func cancelSnapAnimation() {
        snapAnimTimer?.invalidate()
        snapAnimTimer = nil
    }

    /// 把窗口平滑移到目标原点（吸附动画）。
    ///
    /// **不要用 `window.animator().setFrameOrigin(...)`**：在本项目里它是个
    /// 彻底的 no-op —— 实测调用后立即读、以及等 0.6 秒后再读，窗口都停在原位。
    /// 这正是「松手后不吸附」的根因：吸附目标算对了、坐标也写进配置了，
    /// 唯独窗口没动。（`--e2e` 的「窗口帧动画机制」一节专门盯着这一点。）
    ///
    /// 这里改用自己驱动的定时器插值：每帧 `setFrameOrigin` 一次。
    /// 直接赋值是可靠的（拖动路径就是这么做的），插值只是让它看起来顺滑。
    /// 时长 0.16s / 20 帧 ≈ 60fps。
    private func moveWindow(to target: NSPoint) {
        snapAnimTimer?.invalidate()
        snapAnimTimer = nil

        let start = window.frame.origin
        let duration: TimeInterval = 0.16
        let frames = 20
        let interval = duration / Double(frames)
        var step = 0

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                step += 1
                let t = min(1.0, Double(step) / Double(frames))
                // ease-out：起步快、贴近目标时减速，视觉上更像「吸住」
                let e = 1 - pow(1 - t, 3)
                let next = NSPoint(x: start.x + (target.x - start.x) * e,
                                   y: start.y + (target.y - start.y) * e)
                self.window.setFrameOrigin(next)
                if step >= frames {
                    // 收尾时精确落到目标，避免累积误差
                    self.window.setFrameOrigin(target)
                    timer.invalidate()
                    self.snapAnimTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        snapAnimTimer = timer
    }

    /// 把当前窗口位置写入配置。
    ///
    /// 吸附动画进行中**不要**调用：那时 `window.frame` 还是动画途中的中间值，
    /// 会把刚算好的吸附目标覆盖掉（重启后就回到吸附前的位置）。
    private func persistPosition() {
        guard snapAnimTimer == nil else { return }
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
                                  onPositionChange: { [weak self] in
                                      self?.applyPositionSettings()
                                  },
                                  onResetPosition: { [weak self] in
                                      self?.resetPosition()
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
