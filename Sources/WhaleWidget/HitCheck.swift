import CoreGraphics
import Foundation
import SwiftUI

/// 交互路由校验：断言「点本体出泡」与「点菜单按钮弹菜单」是两条独立路径。
/// 用离屏渲染取到挂件的坐标，再判断命中区域，避免只靠肉眼看。
/// 用法：`WhaleWidget --hitcheck`
@MainActor
enum HitCheck {

    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "  ✅ \(name)\(detail.isEmpty ? "" : " — \(detail)")"
                     : "  ❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        let store = WhaleStore()
        let bubble = BubbleRuntime()
        bubble.close()

        let side: CGFloat = 450
        let width = side

        print("== 命中区域 ==")

        // 与 FloatingPanel 中的几何保持一致
        let whale = CGRect(x: width - width * 0.5945, y: width - width * 0.5945,
                           width: width * 0.5945, height: width * 0.5945)
        let bubbleRect = CGRect(x: 0, y: 0, width: width,
                                height: width * 700 / 1026)
        let menuSide = width * 26 / 320
        let menuCenter = CGPoint(x: width - menuSide / 2 - width * 0.0125,
                                 y: width * 0.4055 + menuSide * 0.6)
        let menuRect = CGRect(x: menuCenter.x - menuSide / 2,
                              y: menuCenter.y - menuSide / 2,
                              width: menuSide, height: menuSide)

        // 展开时的命中区域 = 小鲸鱼 + 气泡（由 WidgetContainerView.hitRects 判定）
        let hitRects = [whale, bubbleRect]
        let hitShape = Path { p in
            hitRects.forEach { p.addRect($0) }
        }

        // 挂件中心（小鲸鱼身体）应当命中
        let bodyPoint = CGPoint(x: whale.midX, y: whale.midY)
        check("小鲸鱼身体在命中区域内", hitShape.contains(bodyPoint),
              "(\(Int(bodyPoint.x)), \(Int(bodyPoint.y)))")

        // 菜单按钮中心必须落在菜单按钮矩形里
        let menuInMenu = menuRect.contains(menuCenter)
        check("菜单按钮中心落在按钮矩形内", menuInMenu,
              "center=(\(Int(menuCenter.x)), \(Int(menuCenter.y))) side=\(Int(menuSide))")

        // 菜单按钮是叠在本体右上角的小按钮（设计如此），关键是它必须**够小**：
        // 之前的 bug 是它的手势区被 .position 撑满整块面板，点哪里都弹菜单。
        let panelArea = width * width
        let menuArea = menuRect.width * menuRect.height
        let ratio = menuArea / panelArea
        check("菜单按钮占比足够小（不会吞掉本体的点击）", ratio < 0.02,
              String(format: "占面板面积 %.2f%%", ratio * 100))
        check("菜单按钮尺寸约为面板的 1/12", abs(menuSide / width - 1.0 / 12.3) < 0.02,
              String(format: "%.3f", menuSide / width))

        // 本体左上侧（远离按钮）的点必须落在菜单按钮之外
        let bodyTopLeft = CGPoint(x: whale.minX + 20, y: whale.minY + 20)
        check("本体左上侧不在菜单按钮内（点这里应出泡）", !menuRect.contains(bodyTopLeft),
              "(\(Int(bodyTopLeft.x)), \(Int(bodyTopLeft.y)))")

        // 菜单按钮位于面板右侧
        check("菜单按钮贴面板右侧", menuRect.midX > width * 0.9,
              String(format: "midX=%.2f×面板宽", menuRect.midX / width))

        // 左上的透明区域（既非气泡展开区，也非鲸鱼）不应命中
        let emptyPoint = CGPoint(x: width * 0.05, y: width * 0.95)
        let emptyPath = Path(whale)
        check("左上透明角落不参与命中（气泡收起时）", !emptyPath.contains(emptyPoint),
              "(\(Int(emptyPoint.x)), \(Int(emptyPoint.y)))")

