import CoreGraphics
import Foundation
import AppKit

/// 挂件窗口的尺寸与位置计算。
/// 单独抽出来是为了能在自检里断言（窗口跑到屏幕外过，是个容易回归的问题）。
enum Positioning {

    /// 挂件边长：与参考实现的 `--dshw-base` 同口径。
    /// `clamp(122px, min(250px, min(vw, vh) * 0.28) * scale, 625px)`
    static func panelSide(scale: Double, screenFrame: CGSize) -> CGFloat {
        let s = max(0.6, min(3.0, scale))
        let base = min(250, min(screenFrame.width, screenFrame.height) * 0.28)
        return max(122, base * s)
    }

    /// 把窗口原点夹到「整个窗口都留在可见区域内」。
    /// 屏幕比窗口还小时退化为对齐左上，避免出现负的可移动范围。
    static func clamp(origin: CGPoint, side: CGFloat, visible: CGRect) -> CGPoint {
        let maxX = max(visible.minX, visible.maxX - side)
        let maxY = max(visible.minY, visible.maxY - side)
        return CGPoint(x: min(max(origin.x, visible.minX), maxX),
                       y: min(max(origin.y, visible.minY), maxY))
    }

    /// 是否完全落在可见区域内。
    static func isFullyVisible(origin: CGPoint, side: CGFloat, visible: CGRect) -> Bool {
        origin.x >= visible.minX && origin.y >= visible.minY
            && origin.x + side <= visible.maxX && origin.y + side <= visible.maxY
    }

    /// 吸附区宽度：**按屏幕尺寸取比例**，并保留一个绝对下限。
    ///
    /// 参考实现用 `ratio: { L: 10, R: 10, B: 15 }`（视口宽/高的百分比），
    /// 在 1728px 宽的屏上左/右吸附区约 **173px**。
    /// 而本版原先用固定的 `snapMargin = 24`——只有参考实现宽度的 ~14%，
    /// 于是必须把鲸鱼几乎顶到屏幕边缘才会吸附，手感上就是「吸附不生效」。
    ///
    /// 这里取「比例」与「绝对下限」的较大者：大屏上跟参考实现一致，
    /// 小屏 / 窗口化时也不会窄到点不中。
    static func snapZone(span: CGFloat, percent: Double, floor: CGFloat) -> CGFloat {
        let p = max(0, min(40, percent))
        return max(floor, span * p / 100)
    }

    /// 贴边吸附：返回吸附后的原点与命中的边（`left` / `right` / `none`）。
    ///
    /// 判据是**窗口盒**距离各边的远近：
    /// 窗口是含大量透明区域的方窗，但用户拖动时看到的是整个挂件，
    /// 用窗口盒判定与「拖到边上就吸住」的直觉一致（也让角落吸附更自然）。
    /// 水平方向命中哪条边决定是否翻转（见 `PanelController.refreshMirror`）。
    ///
    /// 四边宽度**各自独立**：参考实现的默认是左 10%、右 10%、下 15%、
    /// **上 0（上边不吸附）**，所以不能用一个 `margin` 打天下。
    static func snapped(origin: CGPoint, side: CGFloat, visible: CGRect,
                        zones: Zones) -> (origin: CGPoint, side: String) {
        let frame = CGRect(origin: origin, size: CGSize(width: side, height: side))
        // 区间是**闭区间**（「等于 margin」也算吸附），与参考实现一致：
        // 原来是 `<= margin`，边界点正好在阈值上时行为反直觉。
        let nearLeft = zones.left > 0 && frame.minX - visible.minX <= zones.left
        let nearRight = zones.right > 0 && visible.maxX - frame.maxX <= zones.right
        let nearBottom = zones.bottom > 0 && frame.minY - visible.minY <= zones.bottom
        let nearTop = zones.top > 0 && visible.maxY - frame.maxY <= zones.top

        var result = origin
        var edge = "none"
        if nearLeft { result.x = visible.minX; edge = "left" }
        else if nearRight { result.x = visible.maxX - side; edge = "right" }
        if nearBottom { result.y = visible.minY }
        else if nearTop { result.y = visible.maxY - side }

        return (clamp(origin: result, side: side, visible: visible), edge)
    }

