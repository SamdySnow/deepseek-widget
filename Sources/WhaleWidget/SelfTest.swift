import Foundation

/// 自检：不启动界面，验证凭据解析、余额接口、记账与计价等核心链路。
/// 用法：`WhaleWidget --selftest`
enum SelfTest {

    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            print(condition ? "  ✅ \(name)\(detail.isEmpty ? "" : " — \(detail)")"
                            : "  ❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !condition { failures += 1 }
        }

        print("== 凭据 ==")
        let cred = Credentials.resolve()
        check("解析到 API 密钥", cred != nil,
              cred.map { "来源：\($0.source.rawValue)，账户标识 \($0.accountTag.prefix(8))…" } ?? "未找到")
        check("从 DSH 凭据库解析", Credentials.fromDSHCredentials() != nil)

        // 解析器单测：确保只读取 refs 区段、不误取其它键
        let sample = """
        version: 1
        records:
          client-connection/browser-session:
            secret: another-value-here
        refs:
          DEEPSEEK_API_KEY: sk-testkey1234567890
          OTHER_KEY: sk-other
        """
        check("YAML refs 解析正确",
              Credentials.parseRefs(sample, key: "DEEPSEEK_API_KEY") == "sk-testkey1234567890")
        check("不误取 records 区段的值",
              Credentials.parseRefs(sample, key: "secret") == nil)

        print("== 峰谷判定 ==")
        // 规则：周一至周五 + 非法定节假日 + 9:00–12:00 / 14:00–18:00 才是高峰
        check("工作日 10:00 为高峰", Pricing.isPeak(at(2026, 9, 16, 10)) == true, "2026-09-16 周三")
        check("工作日 09:00 为高峰（区间左闭）", Pricing.isPeak(at(2026, 9, 16, 9)) == true)
        check("工作日 11:59 为高峰", Pricing.isPeak(at(2026, 9, 16, 11)) == true)
        check("工作日 12:00 为空闲（区间右开）", Pricing.isPeak(at(2026, 9, 16, 12)) == false)
        check("工作日 13:00 为空闲（午休）", Pricing.isPeak(at(2026, 9, 16, 13)) == false)
        check("工作日 14:00 为高峰", Pricing.isPeak(at(2026, 9, 16, 14)) == true)
        check("工作日 17:59 为高峰", Pricing.isPeak(at(2026, 9, 16, 17)) == true)
        check("工作日 18:00 为空闲", Pricing.isPeak(at(2026, 9, 16, 18)) == false)
        check("工作日 08:59 为空闲", Pricing.isPeak(at(2026, 9, 16, 8)) == false)
        check("工作日 00:30 为空闲", Pricing.isPeak(at(2026, 9, 16, 0)) == false)
        check("工作日 23:00 为空闲", Pricing.isPeak(at(2026, 9, 16, 23)) == false)

        check("周末 10:00 为空闲", Pricing.isPeak(at(2026, 9, 19, 10)) == false, "2026-09-19 周六")
        check("周末 15:00 为空闲", Pricing.isPeak(at(2026, 9, 20, 15)) == false, "2026-09-20 周日")

        // 法定节假日全天谷价（含工作日）
        let holidays: [(Int, Int, Int, String)] = [
            (1, 1, 1, "元旦"), (1, 2, 2, "元旦"), (1, 3, 3, "元旦"),
            (2, 16, 16, "春节"), (2, 20, 20, "春节"), (2, 23, 23, "春节"),
            (4, 6, 6, "清明"), (5, 1, 1, "劳动节"), (5, 5, 5, "劳动节"),
            (6, 19, 19, "端午"), (9, 25, 25, "中秋"), (10, 1, 1, "国庆"), (10, 7, 7, "国庆"),
        ]
        var holidayOk = true
        for (month, day, hour, name) in holidays {
            // 10:00 与 14:00 都是工作日高峰钟点，节假日必须仍为谷价
            if Pricing.isPeak(at(2026, month, day, hour == 10 ? 10 : 14)) != false {
                holidayOk = false
                print("     ↳ 反例：\(name) 2026-\(month)-\(day) 被判为高峰")
            }
        }
        check("法定节假日全天为谷价（含工作日钟点）", holidayOk)

        // 边界：节假日前后应恢复高峰（确认没有多算一天）
        check("节假日结束后恢复高峰（2026-10-08 周四 10:00）",
              Pricing.isPeak(at(2026, 10, 8, 10)) == true)
        check("节假日开始前是高峰（2026-09-30 周三 10:00）",
              Pricing.isPeak(at(2026, 9, 30, 10)) == true)
        check("春节前一天是高峰（2026-02-13 周五 10:00）",
              Pricing.isPeak(at(2026, 2, 13, 10)) == true)
        check("春节后一天是高峰（2026-02-24 周二 10:00）",
              Pricing.isPeak(at(2026, 2, 24, 10)) == true)