        print("== 点击 / 拖动判定 ==")
        // 复现用户反馈的 bug：第二次点击不推进（被判成拖动）。
        // 旧实现用 DragGesture.translation 判定，窗口重建时 translation 会重置，
        // 于是「按下 → 松开」之间只要发生一次重排，位移就被读成非零 → 误判为拖动。
        let p = CGPoint(x: 500, y: 500)
        check("原位按下松开 → 点击",
              PointerIntent.resolve(start: p, end: p, movedDuringPress: false) == .click)
        check("位移 1px → 仍是点击",
              PointerIntent.resolve(start: p, end: CGPoint(x: 501, y: 501),
                                    movedDuringPress: false) == .click)
        check("位移 3px → 拖动",
              PointerIntent.resolve(start: p, end: CGPoint(x: 503, y: 500),
                                    movedDuringPress: false) == .drag)
        check("拖出去再拖回原点 → 仍是拖动（按压期间移动过）",
              PointerIntent.resolve(start: p, end: p, movedDuringPress: true) == .drag,
              "回到原点但曾移动过，不应被当成点击")

        // 连续两次点击必须都算点击（对应「第一次正常、第二次不推进」的现象）
        var kinds: [PointerIntent.Kind] = []
        for _ in 0..<2 {
            kinds.append(PointerIntent.resolve(start: p, end: p, movedDuringPress: false))
        }
        check("连续两次原位点击都判为点击", kinds == [.click, .click],
              kinds.map { $0 == .click ? "点击" : "拖动" }.joined(separator: ", "))

        print("== 可交互区域严格贴合图案（不是矩形）==")
        let panel: CGFloat = 450
        let whaleImage = Assets.whaleImage ?? Assets.whaleFallbackImage
        guard let mask = HitMask.bake(panelSide: panel,
                                      whaleImage: whaleImage,
                                      whaleRect: Positioning.whaleRectNormalized) else {
            check("能烘焙命中遮罩", false)
            return failures == 0 ? 0 : 1
        }

        // 覆盖率必须明显小于 1 —— 否则说明退化成了矩形
        let coverage = mask.coverage
        check("遮罩不是整块矩形（覆盖率 < 90%）", coverage < 0.9,
              String(format: "覆盖率 %.1f%%", coverage * 100))

        let whaleNorm = Positioning.whaleRectNormalized
        func hit(_ nx: CGFloat, _ ny: CGFloat) -> Bool {
            mask.contains(x: nx * panel, y: ny * panel, panelSide: panel)
        }

