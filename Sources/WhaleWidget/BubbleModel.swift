import Foundation
import SwiftUI

/// 泡泡内容模型：一个页面 = 若干行，一行 = 若干模块。
/// 行内最多 6 个模块、最多 6 行；图片类模块独占一行且每页只允许一个。
struct BubblePage: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = "新泡泡"
    /// 并列加权：同一页可由多个「候选页」按权重抽一个（A/B 加权出泡）
    var variants: [BubbleVariant] = []
    /// 是否使用并列加权（false 时直接用 variants[0] 的内容）
    var weighted: Bool = false

    var rows: [BubbleRow] { variants.first?.rows ?? [] }

    static func == (l: BubblePage, r: BubblePage) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct BubbleVariant: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var weight: Double = 1
    var rows: [BubbleRow] = []
}

struct BubbleRow: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var modules: [BubbleModule] = []
}

/// 模块类型。
enum ModuleKind: String, Codable, CaseIterable {
    case text          // 纯文本
    case link          // 超链接
    case random        // 随机语句（带权重，不连续重复）
    case image         // 图片 / 动图（独占一行）
    case randomImage   // 随机图片（独占一行）
    case balance       // 余额数值
    case today         // 今日已用
    case peak          // 峰谷时段
    case model         // 每轮消耗金额（`{cost}`）

    var title: String {
        switch self {
        case .text: return "文本"
        case .link: return "超链接"
        case .random: return "随机语句"
        case .image: return "图片/动图"
        case .randomImage: return "随机图片"
        case .balance: return "余额数值"
        case .today: return "今日已用"
        case .peak: return "峰谷时段"
        case .model: return "消耗金额"
        }
    }

    /// 图片类模块独占一行。
    var isImage: Bool { self == .image || self == .randomImage }

    var isBuiltinValue: Bool {
        switch self {
        case .balance, .today, .peak, .model: return true
        default: return false
        }
    }
}

/// 随机条目（语句或图片），带权重。
struct RandomEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var value: String = ""      // 语句文本，或图片资源名
    var weight: Double = 1
}

/// 逐模块样式。
struct ModuleStyle: Codable, Hashable {
    /// 字号档位 1..50
    var size: Int = 20
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    /// 纯色（#RRGGBB）或空
    var color: String = "#203170"
    /// 跑马灯渐变（起止色），非空时优先于 color
    var gradientFrom: String = ""
    var gradientTo: String = ""
    /// 底色
    var background: String = ""

    static let plain = ModuleStyle()

    /// 字号档位 1..50，线性映射到 40u … 240u（u = 泡泡基准单位 = 面板宽 / 1026）。
    /// 参考实现里：行标签约 66u、主数值约 128u、提示行约 56u。
    /// 例：面板 450px 时 u≈0.44px，128u ≈ 56px。
    var unitMultiplier: CGFloat {
        let level = max(1, min(50, size))
        let low: CGFloat = 40, high: CGFloat = 240
        return low + (CGFloat(level - 1) / 49) * (high - low)
    }

    /// 把「想要的 u 倍数」换算成档位（写默认值时用，便于对照参考实现）。
    static func level(forUnits units: CGFloat) -> Int {
        let clamped = max(40, min(240, units))
        return Int(((clamped - 40) / 200 * 49).rounded()) + 1
    }
}

struct BubbleModule: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: ModuleKind = .text
    var text: String = ""
    var url: String = ""
    /// 随机语句 / 随机图片的候选（带权重）
    var entries: [RandomEntry] = []
    /// 图片模块：资源名（内置 assets 文件名）或自定义图片绝对路径
    var asset: String = ""
    /// 内置数值模块的占位符前后缀
    var prefix: String = ""
    var suffix: String = ""
    var style: ModuleStyle = .plain

    static let `default` = BubbleModule()

    /// 图片类模块来源列表。
    var imageCandidates: [RandomEntry] {
        kind == .image ? [RandomEntry(value: asset, weight: 1)] : entries
    }
}

/// 用户可管理的图片库。
enum BubbleImageLibrary {
    /// 内置图片（随包分发）
    static let builtins: [String] = ["bubble-petpet.gif", "bubble-money1.gif", "rua.gif"]

    static var directory: URL = AppConfig.directory.appendingPathComponent("images", isDirectory: true)

