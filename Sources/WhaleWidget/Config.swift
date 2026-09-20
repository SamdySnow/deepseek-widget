import Foundation

/// 挂件配置（外观 / 交互开关 / 位置），持久化到 `~/.whale-widget-mac/config.json`。
struct AppConfig: Codable {
    /// 可选：直接写在配置里的 API 密钥（留空则自动读取 DSH 凭据库）。
    var apiKey: String?

    // 外观
    var scale: Double = 1.8
    var soundOn: Bool = true
    var volume: Double = 0.9
    var soundSet: String = "duck"       // duck | beep
    var peakStyle: String = "default"   // default | minimal | off
    var bubbleOn: Bool = true
    var turnCostOn: Bool = true
    var turnCostCloseMs: Int = 5000
    var menuButtonHidden: Bool = false

    // 交互（锁定 / 不透明度）
    //
    // 这两个字段是 **Optional 且默认 nil**，这是有意为之，不是笔误：
    // Swift 合成的 `init(from:)` **不会**用属性默认值兜住缺失的键，
    // 旧配置文件（没有这个键）会直接抛 keyNotFound → `AppConfig.load()` 返回 nil
    // → 用户的缩放 / 位置 / 开关被静默重置。
    // 写成 Optional 就能走 `decodeIfPresent`，旧配置照常解码。
    // （`SelfTest` 里有针对这一点的回归测试。）

    /// 锁定挂件：整个窗口 click-through，连角色本体也不接收鼠标事件。
    /// 唯一解除入口是菜单栏 🐋（因为挂件本身已经点不动了）。nil = 未锁定。
    var locked: Bool?
    /// 挂件不透明度（`AppConfig.opacityRange` 内）。nil = 1.0（完全不透明）。
    var opacity: Double?

    // 提醒
    /// 余额低于该值时提醒（nil = 关闭）
    var balanceAlert: Double?
    /// 今日已用达到该值时提醒（nil = 关闭）
    var todayBudget: Double?
    /// 提醒气泡自动关闭秒数（0 = 不自动关闭）
    var alertCloseSeconds: Int = 8

    // 吸附与位置
    var snapEnabled: Bool = true
    var snapMargin: Double = 24
    var lastX: Double?
    var lastY: Double?
    /// 贴左时水平镜像：小鲸鱼翻过去朝向屏幕内侧，**文字与图片反翻回来保持可读**
    /// （与参考实现的 `.dshwv-left .dshwv-text{scaleX(-1)}` 一致）。
    var mirrorOnLeftSnap: Bool = true
    /// 当前朝向：`left`（已翻转，朝屏幕右内）/ `right`（未翻转，朝屏幕左内）。
    ///
    /// 由 `PanelController.refreshMirror()` **按几何实时推导**并写入，
    /// 不是用户手动设置的开关 —— 所以只会有 left / right 两个值
    /// （早期版本还写过 `none`，那种「不知道朝哪」的状态已不再出现）。
    var lastSide: String = "right"      // left | right

    // 监听间隔（秒）
    var refreshInterval: Double = 60

    var updatedAt: String = ""

    // MARK: - 派生状态

    /// 不透明度的可调范围。
    ///
    /// 下限**不为 0**：完全透明会让挂件「消失」，而用户又不一定记得
    /// 菜单里有这个滑块 —— 那就变成了「挂件不见了」的求助场景。
    /// 0.2 足够淡，但仍能看见并拖回来。
    static let opacityRange: ClosedRange<Double> = 0.2...1.0

    /// 是否处于锁定状态（缺失键 → 未锁定）。
    var isLocked: Bool { locked ?? false }

