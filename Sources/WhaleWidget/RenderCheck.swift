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

        print(failures == 0 ? "\n渲染校验全部通过 ✅" : "\n有 \(failures) 项失败 ❌")
        return failures == 0 ? 0 : 1
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
