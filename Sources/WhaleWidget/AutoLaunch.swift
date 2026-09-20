import Foundation

/// 开机自启动（登录项）管理。
///
/// 做法：在 `~/Library/LaunchAgents/` 写一个 LaunchAgent plist
/// （`RunAtLoad = true` / `KeepAlive = false`），登录时由 launchd 启动挂件。
///
/// 为什么不用别的方案：
/// - `SMAppService.mainApp`（macOS 13+）要求已签名的 .app bundle，且会登记进
///   「系统设置 → 通用 → 登录项」；本项目是 ad-hoc 签名，也常以裸二进制运行；
/// - `SMLoginItemSetEnabled` 需要额外塞一个 Helper bundle 进 .app；
/// - 旧的 `LSSharedFileList` API 已废弃，新系统上行为不可靠。
/// LaunchAgent 方案对「打包 .app」与「裸二进制」两种形态都有效，且状态可见可删。
///
/// **状态的真值就是那个 plist 文件**（是否存在、指向谁），不额外记进 config.json ——
/// 用户可能在别处删掉它，只有文件本身不会说谎。
enum AutoLaunch {

    /// LaunchAgent 的唯一标识。与 Info.plist 的 CFBundleIdentifier 不同：
    /// 后者属于应用本身，这里是「开机自启动」这个作业的标识。
    static let label = "com.meteornox.deepseek.whalewidget.mac.autostart"

    /// 开机自启动的登记状态。
    enum Status: Equatable {
        /// 未开启（plist 不存在，或那个 plist 不是本作业）。
        case off
        /// 已开启，且指向当前正在运行的这个可执行文件。
        case on
        /// plist 存在，但指向的可执行文件与当前进程不同 ——
        /// 说明二进制被重新构建 / 移动过（例如从 `.build/release` 移到 `dist/*.app`），
        /// 此时开机会启动**旧位置**的程序（可能已不存在）。重新开启一次即可修复。
        case stale(registered: String)

        /// 是否指向当前程序（完全就绪）。
        var isOn: Bool { self == .on }

        /// 文件系统里是否已有本作业的登记（含「指向旧位置」的情况）。
        ///
        /// 界面上的开关用它：**已经登记了就该显示为开** —— 若只认 `.on`，
        /// 二进制移动过之后开关会显示为「关」，而实际上开机仍会启动旧版本，
        /// 这就是典型的「界面与实际不一致」。
        var isRegistered: Bool {
            switch self {
            case .off: return false
            case .on, .stale: return true
            }
        }
    }

    // MARK: - 路径

    /// 真实的状态目录（用户的登录项目录）。
    static var realDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    /// 自检 / 压测等非交互入口一律隔离到临时目录，**绝不动用户真实的登录项**
    /// （与 `AppConfig.directory` 同一套规矩：跑一次自检不该让用户多出一个登录项）。
    /// 需要固定位置时用 `WHALE_LAUNCH_AGENT_DIR` 显式指定。
    static var directory: URL {
        if let env = ProcessInfo.processInfo.environment["WHALE_LAUNCH_AGENT_DIR"],
           !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        if AppConfig.isTestRun {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "whale-widget-launchd-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true)
        }
        return realDirectory
    }

    static var plistURL: URL {
        directory.appendingPathComponent("\(label).plist")
    }

