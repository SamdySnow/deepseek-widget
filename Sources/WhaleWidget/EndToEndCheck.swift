import AppKit
import Foundation
import SwiftUI

/// 端到端自检：起真实窗口 + 真实控制器，用合成鼠标事件走完整链路。
///
/// 为什么需要它：单元测试里直接调 `bubble.handleTap()` 只能证明「状态机本身对」，
/// 无法覆盖「事件是否被重复投递」「命中遮罩是否把点击挡掉」这类接线问题 ——
/// 而「点两下气泡直接消失」恰恰是这一类。所以这里驱动的是
/// `WidgetContainerView.mouseDown/mouseUp`，走和真人点击完全相同的路径。
///
/// 用法：`WhaleWidget --e2e`
@MainActor
enum EndToEndCheck {

    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "  ✅ \(name)\(detail.isEmpty ? "" : " — \(detail)")"
                     : "  ❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let store = WhaleStore()
        let bubble = BubbleRuntime()
        bubble.close()
        let controller = PanelController(store: store, bubble: bubble)
        controller.moveOffscreenForTesting()
        // 真实使用中轮询、动画、SwiftUI 更新都在跑；这里也跑起来，
        // 否则「点击之间 runloop 做了什么」这条线索会被完全跳过。
        store.startAutoRefresh()

        let panel = controller.panelSideLength
        let container = controller.container!

        /// 合成一次完整的按下 → 松开（`to` 为 nil 表示原地点击）。
        /// 坐标是「视图坐标」（原点左下，AppKit 约定）。
        func click(at viewPoint: NSPoint, dragTo: NSPoint? = nil) {
            guard let down = mouseEvent(.leftMouseDown, at: viewPoint) else { return }
            container.mouseDown(with: down)
            pump(0.03)
            if let to = dragTo {
                guard let dragged = mouseEvent(.leftMouseDragged, at: to) else { return }
                container.mouseDragged(with: dragged)
                pump(0.03)
            }
            let end = dragTo ?? viewPoint
            guard let up = mouseEvent(.leftMouseUp, at: end) else { return }
            container.mouseUp(with: up)
            // 让动画 / asyncAfter / SwiftUI 更新都跑完，等价于两次真人点击的间隔
            pump(0.35)
        }

