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

    /// 贴边吸附：返回吸附后的原点与命中的边（`left` / `right` / `none`）。
    static func snapped(origin: CGPoint, side: CGFloat, visible: CGRect,
                        margin: CGFloat) -> (origin: CGPoint, side: String) {
        let frame = CGRect(origin: origin, size: CGSize(width: side, height: side))
        let nearLeft = abs(frame.minX - visible.minX) <= margin
        let nearRight = abs(frame.maxX - visible.maxX) <= margin
        let nearBottom = abs(frame.minY - visible.minY) <= margin
        let nearTop = abs(frame.maxY - visible.maxY) <= margin

        var result = origin
        var edge = "none"
        if nearLeft { result.x = visible.minX; edge = "left" }
        else if nearRight { result.x = visible.maxX - side; edge = "right" }
        if nearBottom { result.y = visible.minY }
        else if nearTop { result.y = visible.maxY - side }

        return (clamp(origin: result, side: side, visible: visible), edge)
    }

    /// 角色图在面板中的归一化矩形（0…1，原点左上）。
    static let whaleRectNormalized = CGRect(x: 1 - 0.5945, y: 1 - 0.5945,
                                            width: 0.5945, height: 0.5945)

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