    static func customImages() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil))?
            .filter { ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    static func displayName(for value: String) -> String {
        if value.isEmpty { return "（未选择）" }
        if value.contains("/") { return URL(fileURLWithPath: value).lastPathComponent }
        return value
    }
}

/// 点击序列 + 模块库（持久化到 config 同目录的 bubbles.json）。
struct BubbleConfig: Codable {
    /// 首次点击显示的泡泡
    var first: BubblePage = BubblePage(name: "首次点击泡")
    /// 再次点击依次出泡的队列
    var queue: [BubblePage] = []
    /// 点按角色推进队列（false = 点角色回到首次点击泡）
    var advanceOnTap: Bool = true
    /// 模块库
    var library: [BubbleModule] = []
    /// 随机模块的「不连续重复」记忆（运行期状态，不落盘）
    var lastRandomIndex: [String: Int] = [:]

    enum CodingKeys: String, CodingKey {
        case first, queue, advanceOnTap, library
    }
}

enum BubbleStore {
    static var url: URL { AppConfig.directory.appendingPathComponent("bubbles.json") }

    static func load() -> BubbleConfig {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(BubbleConfig.self, from: data) else {
            return defaults()
        }
        return cfg
    }

    static func save(_ cfg: BubbleConfig) {
        try? FileManager.default.createDirectory(at: AppConfig.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cfg) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 开箱默认：首次点击泡展示余额 / 今日已用，峰谷时段放在最后一行。
    /// 字号按参考实现的比例换算成档位（标签 66u、主数值 128u、次行 56u），
    /// 面板 450px 时对应约 29px / 56px / 25px，能完整落在泡泡内部。
    static func defaults() -> BubbleConfig {
        var cfg = BubbleConfig()

        // 第 1 行：标题
        var label = BubbleModule()
        label.kind = .text
        label.text = "余 额"
        label.style.size = ModuleStyle.level(forUnits: 66)
        label.style.bold = true

        // 第 2 行：主数值（余额字号略大，提升可读性）
        var amount = BubbleModule()
        amount.kind = .balance
        amount.prefix = "¥ "
        amount.style.size = ModuleStyle.level(forUnits: 152)
        amount.style.bold = true

        // 第 3 行：今日已用
        var today = BubbleModule()
        today.kind = .today
        today.prefix = "今日已用 "
        today.suffix = " 元"
        today.style.size = ModuleStyle.level(forUnits: 56)

        // 第 4 行：峰谷时段（按要求放最后）
        var peak = BubbleModule()
        peak.kind = .peak
        peak.prefix = ""
        peak.style.size = ModuleStyle.level(forUnits: 56)

        cfg.first.name = "首次点击泡"
        cfg.first.variants = [BubbleVariant(weight: 1, rows: [
            BubbleRow(modules: [label]),
            BubbleRow(modules: [amount]),
            BubbleRow(modules: [today]),
            BubbleRow(modules: [peak]),
        ])]

        // 再次点击队列示例：撒娇动图 + 随机台词
        var ruaImg = BubbleModule()
        ruaImg.kind = .image
        ruaImg.asset = "rua.gif"

        var phrase = BubbleModule()
        phrase.kind = .random
        phrase.style.size = ModuleStyle.level(forUnits: 72)
        phrase.entries = [
            RandomEntry(value: "记得看看余额哦~", weight: 1),
            RandomEntry(value: "别烧太多 token 呀", weight: 1),
            RandomEntry(value: "累了就休息一下", weight: 1),
        ]

        var ruaPage = BubblePage(name: "撒娇")
        ruaPage.variants = [BubbleVariant(weight: 1, rows: [
            BubbleRow(modules: [ruaImg]),
            BubbleRow(modules: [phrase]),
        ])]
        cfg.queue = [ruaPage]

        return cfg
    }
}

extension Color {
    /// 解析 `#RRGGBB` / `#AARRGGBB`。
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: "#", with: "")
        guard !s.isEmpty, let value = UInt64(s, radix: 16) else { return nil }
        switch s.count {
        case 6:
            self.init(red: Double((value >> 16) & 0xff) / 255,
                      green: Double((value >> 8) & 0xff) / 255,
                      blue: Double(value & 0xff) / 255)
        case 8:
            self.init(red: Double((value >> 16) & 0xff) / 255,
                      green: Double((value >> 8) & 0xff) / 255,
                      blue: Double(value & 0xff) / 255,
                      opacity: Double((value >> 24) & 0xff) / 255)
        default:
            return nil
        }
    }
}