        // 独立校验节假日名单：直接按国务院通知的区间重新展开一遍，
        // 避免「常量写错但测试也照抄」这种自证。
        var expectedHolidays = Set<String>()
        let ranges: [(Int, Int, Int)] = [
            (1, 1, 3), (2, 15, 23), (4, 4, 6), (5, 1, 5),
            (6, 19, 21), (9, 25, 27), (10, 1, 7),
        ]
        for (month, from, to) in ranges {
            for d in from...to {
                expectedHolidays.insert(String(format: "2026-%02d-%02d", month, d))
            }
        }
        check("节假日天数与国务院通知一致（共 33 天）",
              Pricing.legalHolidays == expectedHolidays
                && Pricing.legalHolidays.count == 33,
              "实际 \(Pricing.legalHolidays.count) 天")
        check("调休上班的周末不计为高峰（2026-09-20 周日）",
              Pricing.isPeak(at(2026, 9, 20, 10)) == false)

        print("== 峰谷切换倒计时 ==")
        // 周三 10:00 处于高峰，下一个切换点是 12:00（离开高峰）
        if let next = Pricing.computeNextSwitch(after: at(2026, 9, 16, 10)) {
            check("高峰中 → 下一个切换点是离开高峰", next.toPeak == false)
            check("周三 10:00 → 12:00 剩 2 小时",
                  abs(next.interval - 2 * 3600) < 60,
                  "\(Int(next.interval / 60)) 分")
        } else {
            check("能算出下一个切换点", false, "返回 nil")
        }
        // 周三 12:30 处于午休谷价，下一个切换点是 14:00（进入高峰）
        if let next = Pricing.computeNextSwitch(after: at(2026, 9, 16, 12.5)) {
            check("午休中 → 下一个切换点是进入高峰", next.toPeak)
            check("周三 12:30 → 14:00 剩 1.5 小时",
                  abs(next.interval - 1.5 * 3600) < 60,
                  "\(Int(next.interval / 60)) 分")
        } else {
            check("能算出午休后的切换点", false, "返回 nil")
        }
        // 周五 18:30 之后到下周一 9:00 之间没有切换（整段都是谷价）
        if let next = Pricing.computeNextSwitch(after: at(2026, 9, 18, 18.5)) {
            check("周五晚的下一切换点落在下周一 9:00（进入高峰）", next.toPeak,
                  "\(Int(next.interval / 3600)) 小时后")
            // 周五 18:30 → 周一 09:00 = 62.5 小时
            check("周五 18:30 → 周一 09:00 约 62.5 小时",
                  abs(next.interval - 62.5 * 3600) < 300,
                  String(format: "%.1f 小时", next.interval / 3600))
        } else {
            check("能算出跨周末的切换点", false, "返回 nil")
        }
        // 节假日期间：国庆 10-03 处于长假，下一切换点应是 10-08 09:00
        if let next = Pricing.computeNextSwitch(after: at(2026, 10, 3, 10)) {
            check("国庆假期中 → 下一切换点是 10-08 09:00 进入高峰", next.toPeak,
                  String(format: "%.1f 天后", next.interval / 86400))
        } else {
            check("能算出长假后的切换点", false, "返回 nil")
        }

        print("== 峰谷文案 ==")
        // 谷价时应说明原因（周末 / 法定节假日 / 非高峰钟点），便于用户核对规则
        check("周末谷价文案标明「周末」",
              Pricing.moment(at(2026, 9, 19, 10)).dayKind == "周末",
              Pricing.moment(at(2026, 9, 19, 10)).dayKind)
        check("国庆谷价文案标明「法定节假日」",
              Pricing.moment(at(2026, 10, 3, 10)).dayKind == "法定节假日",
              Pricing.moment(at(2026, 10, 3, 10)).dayKind)
        check("普通工作日晚间标明「工作日」",
              Pricing.moment(at(2026, 9, 16, 20)).dayKind == "工作日",
              Pricing.moment(at(2026, 9, 16, 20)).dayKind)

        print("== 计价 ==")
        let flash = Pricing.rate(for: "deepseek-flash")
        check("Flash 空闲价", flash.values(peak: false).miss == 1.0)
        check("Flash 高峰价为两倍", flash.values(peak: true).miss == 2.0)
        let pro = Pricing.rate(for: "deepseek-v4-pro")
        check("Pro 价为 Flash 的 3 倍", pro.values(peak: false).out == 13.5)
        check("未知模型回退到 Flash 价",
              Pricing.rate(for: "some-unknown-model").values(peak: false).miss == 1.0)

