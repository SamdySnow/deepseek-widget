import AppKit
import Foundation
import SwiftUI

/// 泡泡运行期：点击序列推进、并列加权抽取、随机不连续重复、图片缓存。
@MainActor
final class BubbleRuntime: ObservableObject {

    @Published private(set) var config: BubbleConfig
    @Published private(set) var isOpen: Bool = false
    /// 鼠标是否悬停在挂件上（用于菜单按钮显隐）
    @Published var isHovering: Bool = false
    /// 每轮消耗泡泡的金额文本（`{cost}` 占位符）
    @Published var costText: String = "0.00"

    /// 当前出泡页在队列中的位置：0 = 首次点击泡
    ///
    /// **必须是 `@Published`**：视图只观察这个对象，而 `currentPage` 由它推导。
    /// 之前它只是普通属性，于是第 2 次点击时 `isOpen` 已经是 true、值没变，
    /// SwiftUI 收不到任何变更通知 → 界面停留在「首次点击泡」，
    /// 看起来就是「第 2 次点击没反应，第 3 次直接收起」。
    @Published private var queueIndex: Int = 0

    /// 仅供自检读取当前队列位置。
    var queueIndexForTesting: Int { queueIndex }
    /// 每个随机模块上一次抽到的下标（不连续重复）
    private var lastPick: [UUID: Int] = [:]
    private var imageCache: [String: NSImage] = [:]
    /// 提醒类临时泡泡（余额预警 / 预算 / 每轮消耗）
    @Published private(set) var transient: TransientBubble?

