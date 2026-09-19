import Foundation

/// DeepSeek 计费内核：峰谷时段判定 + 单价表 + 金额换算。
///
/// 峰谷规则（按北京时间）：
/// - **高峰**：周一至周五，且不是中国法定节假日，且时间落在 9:00–12:00 或 14:00–18:00
/// - **空闲**：其余全部时段，包括周末、法定节假日全天、以及工作日的其他钟点
enum Pricing {

    /// 高峰钟点：9:00–12:00、14:00–18:00（左闭右开）
    static let peakHours: [Range<Int>] = [9..<12, 14..<18]

    /// 中国法定节假日（放假日）→ 全天按谷价。
    ///
    /// 来源：国务院办公厅《关于 2026 年部分节假日安排的通知》
    /// （国办发明电〔2025〕7 号，2025-11-04 发布）。
    ///
    /// 注意：调休上班的周末（2026-01-04、02-14、02-28、05-09、09-20、10-10）
    /// **不计为高峰** —— 规则按「周一至周五」定义工作日，周末一律谷价。
    /// 若日后希望调休日按高峰计费，把它们加进下面的 `makeupWorkdays` 即可。
    static let legalHolidays: Set<String> = {
        var days = Set<String>()
        days.formUnion(dayRange(2026, 1, 1, 3))      // 元旦
        days.formUnion(dayRange(2026, 2, 15, 23))    // 春节（9 天）
        days.formUnion(dayRange(2026, 4, 4, 6))      // 清明节
        days.formUnion(dayRange(2026, 5, 1, 5))      // 劳动节
        days.formUnion(dayRange(2026, 6, 19, 21))    // 端午节
        days.formUnion(dayRange(2026, 9, 25, 27))    // 中秋节
        days.formUnion(dayRange(2026, 10, 1, 7))     // 国庆节
        return days
    }()

    /// 调休上班的周末。当前规则下周末一律谷价，所以这里只作记录 / 备注用途。
    static let makeupWorkdays: Set<String> = [
        "2026-01-04", "2026-02-14", "2026-02-28",
        "2026-05-09", "2026-09-20", "2026-10-10",
    ]

    /// 已收录节假日数据的年份。未收录的年份只按「周一至周五」判断
    /// （节假日本身会按高峰计费），避免把不确定的数据当成确定结果。
    static let knownHolidayYears: Set<Int> = [2026]

    private static func dayRange(_ year: Int, _ month: Int, _ from: Int, _ to: Int) -> [String] {
        (from...to).map { String(format: "%04d-%02d-%02d", year, month, $0) }
    }

    // MARK: - 时刻 → 峰谷判定

    /// 某时刻在北京日历下的关键字段（一次算好，便于反复判定）。
    struct Moment {
        var dayKey: String      // yyyy-MM-dd
        var hour: Int
        var weekday: Int        // 1=周日 … 7=周六
        var year: Int
        /// 是否周末
        var isWeekend: Bool { weekday == 1 || weekday == 7 }
        /// 是否法定节假日
        var isHoliday: Bool {
            Pricing.knownHolidayYears.contains(year) && Pricing.legalHolidays.contains(dayKey)
        }
        /// 是否调休上班的周末（当前不计高峰，仅用于说明）
        var isMakeupWorkday: Bool { Pricing.makeupWorkdays.contains(dayKey) }
        var isPeakHour: Bool { Pricing.peakHours.contains { $0.contains(hour) } }
        /// 当日类别文案
        var dayKind: String {
            if isHoliday { return "法定节假日" }
            if isWeekend { return "周末" }
            return "工作日"
        }
    }