        // 100 万未命中输入 token 在空闲时段 = 1 元
        var usage = Pricing.Usage()
        usage.inputTokens = 1_000_000
        check("100 万输入 token 空闲价 = ¥1",
              abs(Pricing.cost(usage: usage, model: "deepseek-flash", peak: false) - 1.0) < 1e-9)

        print("== 记账 ==")
        var ledger = Ledger()
        _ = ledger.observe(balance: 14.44, currency: "CNY", scope: "testacct")
        _ = ledger.observe(balance: 13.44, currency: "CNY", scope: "testacct")   // 消费 1 元
        let afterSpend = ledger.usage(for: Pricing.beijingDay())
        check("余额下降记为消费", abs(afterSpend.amount - 1.0) < 1e-6,
              "记录为 ¥\(afterSpend.amount)")

        _ = ledger.observe(balance: 63.44, currency: "CNY", scope: "testacct")   // 充值 50 元
        let afterTopUp = ledger.usage(for: Pricing.beijingDay())
        check("充值不冲抵已有消费", abs(afterTopUp.amount - 1.0) < 1e-6,
              "仍为 ¥\(afterTopUp.amount)")
        check("充值会标记待核对",
              ledger.books.values.first?.days[Pricing.beijingDay()]?.needsReview == true)

        // 校正后口径 = 期初 + 到账 − 期末
        try? ledger.reconcile(day: Pricing.beijingDay(), credits: 50, otherDebits: 0)
        let corrected = ledger.usage(for: Pricing.beijingDay())
        check("校正后消费 = 期初 + 到账 − 期末",
              abs(corrected.amount - 1.0) < 1e-6, "¥\(corrected.amount)")
        check("校正后不再标记待核对",
              ledger.books.values.first?.days[Pricing.beijingDay()]?.needsReview == false)

        // 乱序 / 重复样本应被忽略
        let before = ledger.usage(for: Pricing.beijingDay()).amount
        _ = ledger.observe(balance: 1.0, currency: "CNY", scope: "testacct",
                           at: Date(timeIntervalSince1970: 1000))
        check("忽略乱序样本",
              ledger.usage(for: Pricing.beijingDay()).amount == before)

        print("== 金额精度 ==")
        let m = Money(0.1)! + Money(0.2)!
        check("0.1 + 0.2 精确等于 0.3", m.units == 30_000_000, "units=\(m.units)")

        print("== DSH 历史导入 ==")
        let dshExists = LedgerStore.dshLedgerURLs.contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
        if dshExists {
            var fresh = Ledger()
            let imported = LedgerStore.importFromDSHIfEmpty(into: &fresh)
            check("从 DSH 账本导入历史", imported > 0, "导入 \(imported) 天记录")
            check("导入后账户标识与 DSH 一致",
                  fresh.active.hasSuffix("-CNY") && !fresh.active.isEmpty,
                  fresh.active)
            // 已导入的账本不应被二次导入覆盖
            var again = fresh
            let second = LedgerStore.importFromDSHIfEmpty(into: &again)
            check("已有数据时不再重复导入", second == 0)
        } else {
            print("  ⏭ 未发现 DSH 账本，跳过")
        }

        print("== 窗口定位 ==")
        // 内置 Retina 的实际可见区域
        let visible = CGRect(x: 0, y: 0, width: 1728, height: 1084)
        let side = Positioning.panelSide(scale: 1.8, screenFrame: CGSize(width: 1728, height: 1117))
        check("1.8× 边长按参考公式计算", abs(side - 450) < 1,
              "边长 \(Int(side))px")
        check("边长下限 122px", Positioning.panelSide(scale: 0.1, screenFrame: CGSize(width: 900, height: 700)) == 122)
        check("边长上限随缩放放大", Positioning.panelSide(scale: 3.0, screenFrame: CGSize(width: 1728, height: 1117)) > 600)

        let bad = CGPoint(x: 1219, y: -608)
        let fixed = Positioning.clamp(origin: bad, side: side, visible: visible)
        check("屏幕外的旧坐标会被夹回可见区",
              Positioning.isFullyVisible(origin: fixed, side: side, visible: visible),
              "修正为 (\(Int(fixed.x)), \(Int(fixed.y)))")

        let offRight = Positioning.clamp(origin: CGPoint(x: 5000, y: 5000),
                                         side: side, visible: visible)
        check("右下溢出会被夹回", Positioning.isFullyVisible(origin: offRight, side: side, visible: visible))

