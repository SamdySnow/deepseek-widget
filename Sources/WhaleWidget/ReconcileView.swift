import SwiftUI

/// 余额校正：按实际累计到账金额与非调用扣减校正「已观测消费」。
struct ReconcileView: View {

    @ObservedObject var store: WhaleStore

    @State private var credits: String = "0"
    @State private var otherDebits: String = "0"
    @State private var confirmed = false
    @State private var message: String?
    @State private var isError = false

    private let accent = Color(red: 0.125, green: 0.192, blue: 0.439)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("余额校正").font(.system(size: 15, weight: .semibold))

            Text("余额接口只返回余额快照、不提供充值流水。若本统计区间内有过充值或其它余额调整，请按实际金额填写，好让「已观测消费」与 DeepSeek 账户口径一致。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            info

            Divider()

            HStack {
                Text("累计到账金额").font(.system(size: 12)).frame(width: 96, alignment: .leading)
                TextField("0", text: $credits).textFieldStyle(.roundedBorder).frame(width: 100)
                Text("元").font(.system(size: 11)).foregroundColor(.secondary)
            }
            HStack {
                Text("其它非调用扣减").font(.system(size: 12)).frame(width: 96, alignment: .leading)
                TextField("0", text: $otherDebits).textFieldStyle(.roundedBorder).frame(width: 100)
                Text("元（可选）").font(.system(size: 11)).foregroundColor(.secondary)
            }

            Toggle("已核对本统计区间的全部余额调整", isOn: $confirmed)
                .font(.system(size: 11))

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(isError ? .red : .green)
            }

            Spacer()

            HStack {
                Button("重置校正") {
                    do {
                        try store.reconcileToday(credits: nil, otherDebits: nil)
                        report("已重置为纯观测口径", error: false)
                    } catch {
                        report(error.localizedDescription, error: true)
                    }
                }
                Spacer()
                Button("取消") { NSApp.keyWindow?.close() }
                Button("保存校正") {
                    let c = Double(credits) ?? 0
                    let d = Double(otherDebits) ?? 0
                    do {
                        try store.reconcileToday(credits: c, otherDebits: d)
                        report("校正已保存", error: false)
                    } catch {
                        report(error.localizedDescription, error: true)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(minWidth: 400, minHeight: 300, alignment: .topLeading)
    }

    private var info: some View {
        let day = Pricing.beijingDay()
        return VStack(alignment: .leading, spacing: 3) {
            row("统计日期", day)
            row("当前已观测消费", "¥" + String(format: "%.4f", store.todayUsage))
            row("统计口径", store.usageLabel)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, design: .monospaced))
        }
    }

    private func report(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}