    static func moment(_ date: Date) -> Moment {
        let comps = beijingCalendar.dateComponents([.year, .month, .day, .hour, .weekday],
                                                   from: date)
        let key = String(format: "%04d-%02d-%02d",
                         comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        return Moment(dayKey: key, hour: comps.hour ?? 0,
                      weekday: comps.weekday ?? 1, year: comps.year ?? 0)
    }

    /// 是否为高峰计费时段。
    static func isPeak(_ moment: Moment) -> Bool {
        if moment.isHoliday { return false }      // 法定节假日全天谷价
        if moment.isWeekend { return false }      // 周末全天谷价
        return moment.isPeakHour                 // 工作日再按时段判断
    }

    /// 取当前时间直接比较。
    static func isPeak(_ date: Date = Date()) -> Bool {
        isPeak(moment(date))
    }

    // MARK: - 下一次峰谷切换

    /// 峰谷状态只在这些钟点变化：0 点（跨日）、以及高峰区间的四个端点。
    private static let boundaryHours = [0, 9, 12, 14, 18]
    private static let switchCache = SwitchCache()

    /// 距离下一个峰谷切换点的间隔与方向（`toPeak == true` 表示将要进入高峰）。
    static func nextSwitch(after date: Date = Date()) -> (interval: TimeInterval, toPeak: Bool)? {
        switchCache.value(at: date)
    }

    /// 扫描未来的边界时刻，找到第一个状态翻转点。
    static func computeNextSwitch(after date: Date) -> (interval: TimeInterval, toPeak: Bool)? {
        let cal = beijingCalendar
        let current = isPeak(date)
        for dayOffset in 0...10 {
            guard let base = cal.date(byAdding: .day, value: dayOffset, to: date) else { continue }
            let dayStart = cal.startOfDay(for: base)
            for hour in boundaryHours {
                guard let boundary = cal.date(byAdding: .hour, value: hour, to: dayStart),
                      boundary > date else { continue }
                if isPeak(boundary) != current {
                    return (boundary.timeIntervalSince(date), isPeak(boundary))
                }
            }
        }
        return nil
    }

    /// 带 TTL 的切换点缓存（界面每次重绘都读它，没必要重复扫描）。
    private final class SwitchCache {
        private let lock = NSLock()
        private var cachedAt: Date?
        private var cachedResult: (interval: TimeInterval, toPeak: Bool)?
        private let ttl: TimeInterval = 5

        func value(at date: Date) -> (interval: TimeInterval, toPeak: Bool)? {
            lock.lock()
            defer { lock.unlock() }
            if let at = cachedAt, let result = cachedResult,
               date >= at, date.timeIntervalSince(at) < ttl {
                return (max(0, result.interval - date.timeIntervalSince(at)), result.toPeak)
            }
            let result = Pricing.computeNextSwitch(after: date)
            cachedAt = date
            cachedResult = result
            return result
        }
    }

    /// 计费单价，单位：人民币元 / 百万 token。数组为 `[空闲时段, 高峰时段]`。
    struct Rate {
        /// 缓存命中输入
        let hit: [Double]
        /// 缓存未命中输入
        let miss: [Double]
        /// 输出
        let out: [Double]

        /// 取指定时段的价格：`peak == true` 用高峰价。
        func values(peak: Bool) -> (hit: Double, miss: Double, out: Double) {
            let i = peak ? 1 : 0
            return (hit[i], miss[i], out[i])
        }
    }

    /// Flash（正式模型名 `deepseek-flash` = DeepSeek-V4.1-Flash）
    static let flashRate = Rate(hit: [0.02, 0.04], miss: [1, 2], out: [4, 8])
    /// Pro 为 Flash 的 3 倍价
    static let proRate = Rate(hit: [0.15, 0.30], miss: [4.5, 9.0], out: [13.5, 27.0])

    /// 模型名 → 单价，按子串匹配（与参考实现一致，最长键优先）。
    static let rateTable: [(match: String, rate: Rate)] = [
        ("deepseek-v4-pro", proRate),
        ("deepseek-v4-flash-vision-exp", flashRate), // 旧名，按 Flash 计费
        ("deepseek-v4-flash", flashRate),            // 旧名，按 Flash 计费
        ("deepseek-flash", flashRate),
        ("deepseek-pro", proRate),
        ("deepseek-reasoner", flashRate),
        ("deepseek-chat", flashRate),
    ]

    static func rate(for model: String) -> Rate {
        let m = model.lowercased()
        // 长键优先，避免 "pro" 之类的短关键字误命中其它模型
        for entry in rateTable.sorted(by: { $0.match.count > $1.match.count }) where m.contains(entry.match) {
            return entry.rate
        }
        return flashRate
    }

    /// 北京时区日历（与参考实现的 `beijingDay` 口径一致）。
    static let beijing = TimeZone(identifier: "Asia/Shanghai")!
    static var beijingCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = beijing
        return c
    }()

    /// 北京日期字符串 `yyyy-MM-dd`。
    static func beijingDay(_ date: Date = Date()) -> String { moment(date).dayKey }

    static func beijingHour(_ date: Date) -> Int { moment(date).hour }

    /// 一段 token 用量按模型与时段折算的金额（元）。
    struct Usage {
        var inputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var outputTokens: Int = 0
    }

    static func cost(usage: Usage, model: String, peak: Bool) -> Double {
        let rate = rate(for: model).values(peak: peak)
        let missTokens = Double(max(0, usage.inputTokens))
        let hitTokens = Double(max(0, usage.cacheReadTokens))
        let outTokens = Double(max(0, usage.outputTokens))
        return (missTokens * rate.miss + hitTokens * rate.hit + outTokens * rate.out) / 1_000_000
    }

    /// 把时间间隔格式化为紧凑中文，例如 `2小时30分后重置`。
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days)天\(hours)小时" : "\(days)天" }
        if hours > 0 { return minutes > 0 ? "\(hours)小时\(minutes)分" : "\(hours)小时" }
        if minutes > 0 { return "\(minutes)分" }
        return "\(total)秒"
    }
}
