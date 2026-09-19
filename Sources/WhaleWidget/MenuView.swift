import SwiftUI

/// 主菜单面板。
struct MenuView: View {

    @ObservedObject var store: WhaleStore
    @ObservedObject var bubble: BubbleRuntime
    @ObservedObject var soundPlayer: SoundPlayer
    var onScaleChange: () -> Void
    var onOpenUsage: () -> Void
    var onOpenBubbleEditor: () -> Void
    var onReconcile: () -> Void
    var onClose: () -> Void

    @State private var apiKeyInput: String = ""
    @State private var showKeyField = false

    private let accent = Color(red: 0.125, green: 0.192, blue: 0.439)   // #203170

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header

            Divider()

            // 大小
            row("大小") {
                Slider(value: Binding(
                    get: { store.config.scale },
                    set: { value in
                        store.update { $0.scale = value }
                        onScaleChange()
                    }), in: 0.6...3.0)
                Text(String(format: "%.1f×", store.config.scale))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 38, alignment: .trailing)
            }

            // 音效
            row("音效") {
                Toggle("", isOn: Binding(
                    get: { store.config.soundOn },
                    set: { value in
                        store.update { $0.soundOn = value }
                        soundPlayer.enabled = value
                    })).labelsHidden()
                Picker("", selection: Binding(
                    get: { SoundPlayer.Preset(rawValue: store.config.soundSet) ?? .duck },
                    set: { value in
                        store.update { $0.soundSet = value.rawValue }
                        soundPlayer.enabled = store.config.soundOn
                        soundPlayer.playPress(preset: value)
                    })) {
                    ForEach(SoundPlayer.Preset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(preset)
                    }
                }.labelsHidden().frame(width: 96)
            }

            row("音量") {
                Slider(value: Binding(
                    get: { store.config.volume },
                    set: { value in
                        store.update { $0.volume = value }
                        soundPlayer.volume = value
                    }), in: 0...1)
                Text("\(Int(store.config.volume * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 38, alignment: .trailing)
            }

            // 峰值文案
            row("峰值文案") {
                Picker("", selection: Binding(
                    get: { store.config.peakStyle },
                    set: { value in store.update { $0.peakStyle = value } })) {
                    Text("梁文峰谷").tag("default")
                    Text("简洁").tag("minimal")
                    Text("关闭").tag("off")
                }.labelsHidden()
            }

            Divider()

            Toggle("点击显示泡泡", isOn: Binding(
                get: { store.config.bubbleOn },
                set: { value in store.update { $0.bubbleOn = value } }))

            Toggle("每轮对话后显示消耗", isOn: Binding(
                get: { store.config.turnCostOn },
                set: { value in store.update { $0.turnCostOn = value } }))
                .help("需要本地会话记录支持；DSH 端由插件结算，本机版本读取不到会话时不会弹泡")

            row("自动关闭") {
                TextField("秒", value: Binding(
                    get: { store.config.turnCostCloseMs / 1000 },
                    set: { value in store.update { $0.turnCostCloseMs = max(0, value) * 1000 } }),
                          format: .number)
                    .frame(width: 52)
                Text("秒（0 = 不自动关闭）").font(.system(size: 11)).foregroundColor(.secondary)
            }

            Divider()

            // 提醒
            row("余额预警") {
                TextField("金额", value: Binding(
                    get: { store.config.balanceAlert ?? 0 },
                    set: { value in store.update { $0.balanceAlert = value > 0 ? value : nil } }),
                          format: .number)
                    .frame(width: 70)
                Text("元（0 = 关闭）").font(.system(size: 11)).foregroundColor(.secondary)
            }

            row("今日预算") {
                TextField("金额", value: Binding(
                    get: { store.config.todayBudget ?? 0 },
                    set: { value in store.update { $0.todayBudget = value > 0 ? value : nil } }),
                          format: .number)
                    .frame(width: 70)
                Text("元（0 = 关闭）").font(.system(size: 11)).foregroundColor(.secondary)
            }

            Divider()

            Toggle("拖拽吸附屏幕边缘", isOn: Binding(
                get: { store.config.snapEnabled },
                set: { value in store.update { $0.snapEnabled = value } }))

            Toggle("贴左镜像翻转", isOn: Binding(
                get: { store.config.mirrorOnLeftSnap },
                set: { value in store.update { $0.mirrorOnLeftSnap = value } }))

            Toggle("隐藏菜单按钮", isOn: Binding(
                get: { store.config.menuButtonHidden },
                set: { value in store.update { $0.menuButtonHidden = value } }))
                .help("隐藏后：右键小鲸鱼唤出菜单")

            Divider()

            HStack {
                Button("用量记录") { onOpenUsage() }
                Button("自定义泡泡") { onOpenBubbleEditor() }
                Button("余额校正") { onReconcile() }
            }
            .controlSize(.small)

            Divider()

            keySection

            Divider()

            HStack {
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(accent.opacity(0.35), lineWidth: 1))
        )
        .colorScheme(.light)
        .foregroundColor(accent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("🐋").font(.system(size: 15))
                Text("小鲸鱼记账").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                Button { onClose() } label: {
                    Image(systemName: "xmark").font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 4) {
                Text("余额 ¥" + String(format: "%.2f", store.balance))
                    .font(.system(size: 12, weight: .bold))
                Text("· 今日 ¥\(String(format: "%.2f", store.todayUsage))")
                    .font(.system(size: 12))
                if store.isPeak {
                    Text("· ⚡高峰").font(.system(size: 11)).foregroundColor(.orange)
                }
            }
            if !store.peakCountdown.isEmpty {
                Text(store.peakCountdown)
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("API 密钥").font(.system(size: 11))
                Spacer()
                Text(store.maskedKeyHint())
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            if showKeyField {
                HStack {
                    SecureField("sk-...", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Button("保存") {
                        store.updateKey(apiKeyInput)
                        apiKeyInput = ""
                        showKeyField = false
                    }
                    .controlSize(.small)
                }
            } else {
                Button("修改密钥") { showKeyField = true }
                    .controlSize(.small)
                    .font(.system(size: 11))
            }
        }
    }

    private var statusText: String {
        if let error = store.lastError { return "⚠️ \(error)" }
        if let stale = store.staleNotice { return stale }
        if let updated = store.lastUpdated {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return "\(store.usageLabel) · 更新于 \(f.string(from: updated))"
        }
        return "正在获取余额…"
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 62, alignment: .leading)
            content()
        }
    }
}