    /// 归一化后的不透明度：越界值夹回范围，非有限值（NaN / ±inf）取 1.0。
    ///
    /// 手改配置写成 5.0 之类不应让窗口变得不可见，因此这里必须夹取。
    var panelOpacity: Double {
        guard let opacity, opacity.isFinite else { return 1.0 }
        return min(max(opacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
    }

    // MARK: - 读写

    /// 真实的状态目录（用户配置所在）。
    static let realDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".whale-widget-mac", isDirectory: true)

    /// 非交互入口（自检 / 压测 / 渲染校验等）的标记。
    static let testFlags = ["--selftest", "--hitcheck", "--render", "--stress", "--e2e"]

    /// 当前是否运行在自检 / 压测等非交互入口下。
    static var isTestRun: Bool {
        CommandLine.arguments.contains { testFlags.contains($0) }
    }

    /// 状态目录。
    ///
    /// **自检入口一律隔离到临时目录**：这些入口会驱动真实的 store / controller，
    /// 也就必然调用 `save()`。若写到真实目录，跑一次自检就会把用户的
    /// 缩放、位置、开关覆盖掉（这确实发生过：自检后挂件缩放变成了随机的 1.0×）。
    /// 需要固定位置时可用 `WHALE_STATE_DIR` 显式指定。
    static let directory: URL = {
        let env = ProcessInfo.processInfo.environment["WHALE_STATE_DIR"]
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        if isTestRun {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("whale-widget-test-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
        }
        return realDirectory
    }()

    static var configURL: URL { directory.appendingPathComponent("config.json") }
    static var ledgerURL: URL { directory.appendingPathComponent("ledger.json") }

    /// 自检结束时清理隔离目录。
    static func cleanUpTestDirectory() {
        guard isTestRun, directory != realDirectory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    static func load() -> AppConfig? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    func save() {
        var copy = self
        copy.updatedAt = ISO8601DateFormatter().string(from: Date())
        try? FileManager.default.createDirectory(at: AppConfig.directory,
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(copy) else { return }
        try? data.write(to: AppConfig.configURL, options: .atomic)
    }

    /// 写入 / 清除应用内保存的密钥。
    func saveKey(_ key: String?) {
        var copy = self
        copy.apiKey = (key?.isEmpty ?? true) ? nil : key
        copy.save()
    }
}

/// 极简钥匙串读写（用于可选地保存 API 密钥）。
enum Keychain {
    static func read(service: String, account: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    static func write(service: String, account: String, value: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["add-generic-password", "-U", "-s", service, "-a", account, "-w", value]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["delete-generic-password", "-s", service, "-a", account]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }
}

/// 账本持久化。
enum LedgerStore {
    static func load() -> Ledger {
        guard let data = try? Data(contentsOf: AppConfig.ledgerURL),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else {
            return Ledger()
        }
        return ledger
    }

    static func save(_ ledger: Ledger) {
        try? FileManager.default.createDirectory(at: AppConfig.directory,
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(ledger) else { return }
        try? data.write(to: AppConfig.ledgerURL, options: .atomic)
    }

    /// DSH 宿主插件的账本路径（`$DSH_HOME/.dshw-usage.json`）。
    static var dshLedgerURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dshHome = ProcessInfo.processInfo.environment["DSH_HOME"].map {
            URL(fileURLWithPath: $0)
        } ?? home.appendingPathComponent(".dsh", isDirectory: true)
        return [dshHome.appendingPathComponent(".dshw-usage.json")]
    }

    /// 首次运行时，把 DSH 插件的既有记账历史导入过来，
    /// 这样 Mac 版与 DSH 里的「今日已用 / 历史」口径连续，不会从零开始。
    /// 只在本地账本还没有任何观测记录时执行。
    @discardableResult
    static func importFromDSHIfEmpty(into ledger: inout Ledger) -> Int {
        guard ledger.books.isEmpty else { return 0 }

        for url in dshLedgerURLs {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accounting = root["accounting"] as? [String: Any],
                  let books = accounting["books"] as? [String: Any] else { continue }

            var importedDays = 0
            var merged: [String: Ledger.Book] = [:]

            for (context, value) in books {
                guard let book = value as? [String: Any],
                      let currency = book["currency"] as? String,
                      let days = book["days"] as? [String: Any] else { continue }

                var out = Ledger.Book(currency: currency)
                out.lastAt = (book["lastAt"] as? Double)

                for (dayKey, dayValue) in days {
                    guard let row = dayValue as? [String: Any],
                          let firstAt = row["firstAt"] as? Double,
                          let lastAt = row["lastAt"] as? Double,
                          let opening = row["openingUnits"] as? Int64 ?? (row["openingUnits"] as? NSNumber)?.int64Value,
                          let last = row["lastUnits"] as? Int64 ?? (row["lastUnits"] as? NSNumber)?.int64Value
                    else { continue }

                    func units(_ key: String) -> Int64 {
                        (row[key] as? NSNumber)?.int64Value ?? 0
                    }
                    var day = Ledger.Day(day: (row["day"] as? String) ?? dayKey,
                                         firstAt: firstAt, lastAt: lastAt,
                                         openingUnits: opening, lastUnits: last)
                    day.debitUnits = units("debitUnits")
                    day.creditUnits = units("creditUnits")
                    day.revision = (row["revision"] as? NSNumber)?.intValue ?? 0

                    if let correction = row["correction"] as? [String: Any] {
                        day.correction = Ledger.Correction(
                            at: (correction["at"] as? NSNumber)?.doubleValue ?? lastAt,
                            creditsUnits: (correction["creditsUnits"] as? NSNumber)?.int64Value ?? 0,
                            otherDebitsUnits: (correction["otherDebitsUnits"] as? NSNumber)?.int64Value ?? 0,
                            amountUnits: (correction["amountUnits"] as? NSNumber)?.int64Value ?? 0,
                            debitUnits: (correction["debitUnits"] as? NSNumber)?.int64Value ?? 0,
                            creditUnits: (correction["creditUnits"] as? NSNumber)?.int64Value ?? 0)
                    }
                    out.days[day.day] = day
                    importedDays += 1
                }
                merged[context] = out
            }

            guard !merged.isEmpty else { continue }

            ledger.books = merged
            ledger.active = (accounting["active"] as? String) ?? merged.keys.first ?? ""
            ledger.date = (root["date"] as? String) ?? Pricing.beijingDay()
            ledger.lastBalance = (root["lastBalance"] as? Double) ?? 0
            ledger.dayStart = (root["dayStart"] as? Double) ?? 0
            if let history = root["history"] as? [String: Double] {
                ledger.history = history
            }
            ledger.todayUsage = ledger.usage(for: Pricing.beijingDay()).amount
            return importedDays
        }
        return 0
    }
}
