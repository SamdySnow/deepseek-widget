import Foundation

/// 定点金额：按 1e-8 记账，避免浮点累计误差。
/// 移植自参考实现 `lib/accounting.mjs`（SCALE = 100000000）。
struct Money {
    static let scale: Int64 = 100_000_000

    var units: Int64

    init(units: Int64) { self.units = units }

    init?(_ value: Double) {
        guard value.isFinite else { return nil }
        let u = (value * Double(Money.scale)).rounded()
        guard u >= Double(Int64.min), u <= Double(Int64.max) else { return nil }
        self.units = Int64(u)
    }

    var doubleValue: Double { Double(units) / Double(Money.scale) }

    /// 显示用两位小数。
    var display: String { String(format: "%.2f", doubleValue) }

    static func + (l: Money, r: Money) -> Money { Money(units: l.units + r.units) }
    static func - (l: Money, r: Money) -> Money { Money(units: l.units - r.units) }
    static func += (l: inout Money, r: Money) { l = l + r }
}

/// 余额观测账本：把「余额快照」累计成消费，区分下降（消费）与上升（充值）。
/// 观测不是交易流水，因此再提供显式「余额校正」接口。
struct Ledger: Codable {

    struct Correction: Codable {
        var at: Double
        var creditsUnits: Int64
        var otherDebitsUnits: Int64
        var amountUnits: Int64
        var debitUnits: Int64
        var creditUnits: Int64
    }

    struct Day: Codable {
        var day: String
        var firstAt: Double
        var lastAt: Double
        var openingUnits: Int64
        var lastUnits: Int64
        var debitUnits: Int64 = 0
        var creditUnits: Int64 = 0
        var revision: Int = 0
        var correction: Correction?
        var correctionLog: [Correction]?

        /// 观测得到的消费额（优先使用校正结果）。
        var observedAmount: Money {
            if let c = correction {
                return Money(units: c.amountUnits + debitUnits - c.debitUnits)
            }
            return Money(units: debitUnits)
        }

        var needsReview: Bool {
            creditUnits > (correction?.creditUnits ?? 0)
        }

        var revisionKey: String {
            "\(day):\(firstAt):\(lastUnits):\(debitUnits):\(creditUnits):\(revision)"
        }
    }

    struct Book: Codable {
        var currency: String
        var days: [String: Day] = [:]
        var lastAt: Double?
    }

    var date: String = Pricing.beijingDay()
    var dayStart: Double = 0
    var lastBalance: Double = 0
    var todayUsage: Double = 0
    var history: [String: Double] = [:]
    /// 每轮对话结算的 token 明细（用于用量记录窗口）
    var events: [UsageEvent] = []
    var active: String = ""
    var books: [String: Book] = [:]

    struct UsageEvent: Codable {
        var at: Double
        var day: String
        var model: String
        var input: Int
        var cacheRead: Int
        var output: Int
        var cost: Double
        var source: String  // "balance" 观测 | "events" 结算
    }

    enum CodingKeys: String, CodingKey {
        case date, dayStart, lastBalance, todayUsage, history, events, active, books
    }

    // MARK: - 观测

    /// 写入一次余额快照。返回当日摘要。
    @discardableResult
    mutating func observe(balance: Double, currency: String = "CNY",
                          scope: String = "default", at: Date = Date()) -> Day? {
        guard let units = Money(balance)?.units else { return nil }
        let cur = currency.uppercased()
        guard cur.count == 3 else { return nil }
        let context = "\(scope)-\(cur)"
        let stamp = at.timeIntervalSince1970 * 1000
        let day = Pricing.beijingDay(at)

        if books[context] == nil {
            books[context] = Book(currency: cur)
        }
        // 忽略重复 / 乱序样本（含昨天迟到的样本）
        if let last = books[context]?.lastAt, stamp <= last { return books[context]?.days[day] }

        active = context
        if var book = books[context] {
            if var row = book.days[day] {
                let delta = row.lastUnits - units
                if delta > 0 { row.debitUnits += delta }
                if delta < 0 { row.creditUnits -= delta }
                row.lastUnits = units
                row.lastAt = stamp
                book.days[day] = row
            } else {
                book.days[day] = Day(day: day, firstAt: stamp, lastAt: stamp,
                                     openingUnits: units, lastUnits: units)
            }
            book.lastAt = stamp
            books[context] = book
        }

        self.date = day
        if let row = books[context]?.days[day] {
            dayStart = Double(row.openingUnits) / Double(Money.scale)
            lastBalance = Double(row.lastUnits) / Double(Money.scale)
            todayUsage = row.observedAmount.doubleValue
            history[day] = todayUsage
            return row
        }
        return nil
    }