        /// 把当前挂件离屏渲染一遍，返回像素的最大 alpha。
        ///
        /// 之所以要**渲染像素**而不只读配置：不透明度的效果必须落在用户真正看到的
        /// 那层画面上。若把 opacity 挂错层级（例如挂在被后续 modifier 覆盖掉的位置），
        /// 配置值会是对的、渲染结果却不变 —— 只查配置就抓不到。
        func alphaSampler(_ opacity: Double) -> (maxAlpha: Double, meanAlpha: Double) {
            let view = WhalePanelView(store: store, bubble: bubble,
                                      interaction: PanelInteraction(),
                                      onMenu: {})
                .frame(width: panel, height: panel)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            renderer.isOpaque = false
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else {
                return (0, 0)
            }
            var maxAlpha = 0.0
            var sum = 0.0
            var count = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    let a = Double(c.alphaComponent)
                    maxAlpha = Swift.max(maxAlpha, a)
                    sum += a
                    count += 1
                }
            }
            return (maxAlpha, count > 0 ? sum / Double(count) : 0)
        }

        /// 小鲸鱼身体上一个「肯定有像素」的点（面板坐标，原点左上）。
        /// 取角色图中心：鲸鱼本体在那里，任何缩放下都命中。
        let bodyTopLeft = CGPoint(x: panel * 0.70, y: panel * 0.70)
        /// 换算成视图坐标（原点左下）
        let bodyView = NSPoint(x: bodyTopLeft.x, y: panel - bodyTopLeft.y)

        print("== 端到端：点击序列（真实窗口 + 合成事件）==")
        check("面板已建立", panel > 0, "边长 \(Int(panel))px")

        let queueCount = bubble.config.queue.count
        check("默认点击队列非空", queueCount >= 1, "\(queueCount) 项")

        // 第 1 次点击：应展开并显示「首次点击泡」
        click(at: bodyView)
        check("第 1 次点击 → 气泡展开", bubble.isOpen,
              bubble.isOpen ? bubble.currentPage?.name ?? "?" : "仍收起")
        check("第 1 次点击 → 显示首次点击泡",
              bubble.currentPage?.name == "首次点击泡",
              bubble.currentPage?.name ?? "nil")

        // 第 2 次点击：应推进到队列第 1 项，**而不是消失**
        click(at: bodyView)
        check("第 2 次点击 → 气泡仍然展开（这是用户反馈的问题）", bubble.isOpen,
              bubble.isOpen ? "展开" : "❌ 已收起")
        if queueCount >= 1 {
            check("第 2 次点击 → 推进到队列第 1 项",
                  bubble.currentPage?.name == bubble.config.queue[0].name,
                  bubble.currentPage?.name ?? "nil")
        }

        // 继续点到队列末尾，确认不会提前收起
        var steps = 2
        var guardCount = 0
        while bubble.isOpen && guardCount < 20 {
            let before = bubble.currentPage?.name
            click(at: bodyView)
            steps += 1
            guardCount += 1
            if bubble.isOpen && bubble.currentPage?.name == before {
                check("点击能持续推进（未卡住）", false, "停在 \(before ?? "nil")")
                break
            }
        }
        check("点击序列能走到末尾才收起", !bubble.isOpen, "共 \(steps) 次点击")
        check("收起后再点会重新展开",
              { click(at: bodyView); return bubble.isOpen && bubble.currentPage?.name == "首次点击泡" }())
        bubble.close()

        print("== 端到端：拖动不影响点击序列 ==")
        click(at: bodyView)
        let beforeDrag = bubble.currentPage?.name
        // 真实拖一段距离（视图坐标）
        click(at: bodyView,
              dragTo: NSPoint(x: bodyView.x - 60, y: bodyView.y - 40))
        check("拖动不推进气泡序列", bubble.currentPage?.name == beforeDrag,
              "\(beforeDrag ?? "nil") → \(bubble.currentPage?.name ?? "nil")")
        bubble.close()

        print("== 端到端：菜单按钮与点本体不冲突 ==")
        // 菜单按钮叠在小鲸鱼右上角（设计如此）。SwiftUI 的点击优先给按钮，
        // 但容器的原生 mouseDown/Up 也会收到这一下 —— 若它也去推进气泡序列，
        // 就会出现「点菜单按钮，气泡也跟着跳一格」的毛病。
        bubble.close()
        let menu = Positioning.menuButtonRectNormalized
        let menuView = NSPoint(x: menu.midX * panel, y: panel - menu.midY * panel)
        click(at: menuView)
        check("点菜单按钮不推进气泡序列（不展开气泡）", !bubble.isOpen,
              bubble.isOpen ? "❌ 气泡被展开了" : "保持收起")
        bubble.close()

        print("== 端到端：同一点连续点击的状态轨迹 ==")
        // 用户反馈「第 2 次点击不推进、第 3 次消失」。状态机本身能通过单测，
        // 所以怀疑是「点击没送达」（命中遮罩在气泡展开后变化，
        // 或窗口被重建导致后续事件落到别处）。
        // 这里在同一个点上连点 6 次并打印每步状态，把因果摊开。
        bubble.close()
        let tracePoint = NSPoint(x: panel * 0.70, y: panel - panel * 0.70)   // 鲸鱼身体
        print("  取样点（视图坐标）: (\(Int(tracePoint.x)), \(Int(tracePoint.y)))")
        print("  步骤 | isOpen | queueIndex | 当前页名")
        var trace: [(open: Bool, index: Int, name: String)] = []
        for step in 1...6 {
            click(at: tracePoint)
            let name = bubble.currentPage?.name ?? "nil"
            trace.append((bubble.isOpen, bubble.queueIndexForTesting, name))
            print(String(format: "   %d   |  %-5s |    %d       | %@",
                         step, bubble.isOpen ? "开" : "关",
                         bubble.queueIndexForTesting, name))
        }

        // 期望轨迹：开(0,首次) → 开(1,队列1) → 开(2,队列2)… → 关
        let expectedPages = ["首次点击泡"] + bubble.config.queue.map(\.name)
        var expected: [(Bool, Int, String)] = []
        for (i, name) in expectedPages.enumerated() {
            expected.append((true, i, name))
        }
        expected.append((false, 0, "首次点击泡"))

        var mismatch = -1
        for i in 0..<min(trace.count, expected.count) {
            if trace[i].open != expected[i].0
                || trace[i].index != expected[i].1
                || trace[i].name != expected[i].2 {
                mismatch = i
                break
            }
        }
        if mismatch >= 0 {
            check("连续点击的轨迹符合预期", false,
                  "第 \(mismatch + 1) 步期望 (\(expected[mismatch].0 ? "开" : "关"), "
                  + "index \(expected[mismatch].1), \(expected[mismatch].2)) "
                  + "实际 (\(trace[mismatch].open ? "开" : "关"), "
                  + "index \(trace[mismatch].index), \(trace[mismatch].name))")
        } else {
            check("连续点击的轨迹符合预期",
                  true,
                  "\(expectedPages.count) 页依次出现，第 \(expectedPages.count + 1) 次点击收起")
        }

        print("== 端到端：鲸鱼本体上任意一点都应可点击 ==")
        // 若遮罩有「洞」，用户点在某个具体位置就会点不动。
        // 在鲸鱼区域内均匀取样，逐点验证都能推进序列。
        bubble.close()
        var deadPoints: [CGPoint] = []
        var sampled = 0
        for i in 1..<10 {
            for j in 1..<10 {
                let nx = CGFloat(i) / 10
                let ny = CGFloat(j) / 10
                guard container.hitMask?.contains(x: nx * panel, y: ny * panel,
                                                  panelSide: panel) == true else { continue }
                sampled += 1
                let p = NSPoint(x: nx * panel, y: panel - ny * panel)
                let before = bubble.queueIndexForTesting
                let wasOpen = bubble.isOpen
                click(at: p)
                // 点击必须产生状态变化（推进或开合）
                if bubble.queueIndexForTesting == before && bubble.isOpen == wasOpen {
                    deadPoints.append(CGPoint(x: nx, y: ny))
                }
                bubble.close()
            }
        }
        check("遮罩内所有取样点都能响应点击", deadPoints.isEmpty,
              deadPoints.isEmpty
                ? "取样 \(sampled) 点全部可点击"
                : "\(deadPoints.count)/\(sampled) 点无响应，例如 "
                  + String(format: "(%.1f, %.1f)", deadPoints[0].x, deadPoints[0].y))
        bubble.close()

        print("== 端到端：锁定后整块窗口 click-through ==")
        // 锁定的关键是**真的穿透**，而不只是「没人处理事件」。
        // 二者差别就在 `window.ignoresMouseEvents`：只让 hitTest 返回 nil 时，
        // 事件仍然落在本窗口上，下层应用收不到。
        bubble.close()
        store.update { $0.locked = true }
        controller.applyInteractionState()
        pump(0.15)

        check("锁定后窗口忽略鼠标事件（真穿透，非仅不处理）",
              controller.windowIgnoresMouseEvents,
              "ignoresMouseEvents=\(controller.windowIgnoresMouseEvents)")

        // 锁定后点角色本体：既不能出泡，也不能拖动窗口。
        // 这里仍然调用容器的原生事件（而不是只查配置）：要验的是**接线**，
        // 即容器自己是否也认定这一下无效。
        let lockFrameBefore = controller.windowFrameOrigin
        click(at: bodyView)
        check("锁定后点角色本体不展开气泡", !bubble.isOpen,
              bubble.isOpen ? "❌ 仍然出泡了（hitTest 没放行）" : "保持收起")
        click(at: bodyView, dragTo: NSPoint(x: bodyView.x - 50, y: bodyView.y - 40))
        check("锁定后无法拖动窗口", controller.windowFrameOrigin == lockFrameBefore)

        // 锁定后右键也不该唤出菜单 —— 否则「锁定」并非真的不可交互。
        // 这里用一个独立容器计数（不改动真实容器的回调，避免影响后续断言）。
        let lockProbe = WidgetContainerView(frame: NSRect(x: 0, y: 0, width: panel, height: panel))
        lockProbe.hitMask = container.hitMask
        lockProbe.locked = true
        var rightClicksDuringLock = 0
        lockProbe.onRightClick = { _ in rightClicksDuringLock += 1 }
        if let right = mouseEvent(.rightMouseDown, at: bodyView) {
            lockProbe.rightMouseDown(with: right)
            pump(0.1)
        }
        check("锁定后右键不唤出菜单", rightClicksDuringLock == 0,
              "回调 \(rightClicksDuringLock) 次")
        // 对照：未锁定时右键必须仍然可用，否则菜单按钮被隐藏的用户就没有入口了
        lockProbe.locked = false
        if let right = mouseEvent(.rightMouseDown, at: bodyView) {
            lockProbe.rightMouseDown(with: right)
            pump(0.1)
        }
        check("未锁定时右键仍可唤出菜单", rightClicksDuringLock == 1,
              "回调 \(rightClicksDuringLock) 次")

        store.update { $0.locked = false }
        controller.applyInteractionState()
        pump(0.15)
        check("解除锁定后容器恢复可交互", !controller.container.locked)
        click(at: bodyView)
        check("解除锁定后角色本体恢复可点击", bubble.isOpen)
        bubble.close()

        print("== 端到端：不透明度 ==")
        // 不透明度必须**落在视图渲染出来的像素**上（用户看到的就是这个），
        // 而不是只存在配置里。
        store.update { $0.opacity = 1.0 }
        pump(0.1)
        let opaquePixels = alphaSampler(1.0)
        store.update { $0.opacity = 0.4 }
        pump(0.1)
        let fadedPixels = alphaSampler(0.4)

        check("面板渲染像素确实变淡（不只是配置值变了）",
              fadedPixels.maxAlpha < opaquePixels.maxAlpha,
              String(format: "最大 alpha 1.0→%.2f，0.4→%.2f",
                     opaquePixels.maxAlpha, fadedPixels.maxAlpha))
        check("不透明度 0.4 时像素 alpha 约为 0.4",
              abs(fadedPixels.maxAlpha - 0.4) < 0.06,
              String(format: "实测最大 alpha %.3f", fadedPixels.maxAlpha))
        check("不透明度 1.0 时像素不透明",
              opaquePixels.maxAlpha > 0.95,
              String(format: "实测最大 alpha %.3f", opaquePixels.maxAlpha))

        // 减淡不该影响可点击性：命中判定与不透明度无关
        bubble.close()
        click(at: bodyView)
        check("减淡后角色本体仍可点击", bubble.isOpen)
        bubble.close()
        store.update { $0.opacity = 1.0 }
        controller.applyInteractionState()

        print("== 端到端：可交互区域只命中图案像素 ==")
        // 面板左上角是透明区（小鲸鱼在右下），点击这里不应展开气泡
        let emptyView = NSPoint(x: panel * 0.05, y: panel - panel * 0.05)
        click(at: emptyView)
        check("点击透明角落不展开气泡（不拦截桌面）", !bubble.isOpen)

        // 正中偏左下也应是空白
        let emptyView2 = NSPoint(x: panel * 0.05, y: panel - panel * 0.95)
        click(at: emptyView2)
        check("点击左下空白不展开气泡", !bubble.isOpen)

        // 小鲸鱼本体必须能点开
        click(at: bodyView)
        check("小鲸鱼本体可点开气泡", bubble.isOpen)
        bubble.close()

        print(failures == 0 ? "\n端到端校验全部通过 ✅" : "\n有 \(failures) 项失败 ❌")
        return failures == 0 ? 0 : 1
    }

    /// 推进 runloop 指定秒数，让动画 / asyncAfter / 网络回调 / SwiftUI 更新都跑起来。
    private static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point,
                           modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)
    }
}