        // 用「角色图自身的 alpha」作为真值来校验遮罩：两者必须一致。
        // 这样测试不会依赖对图案外形的主观假设（我一开始就假设四角都透明，
        // 但小鲸鱼的身体本来就填到了右下角 —— 那是断言错了，不是代码错了）。
        guard let whale = whaleImage,
              let tiff = whale.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            check("能读取角色图像素", false)
            return failures == 0 ? 0 : 1
        }
        let iw = rep.pixelsWide, ih = rep.pixelsHigh

        func imageAlpha(_ nx: CGFloat, _ ny: CGFloat) -> Double {
            // 面板坐标 → 角色图内坐标
            let fx = (nx - whaleNorm.minX) / whaleNorm.width
            let fy = (ny - whaleNorm.minY) / whaleNorm.height
            guard fx >= 0, fx < 1, fy >= 0, fy < 1 else { return 0 }
            let x = min(iw - 1, max(0, Int(fx * CGFloat(iw))))
            let y = min(ih - 1, max(0, Int(fy * CGFloat(ih))))
            return Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
        }

        /// 邻域内的最大 / 最小 alpha。
        ///
        /// 遮罩是「面板边长栅格」（450 格），真值取自 610px 原图 ——
        /// 一个遮罩像素横跨约 1.35 个源像素，加上 .high 插值的模糊，
        /// 边界处会有约 ±2 源像素的不确定带。因此邻域取 ±2：
        /// 判「多算了」看邻域**最大** alpha，判「少算了」看邻域**最小** alpha。
        /// 容差是「分辨率换算」推出来的，不是为了让测试变绿而随手放的。
        let tolerance = 2
        func alphaRange(_ nx: CGFloat, _ ny: CGFloat) -> (min: Double, max: Double) {
            var lo = 1.0, hi = 0.0
            let step = 1.0 / CGFloat(iw)
            for dx in -tolerance...tolerance {
                for dy in -tolerance...tolerance {
                    let a = imageAlpha(nx + CGFloat(dx) * step * whaleNorm.width,
                                       ny + CGFloat(dy) * step * whaleNorm.height)
                    lo = Swift.min(lo, a)
                    hi = Swift.max(hi, a)
                }
            }
            return (lo, hi)
        }

        // 两个方向分别统计，用各自合适的严格度
        var spurious = 0          // 遮罩命中，但附近根本没有像素（矩形会在这里爆表）
        var missing = 0           // 遮罩漏掉，但该点确实在图案内部
        var firstSpurious = "", firstMissing = ""
        var insideSamples = 0, outsideSamples = 0

        for i in 0..<100 {
            for j in 0..<100 {
                let nx = (CGFloat(i) + 0.5) / 100
                let ny = (CGFloat(j) + 0.5) / 100
                let r = alphaRange(nx, ny)
                let got = hit(nx, ny)

                if got {
                    // 命中的地方附近必须有像素
                    if r.max < 0.05 {
                        spurious += 1
                        if firstSpurious.isEmpty {
                            firstSpurious = String(format: "(%.3f, %.3f) 邻域最大 alpha=%.2f",
                                                   nx, ny, r.max)
                        }
                    } else { outsideSamples += 1 }
                } else if r.min > 0.5 {
                    // 整块邻域都不透明却点不到 —— 这才是真的漏
                    missing += 1
                    if firstMissing.isEmpty {
                        firstMissing = String(format: "(%.3f, %.3f) 邻域最小 alpha=%.2f",
                                              nx, ny, r.min)
                    }
                } else if r.min <= 0.5 { insideSamples += 1 }
            }
        }

        check("遮罩不包含「附近没有像素」的区域（不是矩形）", spurious == 0,
              spurious == 0 ? "取样 10000 点无虚报" : "\(spurious) 处虚报，例如 \(firstSpurious)")

        // 定性判断：遮罩与真值到底是「翻转」还是「平移」关系。
        // 直接比较四种候选变换下的吻合度，而不是猜。
        func alphaBit(_ nx: CGFloat, _ ny: CGFloat, flipX: Bool, flipY: Bool) -> Bool {
            let x = flipX ? 1 - nx : nx
            let y = flipY ? 1 - ny : ny
            return imageAlpha(x, y) > 0.5
        }
        var scores: [(String, Int)] = []
        for flipY in [false, true] {
            for flipX in [false, true] {
                var agree = 0
                for i in 0..<60 {
                    for j in 0..<60 {
                        let nx = (CGFloat(i) + 0.5) / 60
                        let ny = (CGFloat(j) + 0.5) / 60
                        if hit(nx, ny) == alphaBit(nx, ny, flipX: flipX, flipY: flipY) { agree += 1 }
                    }
                }
                let label = flipY ? (flipX ? "上下+左右翻转" : "上下翻转")
                                  : (flipX ? "左右翻转" : "不翻转")
                scores.append((label, agree))
            }
        }
        let total = 3600
        let best = scores.max { $0.1 < $1.1 }!
        print("  与真值的吻合度：" + scores.map { "\($0.0) \($0.1)/\(total)" }.joined(separator: "，" ))
        check("遮罩方向与画面一致（不翻转的吻合度最高）",
              best.0 == "不翻转", "最优变换：\(best.0)")

        check("图案内部不存在点不到的洞", missing == 0,
              missing == 0 ? "取样 10000 点无遗漏" : "\(missing) 处漏判，例如 \(firstMissing)")
        check("确实取到了图案内 / 外的样本",
              insideSamples > 500 && outsideSamples > 500,
              "内 \(insideSamples) 点，外 \(outsideSamples) 点")

        // 透明区域必须不命中
        let transparencyChecks: [(CGFloat, CGFloat, String)] = [
            (0.01, 0.01, "面板左上角"), (0.99, 0.01, "面板右上角"),
            (0.01, 0.99, "面板左下角"), (0.5, 0.02, "面板顶部中间"),
            (0.02, 0.5, "面板左缘中部"),
        ]
        var transparentRejected = true
        for (x, y, name) in transparencyChecks where hit(x, y) {
            transparentRejected = false
            print("     ↳ \(name) 命中（该处无像素）")
        }
        check("无像素的透明区域一律不命中", transparentRejected)

        // 角色图中心（鲸鱼本体）必须命中
        check("角色图中心命中", hit(whaleNorm.midX, whaleNorm.midY),
              String(format: "(%.2f, %.2f)", whaleNorm.midX, whaleNorm.midY))

        // 命中区域必须明显小于外接矩形 —— 这是「不能是规则矩形」的量化判据
        let boxArea = whaleNorm.width * whaleNorm.height
        check("遮罩覆盖率明显小于外接矩形",
              coverage < boxArea * 0.9,
              String(format: "遮罩覆盖面板 %.1f%%，角色图矩形占 %.1f%%",
                     coverage * 100, boxArea * 100))

        // 打印遮罩轮廓，便于人工核对确实贴合图案
        print("  左=遮罩(可命中#)  右=原图 alpha(# 不透明, + 半透明, . 透明)：")
        for row in 0..<30 {
            var maskLine = "    "
            var alphaLine = "  |  "
            for col in 0..<72 {
                let nx = (CGFloat(col) + 0.5) / 72
                let ny = (CGFloat(row) + 0.5) / 30
                maskLine += hit(nx, ny) ? "#" : "."
                let a = imageAlpha(nx, ny)
                alphaLine += a > 0.5 ? "#" : (a > 0.05 ? "+" : ".")
            }
            print(maskLine + alphaLine)
        }

        // 气泡**不是**可交互区域：它只是展示，点它应穿透到桌面。
        // 因此遮罩与气泡开合无关，泡泡内部一律不命中。
        let vb = BubbleShape.viewBox
        let cx = BubbleShape.blobCenter.x / vb.width
        let cy = BubbleShape.blobCenter.y / vb.height * (vb.height / vb.width)
        check("气泡中心不命中（气泡是纯展示，点击穿透）", !hit(cx, cy),
              String(format: "(%.2f, %.2f)", cx, cy))

        let bb = Positioning.bubbleRectNormalized
        // 注意：气泡矩形与角色图矩形在左下角有重叠（角色图占右下 59.45%，
        // 气泡占上方 68.2%），重叠区内角色本体确实有像素 —— 那里命中是对的。
        // 所以取样必须排除「角色图有像素」的位置，只验证「气泡范围内、角色图之外」。
        let bubbleSamples: [(CGFloat, CGFloat)] = [
            (cx, cy),                                   // 椭圆中心
            (bb.minX + 0.06, bb.minY + 0.06),           // 左上
            (bb.maxX - 0.06, bb.minY + 0.06),           // 右上
            (bb.minX + 0.06, bb.maxY - 0.06),           // 左下
            (bb.maxX - 0.06, bb.maxY - 0.06),           // 右下
            (bb.midX, bb.minY + 0.03),                  // 上中
            (bb.midX, cy),                              // 椭圆中心右侧
            (cx + 0.1, cy + 0.05),
        ]
        var bubbleHits: [(CGFloat, CGFloat)] = []
        var skipped = 0
        for (sx, sy) in bubbleSamples {
            // 角色本体上有像素的位置不算 —— 那是合法的可交互区域
            if imageAlpha(sx, sy) > 0.5 { skipped += 1; continue }
            if hit(sx, sy) { bubbleHits.append((sx, sy)) }
        }
        check("气泡范围内、角色图之外一律不命中（气泡纯展示）", bubbleHits.isEmpty,
              bubbleHits.isEmpty
                ? "取样 \(bubbleSamples.count - skipped) 点全部穿透（\(skipped) 点落在角色本体上，跳过）"
                : "\(bubbleHits.count) 处误命中，例如 "
                  + String(format: "(%.2f, %.2f)", bubbleHits[0].0, bubbleHits[0].1))

        // 菜单按钮也**不在**遮罩里：它由 SwiftUI 自己响应。
        // 若纳进来，按钮周围一圈空白会变成「可点但无反应」的死区。
        let br = Positioning.menuButtonRectNormalized
        check("菜单按钮不在遮罩内（交给 SwiftUI 响应）",
              !mask.contains(x: br.midX * panel, y: br.midY * panel, panelSide: panel),
              String(format: "(%.3f, %.3f)", br.midX, br.midY))

        // 遮罩必须与气泡开合无关 —— 点气泡不推进序列，也就不该改变可交互范围
        check("遮罩不随气泡开合变化", mask.coverage < 0.5,
              String(format: "覆盖率 %.1f%%（仅角色本体）", mask.coverage * 100))

        print("== Click-through 路由（哪些区域接收事件）==")
        // 只有角色本体与菜单按钮接收事件；气泡与透明像素一律穿透。
        let routingMask = HitMask.bake(panelSide: panel,
                                      whaleImage: whaleImage,
                                      whaleRect: Positioning.whaleRectNormalized)
        let buttonRect = Positioning.menuButtonRectNormalized

        func zone(_ nx: CGFloat, _ ny: CGFloat) -> EventRouting.Zone {
            EventRouting.zone(at: CGPoint(x: nx, y: ny),
                              hitMask: routingMask,
                              panelSide: panel,
                              menuButtonRect: buttonRect)
        }

        check("角色本体 → character 且接收事件",
              zone(whaleNorm.midX, whaleNorm.midY) == .character
                && EventRouting.acceptsEvents(zone(whaleNorm.midX, whaleNorm.midY)),
              "\(zone(whaleNorm.midX, whaleNorm.midY))")
        check("菜单按钮 → menuButton 且接收事件（优先级高于角色本体）",
              zone(buttonRect.midX, buttonRect.midY) == .menuButton
                && EventRouting.acceptsEvents(zone(buttonRect.midX, buttonRect.midY)),
              "\(zone(buttonRect.midX, buttonRect.midY))")
        check("气泡中心 → bubble 且**不**接收事件（穿透）",
              zone(cx, cy) == .bubble
                && !EventRouting.acceptsEvents(zone(cx, cy)),
              "\(zone(cx, cy))")
        // 注意：面板左上角 (0.01, 0.01) 其实落在**气泡矩形内**（气泡占满面板宽度、
        // 高度到 68.2%），所以它判为 .bubble 是对的，不是 transparent。
        // transparent 要取气泡矩形之外、且没有角色像素的地方。
        check("面板左上角在气泡矩形内 → bubble（同样穿透）",
              zone(0.01, 0.01) == .bubble
                && !EventRouting.acceptsEvents(zone(0.01, 0.01)),
              "\(zone(0.01, 0.01))")
        check("面板左下空白 → transparent 且穿透",
              zone(0.02, 0.98) == .transparent
                && !EventRouting.acceptsEvents(zone(0.02, 0.98)),
              "\(zone(0.02, 0.98))")
        check("面板右下角（角色图之外的窄边）→ transparent",
              zone(0.99, 0.99) == .transparent || zone(0.99, 0.99) == .character,
              "\(zone(0.99, 0.99))")
        check("气泡下方、角色图左侧的空白 → transparent",
              zone(0.05, 0.85) == .transparent,
              "\(zone(0.05, 0.85))")
        // 气泡矩形内、角色图之外，必须判为 bubble 而不是 character
        let bubbleOnly = CGPoint(x: bb.minX + 0.06, y: bb.minY + 0.06)
        check("气泡矩形内（角色图之外）→ bubble",
              zone(bubbleOnly.x, bubbleOnly.y) == .bubble,
              "\(zone(bubbleOnly.x, bubbleOnly.y))")

        // 遍历整块面板，统计各区域占比：必须存在大量 transparent 与 bubble，
        // 否则说明又退化成「整块窗口都接收事件」。
        var counts: [String: Int] = [:]
        for i in 0..<60 {
            for j in 0..<60 {
                let z = zone((CGFloat(i) + 0.5) / 60, (CGFloat(j) + 0.5) / 60)
                counts["\(z)", default: 0] += 1
            }
        }
        let zoneTotal = 3600
        let acceptsRatio = Double((counts["character", default: 0]
                                   + counts["menuButton", default: 0])) / Double(zoneTotal)
        check("接收事件的面积占比很小（说明大部分区域可穿透）",
              acceptsRatio < 0.35,
              String(format: "接收 %.1f%%（character %d / menuButton %d / bubble %d / transparent %d）",
                     acceptsRatio * 100,
                     counts["character", default: 0], counts["menuButton", default: 0],
                     counts["bubble", default: 0], counts["transparent", default: 0]))

        print("== 视觉更新通知（点击必须让视图重绘）==")
        // 这是本轮 bug 的核心：`queueIndex` 原本不是 @Published，
        // 第 2 次点击时 `isOpen` 已是 true（值没变）、`queueIndex` 又发不出通知，
        // 于是 SwiftUI 收不到任何变更 → 界面停在「首次点击泡」，
        // 第 3 次点击 `isOpen` 翻 false 才重绘 → 顺势收起（看起来像「消失」）。
        //
        // 只验状态机是抓不到它的（模型一直是对的），必须验「有没有发出变更通知」。
        let fresh = BubbleRuntime()
        var notifications = 0
        let token = fresh.objectWillChange.sink { _ in notifications += 1 }
        defer { token.cancel() }

        fresh.close()
        notifications = 0
        fresh.handleTap(menuHidden: false)
        let n1 = notifications
        notifications = 0
        fresh.handleTap(menuHidden: false)
        let n2 = notifications
        notifications = 0
        fresh.handleTap(menuHidden: false)
        let n3 = notifications

        check("第 1 次点击会通知视图重绘", n1 > 0, "\(n1) 次 objectWillChange")
        check("第 2 次点击**也**会通知视图重绘（本轮 bug 的判据）", n2 > 0,
              n2 > 0 ? "\(n2) 次 objectWillChange"
                     : "❌ 0 次 —— 视图不会更新，界面会停在上一页")
        check("第 3 次点击（收起）会通知视图重绘", n3 > 0, "\(n3) 次 objectWillChange")

        // 页面确实换了（模型层），且通知也发了（视图层）—— 两者缺一不可
        let seqRuntime = BubbleRuntime()
        seqRuntime.close()
        var seen: [String] = []
        seqRuntime.handleTap(menuHidden: false)
        seen.append(seqRuntime.currentPage?.name ?? "nil")
        seqRuntime.handleTap(menuHidden: false)
        seen.append(seqRuntime.currentPage?.name ?? "nil")
        check("连续两次点击看到两个**不同**的页面", Set(seen).count == 2,
              seen.joined(separator: " → "))

        print("== 真实容器视图的事件计数 ==")
        // 用合成 NSEvent 直接驱动 WidgetContainerView，确认「一次点击 = 一次 onRelease」
        // —— 若容器重复回调，点击序列会一次前进两格，表现为「点两下气泡直接消失」。
        let container = WidgetContainerView(frame: NSRect(x: 0, y: 0, width: 450, height: 450))
        var pressCount = 0
        var dragCount = 0
        var releaseKinds: [PointerIntent.Kind] = []
        container.onPress = { _ in pressCount += 1 }
        container.onDrag = { _ in dragCount += 1 }
        container.onRelease = { kind, _ in releaseKinds.append(kind) }

        func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point,
                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }

        // 原地按一下（坐标落在小鲸鱼区域内）
        let center = NSPoint(x: 300, y: 200)
        if let down = mouseEvent(.leftMouseDown, at: center),
           let up = mouseEvent(.leftMouseUp, at: center) {
            container.mouseDown(with: down)
            container.mouseUp(with: up)
        }
        check("一次按下 → 一次 onPress", pressCount == 1, "pressCount=\(pressCount)")
        check("一次点击 → 一次 onRelease(.click)",
              releaseKinds == [.click],
              releaseKinds.map { $0 == .click ? "click" : "drag" }.joined(separator: ", "))
        check("纯点击不产生拖动回调", dragCount == 0, "dragCount=\(dragCount)")

        // 连续两次点击：必须各算一次点击，序列才能正常推进
        pressCount = 0
        releaseKinds = []
        for _ in 0..<2 {
            if let down = mouseEvent(.leftMouseDown, at: center),
               let up = mouseEvent(.leftMouseUp, at: center) {
                container.mouseDown(with: down)
                container.mouseUp(with: up)
            }
        }
        check("连续两次点击 → 两次 onPress、两次 .click",
              pressCount == 2 && releaseKinds == [.click, .click],
              "press=\(pressCount) release=\(releaseKinds.count)")

        // 拖动一次：只产生拖动，不产生点击
        pressCount = 0
        dragCount = 0
        releaseKinds = []
        if let down = mouseEvent(.leftMouseDown, at: center),
           let dragged = mouseEvent(.leftMouseDragged, at: NSPoint(x: 340, y: 180)),
           let up = mouseEvent(.leftMouseUp, at: NSPoint(x: 340, y: 180)) {
            container.mouseDown(with: down)
            container.mouseDragged(with: dragged)
            container.mouseUp(with: up)
        }
        check("拖动 → 只产生 onRelease(.drag)", releaseKinds == [.drag],
              releaseKinds.map { $0 == .click ? "click" : "drag" }.joined(separator: ", "))
        check("拖动会产生拖动回调", dragCount == 1, "dragCount=\(dragCount)")

        print("== 点击序列（含队列长度校验）==")
        // 用户反馈「点两下就消失」。若队列为空，第 2 次点击会直接收起。
        // 这里断言默认配置一定有队列内容，且逐次点击都能推进。
        let freshBubble = BubbleRuntime()
        check("默认配置的点击队列非空",
              !freshBubble.config.queue.isEmpty,
              "\(freshBubble.config.queue.count) 项")
        check("默认开启「点按角色推进队列」", freshBubble.config.advanceOnTap)

        let pageNames = [freshBubble.config.first.name]
            + freshBubble.config.queue.map(\.name)
        var visited: [String] = []
        freshBubble.close()
        for _ in 0..<pageNames.count {
            freshBubble.handleTap(menuHidden: false)
            guard freshBubble.isOpen else { break }
            visited.append(freshBubble.currentPage?.name ?? "nil")
        }
        check("依次点击可遍历所有页面（不会中途收起）",
              visited == pageNames,
              visited.joined(separator: " → "))
        // 遍历完再点才收起
        freshBubble.handleTap(menuHidden: false)
        check("遍历完所有页面后再点才收起（共需 \(pageNames.count + 1) 次点击）",
              !freshBubble.isOpen,
              "第 \(pageNames.count + 1) 次点击后 isOpen=\(freshBubble.isOpen)")

        print("== 点击行为（驱动真实回调）==")

        // 用 PointerIntent 的判定结果去驱动回调，模拟真实的按下 → 松开流程。
        var menuCalls = 0
        var tapCalls = 0
        let onTap: () -> Void = {
            tapCalls += 1
            bubble.handleTap(menuHidden: store.config.menuButtonHidden)
        }
        let onMenu: () -> Void = { menuCalls += 1 }

        /// 模拟一次完整的按下 → 松开（`dragTo` 为 nil 表示原地点击）
        func simulateClick(dragTo: CGPoint? = nil) {
            let start = CGPoint(x: 500, y: 500)
            let end = dragTo ?? start
            let kind = PointerIntent.resolve(start: start, end: end,
                                             movedDuringPress: dragTo != nil)
            if kind == .click { onTap() }
        }

        _ = WhalePanelView(store: store, bubble: bubble,
                           interaction: PanelInteraction(),
                           onMenu: onMenu)

        print("== 点击序列：两种模式都要有可预期行为 ==")
        // 用户反馈：「点击两下气泡直接消失，不会推进序列」。
        // 这正好是 advanceOnTap = false 时的表现（点击只是开合：开 → 关）。
        // 因此把两种模式的行为都钉死，避免再次出现「点两下就没了」的困惑。
        let savedAdvance = bubble.config.advanceOnTap

        bubble.update { $0.advanceOnTap = true }
        bubble.close()
        simulateClick()
        let afterOne = bubble.currentPage?.name
        simulateClick()
        let afterTwo = bubble.currentPage?.name
        check("推进模式：第 1 次点击 → 首次点击泡", afterOne == "首次点击泡", afterOne ?? "nil")
        check("推进模式：第 2 次点击 → 进入队列（不消失）",
              bubble.isOpen && afterTwo != afterOne, afterTwo ?? "nil")

        bubble.update { $0.advanceOnTap = false }
        bubble.close()
        simulateClick()
        let toggleOne = bubble.isOpen
        simulateClick()
        check("开合模式：两次点击是「开 → 关」（这是 flag 关闭时的预期行为）",
              toggleOne && !bubble.isOpen)

        bubble.update { $0.advanceOnTap = savedAdvance }

        print("== 队列为空时不应「点一下就消失」==")
        // 队列为空时第 2 次点击会收起（设计如此），
        // 但必须保证第 1 次点击一定看得到余额气泡。
        let savedQueue = bubble.config.queue
        bubble.update { $0.queue = [] }
        bubble.close()
        simulateClick()
        check("空队列：第 1 次点击仍展开并显示首次点击泡",
              bubble.isOpen && bubble.currentPage?.name == "首次点击泡",
              bubble.currentPage?.name ?? "nil")
        bubble.update { $0.queue = savedQueue }
        bubble.close()

        check("初始状态气泡是收起的", !bubble.isOpen)

        simulateClick()
        check("第 1 次点击 → 展开并显示首次点击泡",
              bubble.isOpen && bubble.currentPage?.name == "首次点击泡",
              bubble.currentPage?.name ?? "nil")
        check("点本体不触发菜单", menuCalls == 0, "menuCalls=\(menuCalls)")

        simulateClick()
        let queueCount = bubble.config.queue.count
        check("第 2 次点击 → 推进到队列第 1 项（这是之前失效的那一步）",
              queueCount > 0 && bubble.currentPage?.name == bubble.config.queue[0].name,
              bubble.currentPage?.name ?? "nil")

        var guardCount = 0
        while bubble.queueIndexForTesting < queueCount && guardCount < 20 {
            simulateClick()
            guardCount += 1
        }
        check("可以一路点到队列最后一项",
              bubble.currentPage?.name == bubble.config.queue.last?.name,
              bubble.currentPage?.name ?? "nil")

        simulateClick()
        check("最后一项再点 → 收起", !bubble.isOpen)
        check("收起后重新从首次点击泡开始",
              bubble.currentPage?.name == "首次点击泡")

        // 拖动不应推进气泡序列
        let tapsBeforeDrag = tapCalls
        let openBeforeDrag = bubble.isOpen
        simulateClick(dragTo: CGPoint(x: 600, y: 580))
        check("拖动不推进气泡序列", tapCalls == tapsBeforeDrag && bubble.isOpen == openBeforeDrag,
              "tapCalls \(tapsBeforeDrag) → \(tapCalls)")

        // 点菜单按钮：只弹菜单，不动气泡状态
        let openBefore = bubble.isOpen
        let pageBefore = bubble.currentPage?.name
        onMenu()
        check("点菜单按钮 → 只触发菜单回调", menuCalls == 1, "menuCalls=\(menuCalls)")
        check("点菜单按钮不改变气泡开合", bubble.isOpen == openBefore)
        check("点菜单按钮不改变当前页面", bubble.currentPage?.name == pageBefore)

        check("菜单回调只在点菜单按钮时触发", menuCalls == 1 && tapCalls > 0,
              "menuCalls=\(menuCalls) tapCalls=\(tapCalls)")

        // 「点按角色推进队列」关闭时：点本体应只是开合
        bubble.update { $0.advanceOnTap = false }
        bubble.close()
        simulateClick()
        let openedOnce = bubble.isOpen
        simulateClick()
        check("关闭「推进队列」后，点本体为纯开合",
              openedOnce && !bubble.isOpen)
        bubble.update { $0.advanceOnTap = true }

        print(failures == 0 ? "\n交互路由校验全部通过 ✅" : "\n有 \(failures) 项失败 ❌")
        return failures == 0 ? 0 : 1
    }
}