    struct TransientBubble: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var amount: String
        var kind: Kind
        enum Kind { case turnCost, balanceAlert, budget }
    }

    private var autoCloseTask: Task<Void, Never>?

    init() {
        config = BubbleStore.load()
    }

    // MARK: - 当前页

    /// 当前应当显示的页面。开启「点按角色推进队列」时按队列前进。
    var currentPage: BubblePage? {
        if let transient {
            return transientPage(for: transient)
        }
        guard config.advanceOnTap else { return config.first }
        if queueIndex == 0 { return config.first }
        let idx = queueIndex - 1
        guard idx < config.queue.count else { return config.first }
        return config.queue[idx]
    }

    /// 点击角色。
    ///
    /// 序列语义（与参考实现一致）：
    /// - 第一次点击 → 显示「首次点击泡」
    /// - 再点 → 依次出队列第 1、2、3… 项
    /// - 走到最后一项再点 → 收起，下次从「首次点击泡」重新开始
    func handleTap(menuHidden: Bool) {
        if transient != nil { dismissTransient(); return }

        guard config.advanceOnTap else {
            isOpen.toggle()
            if !isOpen { queueIndex = 0 }
            return
        }

        // 第一次点击：显示「首次点击泡」（不能直接跳到队列项）
        guard isOpen else {
            queueIndex = 0
            isOpen = true
            return
        }

        // 已展开且停在最后一项：再点收起
        guard queueIndex < config.queue.count else {
            close()
            return
        }

        queueIndex += 1
    }

    func close() {
        isOpen = false
        queueIndex = 0
    }

    // MARK: - 提醒泡泡

    func showTurnCost(_ amount: Double, closeAfter: Int, text: String?) {
        costText = String(format: "%.4f", amount)
        let template = text ?? "本轮消耗 ¥ {cost}"
        transient = TransientBubble(title: template.replacingOccurrences(
            of: "{cost}", with: costText), amount: costText, kind: .turnCost)
        scheduleAutoClose(seconds: closeAfter)
    }

    func showAlert(_ message: String, seconds: Int) {
        transient = TransientBubble(title: message, amount: "", kind: .balanceAlert)
        scheduleAutoClose(seconds: seconds)
    }

    func dismissTransient() {
        autoCloseTask?.cancel()
        autoCloseTask = nil
        transient = nil
    }

    private func scheduleAutoClose(seconds: Int) {
        autoCloseTask?.cancel()
        guard seconds > 0 else { return }
        autoCloseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.dismissTransient() }
        }
    }

    private func transientPage(for bubble: TransientBubble) -> BubblePage {
        var row = BubbleRow()
        var module = BubbleModule()
        module.kind = .text
        module.text = bubble.title
        module.style.size = 24
        module.style.bold = true
        row.modules = [module]

        var page = BubblePage(name: "提醒")
        page.variants = [BubbleVariant(weight: 1, rows: [row])]
        return page
    }

    // MARK: - 行解析（随机模块在每次出泡时抽一次）

    /// 出泡时解析出的随机文本，缓存于一次展开期间，避免每帧重抽。
    /// key 用模块 UUID，但**顺序**始终以 `page.rows` 为准 ——
    /// 绝不能按字典键排序（UUID 是随机的，会把排版顺序打乱）。
    private var resolvedCache: [UUID: String] = [:]

    /// 按页面配置的行顺序返回待渲染的行（随机模块填入本轮抽中的文本）。
    func resolvedRows(for page: BubblePage) -> [BubbleRow] {
        page.rows.map { row in
            var copy = row
            copy.modules = row.modules.map { module in
                guard module.kind == .random, !module.entries.isEmpty else { return module }
                var m = module
                m.text = randomText(for: module)
                return m
            }
            return copy
        }
    }

    /// 预生成解析结果：每次出泡 / 切换页面时调用，固定本轮的随机内容。
    func refreshResolved(page: BubblePage?) {
        resolvedCache.removeAll()
        guard let page else { return }
        for row in page.rows {
            for module in row.modules where module.kind == .random && !module.entries.isEmpty {
                guard !resolvedCache.keys.contains(module.id) else { continue }
                resolvedCache[module.id] = module.entries[pick(entries: module.entries,
                                                                key: module.id)].value
            }
        }
    }

    /// 随机语句：本轮已抽过就复用，否则按权重抽 1 条（不连续重复）。
    func randomText(for module: BubbleModule) -> String {
        if let cached = resolvedCache[module.id], !cached.isEmpty { return cached }
        guard !module.entries.isEmpty else { return module.text }
        let value = module.entries[pick(entries: module.entries, key: module.id)].value
        resolvedCache[module.id] = value
        return value
    }

    // MARK: - 随机与图片

    /// 加权抽取且避免连续重复。
    private func pick(entries: [RandomEntry], key: UUID) -> Int {
        guard entries.count > 1 else { return 0 }
        let last = lastPick[key]
        var candidates = Array(entries.indices)
        if let last, candidates.count > 1 { candidates.removeAll { $0 == last } }
        let total = candidates.reduce(0.0) { $0 + max(0.0001, entries[$1].weight) }
        var roll = Double.random(in: 0..<total)
        for index in candidates {
            roll -= max(0.0001, entries[index].weight)
            if roll <= 0 {
                lastPick[key] = index
                return index
            }
        }
        let fallback = candidates.last ?? 0
        lastPick[key] = fallback
        return fallback
    }

    /// 解析模块对应的图片（内置资源或自定义路径）。
    func resolvedImage(for module: BubbleModule) -> NSImage? {
        let candidates = module.imageCandidates.filter { !$0.value.isEmpty }
        guard !candidates.isEmpty else { return nil }
        let chosen: String
        if candidates.count == 1 {
            chosen = candidates[0].value
        } else {
            chosen = candidates[pick(entries: candidates, key: module.id)].value
        }
        if let cached = imageCache[chosen] { return cached }
        guard let image = Self.loadImage(chosen) else { return nil }
        imageCache[chosen] = image
        return image
    }

    static func loadImage(_ value: String) -> NSImage? {
        if value.contains("/") {
            return NSImage(contentsOfFile: value)
        }
        return Assets.image(value)
    }

    // MARK: - 配置更新

    func update(_ mutate: (inout BubbleConfig) -> Void) {
        var cfg = config
        mutate(&cfg)
        config = cfg
        BubbleStore.save(cfg)
    }

    /// 把模块存进模块库。
    func saveToLibrary(_ module: BubbleModule) {
        update { $0.library.append(module) }
    }
}