    /// 四边吸附区宽度（px）。
    struct Zones {
        var left: CGFloat
        var right: CGFloat
        var top: CGFloat
        var bottom: CGFloat

        /// 四边同宽（参数化测试 / 简单调用方用）。
        static func uniform(_ margin: CGFloat) -> Zones {
            Zones(left: margin, right: margin, top: margin, bottom: margin)
        }

        /// 按参考实现的默认比例换算成当前屏幕的像素宽度。
        static func reference(for visible: CGRect) -> Zones {
            let d = SnapDefaults.self
            return Zones(
                left: snapZone(span: visible.width, percent: d.leftPercent, floor: d.floorX),
                right: snapZone(span: visible.width, percent: d.rightPercent, floor: d.floorX),
                top: snapZone(span: visible.height, percent: d.topPercent, floor: 0),
                bottom: snapZone(span: visible.height, percent: d.bottomPercent, floor: d.floorY))
        }
    }

    /// 角色图在面板中的归一化矩形（0…1，原点左上）。
    static let whaleRectNormalized = CGRect(x: 1 - 0.5945, y: 1 - 0.5945,
                                            width: 0.5945, height: 0.5945)

    /// 角色图（可见的小鲸鱼）在屏幕上的矩形。
    /// 用于「关闭吸附时按图案位置判断该朝哪边」——与参考实现的
    /// `artCenterAt()` 同一口径：镜像时图案翻到面板左侧。
    static func artRect(origin: CGPoint, side: CGFloat, mirrored: Bool = false) -> CGRect {
        let w = side * whaleRectNormalized.width
        let x = mirrored ? origin.x : origin.x + side - w
        return CGRect(x: x, y: origin.y, width: w, height: w)
    }

    /// 参考实现的默认吸附区比例（占视口宽/高的百分比）。
    /// `ratio: { L: 10, T: 0, R: 10, B: 15, F: 50 }` —— T=0 表示上边**不吸附**。
    enum SnapDefaults {
        static let leftPercent = 10.0
        static let rightPercent = 10.0
        static let bottomPercent = 15.0
        static let topPercent = 0.0
        /// 绝对下限：小屏 / 分屏时也不至于窄到吸不住。
        static let floorX: CGFloat = 48
        static let floorY: CGFloat = 48
    }

    /// 气泡在面板中的归一化矩形（0…1，原点左上）。
    static var bubbleRectNormalized: CGRect {
        let aspect = BubbleShape.viewBox.height / BubbleShape.viewBox.width
        return CGRect(x: 0, y: 0, width: 1, height: aspect)
    }

    /// 菜单按钮的归一化矩形（0…1）。与 FloatingPanel.menuButton 的布局保持一致：
    /// 尺寸 = 面板宽 × 26/320，位置 = 右缘内 1.25%，垂直居中在 40.55% 处。
    static let menuButtonRectNormalized: CGRect = {
        let side = 26.0 / 320.0
        let cx = 1 - side / 2 - 0.0125
        let cy = 0.4055 + side * 0.6
        return CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
    }()

    /// 小鲸鱼所在矩形（面板右下，宽高 59.45%）。坐标原点在左上（同 SwiftUI）。
    static func whaleRect(panelSide: CGFloat) -> CGRect {
        let r = whaleRectNormalized
        return CGRect(x: r.minX * panelSide, y: r.minY * panelSide,
                      width: r.width * panelSide, height: r.height * panelSide)
    }

    /// 气泡所在矩形（面板左上，宽高比 1026:700）。坐标原点在左上。
    static func bubbleRect(panelSide: CGFloat) -> CGRect {
        let aspect = BubbleShape.viewBox.height / BubbleShape.viewBox.width
        return CGRect(x: 0, y: 0, width: panelSide, height: panelSide * aspect)
    }

    /// 默认位置：右下角。
    static func defaultOrigin(side: CGFloat, visible: CGRect, margin: CGFloat) -> CGPoint {
        clamp(origin: CGPoint(x: visible.maxX - side - margin,
                              y: visible.minY + margin),
              side: side, visible: visible)
    }
}