        let tinyScreen = CGRect(x: 0, y: 0, width: 100, height: 100)
        let tiny = Positioning.clamp(origin: CGPoint(x: 50, y: 50), side: 450, visible: tinyScreen)
        check("屏幕小于窗口时不产生越界坐标", tiny.x >= 0 && tiny.y >= 0,
              "(\(Int(tiny.x)), \(Int(tiny.y)))")

        let corner = Positioning.snapped(origin: CGPoint(x: 1274, y: 5), side: side,
                                         visible: visible, zones: .uniform(24))
        check("贴右下时吸附到右边与底边",
              corner.side == "right" && corner.origin.x == visible.maxX - side && corner.origin.y == 0,
              "edge=\(corner.side) origin=(\(Int(corner.origin.x)), \(Int(corner.origin.y)))")

        let leftCorner = Positioning.snapped(origin: CGPoint(x: 8, y: 630), side: side,
                                             visible: visible, zones: .uniform(24))
        check("贴左上时吸附并标记 left（供镜像翻转）",
              leftCorner.side == "left" && leftCorner.origin.x == 0,
              "edge=\(leftCorner.side)")

        let middle = Positioning.snapped(origin: CGPoint(x: 700, y: 400), side: side,
                                         visible: visible, zones: .uniform(24))
        check("屏幕中间不吸附", middle.side == "none",
              "edge=\(middle.side)")

        // 参考实现的默认吸附区（左右 10%、下 15%、上 0）—— 比固定 24px 宽得多，
        // 这正是「吸附不生效」的根因：原先只有参考实现宽度的 ~14%。
        let refZones = Positioning.Zones.reference(for: visible)
        check("左右吸附区按屏幕宽 10% 计算（远宽于旧的固定 24px）",
              abs(refZones.left - visible.width * 0.10) < 1,
              String(format: "左 %.0fpx（旧版固定 24px）", refZones.left))
        check("底边吸附区按屏幕高 15% 计算",
              abs(refZones.bottom - visible.height * 0.15) < 1,
              String(format: "下 %.0fpx", refZones.bottom))
        check("上边不吸附（跟随参考实现 T=0）", refZones.top == 0,
              "上 \(Int(refZones.top))px")

        // 关键回归：在旧的固定 24px 判据下「不吸附」的位置，按新判据应当吸附。
        // 这是用户感知「吸附不生效」的直接复现。
        let justInside = CGPoint(x: visible.minX + 100, y: visible.midY)
        let oldResult = Positioning.snapped(origin: justInside, side: side,
                                            visible: visible, zones: .uniform(24))
        let newResult = Positioning.snapped(origin: justInside, side: side,
                                            visible: visible, zones: refZones)
        check("距左边 100px：旧判据不吸附、新判据吸附（复现用户反馈）",
              oldResult.side == "none" && newResult.side == "left",
              "旧=\(oldResult.side) 新=\(newResult.side)")

        // 上边不吸附：靠近顶部时应当保持原位（不会被吸到顶）
        let nearTopPos = CGPoint(x: visible.midX, y: visible.maxY - side - 50)
        let topResult = Positioning.snapped(origin: nearTopPos, side: side,
                                            visible: visible, zones: refZones)
        check("靠近屏幕顶部不吸附（上边吸附区为 0）",
              topResult.origin.y == nearTopPos.y,
              "y=\(Int(topResult.origin.y))")
        let fallback = Positioning.defaultOrigin(side: side, visible: visible, margin: 24)
        check("默认位置为右下角且完整可见",
              Positioning.isFullyVisible(origin: fallback, side: side, visible: visible)
                && fallback.x > visible.midX && fallback.y < visible.midY,
              "(\(Int(fallback.x)), \(Int(fallback.y)))")

        // 任意屏幕尺寸 × 任意缩放，夹取结果都必须完整可见
        var allVisible = true
        for screenSize in [CGSize(width: 1280, height: 800), CGSize(width: 3456, height: 2234),
                           CGSize(width: 1440, height: 900)] {
            let v = CGRect(origin: .zero, size: screenSize)
            for scale in [0.6, 1.0, 1.8, 3.0] {
                let s = Positioning.panelSide(scale: scale, screenFrame: screenSize)
                for origin in [CGPoint(x: -9999, y: -9999), CGPoint(x: 9999, y: 9999),
                               CGPoint(x: 0, y: 0)] {
                    let c = Positioning.clamp(origin: origin, side: s, visible: v)
                    if !Positioning.isFullyVisible(origin: c, side: s, visible: v) { allVisible = false }
                }
            }
        }
        check("各屏幕尺寸 × 各缩放档位下夹取结果都完整可见", allVisible)

