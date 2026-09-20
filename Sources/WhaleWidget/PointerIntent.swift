import AppKit
import Foundation
import SwiftUI

/// 挂件的交互状态（点击 Q 弹等），由原生事件驱动、SwiftUI 只负责显示。
@MainActor
final class PanelInteraction: ObservableObject {
    /// 点击时播放 Q 弹形变
    @Published var squeezing = false
    /// 鼠标是否悬停在挂件上
    @Published var hovering = false
}

/// 点击 / 拖动的纯逻辑判定。抽出来是为了能直接单测 ——
/// 之前用 SwiftUI `DragGesture.translation` 判定，窗口一动坐标系就跟着动，
/// 判定结果不可靠，导致点击序列推进不下去。
enum PointerIntent {

    enum Kind: Equatable {
        case click
        case drag
    }

    /// 按下后位移是否已达拖动阈值。
    static func isDrag(from start: CGPoint, to current: CGPoint,
                       threshold: CGFloat = 3) -> Bool {
        abs(current.x - start.x) >= threshold || abs(current.y - start.y) >= threshold
    }

    /// 松开时的最终判定。
    static func resolve(start: CGPoint, end: CGPoint,
                        movedDuringPress: Bool,
                        threshold: CGFloat = 3) -> Kind {
        // 按压过程中曾经超过阈值，或最终位移超过阈值，都算拖动。
        // 「曾经移动过」很关键：用户拖出去再拖回来，也应视为拖动而不是点击。
        if movedDuringPress { return .drag }
        return isDrag(from: start, to: end, threshold: threshold) ? .drag : .click
    }

    /// 窗口在拖动中的新原点（位移严格等于鼠标位移）。
    static func windowOrigin(windowStart: CGPoint,
                             mouseStart: CGPoint,
                             mouseNow: CGPoint) -> CGPoint {
        CGPoint(x: windowStart.x + (mouseNow.x - mouseStart.x),
                y: windowStart.y + (mouseNow.y - mouseStart.y))
    }
}

/// 决定「某个位置要不要接收鼠标事件」——click-through 的核心判定。
///
/// 单独抽出来是为了能直接单测：真实实现依赖全局鼠标监听 + `ignoresMouseEvents`，
/// 很难在测试里驱动真实光标。
enum EventRouting {

    /// 面板上各区域的语义。
    enum Zone: Equatable {
        /// 角色本体：本应用处理（点击出泡 / 拖动）
        case character
        /// 菜单按钮：交给 SwiftUI 的按钮
        case menuButton
        /// 气泡：纯展示，**不接收事件**（点击穿透到桌面）
        case bubble
        /// 透明像素：不接收事件
        case transparent
        /// 已锁定：**整块面板**都不接收事件（连角色本体也穿透）
        case locked
    }

    /// 一个区域的完整事件语义。
    ///
    /// 把「是否接收事件」和「命中测试是否放行」拆成两个独立标志 —— 锁定态下
    /// 二者**不一致**：既要穿透（`acceptsEvents = false`），
    /// 又必须让 `hitTest` 返回 nil（`hitTestable = false`），
    /// 否则光标落在角色本体上时会交给容器，容器随后照常推进气泡序列。
    ///
    /// 之前只有一个 `acceptsEvents` 函数，锁定态就没法表达这种差异。
    struct Behavior: Equatable {
        var acceptsEvents: Bool
        var hitTestable: Bool
        /// 是否允许拖动窗口（锁定后彻底不动）
        var draggable: Bool
        /// 是否允许推进气泡序列
        var advancesBubble: Bool
    }

    /// 锁定态下**所有**区域共享的行为：完全惰性，一切交互关闭。
    static let lockedBehavior = Behavior(acceptsEvents: false, hitTestable: false,
                                         draggable: false, advancesBubble: false)

    /// 判断归一化面板坐标（原点左上）落在哪个区域。
    ///
    /// 优先级：锁定 > 菜单按钮 > 角色本体 > 气泡 > 透明。
    /// 锁定排在最前，因为它使其它一切判定失去意义。
    /// 菜单按钮叠在角色本体上，必须先于角色本体判，否则点按钮会被当成点本体。
    static func zone(at point: CGPoint,
                     hitMask: HitMask?,
                     panelSide: CGFloat,
                     menuButtonRect: CGRect?,
                     locked: Bool = false) -> Zone {
        if locked { return .locked }
        if let menuButtonRect, menuButtonRect.contains(point) { return .menuButton }
        // 遮罩只含角色本体像素
        if let hitMask, hitMask.contains(x: point.x * panelSide,
                                         y: point.y * panelSide,
                                         panelSide: panelSide) {
            return .character
        }
        if Positioning.bubbleRectNormalized.contains(point) { return .bubble }
        return .transparent
    }

    /// 区域 → 事件语义。
    ///
    /// 只有角色本体与菜单按钮参与交互；气泡与透明像素一律穿透。
    /// 锁定态下没有任何区域参与交互（含角色本体与菜单按钮）。
    static func behavior(_ zone: Zone) -> Behavior {
        switch zone {
        case .locked:
            return lockedBehavior
        case .character:
            return Behavior(acceptsEvents: true, hitTestable: true,
                            draggable: true, advancesBubble: true)
        case .menuButton:
            // 菜单按钮自己不推进气泡序列 —— 那一下交给 SwiftUI；
            // 若容器也去推进，就会出现「点菜单按钮，气泡跟着跳一格」。
            return Behavior(acceptsEvents: true, hitTestable: true,
                            draggable: false, advancesBubble: false)
        case .bubble, .transparent:
            return Behavior(acceptsEvents: false, hitTestable: false,
                            draggable: false, advancesBubble: false)
        }
    }

    /// 该区域是否需要本窗口接收鼠标事件。
    /// 只有角色本体与菜单按钮需要；气泡、透明像素与锁定态一律穿透。
    static func acceptsEvents(_ zone: Zone) -> Bool { behavior(zone).acceptsEvents }
}
