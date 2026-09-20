import AppKit
import SwiftUI

/// 菜单浮层：大小滑块、音效、峰值文案、泡泡开关、每轮消耗、吸附、额度与密钥、用量记录。
@MainActor
final class MenuPresenter {

    static let shared = MenuPresenter()

    private var window: NSWindow?

    func show(store: WhaleStore,
              bubble: BubbleRuntime,
              soundPlayer: SoundPlayer,
              anchorWindow: NSWindow?,
              onScaleChange: @escaping () -> Void,
              onInteractionChange: @escaping () -> Void = {},
              onPositionChange: @escaping () -> Void = {},
              onResetPosition: @escaping () -> Void = {},
              onClose: @escaping () -> Void) {

        closeCurrent()

        let view = MenuView(
            store: store,
            bubble: bubble,
            soundPlayer: soundPlayer,
            onScaleChange: onScaleChange,
            onInteractionChange: onInteractionChange,
            onPositionChange: onPositionChange,
            onResetPosition: onResetPosition,
            onOpenUsage: { [weak self] in self?.openUsage(store: store, bubble: bubble) },
            onOpenBubbleEditor: { [weak self] in self?.openBubbleEditor(bubble: bubble, store: store) },
            onReconcile: { [weak self] in self?.openReconcile(store: store) },
            onClose: { [weak self] in
                self?.closeCurrent()
                onClose()
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.layout()
        let size = hosting.fittingSize
        let panel = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        // 关键：默认 true 时关闭窗口会自行释放，而我们同时持有强引用，
        // 之后再次访问/释放就会过度释放（SIGSEGV in objc_release）。
        panel.isReleasedWhenClosed = false

        // 定位到挂件左侧（空间不足则右侧）
        if let anchor = anchorWindow {
            let margin: CGFloat = 8
            var origin = NSPoint(x: anchor.frame.minX - size.width - margin,
                                 y: anchor.frame.maxY - size.height)
            if origin.x < (anchor.screen?.visibleFrame.minX ?? 0) {
                origin.x = anchor.frame.maxX + margin
            }
            let visible = anchor.screen?.visibleFrame ?? .zero
            origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }

        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window = panel
    }

    /// 关闭并释放当前菜单窗口（同一时刻只允许一个）。
    func closeCurrent() {
        guard let window else { return }
        self.window = nil
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    private func openUsage(store: WhaleStore, bubble: BubbleRuntime) {
        WindowPresenter.shared.show(
            title: "用量记录",
            size: NSSize(width: 460, height: 560)
        ) { UsageView(store: store) }
    }

    private func openBubbleEditor(bubble: BubbleRuntime, store: WhaleStore) {
        WindowPresenter.shared.show(
            title: "自定义泡泡",
            size: NSSize(width: 760, height: 620)
        ) { BubbleEditorView(bubble: bubble, store: store) }
    }

    private func openReconcile(store: WhaleStore) {
        WindowPresenter.shared.show(
            title: "余额校正",
            size: NSSize(width: 420, height: 300)
        ) { ReconcileView(store: store) }
    }
}

/// 通用窗口呈现器（用于用量记录 / 泡泡编辑器 / 校正等辅助窗口）。
@MainActor
final class WindowPresenter {

    static let shared = WindowPresenter()
    private var windows: [NSWindow] = []
    private var observers: [NSObjectProtocol] = []

    func show<V: View>(title: String, size: NSSize, @ViewBuilder content: () -> V) {
        let hosting = NSHostingView(rootView: content())
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentView = hosting
        // 默认 true 时会与我们的强引用重复释放，必须显式关掉
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windows.append(window)

        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] note in
                Task { @MainActor in
                    guard let self, let closed = note.object as? NSWindow else { return }
                    self.windows.removeAll { $0 === closed }
                }
            }
        observers.append(observer)
    }
}
