import AppKit

/// 承载 SwiftUI 内容的容器视图，负责**所有**指针输入。
///
/// 为什么不用 SwiftUI 的 `DragGesture`：
/// 1. `translation` 是相对手势起始视图坐标系的，窗口被拖动后坐标系随之移动，
///    位移会自我反馈 → 挂件抽搐；
/// 2. 窗口重建时手势会被重置，`translation` 突然从 0 重算，本应判为点击的
///    操作被当成拖动，点击序列就推进不下去。
/// 原生 `mouseDown/Dragged/Up` 直接给出屏幕全局坐标，没有这两个问题。
final class WidgetContainerView: NSView {

    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    /// 按下（开始可能拖动）；参数为按下时的屏幕坐标
    var onPress: ((NSPoint) -> Void)?
    /// 拖动中（已确认超过阈值）；参数为当前指针的屏幕坐标
    var onDrag: ((NSPoint) -> Void)?
    /// 松开：判定结果 + 松开时的屏幕坐标
    var onRelease: ((PointerIntent.Kind, NSPoint) -> Void)?

    private var hoverArea: NSTrackingArea?
    private var isUpdating = false

    /// 按下时的全局鼠标位置与该次按压是否已判定为拖动
    private var pressStart: CGPoint?
    private var movedDuringPress = false

    // MARK: - 命中路由（click-through 的关键）

    /// 决定这个位置由谁接收鼠标事件。
    ///
    /// 返回 `nil` → 事件穿透到下层窗口（click-through），
    /// 这正是「透明像素不该挡住桌面点击」的实现方式。
    ///
    /// 三种结果：
    /// - **菜单按钮**：交给 SwiftUI 宿主视图，让按钮自己的 `onTapGesture` 生效；
    /// - **角色本体**：返回 `self`，由容器处理拖动 / 点击（不能返回子视图，
    ///   否则事件会被 SwiftUI 吃掉，容器收不到 `mouseDown/Dragged/Up`）；
    /// - **其余（气泡、透明角落）**：返回 nil，穿透。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }

        let p = panelPoint(local: local)

        // ① 菜单按钮优先：它叠在角色本体右上角，需要交给 SwiftUI 的按钮
        if let rect = menuButtonRect, rect.contains(p) {
            return super.hitTest(point)
        }

        // ② 角色本体：容器自己处理
        if let hitMask, hitMask.contains(x: p.x * bounds.width,
                                         y: p.y * bounds.height,
                                         panelSide: bounds.width) {
            return self
        }

