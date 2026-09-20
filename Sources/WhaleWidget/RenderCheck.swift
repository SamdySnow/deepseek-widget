import AppKit
import Foundation
import SwiftUI

/// 离屏渲染校验：把挂件（含气泡）渲染成 PNG，并对像素做断言。
/// 用法：`WhaleWidget --render <输出目录>`
/// 这样无需人工截图即可验证「气泡形状 / 描边 / 文字 / 角色图」确实画出来了。
@MainActor
enum RenderCheck {

    static func run(outputDir: String) -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "  ✅ \(name)\(detail.isEmpty ? "" : " — \(detail)")"
                     : "  ❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let store = WhaleStore()
        let bubble = BubbleRuntime()

        print("== 离屏渲染 ==")

        // 1) 只有小鲸鱼（气泡收起）
        bubble.close()
        let closed = render(store: store, bubble: bubble, side: 450)
        check("渲染挂件（气泡收起）", closed != nil)
        if let closed {
            write(closed, to: "\(outputDir)/panel-closed.png")
            let stats = analyze(closed)
            check("角色图已绘制（存在不透明像素）", stats.opaqueRatio > 0.01,
                  String(format: "不透明像素占比 %.1f%%", stats.opaqueRatio * 100))
            check("气泡收起时没有白色填充区域", stats.whiteRatio < 0.02,
                  String(format: "白色占比 %.2f%%", stats.whiteRatio * 100))
        }

        // 2) 出泡（首次点击泡）
        bubble.handleTap(menuHidden: false)
        let open = render(store: store, bubble: bubble, side: 450)
        check("渲染挂件（出泡）", open != nil)
        if let open {
            write(open, to: "\(outputDir)/panel-open.png")
            let stats = analyze(open)
            check("气泡已绘制出白色填充", stats.whiteRatio > 0.05,
                  String(format: "白色占比 %.2f%%", stats.whiteRatio * 100))
            check("气泡描边已绘制（#203170 深蓝像素）", stats.strokeRatio > 0.002,
                  String(format: "深蓝描边占比 %.3f%%", stats.strokeRatio * 100))
            check("文字已绘制（深蓝系像素）", stats.textPixelCount > 500,
                  "文字像素 \(stats.textPixelCount)")
            // 布局：气泡应位于左上，角色图位于右下（与参考实现一致）
            check("气泡位于左上半区",
                  stats.whiteCentroid.x < 0.55 && stats.whiteCentroid.y < 0.60,
                  String(format: "白色质心 (%.2f, %.2f)", stats.whiteCentroid.x, stats.whiteCentroid.y))
            check("角色图位于右下半区",
                  stats.whaleCentroid.x > 0.55 && stats.whaleCentroid.y > 0.45,
                  String(format: "角色质心 (%.2f, %.2f)", stats.whaleCentroid.x, stats.whaleCentroid.y))
        }

        // 文字必须落在气泡内部 —— 单独渲染气泡层来测。
        // 不能拿整块面板测：小鲸鱼角色图既有白色也有深蓝像素，
        // 会同时污染「气泡包围盒」与「文字包围盒」（第一版就是这么误报的）。
        if let bubbleOnly = renderBubbleLayer(store: store, bubble: bubble, panelWidth: 450) {
            write(bubbleOnly, to: "\(outputDir)/bubble-only.png")
            let stats = analyze(bubbleOnly)
            if let tb = stats.darkTextBounds, let bb = stats.whiteBounds {
                let inside = tb.minX >= bb.minX && tb.maxX <= bb.maxX
                    && tb.minY >= bb.minY && tb.maxY <= bb.maxY
                check("气泡文字完整落在气泡内部", inside,
                      String(format: "文字 x[%.3f,%.3f] y[%.3f,%.3f] vs 气泡 x[%.3f,%.3f] y[%.3f,%.3f]",
                             tb.minX, tb.maxX, tb.minY, tb.maxY,
                             bb.minX, bb.maxX, bb.minY, bb.maxY))
                let marginX = min(tb.minX - bb.minX, bb.maxX - tb.maxX)
                let marginY = min(tb.minY - bb.minY, bb.maxY - tb.maxY)
                check("文字与气泡边缘留有边距（未被撑满）",
                      marginX > 0.02 && marginY > 0.02,
                      String(format: "左右最小边距 %.1f%%，上下最小边距 %.1f%%",
                             marginX * 100, marginY * 100))
            } else {
                check("能取到文字与气泡的包围盒", false,
                      "text=\(stats.darkTextBounds != nil) bubble=\(stats.whiteBounds != nil)")
            }
        } else {
            check("能单独渲染气泡层", false)
        }

        // 峰谷时段应在最后一行：验证默认配置的行序
        let rows = bubble.config.first.rows
        let kinds = rows.flatMap { $0.modules.map(\.kind) }
        check("峰谷时段字段排在最后", kinds.last == .peak,
              kinds.map(\.title).joined(separator: " → "))
        check("默认泡泡共 4 行", rows.count == 4, "\(rows.count) 行")

