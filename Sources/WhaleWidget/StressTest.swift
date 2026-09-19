import AppKit
import Foundation
import SwiftUI

/// 稳定性压测：不等人操作，直接把最容易出问题的事件循环放大跑一遍，
/// 用于快速复现「运行一段时间后 SIGSEGV in objc_release」这类问题。
/// 用法：`WhaleWidget --stress [秒数]`
@MainActor
enum StressTest {

    private static var panel: PanelController?
    private static var store: WhaleStore?
    private static var bubble: BubbleRuntime?
    private static var ticks = 0

    static func run(seconds: Double) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let store = WhaleStore()
        let bubble = BubbleRuntime()
        Self.store = store
        Self.bubble = bubble

        panel = PanelController(store: store, bubble: bubble)

        // 模拟轮询带来的状态变化：每 120ms 改一次余额与今日已用，
        // 足以触发挂件的重排 / 数字动画 / 气泡重绘。
        let timer = Timer(timeInterval: 0.12, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let store = Self.store, let bubble = Self.bubble else { return }
                ticks += 1
                store.stressTick(delta: ticks % 7 == 0 ? 0.37 : 0)
                // 周期性开合气泡，覆盖图片模块与随机模块的重绘路径
                if ticks % 20 == 0 {
                    bubble.handleTap(menuHidden: false)
                }
                if ticks % 25 == 0 {
                    bubble.showTurnCost(0.0123, closeAfter: 1, text: "本轮消耗 ¥ {cost}")
                }
                // 周期性改缩放，覆盖窗口 resize + tracking area 重算
                if ticks % 60 == 0 {
                    store.update { $0.scale = Double.random(in: 0.8...2.4) }
                    Self.panel?.applyScale()
                }
                // 周期性开合菜单，覆盖菜单窗口的创建 / 关闭 / 释放
                if ticks % 30 == 0 {
                    MenuPresenter.shared.show(store: store, bubble: bubble,
                                              soundPlayer: SoundPlayer(),
                                              anchorWindow: nil,
                                              onScaleChange: {},
                                              onClose: {})
                }
                if ticks % 30 == 5 {
                    MenuPresenter.shared.closeCurrent()
                }
                // 周期性开关辅助窗口，覆盖 WindowPresenter 的持有与释放
                if ticks % 45 == 0 {
                    WindowPresenter.shared.show(title: "压测窗口",
                                                size: NSSize(width: 300, height: 300)) {
                        Text("stress").frame(width: 300, height: 300)
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)

        print("压测开始：目标 \(Int(seconds)) 秒，每 0.12s 触发一次状态变化")
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        print("压测通过：\(ticks) 次状态变化后进程仍存活 ✅")
        return 0
    }
}
