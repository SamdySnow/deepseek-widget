import AppKit
import Foundation

/// 单实例守卫。
///
/// 有了「开机自启动」之后，同时跑两份挂件变成常态：登录时 launchd 拉起一份，
/// 用户又双击了 `.app`（或跑了一次 `--autostart on`，bootstrap 会立刻启动一份）。
/// 两份挂件的后果不是「多一个图标」那么简单：
/// - 两个悬浮窗叠在一起，各自按自己的账本记账 → 余额读数互相打架；
/// - 两份进程都在轮询余额接口，白白多花请求；
/// - 退出时只关掉一个，另一个还在屏幕上，看起来像「退不掉」。
///
/// 做法是经典的 **flock 文件锁**。选它而不是「写一个 pid 文件」的关键理由：
/// 锁的持有者是进程，进程无论怎么消失（正常退出 / 被 kill / 崩溃）内核都会
/// 立刻释放，不会留下僵尸锁把后续启动全挡死 —— 那种故障用户自己修不了。
enum SingleInstance {

    /// 锁文件路径。
    ///
    /// 用 `/tmp` 而不是配置目录：它表达的是「本机此刻是否有实例在跑」，
    /// 与用户配置无关，也不该被 `WHALE_STATE_DIR` 之类的隔离影响 ——
    /// 隔离目录里的测试进程与真实挂件仍应互斥。
    static var lockURL: URL {
        // 自检用独立锁文件：否则「用户正开着挂件时跑一次自检」会直接失败，
        // 变成一条与被测代码毫无关系的假红灯。
        // （真实使用不设这个变量，走的是下面的 uid 路径。）
        if let override = ProcessInfo.processInfo.environment["WHALE_LOCK_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        // 用 uid 分隔：多用户共享机器时各锁各的
        return URL(fileURLWithPath: "/tmp/whale-widget-\(getuid()).lock")
    }

    /// `flock` 文件描述符。取得后全程持有（进程存活期间不关闭），
    /// 让内核替我们维护「本进程在跑」这个事实。
    nonisolated(unsafe) private static var lockFD: Int32 = -1
    /// 当前持有的锁文件路径，用于识别「同一个文件重复 acquire」。
    nonisolated(unsafe) private static var lockedPath: String?

    /// 已有实例在运行时为真。
    private(set) nonisolated(unsafe) static var hasOtherInstance = false

    /// 尝试取得单实例锁。
    ///
    /// - Returns: 取得锁（本进程是新实例）返回 true；已有实例在跑返回 false。
    ///
    /// 打不开文件时**返回 true**：宁可多开一个，也不能因为文件系统上的
    /// 意外让用户完全启动不了挂件（多开是可恢复的，起不来不是）。
    @discardableResult
    static func acquire() -> Bool {
        acquire(at: lockURL)
    }

    /// 指定锁文件路径的版本（自检用临时路径调用，不干扰真实挂件的锁）。
    @discardableResult
    static func acquire(at url: URL) -> Bool {
        // 幂等：本进程已持有该文件的锁就直接成功。
        // 少了这一句会失败得很费解 —— 第二次 `open()` 拿到的是**另一条**
        // open file description，`flock` 把它当成另一个竞争者而拒绝，
        // 于是「自己和自己抢锁」失败，而且只在重复调用时才出现。
        if lockFD >= 0, lockedPath == url.path { return true }

        // O_CLOEXEC：不让子进程继承这个 fd。继承了之后父子共享同一条
        // open file description，子进程再 flock 同一个 fd 会**假成功**。
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }

        // LOCK_NB：拿不到立刻返回，不阻塞 —— 否则第二个实例会静默卡住，
        // 表现为「双击了没反应」，比报错更难排查。
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            hasOtherInstance = true
            return false
        }
        lockFD = fd
        lockedPath = url.path
        return true
    }

    /// 把已有实例带到前台（用户双击了第二份时的正确反应是「唤醒原来那个」）。
    ///
    /// 尽力而为：绑定标识来自 `Info.plist` 的 `CFBundleIdentifier`，
    /// 裸二进制（`.build/release/WhaleWidget`）不在 LaunchServices 注册表里，
    /// 此时查不到任何实例。
    @discardableResult
    static func activateExisting() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let existing = others.first else { return false }
        // 挂件是 accessory（LSUIElement），没有常规窗口可 activate；
        // activate 之后配合 `.activateAllWindows` 让它的悬浮面板回到最前。
        existing.activate(options: [.activateAllWindows])
        return true
    }
}