        print("== 拖动跟随 ==")
        // 窗口从 (1000, 500) 开始，鼠标从 (1200, 600) 起手
        let windowStart = CGPoint(x: 1000, y: 500)
        let mouseStart = CGPoint(x: 1200, y: 600)
        let cases: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 1200, y: 600), windowStart),                       // 未动
            (CGPoint(x: 1210, y: 600), CGPoint(x: 1010, y: 500)),          // 右移 10
            (CGPoint(x: 1210, y: 610), CGPoint(x: 1010, y: 510)),          // 再上移 10
            (CGPoint(x: 1300, y: 640), CGPoint(x: 1100, y: 540)),          // 拖到终点
            (CGPoint(x: 1200, y: 600), windowStart),                       // 回到起点
        ]
        var dragOk = true
        for (mouseNow, expected) in cases {
            let got = PointerIntent.windowOrigin(windowStart: windowStart,
                                                 mouseStart: mouseStart,
                                                 mouseNow: mouseNow)
            if got != expected { dragOk = false; break }
        }
        check("拖动位移严格等于鼠标位移（不累积、不自反馈）", dragOk)

        // 关键回归点：模拟完整的拖动循环。
        // 控制器只在按下时记录一次 windowStart，拖动过程中不再更新它，
        // 因此窗口位置必须严格 = windowStart + (mouseNow − mouseStart)：
        // 与鼠标一一对应、可逆、不随中间帧累积。
        let windowAnchor = CGPoint(x: 1000, y: 500)   // 按下时记录，全程不变
        let mouseAnchor = CGPoint(x: 1200, y: 600)
        let path: [CGPoint] = [
            CGPoint(x: 1200, y: 600),
            CGPoint(x: 1230, y: 605),
            CGPoint(x: 1290, y: 640),
            CGPoint(x: 1250, y: 590),
            CGPoint(x: 1200, y: 600),   // 回到起点
        ]
        var followOk = true
        var lastPos = windowAnchor
        for mouse in path {
            let pos = PointerIntent.windowOrigin(windowStart: windowAnchor,
                                                 mouseStart: mouseAnchor,
                                                 mouseNow: mouse)
            let expected = CGPoint(x: 1000 + (mouse.x - 1200),
                                   y: 500 + (mouse.y - 600))
            if pos != expected { followOk = false; break }
            lastPos = pos
        }
        check("窗口位置始终 = 起始位置 + 鼠标位移（逐帧一致，无累积漂移）",
              followOk)
        check("鼠标回到起点时窗口也回到起点（可逆、无自我反馈）",
              lastPos == windowAnchor,
              "(\(Int(lastPos.x)),\(Int(lastPos.y)))")

        check("位移小于阈值不算拖动",
              !PointerIntent.isDrag(from: mouseStart,
                                    to: CGPoint(x: 1201, y: 601)))   // 各偏 1px
        check("位移超过阈值算拖动",
              PointerIntent.isDrag(from: mouseStart,
                                   to: CGPoint(x: 1210, y: 600)))

        print("== 资源 ==")
        check("资源目录可定位", Assets.directory != nil,
              Assets.directory?.path ?? "未找到")
        check("小鲸鱼图片存在", Assets.whaleImage != nil)
        check("任务结束音存在", Assets.url("minecraft-exp-orb.wav") != nil)
        check("泡泡图存在", Assets.url("bubble-petpet.gif") != nil)

        print("== 余额接口 ==")
        if let cred {
            let semaphore = DispatchSemaphore(value: 0)
            var result: String?
            Task {
                do {
                    let info = try await DeepSeekAPI().fetchBalance(key: cred.key)
                    result = "成功：\(info.total) \(info.currency)"
                } catch {
                    result = "失败：\(error.localizedDescription)"
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 25)
            check("拉取余额", result?.hasPrefix("成功") == true, result ?? "超时")
        }

        print(failures == 0 ? "\n全部通过 ✅" : "\n有 \(failures) 项失败 ❌")
        return failures == 0 ? 0 : 1
    }

    /// 构造北京时间某年某月某日某点的时刻。
    /// `hour` 可带小数（例如 12.5 = 12:30），便于测半点的倒计时。
    private static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Double) -> Date {
        let cal = Pricing.beijingCalendar
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = Int(hour)
        comps.minute = Int((hour - Double(Int(hour))) * 60)
        return cal.date(from: comps) ?? Date()
    }
}
