import SwiftUI

/// 「开机自启动」的提示区（**不含开关**）。
///
/// 为什么与开关分开：`Toggle` 的开关自己会画出强调色像素 ——
/// 在离屏渲染里它是一个橙红色块，而且**开 / 关两种状态完全一样**
/// （实测 784 个橙色像素，四个状态里数值分毫不差、位置固定在开关那一行）。
/// 于是「统计整节的橙色像素」这条判据根本分不出「有没有画警告」：
/// 连「本来就没有警告」的状态也会数出同样的橙色，断言必然假红。
///
/// 提示区独立出来后，橙色就只是「警告确实画出来了」的干净信号，
/// 三种状态因此可以逐个做像素断言。
struct AutoLaunchNotice: View {

    /// 登记状态
    let status: AutoLaunch.Status
    /// 最近一次开关操作的错误（nil = 没有错误）
    let error: String?
    /// 可执行文件路径（用于「已登记」时显示，便于核对）
    let executable: String?
    /// 用户点击「改为当前程序」
    let onFix: () -> Void

    /// 警告色。
    ///
    /// 提示区里**只有警告**用这个颜色（其余是 `.secondary` 灰），
    /// 所以像素断言可以拿它当判据。
    private let warning = Color.orange

    var body: some View {
        if case .stale(let registered) = status {
            staleNotice(registered: registered)
        } else if let error {
            Text("⚠️ \(error)")
                .font(.system(size: 10))
                .foregroundColor(warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("autoLaunchError")
        } else if status.isOn {
            Text("已登记 · \(AutoLaunch.abbreviated(executable ?? ""))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text("关闭时挂件不随登录启动（可随时再打开）")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    /// 「已登记但指向旧位置」—— 二进制被移动 / 重新构建过时的提示。
    ///
    /// 这是最容易让人困惑的状态：开关看起来是「开」的，但开机会启动一个
    /// 不存在（或过时）的程序。所以既要警告，也要给出一键修复。
    private func staleNotice(registered: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("⚠️ 登记的是旧位置，开机可能不生效")
                .font(.system(size: 10))
                .foregroundColor(warning)
                .accessibilityIdentifier("autoLaunchStaleWarning")
            Text(AutoLaunch.abbreviated(registered))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("改为当前程序") { onFix() }
                .controlSize(.small)
                .font(.system(size: 10))
        }
    }
}

/// 菜单里的「开机自启动」一节 = 开关 + 提示区。
///
/// 特意做成**纯展示**视图（输入只有 `status` / `error` + 两个回调）：这样 `--render`
/// 能把三种状态各画一次做像素断言 —— 而不是只能在真机点开菜单肉眼看。
/// 三种状态各自要传达的信息完全不同，少写一种用户就会掉进
/// 「开了却没生效」而没有任何线索的坑里：
///
/// - `.off`   未登记：说明关闭的含义；
/// - `.on`    已登记且指向当前程序：显示登记的程序路径（可核对）；
/// - `.stale` 已登记但指向旧位置：**必须报警并给一键修法**。
struct AutoLaunchSection: View {

    let status: AutoLaunch.Status
    /// 最近一次开关操作的错误（nil = 没有错误）
    let error: String?
    /// 执行文件路径（用于 `.on` 时显示）
    let executable: String?
    /// 用户拨动开关
    let onToggle: (Bool) -> Void
    /// 「改为当前程序」按钮
    let onFix: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("开机自启动", isOn: Binding(get: { status.isRegistered },
                                            set: { onToggle($0) }))
                .help("登录后在后台启动小鲸鱼挂件（写入 ~/Library/LaunchAgents，"
                      + "可从「系统设置 → 通用 → 登录项」或本开关随时移除）")

            // 提示与开关分开，理由见 AutoLaunchNotice 的说明
            AutoLaunchNotice(status: status, error: error,
                             executable: executable, onFix: onFix)
        }
    }
}
