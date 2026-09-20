import AppKit
import SwiftUI

@main
struct WhaleWidgetApp {

    /// NSApplication.delegate 是弱引用，必须自己持有强引用，否则 delegate 会被立刻释放。
    private static var delegate: AppDelegate?

    static func main() {
        // 自检 / 压测 / 渲染等入口会驱动真实的 store 与 controller（进而写配置），
        // 因此统一在隔离的临时状态目录里跑，结束后清理 —— 绝不动用户的真实配置。
        // 见 AppConfig.directory 的说明。
        func runIsolated(_ body: () -> Int32) -> Never {
            let code = body()
            AppConfig.cleanUpTestDirectory()
            // 自检用的 LaunchAgent 隔离目录也要清掉 —— 否则每跑一次验证
            // 就在临时目录里留下一个 plist（真实登录项则从未被触碰）。
            AutoLaunch.cleanUpTestDirectory()
            exit(code)
        }

        // 单实例锁的探针入口（供 `--selftest` 跨进程校验使用）：
        // 抢不到锁就用专用退出码 7 让位 —— 与「崩溃」（非 0 的其它值）区分开。
        // 必须放在最前面：它只关心锁，不做任何初始化。
        if CommandLine.arguments.contains("--probe-single-instance") {
            exit(SingleInstance.acquire() ? 0 : 7)
        }

        // 自检模式：不启动界面，只验证核心链路（凭据 / 计价 / 记账 / 接口 / 资源）
        if CommandLine.arguments.contains("--selftest") {
            runIsolated { SelfTest.run() }
        }
        // 交互路由校验：确认「点本体出泡」「点菜单按钮弹菜单」互不干扰
        if CommandLine.arguments.contains("--hitcheck") {
            runIsolated { HitCheck.run() }
        }
        // 端到端校验：起真实窗口，用合成鼠标事件走完整链路
        if CommandLine.arguments.contains("--e2e") {
            runIsolated { EndToEndCheck.run() }
        }
        // 离屏渲染校验：把挂件画成 PNG 并做像素断言
        if let index = CommandLine.arguments.firstIndex(of: "--render") {
            // 默认输出到临时目录，**不要**默认写当前目录 ——
            // 否则会在仓库根目录留下一堆 png，还会让 SwiftPM 报
            // "found N file(s) which are unhandled"。
            let dir = index + 1 < CommandLine.arguments.count
                ? CommandLine.arguments[index + 1]
                : FileManager.default.temporaryDirectory
                    .appendingPathComponent("whale-render").path
            runIsolated { RenderCheck.run(outputDir: dir) }
        }
        // 稳定性压测：放大状态变化频率，用于复现运行期崩溃
        if let index = CommandLine.arguments.firstIndex(of: "--stress") {
            let seconds = index + 1 < CommandLine.arguments.count
                ? Double(CommandLine.arguments[index + 1]) ?? 180 : 180
            runIsolated { StressTest.run(seconds: seconds) }
        }
        // 开机自启动的开关/查询。**刻意不走隔离目录**：这个命令要操作的就是
        // 用户真实的 `~/Library/LaunchAgents`（也正因如此它是显式命令，
        // 不做任何"猜你想开"的自动化）。
        // 用法：`WhaleWidget --autostart [on|off|status]`，省略参数等同 status。
        if let index = CommandLine.arguments.firstIndex(of: "--autostart") {
            let action = index + 1 < CommandLine.arguments.count
                ? CommandLine.arguments[index + 1] : "status"
            exit(AutoLaunchCommand.run(action))
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // 单实例守卫：在开机自启动（launchd 拉起一份）与用户双击 .app 同时发生时，
        // 必须只保留一份挂件 —— 否则两个悬浮窗各按自己的账本记账，读数会互相打架。
        // 上面各测试入口都已 exit，所以这里不会影响自检。
        guard SingleInstance.acquire() else {
            // 已有实例：把它带到最前，而不是再开一个窗口
            SingleInstance.activateExisting()
            exit(0)
        }

        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var panel: PanelController?
    private let store = WhaleStore()
    private let bubble = BubbleRuntime()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var unlockItem: NSMenuItem?
    private var autoLaunchItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 先在菜单栏放一个入口，方便在挂件被隐藏时找回
        setupStatusItem()

        // 排查用：WHALE_SKIP_PANEL=1 时只跑菜单栏，不创建悬浮面板
        if ProcessInfo.processInfo.environment["WHALE_SKIP_PANEL"] != "1" {
            panel = PanelController(store: store, bubble: bubble)
        }
        store.startAutoRefresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stopAutoRefresh()
        LedgerStore.save(store.ledger)
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🐋"
        item.button?.toolTip = "DeepSeek 小鲸鱼挂件"

        let menu = NSMenu()
        menu.addItem(withTitle: "显示 / 隐藏挂件", action: #selector(togglePanel), keyEquivalent: "h")
        menu.addItem(withTitle: "立即刷新余额", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(.separator())
        // 锁定的**唯一**解锁入口：锁定后整个挂件 click-through，
        // 连菜单按钮与右键都不再响应，用户只能从这里回来。
        let unlock = NSMenuItem(title: "解锁挂件",
                                action: #selector(unlockPanel), keyEquivalent: "l")
        menu.addItem(unlock)
        unlockItem = unlock
        menu.addItem(.separator())
        // 开机自启动：与挂件菜单里的开关共用**同一个真值**（LaunchAgent plist 文件）。
        // 两处都在「用的时候」重新读盘，所以不需要互相通知也能各自正确；
        // 本项在 menuNeedsUpdate 里刷新，挂件菜单在 onAppear / didChangeNotification 时刷新。
        let autostart = NSMenuItem(title: "开机自启动",
                                   action: #selector(toggleAutoLaunch), keyEquivalent: "")
        menu.addItem(autostart)
        autoLaunchItem = autostart
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        for menuItem in menu.items { menuItem.target = self }
        item.menu = menu
        statusItem = item
        // 菜单每次弹出前刷新各项的可用状态（解锁 / 自启动勾选）
        menu.delegate = self
    }

    @objc private func togglePanel() { panel?.toggleVisibility() }

    @objc private func refresh() { Task { await store.refresh() } }

    /// 切换开机自启动。失败时用 alert 说明原因 —— 菜单项的标题变化不足以
    /// 传达「写入 LaunchAgents 失败」这类需要用户处理的问题。
    @objc private func toggleAutoLaunch() {
        let enable = !AutoLaunch.status().isRegistered
        if let error = AutoLaunch.setEnabled(enable) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = enable ? "无法开启开机自启动" : "无法关闭开机自启动"
            alert.informativeText = "\(error)\n\n登记文件：\(AutoLaunch.plistURL.path)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    /// 解除锁定。锁定时挂件本身不可交互，因此这个入口必须在菜单栏可用。
    @objc private func unlockPanel() {
        guard store.config.isLocked else { return }
        store.update { $0.locked = false }
        panel?.applyInteractionState()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// 菜单弹出前刷新各项状态：未锁定时「解锁挂件」置灰；自启动显示勾选
    /// 与「指向旧位置」的提示。
    func menuNeedsUpdate(_ menu: NSMenu) {
        unlockItem?.isEnabled = store.config.isLocked

        switch AutoLaunch.status() {
        case .off:
            autoLaunchItem?.state = .off
            autoLaunchItem?.title = "开机自启动"
        case .on:
            autoLaunchItem?.state = .on
            autoLaunchItem?.title = "开机自启动"
        case .stale(let registered):
            // 勾上（确实已登记），但标题点明问题：否则用户只会看到「开了却没生效」
            autoLaunchItem?.state = .on
            autoLaunchItem?.title = "开机自启动（指向旧位置：\(AutoLaunch.abbreviated(registered))）"
        }
    }

    @objc private func openSettings() {
        settingsWindow?.close()
        let hosting = NSHostingView(rootView: SettingsView(store: store, bubble: bubble,
                                                           onScaleChange: { [weak self] in
            self?.panel?.applyScale()
        }, onInteractionChange: { [weak self] in
            self?.panel?.applyInteractionState()
        }, onPositionChange: { [weak self] in
            self?.panel?.applyPositionSettings()
        }, onResetPosition: { [weak self] in
            self?.panel?.resetPosition()
        }))
        let size = NSSize(width: 380, height: 520)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "小鲸鱼挂件设置"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}

/// 独立设置窗口（与挂件菜单内容一致，便于从菜单栏打开）。
struct SettingsView: View {

    @ObservedObject var store: WhaleStore
    @ObservedObject var bubble: BubbleRuntime
    var onScaleChange: () -> Void
    var onInteractionChange: () -> Void
    var onPositionChange: () -> Void
    var onResetPosition: () -> Void

    var body: some View {
        ScrollView {
            MenuView(store: store,
                     bubble: bubble,
                     soundPlayer: SoundPlayer(),
                     onScaleChange: onScaleChange,
                     onInteractionChange: onInteractionChange,
                     onPositionChange: onPositionChange,
                     onResetPosition: onResetPosition,
                     onOpenUsage: {
                         WindowPresenter.shared.show(title: "用量记录",
                                                     size: NSSize(width: 460, height: 560)) {
                             UsageView(store: store)
                         }
                     },
                     onOpenBubbleEditor: {
                         WindowPresenter.shared.show(title: "自定义泡泡",
                                                     size: NSSize(width: 900, height: 600)) {
                             BubbleEditorView(bubble: bubble, store: store)
                         }
                     },
                     onReconcile: {
                         WindowPresenter.shared.show(title: "余额校正",
                                                     size: NSSize(width: 420, height: 320)) {
                             ReconcileView(store: store)
                         }
                     },
                     onClose: { NSApp.keyWindow?.close() })
                .padding(0)
        }
        .frame(width: 340, height: 520)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