        // 余额字号应当是全泡最大的（用户要求「余额的显示字体稍微大一点」）
        let balanceSize = rows.flatMap { $0.modules }
            .first { $0.kind == .balance }?.style.unitMultiplier ?? 0
        let otherSizes = rows.flatMap { $0.modules }
            .filter { $0.kind != .balance }
            .map(\.style.unitMultiplier)
        check("余额字号大于其它各行",
              otherSizes.allSatisfy { balanceSize > $0 },
              "余额 \(Int(balanceSize))u，其它 \(otherSizes.map { Int($0) }.sorted())u")

        // 文字在各缩放档位下都必须留在气泡内部
        for scale in [0.6, 1.0, 1.8, 3.0] {
            let side = panelSide(scale: scale)
            guard let layer = renderBubbleLayer(store: store, bubble: bubble,
                                                panelWidth: side) else {
                check("\(scale)× 可单独渲染气泡层", false); continue
            }
            let stats = analyze(layer)
            if let tb = stats.darkTextBounds, let bb = stats.whiteBounds {
                let inside = tb.minX >= bb.minX && tb.maxX <= bb.maxX
                    && tb.minY >= bb.minY && tb.maxY <= bb.maxY
                check("\(scale)× 下文字仍在气泡内部", inside,
                      String(format: "文字底 %.3f / 气泡底 %.3f", tb.maxY, bb.maxY))
            } else {
                check("\(scale)× 能取到文字与气泡包围盒", false)
            }
        }

        // 3) 每轮消耗泡泡（`{cost}` 替换）
        bubble.dismissTransient()
        bubble.showTurnCost(0.1234, closeAfter: 0, text: "本轮消耗 ¥ {cost}")
        let cost = render(store: store, bubble: bubble, side: 450)
        if let cost {
            write(cost, to: "\(outputDir)/bubble-turn-cost.png")
            check("消耗泡泡渲染成功", analyze(cost).whiteRatio > 0.05)
        }
        check("`{cost}` 占位符已替换", bubble.costText == "0.1234")

        // 3b) 点击序列的每一页都必须真的显示出来。
        // 用户反馈过「点两下气泡直接消失」—— 这里逐页渲染，确认每一页都有可见内容，
        // 避免「页面切过去了但画不出来」看起来像消失。
        bubble.dismissTransient()
        bubble.close()
        // 序列共 pageNames.count 页（首次点击泡 + 队列），逐页点击并渲染。
        // 注意：点完最后一页后再点一次会收起，那是设计行为，不该当成失败。
        let pageCount = 1 + bubble.config.queue.count
        for step in 1...pageCount {
            bubble.handleTap(menuHidden: false)
            guard bubble.isOpen, let page = bubble.currentPage else {
                check("第 \(step) 次点击后气泡仍展开（应共 \(pageCount) 页）", false,
                      "isOpen=false")
                break
            }
            guard let img = render(store: store, bubble: bubble, side: 450) else {
                check("第 \(step) 次点击后（\(page.name)）可渲染", false)
                break
            }
            write(img, to: "\(outputDir)/sequence-\(step)-\(page.name).png")
            let s = analyze(img)
            // 气泡白底或其中文字至少要有一样明显可见
            let visible = s.whiteRatio > 0.03 || s.textPixelCount > 300
            check("第 \(step) 次点击后（\(page.name)）气泡可见",
                  visible,
                  String(format: "白色 %.2f%% / 文字 %d 像素 / 行数 %d",
                         s.whiteRatio * 100, s.textPixelCount, page.rows.count))
        }
        // 走完所有页后再点一次才收起
        bubble.handleTap(menuHidden: false)
        check("遍历完 \(pageCount) 页后再点才收起", !bubble.isOpen,
              "第 \(pageCount + 1) 次点击后 isOpen=\(bubble.isOpen)")

        // 4) 多个缩放档位都能渲染
        for scale in [0.6, 1.0, 3.0] {
            var cfg = store.config
            cfg.scale = scale
            let side = panelSide(scale: scale)
            let image = render(store: store, bubble: bubble, side: side)
            check("缩放 \(scale)× 可渲染（边长 \(Int(side))px）", image != nil)
        }