    /// 显式校正：填写本统计区间累计到账金额（充值/赠金）与其它非调用扣减。
    /// `credits` / `otherDebits` 传 nil 表示重置校正。
    mutating func reconcile(day: String, credits: Double?, otherDebits: Double? = 0,
                            confirmed: Bool = true, at: Date = Date()) throws {
        guard let context = active.isEmpty ? books.keys.first : active,
              var book = books[context], var row = book.days[day] else {
            throw WhaleError.message("这一天没有余额观测记录，无法校正")
        }
        guard confirmed else { throw WhaleError.message("请先确认已核对本统计区间的全部余额调整") }

        var correction: Correction?
        if let credits {
            guard credits >= 0, let cUnits = Money(credits)?.units else {
                throw WhaleError.message("到账金额须为非负数")
            }
            let dUnits = Money(otherDebits ?? 0)?.units ?? 0
            let amount = row.openingUnits + cUnits - dUnits - row.lastUnits
            guard amount >= 0 else {
                throw WhaleError.message("校正后消费为负，请核对统计起点与累计到账金额")
            }
            correction = Correction(at: at.timeIntervalSince1970 * 1000,
                                    creditsUnits: cUnits, otherDebitsUnits: dUnits,
                                    amountUnits: amount, debitUnits: row.debitUnits,
                                    creditUnits: row.creditUnits)
        }
        row.correction = correction
        row.revision += 1
        book.days[day] = row
        books[context] = book
        history[day] = row.observedAmount.doubleValue
        if date == day { todayUsage = row.observedAmount.doubleValue }
    }

    // MARK: - 查询

    /// 指定日期的消费额；没有观测记录时回退到本地事件估算。
    func usage(for day: String) -> (amount: Double, label: String, source: String) {
        if let context = active.isEmpty ? books.keys.first : active,
           let row = books[context]?.days[day] {
            let label: String
            let source: String
            if row.needsReview {
                label = "已观测消费 · 待核对余额调整"
                source = "balance-needs-review"
            } else if row.correction != nil {
                label = "已校正消费"
                source = "balance-corrected"
            } else {
                label = "已观测消费"
                source = "balance-observed"
            }
            return (row.observedAmount.doubleValue, label, source)
        }
        let estimate = events.filter { $0.day == day }.reduce(0.0) { $0 + $1.cost }
        return (estimate, "本地估算", "events")
    }

    /// 近 `days` 天每日消费明细（含今天），按日期升序。
    func recentDays(_ count: Int) -> [(day: String, amount: Double)] {
        var out: [(String, Double)] = []
        let cal = Pricing.beijingCalendar
        let today = Date()
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = Pricing.beijingDay(d)
            out.append((key, usage(for: key).amount))
        }
        return out
    }

    /// 按模型聚合的当日消费占比。
    func modelBreakdown(for day: String) -> [(model: String, cost: Double, count: Int)] {
        var agg: [String: (Double, Int)] = [:]
        for e in events where e.day == day {
            let cur = agg[e.model] ?? (0, 0)
            agg[e.model] = (cur.0 + e.cost, cur.1 + 1)
        }
        return agg.map { (model: $0.key, cost: $0.value.0, count: $0.value.1) }
            .sorted { $0.cost > $1.cost }
    }

    /// 记录的消费区间起点（用于「今日已用」未就绪提示）。
    var firstObservationDate: String? {
        guard let context = active.isEmpty ? books.keys.first : active,
              let book = books[context] else { return nil }
        return book.days.keys.sorted().first
    }
}

enum WhaleError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}
