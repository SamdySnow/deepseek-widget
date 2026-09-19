import Combine
import Foundation

/// 挂件中央状态：余额轮询、记账、菜单与窗口共享的数据源。
@MainActor
final class WhaleStore: ObservableObject {

    // MARK: - 对外发布的状态

    @Published private(set) var balance: Double = 0
    @Published private(set) var currency: String = "CNY"
    /// 今日已用（元），以及统计口径说明
    @Published private(set) var todayUsage: Double = 0
    @Published private(set) var usageLabel: String = "本地估算"
    /// 余额上升但尚未核对时提示
    @Published private(set) var needsReview: Bool = false
    /// 余额变化时的滚动动画方向
    @Published private(set) var balancePulse: Int = 0

    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?
    /// 瞬时抖动时沿用最近余额，界面上给一个温和提示
    @Published private(set) var staleNotice: String?
    @Published private(set) var credentialSource: Credentials.Source = .none
    @Published private(set) var isLoading: Bool = false

    @Published var config: AppConfig
    @Published private(set) var ledger: Ledger

    /// 每轮消耗泡泡的内容回调（由界面层注入）
    var onTurnCost: ((Double) -> Void)?
    /// 余额预警 / 今日预算提醒回调
    var onAlert: ((String) -> Void)?

    private let api = DeepSeekAPI()
    private var timer: Timer?
    private var resolved: Credentials.Resolved?

    // MARK: - 初始化

    init() {
        config = AppConfig.load() ?? AppConfig()
        ledger = LedgerStore.load()
        // 首次运行：把 DSH 插件的既有记账历史导入，保证口径连续（不覆盖已有数据）
        if LedgerStore.importFromDSHIfEmpty(into: &ledger) > 0 {
            LedgerStore.save(ledger)
        }
        resolved = Credentials.resolve()
        credentialSource = resolved?.source ?? .none
        if ledger.firstObservationDate != nil {
            let usage = ledger.usage(for: Pricing.beijingDay())
            todayUsage = usage.amount
            usageLabel = usage.label
        }
    }

    // MARK: - 峰谷状态

    var isPeak: Bool { Pricing.isPeak() }

    /// 当前时刻的峰谷信息（周末 / 法定节假日全天谷价）。
    var moment: Pricing.Moment { Pricing.moment(Date()) }

    var peakText: String {
        let m = moment
        switch config.peakStyle {
        case "off":
            return ""
        case "minimal":
            // 简洁样式：直接给时段判断结果
            return Pricing.isPeak(m) ? "高峰" : "谷价"
        default:
            if Pricing.isPeak(m) { return "⚡ 高峰时段" }
            // 谷价时说明原因，便于核对规则（周末 / 法定节假日 / 非高峰钟点）
            switch m.dayKind {
            case "法定节假日": return "🌙 法定节假日·谷价"
            case "周末": return "🌙 周末·谷价"
            default: return "🌙 空闲时段"
            }
        }
    }

    var peakCountdown: String {
        guard let next = Pricing.nextSwitch() else { return "" }
        let d = Pricing.compactDuration(next.interval)
        return next.toPeak ? "\(d)后进入高峰" : "\(d)后回到谷价"
    }

    // MARK: - 轮询

    func startAutoRefresh() {
        stopAutoRefresh()
        let interval = max(15, config.refreshInterval)
        // Timer.scheduledTimer 已经把它加进当前 runloop 的 default mode；
        // 再 add 一次会让 runloop 重复持有，导致过度释放。这里只额外挂到 common mode，
        // 保证拖拽 / 滚动时轮询不被暂停。
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await refresh() }
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        if resolved == nil { resolved = Credentials.resolve() }
        credentialSource = resolved?.source ?? .none
        guard let cred = resolved else {
            lastError = "未配置 DEEPSEEK_API_KEY（在菜单 → 密钥里填写，或配置到 DSH 凭据库）"
            return
        }

