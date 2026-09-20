import Foundation

/// 开机自启动的命令行入口：`WhaleWidget --autostart [on|off|status]`。
///
/// 为什么要有它：
/// - 打包脚本 / 部署流程可以一行命令装好自启动，不必手工点菜单；
/// - 菜单开关只能验「函数返回值」，这个入口能验「真的写到了
///   `~/Library/LaunchAgents` 且 launchctl 认到」——端到端的那一半。
enum AutoLaunchCommand {

    static func run(_ action: String) -> Int32 {
        switch action {
        case "on", "enable":
            return apply(enable: true)
        case "off", "disable":
            return apply(enable: false)
        case "status":
            return printStatus()
        default:
            FileHandle.standardError.write(Data("""
            用法：WhaleWidget --autostart [on|off|status]

              on      登记开机自启动（写入 ~/Library/LaunchAgents）
              off     移除开机自启动
              status  查看当前登记状态（默认）

            """.utf8))
            return 2
        }
    }

    private static func apply(enable: Bool) -> Int32 {
        if let error = AutoLaunch.setEnabled(enable) {
            FileHandle.standardError.write(Data("❌ \(error)\n".utf8))
            return 1
        }
        // 开关成功就回 0（刻意不用 printStatus() 的退出码：那个码表达的是
        // "当前处于什么状态"，不是"这次操作成功没有"）。
        _ = printStatus()
        return 0
    }

    private static func printStatus() -> Int32 {
        switch AutoLaunch.status() {
        case .off:
            print("开机自启动：关闭")
            return 1
        case .on:
            print("开机自启动：已开启")
            print("  程序：\(AutoLaunch.executablePath ?? "（未知）")")
            print("  登记：\(AutoLaunch.plistURL.path)")
            return 0
        case .stale(let registered):
            // 退出码与「关闭」区分开：脚本能据此判断「开着但需要修」
            print("开机自启动：已开启，但登记的是旧位置")
            print("  登记：\(registered)")
            print("  当前：\(AutoLaunch.executablePath ?? "（未知）")")
            print("  修法：WhaleWidget --autostart on")
            return 3
        }
    }
}