        // 5) 锁定角标：锁定后整块面板都不响应鼠标，界面上必须有可见反馈，
        //    否则用户会以为挂件坏了。这里用「菜单按钮区域出现白色像素」来判定 ——
        //    菜单按钮在锁定态会被隐藏、改由角标占据同一位置。
        //    用差分而不是绝对阈值：先把两个状态都渲染出来再比，避免受缩放 / 主题影响。
        store.update { $0.locked = false; $0.menuButtonHidden = true; $0.opacity = 1.0 }
        let unlocked = render(store: store, bubble: bubble, side: 450)
        store.update { $0.locked = true }
        let locked = render(store: store, bubble: bubble, side: 450)
        if let unlocked, let locked {
            write(locked, to: "\(outputDir)/panel-locked.png")
            let whiteUnlocked = whiteInButtonRect(unlocked)
            let whiteLocked = whiteInButtonRect(locked)
            check("锁定后在菜单按钮位置画出锁定角标（比未锁定时更亮）",
                  whiteLocked > whiteUnlocked,
                  String(format: "按钮区白色像素 未锁定 %d → 锁定 %d", whiteUnlocked, whiteLocked))
            check("锁定角标确实可见（该区域有明显白色像素）", whiteLocked > 100,
                  "\(whiteLocked) 像素")
        } else {
            check("能渲染锁定态", false)
        }
        store.update { $0.locked = false; $0.menuButtonHidden = false }

        // 6) 不透明度要真的改变渲染像素（用户看到的就是这一层）。
        //    下限不为 0 是刻意的：完全透明会让挂件「消失」而用户未必记得有这个滑块。
        let full = render(store: store, bubble: bubble, side: 450)
        store.update { $0.opacity = AppConfig.opacityRange.lowerBound }
        let faint = render(store: store, bubble: bubble, side: 450)
        store.update { $0.opacity = 1.0 }
        if let full, let faint, let fullRep = bitmap(full), let faintRep = bitmap(faint) {
            let fullMax = maxAlpha(fullRep)
            let faintMax = maxAlpha(faintRep)
            check("不透明度会改变渲染像素（不只是改了配置值）",
                  faintMax < fullMax,
                  String(format: "最大 alpha %.2f → %.2f", fullMax, faintMax))
            check("下限 \(AppConfig.opacityRange.lowerBound) 时仍可见（不为 0）",
                  faintMax > 0.1,
                  String(format: "最大 alpha %.2f", faintMax))
        } else {
            check("能渲染不透明度的两个档位", false)
        }

        // 5) 贴左镜像：**只翻转朝向，不翻转内容**。
        //
        // 参考实现的语义（也是用户报过的 bug）：
        //   `.dshwv-root.dshwv-left{transform:scaleX(-1)}`      ← 整机翻
        //   `.dshwv-left .dshwv-text{transform:scaleX(-1)}`     ← 文字反翻回来
        //   `.dshwv-left .dshwv-gif{transform:scaleX(-1)}`      ← 图片同理
        // 小鲸鱼翻过去朝向屏幕内侧，但**文字与图片必须仍然正向可读**。
        //
        // 怎么验？**单独渲染气泡层**（不含小鲸鱼）—— 小鲸鱼自己也是深蓝色、
        // 还有大片白色，任何在全图里找「文字」的判据都会把鲸鱼算进来
        // （本轮先后试过白色包围盒 / 全图深蓝像素 / 差值法，都被它污染，
        // 甚至量出过镜像前后完全相同的数值）。
        //
        // 隔离之后结论就非常干脆：
        //   反翻的本质就是「把内容水平翻一次」，所以
        //     BubbleLayer(mirrored: true)  必须等于
        //     `BubbleLayer(mirrored: false)` 的水平翻转。
        //   若哪天有人删掉反翻，两者会变得**完全相同** → 这条断言立刻变红。
        let savedPage = bubble.config.first
        bubble.close()
        var probeVariant = BubbleVariant()
        probeVariant.rows = [BubbleRow(modules: [
            BubbleModule(kind: .text, text: "DSH-镜像验证"),
        ])]
        bubble.update { $0.first = BubblePage(name: "镜像测试", variants: [probeVariant]) }
        bubble.handleTap(menuHidden: false)   // 出泡，否则气泡层渲染不出内容

        let plainLayer = renderBubbleLayerOnly(store: store, bubble: bubble,
                                              panelWidth: 450, mirrored: false)
        let flippedLayer = renderBubbleLayerOnly(store: store, bubble: bubble,
                                                panelWidth: 450, mirrored: true)
        if let a = plainLayer, let b = flippedLayer {
            write(a, to: "\(outputDir)/bubble-unmirrored.png")
            write(b, to: "\(outputDir)/bubble-mirrored.png")

            let differs = imageDifferenceRatio(a, b)
            check("反翻确实起了作用（镜像与未镜像的气泡层不同）", differs > 0.02,
                  String(format: "像素差异 %.1f%%（若为 0 说明反翻被删掉了）", differs * 100))

            // 核心断言：镜像态下的**文字朝向**必须与未镜像一致（即仍然可读）。
            //
            // 判据用「位置无关的字形掩码」：把文字像素归一化到自身包围盒，
            // 采样成 N×N 的布尔网格，再比较两个朝向的掩码：
            //   同向  → 掩码相同（文字可读，只是位置变了）
            //   翻反  → 掩码等于「镜像后的掩码」（文字被翻反，即用户报的 bug）
            // 这样比较不受气泡整体挪位的影响，也不会被泡泡形状自身的翻转干扰。
            if let mPlain = textGlyphMask(a), let mFlipped = textGlyphMask(b) {
                let same = hamming(mPlain, mFlipped)
                let flip = hamming(mPlain, mirrorMask(mFlipped))
                check("镜像后文字朝向与未镜像一致（同向差异 < 翻反差异）", same < flip,
                      String(format: "同向差异 %.1f%% vs 翻反差异 %.1f%%",
                             same * 100, flip * 100))
                check("镜像后文字确实可读（与未镜像字形高度吻合）", same < 0.15,
                      String(format: "同向差异 %.1f%%", same * 100))
            } else {
                check("能提取文字字形掩码", false)
            }
        } else {
            check("能单独渲染气泡层（含镜像态）", false)
        }

