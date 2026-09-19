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
            exit(code)
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
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var panel: PanelController?
    private let store = WhaleStore()
    private let bubble = BubbleRuntime()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

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
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        for menuItem in menu.items { menuItem.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() { panel?.toggleVisibility() }

    @objc private func refresh() { Task { await store.refresh() } }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        settingsWindow?.close()
        let hosting = NSHostingView(rootView: SettingsView(store: store, bubble: bubble,
                                                           onScaleChange: { [weak self] in
            self?.panel?.applyScale()
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

    var body: some View {
        ScrollView {
            MenuView(store: store,
                     bubble: bubble,
                     soundPlayer: SoundPlayer(),
                     onScaleChange: onScaleChange,
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
