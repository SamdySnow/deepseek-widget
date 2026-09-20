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

        /// 把窗口停到屏幕外并复位朝向，作为各节开始前的**确定状态**。
        ///
        /// 为什么需要：拖动相关的断言会真的把窗口拖到屏幕边缘，而贴左会触发
        /// 镜像翻转（这是正确行为）。之后各节用的取样坐标是按「未镜像」算的，
        /// 窗口一镜像，同一个坐标就落到别处 → 整节点击失效。
        /// （实测：不复位时「同一点连续点击」与「遮罩取样点」两节会大面积报红，
        /// 但那是测试自己没跟上窗口状态，不是功能坏了。）
        func parkNeutral() {
            controller.placeForTesting(origin: NSPoint(x: -10_000, y: -10_000))
            store.update { $0.lastSide = "right" }
            controller.refreshMirrorForTesting()
        }

        /// 取角色图中心：鲸鱼本体在那里，任何缩放下都命中。
        let bodyTopLeft = CGPoint(x: panel * 0.70, y: panel * 0.70)
        /// 换算成视图坐标（原点左下）
        let bodyView = NSPoint(x: bodyTopLeft.x, y: panel - bodyTopLeft.y)

        print("== 端到端：点击序列（真实窗口 + 合成事件）==")
        check("面板已建立", panel > 0, "边长 \(Int(panel))px")

        // 先清掉可能存在的临时提醒泡泡（余额预警 / 预算 / 每轮消耗）。
        // `BubbleRuntime.handleTap` 在 transient 存在时**只做关闭**、不推进序列，
        // 于是「第 1 次点击」会被这条提醒吃掉 —— 断言看起来像「点击失效」，
        // 其实是被测场景里混进了一个真实状态的提醒。
        // 本节的关注点是点击序列本身，所以先把提醒清干净。
        // （实测确实会命中：真机上有余额/账本状态时，轮询回调可能抢先弹出提醒。）
        if bubble.transient != nil {
            print("  ℹ️ 检测到临时提醒泡泡（\(bubble.transient?.title ?? "?")），"
                  + "已清除以免干扰点击序列断言")
            bubble.dismissTransient()
            bubble.close()
        }
        check("点击序列开始前没有待处理的临时提醒", bubble.transient == nil)

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
        parkNeutral()
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
        parkNeutral()
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
        parkNeutral()
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
        parkNeutral()
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

        print("== 端到端：吸附（拖动松手后真的贴边）==")
        // 用户反馈「吸附屏幕边缘功能不生效」。这里逐条复现真实几何。
        // 关键是必须**等动画跑完**再读 frame：吸附位移动画是异步的，
        // 立刻读会读到动画前的值（诊断阶段就因为这个误判过一次）。
        store.update { $0.snapEnabled = true; $0.mirrorOnLeftSnap = true }
        let visible = controller.visibleFrameForTesting

        // 吸附区宽度：参考实现是屏幕宽 10%（1728px 屏 ≈ 173px），
        // 而旧版固定 24px —— 只有 ~14%，必须几乎顶到边缘才吸附，
        // 手感上就是「不生效」。这条断言把宽度钉住。
        let zones = Positioning.Zones.reference(for: visible)
        check("左右吸附区按屏幕宽 10% 计算（远宽于旧的固定 24px）",
              abs(zones.left - visible.width * 0.10) < 1,
              String(format: "%.0fpx（旧版固定 24px）", zones.left))
        check("上边不吸附（跟随参考实现 T=0）", zones.top == 0)

        // 距左边 100px 处：旧判据（24px）不吸附，新判据应吸附
        let farButInside = NSPoint(x: visible.minX + 100, y: visible.midY)
        controller.placeForTesting(origin: farButInside)
        controller.simulateDragReleaseForTesting()
        pump(0.5)
        check("距屏幕左边 100px 松手 → 吸附到左边（旧版需 <24px 才吸）",
              abs(controller.windowFrameOrigin.x - visible.minX) < 1,
              "x=\(Int(controller.windowFrameOrigin.x))")

        // 右侧同理
        let nearRight = NSPoint(x: visible.maxX - panel - 100, y: visible.midY)
        controller.placeForTesting(origin: nearRight)
        controller.simulateDragReleaseForTesting()
        pump(0.5)
        check("距屏幕右边 100px 松手 → 吸附到右边",
              abs(controller.windowFrameOrigin.x - (visible.maxX - panel)) < 1,
              "x=\(Int(controller.windowFrameOrigin.x))")

        // 右下角：应当同时吸到右边与底边
        controller.placeForTesting(origin: NSPoint(x: visible.maxX - panel - 10,
                                                   y: visible.minY + 10))
        controller.simulateDragReleaseForTesting()
        pump(0.5)
        let cornerOrigin = controller.windowFrameOrigin
        check("右下角附近松手 → 右边与底边都吸住",
              abs(cornerOrigin.x - (visible.maxX - panel)) < 1
                && abs(cornerOrigin.y - visible.minY) < 1,
              "(\(Int(cornerOrigin.x)), \(Int(cornerOrigin.y)))")

        // 上边不吸附：靠近顶部时 y 保持不动
        let nearTop = NSPoint(x: visible.midX, y: visible.maxY - panel - 50)
        controller.placeForTesting(origin: nearTop)
        controller.simulateDragReleaseForTesting()
        pump(0.5)
        check("靠近屏幕顶部不吸附（上边吸附区为 0）",
              abs(controller.windowFrameOrigin.y - nearTop.y) < 1,
              "y=\(Int(controller.windowFrameOrigin.y))（期望 \(Int(nearTop.y))）")

        // 屏幕中间不吸附
        let middleOrigin = NSPoint(x: visible.midX - panel / 2, y: visible.midY - panel / 2)
        controller.placeForTesting(origin: middleOrigin)
        controller.simulateDragReleaseForTesting()
        pump(0.5)
        check("屏幕中间松手不吸附",
              abs(controller.windowFrameOrigin.x - middleOrigin.x) < 1
                && abs(controller.windowFrameOrigin.y - middleOrigin.y) < 1,
              "(\(Int(controller.windowFrameOrigin.x)), \(Int(controller.windowFrameOrigin.y)))")

        // **持久化**的位置必须是吸附目标，而不是动画途中的中间值。
        // 曾经的 bug：`persistPosition()` 在动画前用旧 frame 覆盖了 lastX/lastY，
        // 于是「吸附看起来生效了，重启后又回到旧位置」。
        controller.placeForTesting(origin: NSPoint(x: visible.minX + 80, y: visible.midY))
        controller.simulateDragReleaseForTesting()
        pump(0.5)
        check("吸附后写入配置的坐标 = 吸附目标（重启不会回到旧位置）",
              abs((store.config.lastX ?? -1) - Double(visible.minX)) < 1,
              "lastX=\(store.config.lastX ?? -1)（期望 \(visible.minX)）")

        print("== 端到端：窗口帧动画机制（吸附位移依赖它）==")
        // 这里断言的是**机制本身**。若哪天有人改回
        // `window.animator().setFrameOrigin(...)`，这条会立刻变红 ——
        // 实测它在这个项目里是 no-op，正是「松手不吸附」的根因。
        let animTarget = NSPoint(x: visible.midX - panel / 2, y: visible.midY - panel / 2)
        controller.placeForTesting(origin: NSPoint(x: 120, y: 120))
        controller.animateToForTesting(animTarget)
        pump(0.6)
        check("窗口帧动画确实会移动窗口（若改回 animator() 这条会红）",
              abs(controller.windowFrameOrigin.x - animTarget.x) < 1,
              "x=\(Int(controller.windowFrameOrigin.x))（期望 \(Int(animTarget.x))）")

        print("== 端到端：朝向翻转（贴左必翻 / 贴右不翻 / 左半边翻）==")
        // 用户反馈「位于屏幕左侧时不会翻转」。参考实现的 `refreshFlip()`：
        // 贴左必翻、贴右不翻，自由摆放时看图案中心与屏幕中线。
        store.update { $0.mirrorOnLeftSnap = true }
        controller.placeForTesting(origin: NSPoint(x: visible.minX + 60, y: visible.midY))
        controller.refreshMirrorForTesting()
        check("屏幕左侧（自由摆放）→ 镜像翻转", controller.isMirroredForTesting,
              "isMirrored=\(controller.isMirroredForTesting) lastSide=\(store.config.lastSide)")

        controller.placeForTesting(origin: NSPoint(x: visible.maxX - panel - 60, y: visible.midY))
        controller.refreshMirrorForTesting()
        check("屏幕右侧（自由摆放）→ 不翻转", !controller.isMirroredForTesting,
              "isMirrored=\(controller.isMirroredForTesting) lastSide=\(store.config.lastSide)")

        // 贴左吸附 → 必翻
        controller.placeForTesting(origin: NSPoint(x: visible.minX + 40, y: visible.midY))
        controller.simulateDragReleaseForTesting()
        pump(0.5)
        check("贴左吸附 → 必然翻转（朝屏幕内侧）",
              controller.isMirroredForTesting && store.config.lastSide == "left",
              "lastSide=\(store.config.lastSide)")

        // 贴右吸附 → 不翻
        controller.placeForTesting(origin: NSPoint(x: visible.maxX - panel - 40, y: visible.midY))
        controller.simulateDragReleaseForTesting()
        pump(0.5)
        check("贴右吸附 → 不翻转",
              !controller.isMirroredForTesting && store.config.lastSide == "right",
              "lastSide=\(store.config.lastSide)")

        // **关闭吸附后**贴到左边也必须翻转 —— 这是用户反馈里最容易漏的一条
        // （旧版直接置 lastSide="none" → 永不翻转）。
        store.update { $0.snapEnabled = false }
        controller.placeForTesting(origin: NSPoint(x: visible.minX, y: visible.midY))
        controller.refreshMirrorForTesting()
        check("关闭吸附 + 停在屏幕左边 → 仍然翻转",
              controller.isMirroredForTesting,
              "isMirrored=\(controller.isMirroredForTesting) lastSide=\(store.config.lastSide)")
        controller.placeForTesting(origin: NSPoint(x: visible.maxX - panel, y: visible.midY))
        controller.refreshMirrorForTesting()
        check("关闭吸附 + 停在屏幕右边 → 不翻转",
              !controller.isMirroredForTesting,
              "isMirrored=\(controller.isMirroredForTesting) lastSide=\(store.config.lastSide)")
        store.update { $0.snapEnabled = true }

        // 关掉「贴左镜像翻转」开关后，即使贴在左边也不翻
        store.update { $0.mirrorOnLeftSnap = false }
        controller.placeForTesting(origin: NSPoint(x: visible.minX, y: visible.midY))
        controller.refreshMirrorForTesting()
        check("关掉「贴左镜像翻转」后贴左也不翻",
              !controller.isMirroredForTesting,
              "isMirrored=\(controller.isMirroredForTesting)")
        store.update { $0.mirrorOnLeftSnap = true }

        print("== 端到端：镜像后点击坐标仍要正确映射 ==")
        // 镜像会改变面板坐标的映射。若容器不知道已经镜像，
        // 点击落在角色本体上会被判成透明区 —— 表现为「翻转后点鲸鱼点不动」。
        // 曾经的 bug：`applySnap` 改了 lastSide 却不通知容器。
        store.update { $0.snapEnabled = true }
        controller.placeForTesting(origin: NSPoint(x: visible.minX + 20, y: visible.midY))
        controller.simulateDragReleaseForTesting()
        pump(0.5)
        check("贴左后容器已同步镜像标记", controller.isMirroredForTesting)

        // 角色图在面板中会因镜像翻到左侧，所以取样点要按镜像后的位置算
        bubble.close()
        let whaleRectNorm = Positioning.whaleRectNormalized
        let artPointNorm = CGPoint(x: whaleRectNorm.midX, y: whaleRectNorm.midY)
        let mirroredNorm = CGPoint(x: 1 - artPointNorm.x, y: artPointNorm.y)
        let clickNorm = controller.isMirroredForTesting ? mirroredNorm : artPointNorm
        let artView = NSPoint(x: clickNorm.x * panel, y: panel - clickNorm.y * panel)
        click(at: artView)
        check("镜像状态下点击角色本体仍能出泡（坐标映射正确）",
              bubble.isOpen, bubble.isOpen ? "展开" : "❌ 没反应")
        bubble.close()

        print("== 端到端：重置位置 ==")
        // 该功能原本就有 `resetPosition()`，但**没有接进 UI**（菜单里找不到入口）。
        // 这里断言它无条件回到右下角默认位 —— 而不是复用 applySnap 去推断：
        // 用户在屏幕中间时 applySnap 会算出不吸附，那「重置」就变成「原地不动」。
        store.update { $0.snapEnabled = true; $0.mirrorOnLeftSnap = true }
        controller.placeForTesting(origin: NSPoint(x: visible.midX, y: visible.midY))
        controller.resetPositionForTesting()
        pump(0.4)
        let resetOrigin = controller.windowFrameOrigin
        let expectX = visible.maxX - panel - store.config.snapMargin
        let expectY = visible.minY + store.config.snapMargin
        check("重置位置 → 回到右下角默认位",
              abs(resetOrigin.x - expectX) < 1 && abs(resetOrigin.y - expectY) < 1,
              "(\(Int(resetOrigin.x)), \(Int(resetOrigin.y)))（期望 (\(Int(expectX)), \(Int(expectY)))）")
        check("重置后完整位于可见区域内",
              Positioning.isFullyVisible(origin: resetOrigin, side: panel, visible: visible))
        check("重置后朝向右（右下角 → 不翻转）",
              !controller.isMirroredForTesting && store.config.lastSide == "right",
              "lastSide=\(store.config.lastSide)")
        check("重置后坐标已写入配置（重启仍在右下角）",
              abs((store.config.lastX ?? -1) - Double(expectX)) < 1
                && abs((store.config.lastY ?? -1) - Double(expectY)) < 1,
              "lastX=\(store.config.lastX ?? -1) lastY=\(store.config.lastY ?? -1)")

        print("== 端到端：可交互区域只命中图案像素 ==")
        parkNeutral()
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