        // ★ 关键：上面那两条只验了「气泡层自身」，**验不到「文字相对泡泡是否居中」**——
        // 因为两处镜像是在**不同的嵌套/顺序**下生效的，只有整块面板的复合结果
        // 才暴露问题（曾经：气泡层单测全绿，实机上文字却偏了约 50px）。
        // 所以这里必须渲染**整块面板**再量偏移。
        //
        // 判据用「相对偏移」而不是绝对值：一段文字自身的墨迹本来就不在字形盒中心，
        // 但**同一个气泡形状下的相对偏移**应当与朝向无关。取「文字重心 − 气泡填充重心」，
        // 两个朝向的结果应当几乎相同。
        let panelPlain = render(store: store, bubble: bubble, side: 450)
        let panelMirror: NSImage? = {
            let saved = store.config.lastSide
            store.update { $0.lastSide = "left" }
            let img = render(store: store, bubble: bubble, side: 450)
            store.update { $0.lastSide = saved }
            return img
        }()
        if let pp = panelPlain, let pm = panelMirror {
            write(pm, to: "\(outputDir)/panel-bubble-mirrored.png")
            if let cPlain = textCentroidX(pp), let cMirror = textCentroidX(pm) {
                // 文字应当落在**泡泡椭圆的中心**，而椭圆中心并不在面板正中 ——
                // 它在气泡盒的 `textAreaCenterX`（0.4425，即 SVG 里的 454/1026）。
                // 镜像后整块面板翻转，椭圆中心随之到 `1 - 0.4425 = 0.5575`。
                // 所以「居中」的期望值本身是随朝向变的 —— 不能拿面板中线 0.5 当基准
                // （拿 0.5 比会得出一个假的 52px 偏差，那其实只是泡泡自己挪了位置）。
                let cx = BubbleLayer.textAreaCenterX
                let expectPlain = cx
                let expectMirror = 1 - cx
                check("未镜像时文字落在泡泡中心",
                      abs(cPlain - expectPlain) < 0.05,
                      String(format: "重心 x=%.4f（期望 %.4f，偏 %.1fpx）",
                             cPlain, expectPlain, (cPlain - expectPlain) * 450))
                check("镜像后文字**仍然**落在泡泡中心（本轮修复的正是这条）",
                      abs(cMirror - expectMirror) < 0.05,
                      String(format: "重心 x=%.4f（期望 %.4f，偏 %.1fpx）",
                             cMirror, expectMirror, (cMirror - expectMirror) * 450))
                // 换算到「相对泡泡中心」的偏移，两个朝向应当一致
                let relPlain = cPlain - expectPlain
                let relMirror = cMirror - expectMirror
                check("两个朝向的文字相对泡泡中心的偏移一致",
                      abs(relPlain - relMirror) < 0.03,
                      String(format: "未镜像 %+.4f vs 镜像 %+.4f", relPlain, relMirror))
            } else {
                check("能从整块面板量出文字重心", false)
            }
        } else {
            check("能渲染整块面板（含镜像态）", false)
        }
        bubble.update { $0.first = savedPage }
        bubble.close()

        // 对照：小鲸鱼**必须**确实翻过去了（否则这次「修复」就成了把翻转整个去掉）。
        // 用「角色图区域内不透明像素的重心」判断：鲸鱼左右不对称，镜像后重心换侧。
        store.update { $0.mirrorOnLeftSnap = true }
        store.update { $0.lastSide = "right" }
        let whaleRight = render(store: store, bubble: bubble, side: 450)
        store.update { $0.lastSide = "left" }
        let whaleLeft = render(store: store, bubble: bubble, side: 450)
        store.update { $0.lastSide = "right" }
        if let wr = whaleRight, let wl = whaleLeft,
           let cxR = whaleCentroidX(wr), let cxL = whaleCentroidX(wl) {
            check("小鲸鱼确实被翻过去了（整机镜像仍然生效）",
                  abs(cxR - cxL) > 0.05,
                  String(format: "鲸鱼重心 x %.3f → %.3f", cxR, cxL))
        } else {
            check("能渲染整机镜像对照", false)
        }