        // ③ 气泡 / 透明像素：穿透到桌面
        return nil
    }

    // MARK: - 悬停

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // AppKit 会在布局过程中回调这里；若在这里再触发布局，可能重入并
        // 对同一个 tracking area 二次 remove，造成过度释放（SIGSEGV in objc_release）。
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        if let existing = hoverArea {
            removeTrackingArea(existing)
            hoverArea = nil
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        // 只有真正落在「有像素」的区域才算悬停 —— 透明角落不该让菜单按钮冒出来。
        // 推迟到下一个 runloop tick：悬停会改 @Published 状态并触发 SwiftUI 重排，
        // 在事件回调里同步改容易与 tracking area 的更新打架。
        guard hitContains(event) else { return }
        DispatchQueue.main.async { [weak self] in self?.onMouseEnter?() }
    }

    override func mouseMoved(with event: NSEvent) {
        // 命中遮罩会随气泡开合变化，需要在移动中重新判定进入 / 离开。
        // （inVisibleRect 的 tracking area 只在跨越视图边界时才发 entered/exited）
        let inside = hitContains(event)
        guard inside != isInsideHitArea else { return }
        isInsideHitArea = inside
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if inside { self.onMouseEnter?() } else { self.onMouseExit?() }
        }
    }

    override func mouseExited(with event: NSEvent) {
        isInsideHitArea = false
        DispatchQueue.main.async { [weak self] in self?.onMouseExit?() }
    }

    /// 当前是否位于可交互区域内
    private var isInsideHitArea = false

    // MARK: - 指针

    /// 右键小鲸鱼唤出菜单（菜单按钮隐藏后的入口）。
    override func rightMouseDown(with event: NSEvent) {
        DispatchQueue.main.async { [weak self] in self?.onRightClick?(event) }
    }

    override func mouseDown(with event: NSEvent) {
        // 只有落在「小鲸鱼 / 气泡」的可见区域才响应，
        // 方窗的透明四角不拦截桌面点击。
        guard hitContains(event) else {
            super.mouseDown(with: event)
            return
        }
        // 菜单按钮叠在小鲸鱼右上角：这一下交给 SwiftUI 的按钮处理，
        // 容器不要把它当成「点本体」，否则点菜单会顺带把气泡也翻一格。
        if let menuButtonRect, menuButtonRect.contains(panelPoint(event)) {
            super.mouseDown(with: event)
            return
        }
        let p = pointerLocation(event)
        pressStart = p
        movedDuringPress = false
        onPress?(p)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressStart else { return }
        let p = pointerLocation(event)
        if !movedDuringPress, PointerIntent.isDrag(from: start, to: p) {
            movedDuringPress = true
        }
        guard movedDuringPress else { return }
        onDrag?(p)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = pressStart else {
            super.mouseUp(with: event)
            return
        }
        let p = pointerLocation(event)
        pressStart = nil
        let wasDrag = movedDuringPress
        movedDuringPress = false
        let kind = PointerIntent.resolve(start: start, end: p, movedDuringPress: wasDrag)
        onRelease?(kind, p)
    }

    /// 取事件发生时的屏幕坐标。
    ///
    /// 用事件自带的 `locationInWindow` 换算，而**不是**读 `NSEvent.mouseLocation`：
    /// 后者是「读取那一刻」的鼠标位置，与事件生成时刻可能不同；
    /// 而且它无法在合成事件的测试里被驱动。
    private func pointerLocation(_ event: NSEvent) -> NSPoint {
        guard let win = window else { return event.locationInWindow }
        return win.convertPoint(toScreen: convert(event.locationInWindow, from: nil))
    }

    /// 当前有效的命中遮罩（**只含角色本体**，由控制器按角色图像素更新）。
    /// 为空表示整块视图都可命中（仅用于测试 / 降级）。
    var hitMask: HitMask?

    /// 面板是否处于水平镜像（贴左吸附）。
    var isMirrored = false

    /// 菜单按钮的归一化矩形（面板坐标，原点左上）；nil 表示按钮隐藏。
    /// 用于两件事：`hitTest` 把这一块交给 SwiftUI 按钮；
    /// `mouseDown` 不要把这一下也算成「点本体」。
    var menuButtonRect: CGRect?

    /// 视图坐标 → 归一化面板坐标（原点左上、未镜像）。
    private func panelPoint(local: CGPoint) -> CGPoint {
        var x = local.x
        let y = bounds.height - local.y          // AppKit 的 y 向上，面板坐标向下
        if isMirrored { x = bounds.width - x }
        return CGPoint(x: x / max(1, bounds.width), y: y / max(1, bounds.height))
    }

    /// 事件 → 归一化面板坐标。
    private func panelPoint(_ event: NSEvent) -> CGPoint {
        panelPoint(local: convert(event.locationInWindow, from: nil))
    }

    /// 屏幕坐标 → 归一化面板坐标。供全局鼠标监听判断「光标现在落在哪个区域」。
    /// 返回 nil 表示本视图还没有窗口，无法换算。
    func panelPoint(screen: NSPoint) -> CGPoint? {
        guard let win = window else { return nil }
        let inWindow = win.convertPoint(fromScreen: screen)
        return panelPoint(local: convert(inWindow, from: nil))
    }

    private func hitContains(_ event: NSEvent) -> Bool {
        guard let hitMask else { return true }
        let p = panelPoint(event)
        return hitMask.contains(x: p.x * bounds.width,
                               y: p.y * bounds.height,
                               panelSide: bounds.width)
    }

    /// 视图尺寸变化后需要重新计算 tracking area。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
    }
}