        do {
            let info = try await api.fetchBalance(key: cred.key)
            lastError = nil
            staleNotice = nil
            let previous = balance
            balance = info.total
            currency = info.currency
            lastUpdated = Date()

            if abs(previous - info.total) > 0.00000001 { balancePulse += 1 }

            // 记账：余额下降记为消费，上升记为充值（不冲抵消费）
            if let row = ledger.observe(balance: info.total, currency: info.currency,
                                        scope: cred.accountTag) {
                let day = Pricing.beijingDay()
                let summary = ledger.usage(for: day)
                todayUsage = summary.amount
                usageLabel = summary.label
                needsReview = row.needsReview
                if needsReview {
                    onAlert?("检测到余额增加，消费需在「余额校正」里核对")
                }
                checkThresholds()
            }
            LedgerStore.save(ledger)
        } catch {
            let message = error.localizedDescription
            if let apiError = error as? DeepSeekAPI.APIError, apiError.isTransient, lastUpdated != nil {
                // 瞬时抖动：沿用最近余额，不报错
                staleNotice = "网络抖动，显示最近一次余额"
            } else {
                lastError = message
            }
        }
    }

    private func checkThresholds() {
        if let budget = config.todayBudget, budget > 0, todayUsage >= budget {
            onAlert?("今日已用已达预算 \(String(format: "%.2f", budget)) 元")
        }
    }

    // MARK: - 记账校正

    func reconcileToday(credits: Double?, otherDebits: Double?) throws {
        let day = Pricing.beijingDay()
        try ledger.reconcile(day: day, credits: credits, otherDebits: otherDebits)
        LedgerStore.save(ledger)
        let summary = ledger.usage(for: day)
        todayUsage = summary.amount
        usageLabel = summary.label
        if let context = ledger.active.isEmpty ? ledger.books.keys.first : ledger.active,
           let row = ledger.books[context]?.days[day] {
            needsReview = row.needsReview
        }
    }

    // MARK: - 密钥

    func updateKey(_ key: String?) {
        var cfg = config
        cfg.apiKey = (key?.isEmpty ?? true) ? nil : key
        config = cfg
        cfg.save()
        resolved = Credentials.resolve()
        credentialSource = resolved?.source ?? .none
        lastError = nil
        Task { await refresh() }
    }

    func maskedKeyHint() -> String {
        guard let cred = resolved else { return "未配置" }
        let tail = cred.key.suffix(4)
        return "••••\(tail)（来源：\(cred.source.rawValue)）"
    }

    // MARK: - 配置更新

    func update(_ mutate: (inout AppConfig) -> Void) {
        var cfg = config
        mutate(&cfg)
        config = cfg
        cfg.save()
    }

    /// 每轮对话结算（供本地会话统计或手动触发的场景使用）。
    func recordTurn(usage: Pricing.Usage, model: String, peak: Bool? = nil) {
        let isPeakNow = peak ?? Pricing.isPeak()
        let cost = Pricing.cost(usage: usage, model: model, peak: isPeakNow)
        let event = Ledger.UsageEvent(at: Date().timeIntervalSince1970 * 1000,
                                      day: Pricing.beijingDay(),
                                      model: model,
                                      input: usage.inputTokens,
                                      cacheRead: usage.cacheReadTokens,
                                      output: usage.outputTokens,
                                      cost: cost,
                                      source: "events")
        ledger.events.append(event)
        // 仅保留最近 30 天明细，避免文件无限增长
        let cutoff = Pricing.beijingDay(Date().addingTimeInterval(-30 * 86400))
        ledger.events.removeAll { $0.day < cutoff }
        LedgerStore.save(ledger)
        if config.turnCostOn { onTurnCost?(cost) }
    }

    // MARK: - 明细查询

    /// 仅供压测使用：不联网，直接改发布状态，放大重排 / 动画路径。
    func stressTick(delta: Double) {
        if delta > 0 {
            balance += delta
            todayUsage += delta
            balancePulse += 1
            lastUpdated = Date()
        }
    }

    var recentWeek: [(day: String, amount: Double)] { ledger.recentDays(7) }

    var todayModels: [(model: String, cost: Double, count: Int)] {
        ledger.modelBreakdown(for: Pricing.beijingDay())
    }

    var allTimeTotal: Double {
        var total = 0.0
        if let context = ledger.active.isEmpty ? ledger.books.keys.first : ledger.active,
           let book = ledger.books[context] {
            for (_, row) in book.days { total += row.observedAmount.doubleValue }
        }
        let observedDays = Set(ledger.books.values.flatMap { $0.days.keys })
        let eventOnly = ledger.events.filter { !observedDays.contains($0.day) }
            .reduce(0.0) { $0 + $1.cost }
        return total + eventOnly
    }

    var todayFriendlyModels: [(model: String, cost: Double, count: Int)] {
        todayModels.map { (FriendlyModel.name($0.model), $0.cost, $0.count) }
    }
}

/// 模型 id → 友好名称（与参考实现的面板标注一致）。
enum FriendlyModel {
    static func name(_ id: String) -> String {
        let m = id.lowercased()
        if m.contains("v4-pro") || m.contains("deepseek-pro") { return "DeepSeek-V4 Pro" }
        if m.contains("v4-flash-vision") { return "DeepSeek-V4.1-Flash（视觉·实验）" }
        if m.contains("v4-flash") { return "DeepSeek-V4.1-Flash（旧名）" }
        if m.contains("flash") { return "DeepSeek-V4.1-Flash" }
        if m.contains("reasoner") { return "DeepSeek-Reasoner" }
        if m.contains("chat") { return "DeepSeek-Chat" }
        return id
    }
}