        // 关掉「贴左镜像翻转」开关后，整机不应再翻转（鲸鱼重心不动）
        store.update { $0.mirrorOnLeftSnap = false }
        let noMirrorR = render(store: store, bubble: bubble, side: 450)
        store.update { $0.lastSide = "left" }
        let noMirrorL = render(store: store, bubble: bubble, side: 450)
        store.update { $0.lastSide = "right"; $0.mirrorOnLeftSnap = true }
        if let nr = noMirrorR, let nl = noMirrorL,
           let cR = whaleCentroidX(nr), let cL = whaleCentroidX(nl) {
            check("关掉开关后贴左也不翻转（鲸鱼重心不动）", abs(cR - cL) < 0.001,
                  String(format: "重心 %.3f → %.3f", cR, cL))
        } else {
            check("能渲染「关掉镜像」对照", false)
        }

        print(failures == 0 ? "\n渲染校验全部通过 ✅" : "\n有 \(failures) 项失败 ❌")
        return failures == 0 ? 0 : 1
    }

    /// 提取文字的「位置无关字形掩码」：先取深蓝文字像素的包围盒，
    /// 再归一化采样成 `n×n` 布尔网格。
    ///
    /// 归一化到包围盒是关键 —— 镜像会把气泡整体挪到面板另一侧，
    /// 直接比对绝对坐标会得到一大堆差异（那是位置差，不是朝向差）。
    /// 归一化之后，同一段文字无论被摆在哪里，掩码都相同；
    /// 而**被翻反**的文字，掩码会等于原掩码的镜像 —— 这正是要判别的差异。
    private static func textGlyphMask(_ image: NSImage, n: Int = 24,
                                      threshold: Double = 0.35) -> [[Bool]]? {
        guard let rep = bitmap(image) else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh

        // ① 找深蓝文字像素的包围盒
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                let r = Int(c.redComponent * 255), g = Int(c.greenComponent * 255)
                let bl = Int(c.blueComponent * 255)
                guard bl > r + 18, bl > g + 14, bl > 70, r < 190 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        let bw = maxX - minX + 1, bh = maxY - minY + 1

        // ② 归一化采样：每个格子看该区域是否以深蓝像素为主
        var mask = [[Bool]](repeating: [Bool](repeating: false, count: n), count: n)
        for gy in 0..<n {
            for gx in 0..<n {
                let x0 = minX + bw * gx / n, x1 = minX + max(x0 + 1, bw * (gx + 1) / n)
                let y0 = minY + bh * gy / n, y1 = minY + max(y0 + 1, bh * (gy + 1) / n)
                var ink = 0, cells = 0
                for y in y0..<min(y1, h) {
                    for x in x0..<min(x1, w) {
                        cells += 1
                        guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                        let r = Int(c.redComponent * 255), g = Int(c.greenComponent * 255)
                        let bl = Int(c.blueComponent * 255)
                        if bl > r + 18, bl > g + 14, bl > 70, r < 190 { ink += 1 }
                    }
                }
                mask[gy][gx] = cells > 0 && Double(ink) / Double(cells) > threshold
            }
        }
        return mask
    }

    /// 两个掩码的差异比例（0 = 完全相同）。
    private static func hamming(_ a: [[Bool]], _ b: [[Bool]]) -> Double {
        guard a.count == b.count, let cols = a.first?.count, cols == b.first?.count else { return 1 }
        var diff = 0, total = 0
        for y in 0..<a.count {
            for x in 0..<cols {
                total += 1
                if a[y][x] != b[y][x] { diff += 1 }
            }
        }
        return total > 0 ? Double(diff) / Double(total) : 1
    }

    /// 掩码的水平镜像（用于判定「文字是否被翻反」）。
    private static func mirrorMask(_ a: [[Bool]]) -> [[Bool]] {
        a.map { $0.reversed() }
    }

    /// 文字墨迹重心的归一化 x（**只在气泡上半部统计**）。
    ///
    /// 为什么要限制纵向范围：整块面板里**小鲸鱼也是深蓝**，
    /// 不限制的话量到的其实是鲸鱼（本轮又踩了一次 —— 镜像前后得到 ±0.21
    /// 这种「恰好反号」的数，正是"量到了跟随镜像一起翻的鲸鱼"的指纹）。
    /// 气泡占 y ∈ [0, 0.682]，鲸鱼从 y = 0.4055 开始，所以取 `y < 0.40`
    /// 这段既在气泡内、又完全避开鲸鱼；文字区本身在 y ∈ [0.04, 0.396]，也落在这里。
    private static func textCentroidX(_ image: NSImage) -> Double? {
        guard let rep = bitmap(image) else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let yLimit = Int(Double(h) * 0.40)
        var sum = 0.0, n = 0
        for y in 0..<yLimit {
            for x in 0..<w {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                let r = Int(c.redComponent * 255), g = Int(c.greenComponent * 255)
                let bl = Int(c.blueComponent * 255)
                guard bl > r + 18, bl > g + 14, bl > 70, r < 190 else { continue }
                sum += Double(x) / Double(w)
                n += 1
            }
        }
        return n > 0 ? sum / Double(n) : nil
    }

    /// 单独渲染气泡层（**不含小鲸鱼与菜单按钮**），可选镜像态。
    ///
    /// 之所以要能渲染镜像态：验「文字有没有被反翻回来」时，
    /// 只要有鲸鱼在画面里，任何「找文字像素」的判据都会被鲸鱼（也是深蓝 + 大片白）
    /// 污染。隔离到只剩气泡层，结论就干净了。
    private static func renderBubbleLayerOnly(store: WhaleStore, bubble: BubbleRuntime,
                                             panelWidth: CGFloat,
                                             mirrored: Bool) -> NSImage? {
        guard bubble.isOpen else { return nil }
        let unit = panelWidth / BubbleShape.viewBox.width
        let view = BubbleLayer(store: store, bubble: bubble, unit: unit, mirrored: mirrored)
            .frame(width: panelWidth,
                   height: panelWidth * BubbleShape.viewBox.height / BubbleShape.viewBox.width)
            .background(Color.clear)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.nsImage
    }

    /// 两张图的差异像素占比（形状一致时应当很小）。
    private static func imageDifferenceRatio(_ x: NSImage, _ y: NSImage) -> Double {
        guard let a = bitmap(x), let b = bitmap(y),
              a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 1 }
        var diff = 0, total = 0
        for yy in stride(from: 0, to: a.pixelsHigh, by: 2) {
            for xx in stride(from: 0, to: a.pixelsWide, by: 2) {
                guard let ca = a.colorAt(x: xx, y: yy), let cb = b.colorAt(x: xx, y: yy) else { continue }
                total += 1
                let d = abs(Double(ca.alphaComponent) - Double(cb.alphaComponent))
                    + abs(Double(ca.redComponent) - Double(cb.redComponent))
                    + abs(Double(ca.greenComponent) - Double(cb.greenComponent))
                    + abs(Double(ca.blueComponent) - Double(cb.blueComponent))
                if d > 0.15 { diff += 1 }
            }
        }
        return total > 0 ? Double(diff) / Double(total) : 1
    }

    /// 角色图（小鲸鱼）区域内不透明像素的归一化重心 x。
    ///
    /// 为什么这么做：小鲸鱼本身既深蓝又有大片白色，任何「全图找深蓝像素」或
    /// 「全图找白色包围盒」的判据都会把鲸鱼算进来（本轮先后踩了这两个坑，
    /// 甚至得到过镜像前后**完全相同**的数值）。用**差值**就精确了：
    /// 出泡与收泡两张图里鲸鱼完全一致，相减即把它消掉，只剩气泡像素。
    ///
    /// 两个都必须处理的细节：
    /// 1. 相减的两张图**朝向必须相同** —— 否则鲸鱼没被消掉，差值会覆盖整块面板
    ///    （最初把「镜像出泡」与「未镜像收泡」相减，量出 59 万像素的"气泡"）。
    /// 2. 还要**排除泡泡自身的描边** —— 描边也是深蓝、且左右对称，
    ///    会把文字的不对称度稀释到接近 0。按包围盒内缩 15% 即可避开描边带。
    ///
    /// - Returns: `asymmetry` = 文字包围盒内的 `(右半−左半)/总数`。
    ///   水平翻转文字会使其变号，因此可用「是否变号」判定文字有没有被翻反。
    private static func bubbleTextAsymmetry(open: NSImage,
                                            closed: NSImage) -> (asymmetry: Double, total: Int)? {
        guard let a = bitmap(open), let b = bitmap(closed),
              a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return nil }
        let w = a.pixelsWide, h = a.pixelsHigh

        // ① 差值定位气泡（鲸鱼被消掉）
        var bubbleMinX = w, bubbleMaxX = 0, bubbleMinY = h, bubbleMaxY = 0
        var bubblePixels = 0
        for y in 0..<h {
            for x in 0..<w {
                guard let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y) else { continue }
                let da = abs(Double(ca.alphaComponent) - Double(cb.alphaComponent))
                let dr = abs(Double(ca.redComponent) - Double(cb.redComponent))
                let dg = abs(Double(ca.greenComponent) - Double(cb.greenComponent))
                let db = abs(Double(ca.blueComponent) - Double(cb.blueComponent))
                guard da > 0.25 || dr > 0.15 || dg > 0.15 || db > 0.15 else { continue }
                bubblePixels += 1
                bubbleMinX = min(bubbleMinX, x); bubbleMaxX = max(bubbleMaxX, x)
                bubbleMinY = min(bubbleMinY, y); bubbleMaxY = max(bubbleMaxY, y)
            }
        }
        guard bubblePixels > 200 else { return nil }

        // ② 内缩避开描边带（描边是深蓝且左右对称，留着会把信号稀释掉）
        let insetX = Int(Double(bubbleMaxX - bubbleMinX) * 0.15)
        let insetY = Int(Double(bubbleMaxY - bubbleMinY) * 0.15)
        let innerMinX = bubbleMinX + insetX, innerMaxX = bubbleMaxX - insetX
        let innerMinY = bubbleMinY + insetY, innerMaxY = bubbleMaxY - insetY
        guard innerMaxX > innerMinX, innerMaxY > innerMinY else { return nil }
        let midX = (innerMinX + innerMaxX) / 2

        // ③ 只统计深蓝系文字像素
        var left = 0, right = 0
        for y in innerMinY...innerMaxY {
            for x in innerMinX...innerMaxX {
                guard let c = a.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                let r = Int(c.redComponent * 255), g = Int(c.greenComponent * 255)
                let bl = Int(c.blueComponent * 255)
                guard bl > r + 18, bl > g + 14, bl > 70, r < 190 else { continue }
                if x < midX { left += 1 } else { right += 1 }
            }
        }
        let total = left + right
        guard total > 50 else { return nil }
        return (Double(right - left) / Double(total), total)
    }

    /// 角色图（小鲸鱼）区域内不透明像素的归一化重心 x。
    /// 鲸鱼左右不对称，镜像后重心会明显换到另一侧 —— 用它证明整机确实翻了。
    private static func whaleCentroidX(_ image: NSImage) -> Double? {
        guard let rep = bitmap(image) else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let r = Positioning.whaleRectNormalized
        var sum = 0.0, n = 0
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let nx = Double(x) / Double(w)
                let ny = Double(y) / Double(h)
                guard r.contains(CGPoint(x: nx, y: ny)) else { continue }
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                sum += nx; n += 1
            }
        }
        return n > 0 ? sum / Double(n) : nil
    }

    /// 菜单按钮所在矩形内的白色像素数（用于判定锁定角标是否画出来了）。
    private static func whiteInButtonRect(_ image: NSImage) -> Int {
        guard let rep = bitmap(image) else { return 0 }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let rect = Positioning.menuButtonRectNormalized
        var count = 0
        for y in 0..<h {
            for x in 0..<w {
                let nx = Double(x) / Double(w)
                let ny = Double(y) / Double(h)
                guard rect.contains(CGPoint(x: nx, y: ny)) else { continue }
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                if c.redComponent > 0.9, c.greenComponent > 0.9, c.blueComponent > 0.9 {
                    count += 1
                }
            }
        }
        return count
    }

    private static func bitmap(_ image: NSImage) -> NSBitmapImageRep? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    private static func maxAlpha(_ rep: NSBitmapImageRep) -> Double {
        var maxA = 0.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                maxA = Swift.max(maxA, Double(c.alphaComponent))
            }
        }
        return maxA
    }

    /// 与 PanelController.panelSide() 保持一致。
    private static func panelSide(scale: Double) -> CGFloat {
        let s = max(0.6, min(3.0, scale))
        let base = min(250, min(NSScreen.main?.frame.width ?? 1440,
                                NSScreen.main?.frame.height ?? 900) * 0.28)
        return max(122, base * s)
    }

    private static func render(store: WhaleStore, bubble: BubbleRuntime, side: CGFloat) -> NSImage? {
        let view = WhalePanelView(store: store, bubble: bubble,
                                  interaction: PanelInteraction(),
                                  onMenu: {})
            .frame(width: side, height: side)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = false
        return renderer.nsImage
    }

    /// 只渲染气泡层（不含小鲸鱼 / 菜单按钮），用于精确测量文字与气泡的关系。
    private static func renderBubbleLayer(store: WhaleStore, bubble: BubbleRuntime,
                                          panelWidth: CGFloat) -> NSImage? {
        guard bubble.isOpen else { return nil }
        let unit = panelWidth / BubbleShape.viewBox.width
        let view = BubbleLayer(store: store, bubble: bubble, unit: unit)
            .frame(width: panelWidth,
                   height: panelWidth * BubbleShape.viewBox.height / BubbleShape.viewBox.width)
            .background(Color.clear)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = false
        return renderer.nsImage
    }

    private static func write(_ image: NSImage, to path: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    struct Stats {
        var opaqueRatio: Double
        var whiteRatio: Double
        var strokeRatio: Double
        var textPixelCount: Int
        /// 气泡白色区域的质心（归一化 0..1，y 向下）
        var whiteCentroid: CGPoint = .zero
        /// 角色图非白不透明区域的质心
        var whaleCentroid: CGPoint = .zero
        /// 气泡（白色填充）的归一化包围盒
        var whiteBounds: CGRect?
        /// 深蓝文字的归一化包围盒
        var darkTextBounds: CGRect?
    }

    /// 统计像素构成：白色（气泡填充）、#203170（描边 / 文字）、深蓝系（文字），
    /// 并计算气泡与角色图的质心 / 包围盒用于布局断言。
    ///
    /// 注意：小鲸鱼角色图本身也是深蓝色，所以「文字包围盒」必须在**气泡区域内**
    /// 统计，否则会把角色图算成文字（第一版就是这么误报的）。
    private static func analyze(_ image: NSImage) -> Stats {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return Stats(opaqueRatio: 0, whiteRatio: 0, strokeRatio: 0, textPixelCount: 0)
        }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let total = max(1, w * h)
        let sampled = Double(total / 4)

        var opaque = 0, white = 0, stroke = 0, text = 0
        var whiteX = 0.0, whiteY = 0.0
        var whaleX = 0.0, whaleY = 0.0, whaleN = 0.0
        var whiteMinX = Double.greatestFiniteMagnitude, whiteMaxX = -1.0
        var whiteMinY = Double.greatestFiniteMagnitude, whiteMaxY = -1.0

        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                guard c.alphaComponent > 0.5 else { continue }
                opaque += 1
                let r = Int(c.redComponent * 255)
                let g = Int(c.greenComponent * 255)
                let b = Int(c.blueComponent * 255)
                let nx = Double(x) / Double(w)
                let ny = Double(y) / Double(h)

                if r > 240, g > 240, b > 240 {
                    white += 1
                    whiteX += nx; whiteY += ny
                    whiteMinX = min(whiteMinX, nx); whiteMaxX = max(whiteMaxX, nx)
                    whiteMinY = min(whiteMinY, ny); whiteMaxY = max(whiteMaxY, ny)
                } else {
                    // 非白色不透明像素 ≈ 角色图 / 描边 / 文字
                    whaleX += nx; whaleY += ny; whaleN += 1
                }
                // #203170 = (32, 49, 112)
                if abs(r - 32) < 26, abs(g - 49) < 26, abs(b - 112) < 30 { stroke += 1 }
            }
        }

        let whiteBounds = whiteMaxX > 0
            ? CGRect(x: whiteMinX, y: whiteMinY,
                     width: whiteMaxX - whiteMinX, height: whiteMaxY - whiteMinY)
            : nil

        // 第二遍：只在气泡「内圈」统计文字包围盒。
        // 必须跳过描边带：泡泡描边本身是 #203170，其内侧抗锯齿像素也偏深蓝，
        // 紧贴白色区域边界统计会把描边误当成文字（第一版就因此得出 0 边距）。
        // 描边宽 18 单位，在 viewBox 1026 宽下约 1.8% 图像宽度，这里内缩 3% 以稳妥跳过。
        let inset = 0.03
        var textMinX = Double.greatestFiniteMagnitude, textMaxX = -1.0
        var textMinY = Double.greatestFiniteMagnitude, textMaxY = -1.0
        if let bb = whiteBounds {
            let inner = bb.insetBy(dx: bb.width * inset, dy: bb.height * inset)
            for y in stride(from: 0, to: h, by: 2) {
                for x in stride(from: 0, to: w, by: 2) {
                    let nx = Double(x) / Double(w)
                    let ny = Double(y) / Double(h)
                    guard nx >= inner.minX, nx <= inner.maxX,
                          ny >= inner.minY, ny <= inner.maxY else { continue }
                    guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                    let r = Int(c.redComponent * 255)
                    let g = Int(c.greenComponent * 255)
                    let b = Int(c.blueComponent * 255)
                    // 深蓝系文字（含抗锯齿过渡色），排除白色气泡底
                    guard b > r + 18, b > g + 14, b > 70, r < 190 else { continue }
                    text += 1
                    textMinX = min(textMinX, nx); textMaxX = max(textMaxX, nx)
                    textMinY = min(textMinY, ny); textMaxY = max(textMaxY, ny)
                }
            }
        }

        return Stats(
            opaqueRatio: Double(opaque) / sampled,
            whiteRatio: Double(white) / sampled,
            strokeRatio: Double(stroke) / sampled,
            textPixelCount: text,
            whiteCentroid: white > 0 ? CGPoint(x: whiteX / Double(white), y: whiteY / Double(white)) : .zero,
            whaleCentroid: whaleN > 0 ? CGPoint(x: whaleX / whaleN, y: whaleY / whaleN) : .zero,
            whiteBounds: whiteBounds,
            darkTextBounds: textMaxX > 0
                ? CGRect(x: textMinX, y: textMinY,
                         width: textMaxX - textMinX, height: textMaxY - textMinY)
                : nil
        )
    }
}