    /// launchd 日志目录。
    ///
    /// 同样在测试下隔离：否则跑一次自检就会在用户 `~/Library/Logs` 里
    /// 留下一个空目录（虽然无害，但违反「测试不碰用户环境」的约定）。
    static var logDirectory: URL {
        if let env = ProcessInfo.processInfo.environment["WHALE_LAUNCH_LOG_DIR"],
           !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        if AppConfig.isTestRun { return directory.appendingPathComponent("Logs", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WhaleWidget", isDirectory: true)
    }

    /// 当前进程的可执行文件绝对路径。取不到就返回 nil（此时无法登记自启动）。
    ///
    /// `Bundle.main.executablePath` 对裸二进制（`.build/release/WhaleWidget`）
    /// 与打包后的 `.app/Contents/MacOS/WhaleWidget` 都返回绝对路径。
    static var executablePath: String? {
        if let path = Bundle.main.executablePath, path.hasPrefix("/") { return path }
        // 兜底：argv[0]（仅在确是绝对路径时可用）
        let argv0 = CommandLine.arguments.first ?? ""
        return argv0.hasPrefix("/") ? argv0 : nil
    }

    // MARK: - 状态查询

    /// 读取当前登记状态。真值完全来自 plist 文件本身。
    static func status(executable: String? = AutoLaunch.executablePath) -> Status {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = (try? PropertyListSerialization.propertyList(
                  from: data, format: nil)) as? [String: Any] else { return .off }
        // 文件在、但不是本作业（Label 对不上）：launchd 也不会加载它。
        // 这里报 .off 是有意为之 —— 用户再打开一次就会覆盖成正确内容，属于自愈。
        guard (plist["Label"] as? String) == label else { return .off }

        let registered = (plist["ProgramArguments"] as? [String])?.first ?? ""
        guard let executable, !executable.isEmpty else {
            // 拿不到自己的可执行路径就无法核对，有记录就当开着（界面仍可关闭）
            return registered.isEmpty ? .off : .on
        }
        guard registered == executable else {
            return .stale(registered: registered.isEmpty ? "（未指定程序）" : registered)
        }
        return .on
    }

    static var isEnabled: Bool { status().isOn }

    // MARK: - plist 内容（纯函数，便于单测）

    /// 生成 LaunchAgent 的内容。
    ///
    /// - `RunAtLoad = true`：登录时启动。
    /// - `KeepAlive = false`：**不要**常驻拉起 —— 用户在菜单里「退出」就是真的退出，
    ///   否则会被 launchd 立刻重启（那会变成一个关不掉的程序）。
    /// - `LimitLoadToSessionType = Aqua`：只在图形登录会话里启动，
    ///   避免在 ssh / 后台会话中也被拉起来。
    /// - `logDirectory` 传 nil 时不写日志键（目录建不出来时的降级）。
    static func plistContents(executable: String, logDirectory: URL?) -> [String: Any] {
        var dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        if let logDirectory {
            // 崩溃/启动失败时能从这里找线索（launchd 自己不会弹窗报错）
            let log = logDirectory.appendingPathComponent("autostart.log").path
            dict["StandardOutPath"] = log
            dict["StandardErrorPath"] = log
        }
        return dict
    }

    // MARK: - 开关

    /// 登记状态发生变化时广播。
    ///
    /// 为什么需要它：同一份状态有**两个**界面在显示（挂件菜单里的开关、
    /// 菜单栏 🐋 里的勾选项）。两处都是「用的时候才去读文件」——
    /// 于是「设置窗口开着的时候从菜单栏改一下」就会让设置窗口一直显示旧状态，
    /// 看起来像开关失灵。变更后广播一次，各处重新读盘即可保持一致。
    static let didChangeNotification = Notification.Name("whaleAutoLaunchDidChange")

    /// 开启 / 关闭开机自启动。返回 nil 表示成功，否则是面向用户的错误说明。
    ///
    /// - Parameter executable: 要登记的可执行文件绝对路径，默认取当前进程。
    ///   暴露成参数是为了能单测「指向旧位置」的分支 —— 不传就始终是稳定行为。
    @discardableResult
    static func setEnabled(_ enabled: Bool,
                           executable: String? = AutoLaunch.executablePath) -> String? {
        let error = enabled ? install(executable: executable) : remove()
        // 无论成功失败都广播：失败时界面也该重新读一次（例如「删不掉」这种情况
        // 文件还在，界面必须如实显示为「仍已登记」，而不是停在用户期望的新状态）。
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        return error
    }

    /// 写入 plist 并交给 launchd。重复调用是幂等的（覆盖同一文件）。
    @discardableResult
    static func install(executable: String? = AutoLaunch.executablePath) -> String? {
        guard let executable, executable.hasPrefix("/") else {
            return "找不到可执行文件路径，无法登记开机自启动"
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return "无法创建 \(directory.path)：\(error.localizedDescription)"
        }

        // 日志目录只是锦上添花：建不出来就退化成不写日志键。
        // 别让「日志目录建不了」升级成「开机自启动装不上」。
        var logs: URL? = logDirectory
        if (try? fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)) == nil {
            logs = nil
        }

        let contents = plistContents(executable: executable, logDirectory: logs)
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: contents,
                                                          format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return "写入 \(plistURL.lastPathComponent) 失败：\(error.localizedDescription)"
        }

        // 立刻让 launchd 认到（失败不致命：文件已经在位，下次登录照样生效）
        _ = loadIntoLaunchd()
        return nil
    }

    /// 移除 plist。对「本来就没开」是幂等的，返回 nil。
    @discardableResult
    static func remove() -> String? {
        _ = unloadFromLaunchd()
        let path = plistURL.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            try FileManager.default.removeItem(at: plistURL)
        } catch {
            return "删除 \(plistURL.lastPathComponent) 失败：\(error.localizedDescription)"
        }
        return nil
    }

    // MARK: - launchctl

    /// launchd 的目标域。现代写法是 `gui/<uid>`（旧写法 `load -w` 已废弃）。
    static var launchdDomain: String { "gui/\(getuid())" }

    /// 让 launchd 立刻载入本作业。
    ///
    /// 状态真值是 plist 文件，因此这里失败不影响正确性（下次登录照常生效）；
    /// 只在自检里被跳过 —— 测试不该去动用户真实的 launchd。
    @discardableResult
    static func loadIntoLaunchd() -> Bool {
        guard !AppConfig.isTestRun else { return false }
        return runLaunchctl(["bootstrap", launchdDomain, plistURL.path])
    }

    @discardableResult
    static func unloadFromLaunchd() -> Bool {
        guard !AppConfig.isTestRun else { return false }
        return runLaunchctl(["bootout", launchdDomain, plistURL.path])
    }

    private static func runLaunchctl(_ arguments: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = arguments
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    // MARK: - 测试隔离清理

    /// 清理自检用的隔离目录（与 `AppConfig.cleanUpTestDirectory()` 配套调用）。
    static func cleanUpTestDirectory() {
        guard AppConfig.isTestRun, directory != realDirectory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// 把绝对路径缩写成 `~/…` 形式，用于界面提示。
    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
