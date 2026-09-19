import AppKit
import SwiftUI

/// 自定义泡泡窗口：点击序列、模块化排版、逐模块样式、模块库、图片库。
struct BubbleEditorView: View {

    @ObservedObject var bubble: BubbleRuntime
    @ObservedObject var store: WhaleStore

    /// 当前编辑目标：nil = 首次点击泡，否则为队列下标
    @State private var editingQueueIndex: Int?
    @State private var selectedRow: UUID?
    @State private var selectedModule: UUID?
    @State private var message: String?

    private let accent = Color(red: 0.125, green: 0.192, blue: 0.439)

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
            editor
                .frame(minWidth: 380)
            inspector
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 320)
        }
        .frame(minWidth: 900, minHeight: 600)
        .colorScheme(.light)
        .foregroundColor(accent)
    }

    // MARK: - 左：点击序列

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("点击序列").font(.system(size: 12, weight: .semibold))
            Text("第一次点击显示「首次点击泡」，再点按队列依次出泡。")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("点按角色推进队列", isOn: Binding(
                get: { bubble.config.advanceOnTap },
                set: { value in bubble.update { $0.advanceOnTap = value } }))
                .font(.system(size: 11))
                .help("关闭时：点角色后回到「首次点击泡」")

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sequenceRow(title: "① 首次点击泡", index: nil)
                    ForEach(Array(bubble.config.queue.enumerated()), id: \.element.id) { index, page in
                        sequenceRow(title: "\(index + 2). \(page.name)", index: index)
                    }
                }
            }

            HStack {
                Button {
                    bubble.update { cfg in
                        var page = BubblePage(name: "泡泡 \(cfg.queue.count + 1)")
                        var row = BubbleRow()
                        var module = BubbleModule()
                        module.kind = .text
                        module.text = "写点什么…"
                        row.modules = [module]
                        page.variants = [BubbleVariant(weight: 1, rows: [row])]
                        cfg.queue.append(page)
                    }
                    editingQueueIndex = bubble.config.queue.count - 1
                } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)

                Button {
                    guard let index = editingQueueIndex, index < bubble.config.queue.count else { return }
                    bubble.update { $0.queue.remove(at: index) }
                    editingQueueIndex = nil
                } label: { Image(systemName: "minus") }
                .buttonStyle(.plain)
                .disabled(editingQueueIndex == nil)

                Spacer()
            }
            .font(.system(size: 11))

            Divider()

            Text("模块库").font(.system(size: 12, weight: .semibold))
            Text("\(bubble.config.library.count) 个已保存模块")
                .font(.system(size: 10)).foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(bubble.config.library) { module in
                        HStack {
                            Text(module.kind.title + "：" + displayText(module))
                                .font(.system(size: 10))
                                .lineLimit(1)
                            Spacer()
                            Button {
                                addModule(module)
                            } label: { Image(systemName: "plus.circle") }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.06))
    }

    private func sequenceRow(title: String, index: Int?) -> some View {
        let selected = editingQueueIndex == index
        return Button {
            editingQueueIndex = index
            selectedRow = nil
            selectedModule = nil
        } label: {
            HStack {
                Text(title).font(.system(size: 11)).lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(selected ? accent.opacity(0.18) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 中：排版编辑

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(editingTitle).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("预览出泡") {
                    bubble.close()
                    bubble.update { _ in }
                }
                .controlSize(.small)
            }

            if let page = currentPage, !page.variants.isEmpty {
                Text("整行可排序；每行最多 6 个模块、最多 6 行；图片模块独占一行且每个泡泡只允许一个。")
                    .font(.system(size: 10)).foregroundColor(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(page.variants[currentVariantIndex].rows.enumerated()), id: \.element.id) { rowIndex, row in
                            rowEditor(rowIndex: rowIndex, row: row)
                        }
                    }
                    .padding(.vertical, 4)
                }

                HStack {
                    Button("新增一行") { addRow() }
                        .controlSize(.small)
                        .disabled(page.variants[currentVariantIndex].rows.count >= 6)

                    Button("删除选中行") { deleteSelectedRow() }
                        .controlSize(.small)
                        .disabled(selectedRow == nil)

                    Spacer()

                    Menu("添加模块") {
                        ForEach(ModuleKind.allCases, id: \.self) { kind in
                            Button(kind.title) { addModule(BubbleModule(kind: kind)) }
                        }
                    }
                    .controlSize(.small)
                    .disabled(page.variants[currentVariantIndex].rows.count <= 1 && selectedRow == nil)

                    Button("存为模块库") { saveSelectedModule() }
                        .controlSize(.small)
                        .disabled(selectedModule == nil)
                }
            } else {
                Text("新建一个泡泡开始编辑").font(.system(size: 12)).foregroundColor(.secondary)
            }

            if let message {
                Text(message).font(.system(size: 10)).foregroundColor(.green)
            }
        }
        .padding(10)
    }

    private func rowEditor(rowIndex: Int, row: BubbleRow) -> some View {
        let isSelected = selectedRow == row.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("第 \(rowIndex + 1) 行").font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Button {
                    moveRow(rowIndex, by: -1)
                } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.plain).disabled(rowIndex == 0)

                Button {
                    moveRow(rowIndex, by: 1)
                } label: { Image(systemName: "arrow.down") }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                ForEach(row.modules) { module in
                    moduleChip(module)
                }
                Button {
                    selectedRow = row.id
                    addModuleToRow(row.id)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .disabled(row.modules.count >= 6)
                Spacer()
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? accent.opacity(0.10) : Color.gray.opacity(0.07))
            )
            .onTapGesture { selectedRow = row.id }
        }
    }

    private func moduleChip(_ module: BubbleModule) -> some View {
        let isSelected = selectedModule == module.id
        return Text(module.kind.title + "\n" + displayText(module))
            .font(.system(size: 10))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(width: 74, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? accent.opacity(0.22) : Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(isSelected ? accent : Color.gray.opacity(0.4), lineWidth: 1))
            )
            .onTapGesture {
                selectedModule = module.id
                selectedRow = rowContaining(module.id)
            }
    }

    private func displayText(_ module: BubbleModule) -> String {
        switch module.kind {
        case .text, .link: return module.text.isEmpty ? "（空）" : String(module.text.prefix(8))
        case .random: return "\(module.entries.count) 条"
        case .image: return BubbleImageLibrary.displayName(for: module.asset)
        case .randomImage: return "\(module.entries.count) 张"
        case .balance, .today, .peak, .model: return module.prefix + "…"
        }
    }

    // MARK: - 右：模块样式

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("模块设置").font(.system(size: 12, weight: .semibold))
            if let module = selectedModuleValue {
                contentEditor(module)
            } else {
                Text("选择一个模块后可编辑内容与样式")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.gray.opacity(0.06))
    }

    @ViewBuilder
    private func contentEditor(_ module: BubbleModule) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(module.kind.title).font(.system(size: 11, weight: .semibold))

                switch module.kind {
                case .text:
                    TextField("文本", text: binding(for: \.text, default: ""))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))

                case .link:
                    TextField("显示文字", text: binding(for: \.text, default: ""))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    TextField("https://…", text: binding(for: \.url, default: ""))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))

                case .random:
                    randomListEditor(module)

                case .image:
                    imagePicker(module, random: false)

                case .randomImage:
                    randomImageEditor(module)

                case .balance, .today, .peak, .model:
                    TextField("前缀", text: binding(for: \.prefix, default: ""))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    TextField("后缀", text: binding(for: \.suffix, default: ""))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    if module.kind == .model {
                        Text("金额用 {cost} 引用（例如「本轮消耗 ¥ {cost}」）")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }

                Divider()
                styleEditor(module)

                Divider()
                HStack {
                    Button("存为模块库") { saveSelectedModule() }
                        .controlSize(.small)
                    Button("删除模块") { deleteSelectedModule() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func randomListEditor(_ module: BubbleModule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("随机语句（带权重，每次抽 1 条且不连续重复）")
                .font(.system(size: 10)).foregroundColor(.secondary)
            ForEach(Array(module.entries.enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 4) {
                    TextField("语句", text: entryBinding(module, index: index, \.value))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    TextField("权重", value: entryBinding(module, index: index, \.weight), format: .number)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 44)
                    Button {
                        removeEntry(module, index: index)
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                }
            }
            Button("添加一条") { addEntry(module) }.controlSize(.small)
        }
    }

    private func randomImageEditor(_ module: BubbleModule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("随机图片（带权重，抽 1 张且不连续重复，独占一行）")
                .font(.system(size: 10)).foregroundColor(.secondary)
            ForEach(Array(module.entries.enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 4) {
                    Picker("", selection: entryBinding(module, index: index, \.value)) {
                        ForEach(BubbleImageLibrary.builtins, id: \.self) { name in
                            Text(name).tag(name)
                        }
                        ForEach(BubbleImageLibrary.customImages(), id: \.path) { url in
                            Text(url.lastPathComponent).tag(url.path)
                        }
                    }
                    .labelsHidden().font(.system(size: 10))
                    TextField("权重", value: entryBinding(module, index: index, \.weight), format: .number)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 44)
                    Button { removeEntry(module, index: index) } label: {
                        Image(systemName: "minus.circle")
                    }.buttonStyle(.plain)
                }
            }
            Button("添加一张") { addEntry(module) }.controlSize(.small)
        }
    }

    private func imagePicker(_ module: BubbleModule, random: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("图片", selection: binding(for: \.asset, default: "")) {
                Text("（未选择）").tag("")
                Section("内置") {
                    ForEach(BubbleImageLibrary.builtins, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Section("自定义") {
                    ForEach(BubbleImageLibrary.customImages(), id: \.path) { url in
                        Text(url.lastPathComponent).tag(url.path)
                    }
                }
            }
            .font(.system(size: 11))

            Button("导入图片…") { importImage(module) }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func styleEditor(_ module: BubbleModule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("样式").font(.system(size: 11, weight: .semibold))

            HStack {
                Text("字号").font(.system(size: 10))
                Slider(value: Binding(
                    get: { Double(module.style.size) },
                    set: { value in updateModule(module) { $0.style.size = Int(value) } }
                ), in: 1...50)
                Text("\(module.style.size)").font(.system(size: 10, design: .monospaced)).frame(width: 22)
            }

            HStack(spacing: 6) {
                Toggle("粗", isOn: flagBinding(module, \.bold)).font(.system(size: 10))
                Toggle("斜", isOn: flagBinding(module, \.italic)).font(.system(size: 10))
                Toggle("下划线", isOn: flagBinding(module, \.underline)).font(.system(size: 10))
            }
            .toggleStyle(.checkbox)

            HStack {
                Text("文字色").font(.system(size: 10))
                ColorPicker("", selection: colorBinding(module, \.color, fallback: "#203170"))
                    .labelsHidden()
                TextField("#203170", text: binding(for: \.style.color, default: "#203170"))
                    .textFieldStyle(.roundedBorder).font(.system(size: 10, design: .monospaced))
            }

            HStack {
                Text("渐变").font(.system(size: 10))
                ColorPicker("", selection: colorBinding(module, \.gradientFrom, fallback: "#8f9bd0"))
                    .labelsHidden()
                ColorPicker("", selection: colorBinding(module, \.gradientTo, fallback: "#203170"))
                    .labelsHidden()
                Button("清除") {
                    updateModule(module) { $0.style.gradientFrom = ""; $0.style.gradientTo = "" }
                }.controlSize(.small).font(.system(size: 10))
            }

            HStack {
                Text("底色").font(.system(size: 10))
                ColorPicker("", selection: colorBinding(module, \.background, fallback: "#ffffff"))
                    .labelsHidden()
                Button("清除") {
                    updateModule(module) { $0.style.background = "" }
                }.controlSize(.small).font(.system(size: 10))
            }

            Text("渐变色非空时按跑马灯渐变渲染，优先于文字色。")
                .font(.system(size: 9)).foregroundColor(.secondary)
        }
    }

    // MARK: - 数据操作

    private var currentPage: BubblePage? {
        if let index = editingQueueIndex {
            guard index < bubble.config.queue.count else { return bubble.config.first }
            return bubble.config.queue[index]
        }
        return bubble.config.first
    }

    private var currentVariantIndex: Int { 0 }

    private var editingTitle: String {
        if let index = editingQueueIndex, index < bubble.config.queue.count {
            return "编辑：\(bubble.config.queue[index].name)"
        }
        return "编辑：首次点击泡"
    }

    private func mutatePage(_ body: (inout BubblePage) -> Void) {
        bubble.update { cfg in
            if let index = editingQueueIndex, index < cfg.queue.count {
                body(&cfg.queue[index])
            } else {
                body(&cfg.first)
            }
        }
    }

    private func addRow() {
        mutatePage { page in
            var variant = page.variants.first ?? BubbleVariant()
            var row = BubbleRow()
            var module = BubbleModule()
            module.kind = .text
            module.text = "新文本"
            row.modules = [module]
            variant.rows.append(row)
            page.variants = [variant]
        }
    }

    private func deleteSelectedRow() {
        guard let selectedRow else { return }
        mutatePage { page in
            var variant = page.variants.first ?? BubbleVariant()
            variant.rows.removeAll { $0.id == selectedRow }
            page.variants = [variant]
        }
        self.selectedRow = nil
        selectedModule = nil
    }

    private func moveRow(_ index: Int, by delta: Int) {
        let target = index + delta
        mutatePage { page in
            var variant = page.variants.first ?? BubbleVariant()
            guard variant.rows.indices.contains(index), variant.rows.indices.contains(target) else { return }
            variant.rows.swapAt(index, target)
            page.variants = [variant]
        }
    }

    private func addModule(_ module: BubbleModule) {
        var target = selectedRow
        if target == nil {
            target = currentPage?.variants.first?.rows.last?.id
        }
        guard let rowId = target else {
            addRow()
            return
        }
        insert(module, into: rowId)
    }

    private func addModuleToRow(_ rowId: UUID) {
        var module = BubbleModule()
        module.kind = .text
        module.text = "新文本"
        insert(module, into: rowId)
    }

    /// 图片模块独占一行；已有图片模块时拒绝再加。
    private func insert(_ module: BubbleModule, into rowId: UUID) {
        let page = currentPage
        if module.kind.isImage {
            let hasImage = page?.variants.first?.rows
                .flatMap { $0.modules }
                .contains { $0.kind.isImage } ?? false
            if hasImage {
                message = "图片类模块独占一行，且每个泡泡只允许一个"
                return
            }
        }
        mutatePage { page in
            var variant = page.variants.first ?? BubbleVariant()
            guard let index = variant.rows.firstIndex(where: { $0.id == rowId }) else { return }
            if module.kind.isImage {
                // 图片：独占新行
                var row = BubbleRow()
                row.modules = [module]
                variant.rows.insert(row, at: index + 1)
            } else if variant.rows[index].modules.count < 6 {
                variant.rows[index].modules.append(module)
            } else {
                var row = BubbleRow()
                row.modules = [module]
                variant.rows.insert(row, at: index + 1)
            }
            page.variants = [variant]
        }
        selectedModule = module.id
        message = "已添加"
    }

    private func saveSelectedModule() {
        guard let module = selectedModuleValue else { return }
        bubble.saveToLibrary(module)
        message = "已存入模块库"
    }

    private func deleteSelectedModule() {
        guard let id = selectedModule else { return }
        mutatePage { page in
            var variant = page.variants.first ?? BubbleVariant()
            for i in variant.rows.indices {
                variant.rows[i].modules.removeAll { $0.id == id }
            }
            variant.rows.removeAll { $0.modules.isEmpty }
            page.variants = [variant]
        }
        selectedModule = nil
    }

    private func addEntry(_ module: BubbleModule) {
        updateModule(module) { $0.entries.append(RandomEntry(value: $0.kind == .randomImage
                                                            ? (BubbleImageLibrary.builtins.first ?? "")
                                                            : "新语句", weight: 1)) }
    }

    private func removeEntry(_ module: BubbleModule, index: Int) {
        updateModule(module) { if $0.entries.indices.contains(index) { $0.entries.remove(at: index) } }
    }

    // MARK: - 绑定工具

    private var selectedModuleValue: BubbleModule? {
        guard let id = selectedModule else { return nil }
        let rows = currentPage?.variants.first?.rows ?? []
        return rows.flatMap { $0.modules }.first { $0.id == id }
    }

    private func rowContaining(_ moduleId: UUID) -> UUID? {
        currentPage?.variants.first?.rows
            .first { $0.modules.contains { $0.id == moduleId } }?.id
    }

    private func updateModule(_ module: BubbleModule, _ body: (inout BubbleModule) -> Void) {
        mutatePage { page in
            var variant = page.variants.first ?? BubbleVariant()
            for i in variant.rows.indices {
                if let j = variant.rows[i].modules.firstIndex(where: { $0.id == module.id }) {
                    body(&variant.rows[i].modules[j])
                }
            }
            page.variants = [variant]
        }
    }

    private func binding<T>(for keyPath: KeyPath<BubbleModule, T>, default def: T) -> Binding<T> {
        Binding(
            get: { selectedModuleValue.map { $0[keyPath: keyPath] } ?? def },
            set: { newValue in
                guard let module = selectedModuleValue else { return }
                updateModule(module) { module in
                    switch keyPath {
                    case \BubbleModule.text: module.text = newValue as? String ?? ""
                    case \BubbleModule.url: module.url = newValue as? String ?? ""
                    case \BubbleModule.prefix: module.prefix = newValue as? String ?? ""
                    case \BubbleModule.suffix: module.suffix = newValue as? String ?? ""
                    case \BubbleModule.asset: module.asset = newValue as? String ?? ""
                    case \BubbleModule.style.color: module.style.color = newValue as? String ?? ""
                    default: break
                    }
                }
            }
        )
    }

    private func entryBinding(_ module: BubbleModule, index: Int,
                              _ keyPath: WritableKeyPath<RandomEntry, String>) -> Binding<String> {
        Binding(
            get: { module.entries.indices.contains(index) ? module.entries[index][keyPath: keyPath] : "" },
            set: { value in
                updateModule(module) {
                    if $0.entries.indices.contains(index) { $0.entries[index][keyPath: keyPath] = value }
                }
            }
        )
    }

    private func entryBinding(_ module: BubbleModule, index: Int,
                              _ keyPath: WritableKeyPath<RandomEntry, Double>) -> Binding<Double> {
        Binding(
            get: { module.entries.indices.contains(index) ? module.entries[index][keyPath: keyPath] : 1 },
            set: { value in
                updateModule(module) {
                    if $0.entries.indices.contains(index) { $0.entries[index][keyPath: keyPath] = value }
                }
            }
        )
    }

    private func flagBinding(_ module: BubbleModule,
                             _ keyPath: WritableKeyPath<ModuleStyle, Bool>) -> Binding<Bool> {
        Binding(
            get: { selectedModuleValue?.style[keyPath: keyPath] ?? false },
            set: { value in updateModule(module) { $0.style[keyPath: keyPath] = value } }
        )
    }

    private func colorBinding(_ module: BubbleModule,
                              _ keyPath: WritableKeyPath<ModuleStyle, String>,
                              fallback: String) -> Binding<Color> {
        Binding(
            get: { Color(hex: selectedModuleValue?.style[keyPath: keyPath] ?? "") ?? Color(hex: fallback)! },
            set: { newColor in
                let hex = newColor.hexString
                updateModule(module) { $0.style[keyPath: keyPath] = hex }
            }
        )
    }

    private func importImage(_ module: BubbleModule) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic, .image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dest = BubbleImageLibrary.directory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.createDirectory(at: BubbleImageLibrary.directory,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        updateModule(module) { $0.asset = dest.path }
    }
}

extension Color {
    /// 转回 `#RRGGBB`（用于写回配置）。
    var hexString: String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(round(rgb.redComponent * 255)),
                      Int(round(rgb.greenComponent * 255)),
                      Int(round(rgb.blueComponent * 255)))
    }
}
