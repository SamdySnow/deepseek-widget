import CoreGraphics
import Foundation
import SwiftUI

/// 最小 SVG 路径解析器（仅需 `M / L / A / Z`），用于把参考实现的泡泡路径
/// 原样搬到 Core Graphics —— 泡泡造型与宿主插件完全一致。
enum SvgPath {

    /// 解析 SVG `d` 属性，返回 CGPath。
    static func cgPath(_ d: String, scale: CGFloat = 1, offset: CGPoint = .zero) -> CGPath {
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero

        for command in commands(in: d) {
            switch command {
            case .move(let p):
                current = p
                start = p
                path.move(to: transform(p, scale: scale, offset: offset))

            case .line(let p):
                path.addLine(to: transform(p, scale: scale, offset: offset))
                current = p

            case .arc(let rx, let ry, let rotation, let largeArc, let sweep, let end):
                appendArc(to: path, from: current, to: end,
                          rx: rx, ry: ry, rotationDeg: rotation,
                          largeArc: largeArc, sweep: sweep,
                          scale: scale, offset: offset)
                current = end

            case .close:
                path.closeSubpath()
                current = start
            }
        }
        return path
    }

    private static func transform(_ p: CGPoint, scale: CGFloat, offset: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y)
    }

    private enum Command {
        case move(CGPoint)
        case line(CGPoint)
        case arc(rx: CGFloat, ry: CGFloat, rotation: CGFloat,
                 largeArc: Bool, sweep: Bool, end: CGPoint)
        case close
    }

    private static func numbers(_ s: String) -> [CGFloat] {
        var out: [CGFloat] = []
        var buffer = ""
        for ch in s {
            if ch.isNumber || ch == "." || ch == "-" || ch == "+" || ch == "e" || ch == "E" {
                buffer.append(ch)
            } else {
                if !buffer.isEmpty, let v = Double(buffer) { out.append(CGFloat(v)) }
                buffer = ""
            }
        }
        if !buffer.isEmpty, let v = Double(buffer) { out.append(CGFloat(v)) }
        return out
    }

    private static func commands(in d: String) -> [Command] {
        var result: [Command] = []
        var letter = ""
        var buffer = ""

        func flush() {
            defer { buffer = "" }
            guard !letter.isEmpty else { return }
            let v = numbers(buffer)
            guard !v.isEmpty else { return }
            switch letter {
            case "M", "m":
                guard v.count >= 2 else { return }
                result.append(.move(CGPoint(x: v[0], y: v[1])))
            case "L", "l":
                guard v.count >= 2 else { return }
                result.append(.line(CGPoint(x: v[0], y: v[1])))
            case "A", "a":
                // 注意：`case "A", "a" where v.count >= 7` 里的 where **只作用于最后一个
                // 模式**，大写 A 会漏过长度检查 → v[5]/v[6] 越界崩溃。
                // 长度校验必须写进分支里。
                guard v.count >= 7 else { return }
                result.append(.arc(rx: v[0], ry: v[1], rotation: v[2],
                                   largeArc: v[3] != 0, sweep: v[4] != 0,
                                   end: CGPoint(x: v[5], y: v[6])))
            case "Z", "z":
                result.append(.close)
            default:
                break
            }
        }

        for ch in d {
            if ch.isLetter {
                flush()
                letter = String(ch)
            } else if letter == "Z" || letter == "z" {
                continue
            } else {
                buffer.append(ch)
            }
        }
        flush()
        return result
    }

    /// SVG 椭圆弧 → 三次贝塞尔（按 ≤90° 分段），遵循 SVG 规范的端点参数化。
    private static func appendArc(to path: CGMutablePath,
                                  from p0: CGPoint, to p1: CGPoint,
                                  rx rxIn: CGFloat, ry ryIn: CGFloat, rotationDeg: CGFloat,
                                  largeArc: Bool, sweep: Bool,
                                  scale: CGFloat, offset: CGPoint) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || (p0 == p1) {
            path.addLine(to: transform(p1, scale: scale, offset: offset))
            return
        }
        let phi = rotationDeg * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx2 = (p0.x - p1.x) / 2, dy2 = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        // 半径过小则按规范放大
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }

        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coef = denominator == 0 ? 0 : sign * sqrt(numerator / denominator)
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * (-ry * x1p / rx)

        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard len != 0 else { return 0 }
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var deltaTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
                               (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && deltaTheta > 0 { deltaTheta -= 2 * .pi }
        if sweep && deltaTheta < 0 { deltaTheta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(deltaTheta) / (.pi / 2))))
        let delta = deltaTheta / CGFloat(segments)
        var t = theta1

        func point(_ theta: CGFloat) -> CGPoint {
            let x = rx * cos(theta), y = ry * sin(theta)
            return CGPoint(x: cosPhi * x - sinPhi * y + cx,
                           y: sinPhi * x + cosPhi * y + cy)
        }

        for _ in 0..<segments {
            let t2 = t + delta
            let k = 4.0 / 3.0 * tan(delta / 4)
            let pA = point(t), pB = point(t2)
            let dA = CGPoint(x: -rx * sin(t), y: ry * cos(t))
            let dB = CGPoint(x: -rx * sin(t2), y: ry * cos(t2))

            func rot(_ p: CGPoint) -> CGPoint {
                // 旋转矩阵已包含在中心变换的求导里：对切向量做同样旋转
                CGPoint(x: cosPhi * p.x - sinPhi * p.y, y: sinPhi * p.x + cosPhi * p.y)
            }
            let rA = rot(dA), rB = rot(dB)

            let c1 = CGPoint(x: pA.x + k * rA.x, y: pA.y + k * rA.y)
            let c2 = CGPoint(x: pB.x - k * rB.x, y: pB.y - k * rB.y)
            path.addCurve(to: transform(pB, scale: scale, offset: offset),
                          control1: transform(c1, scale: scale, offset: offset),
                          control2: transform(c2, scale: scale, offset: offset))
            t = t2
        }
    }
}

/// 参考实现里的泡泡造型（`viewBox="0 0 1026 700"`，描边 #203170、填充纯白）。
/// 直接沿用其 path / ellipse 数据，保证外观一致。
struct BubbleShape: Shape {
    static let viewBox = CGSize(width: 1026, height: 700)
    static let strokeWidth: CGFloat = 18
    static let stroke = Color(red: 0.125, green: 0.192, blue: 0.439)   // #203170
    static let fill = Color.white

    /// 主线：一个圆角大泡 + 两个小尾巴圆。
    private static let blobD = "M 827 248 A 373 232 0 1 0 81 246 A 373 232 0 0 0 301 465 A 57 32 10 0 0 413 484 A 373 232 0 0 0 827 248 Z"
    private static let tail1 = CGRect(x: 352 - 37.5, y: 561 - 26, width: 75, height: 52)
    private static let tail2 = CGRect(x: 442 - 24.5, y: 646 - 18, width: 49, height: 36)

    // MARK: - 供命中测试复用的几何参数

    /// 泡泡主干的中心与半径（来自上面 path 的两段椭圆弧：rx=373, ry=232）。
    /// 该弧的两个端点 (827,248) / (81,246) 的中点即中心，半径即弧参数。
    static let blobCenter = CGPoint(x: (827 + 81) / 2, y: (248 + 246) / 2)
    static let blobRadii = CGSize(width: 373, height: 232)

    /// 两个小尾巴圆（外接矩形）。
    static var tailCircles: [CGRect] { [tail1, tail2] }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width / Self.viewBox.width, rect.height / Self.viewBox.height)
        let ox = rect.minX + (rect.width - Self.viewBox.width * s) / 2
        let oy = rect.minY + (rect.height - Self.viewBox.height * s) / 2

        var path = Path()
        path.addPath(Path(SvgPath.cgPath(Self.blobD, scale: s, offset: CGPoint(x: ox, y: oy))))
        path.addEllipse(in: CGRect(x: ox + Self.tail1.minX * s, y: oy + Self.tail1.minY * s,
                                   width: Self.tail1.width * s, height: Self.tail1.height * s))
        path.addEllipse(in: CGRect(x: ox + Self.tail2.minX * s, y: oy + Self.tail2.minY * s,
                                   width: Self.tail2.width * s, height: Self.tail2.height * s))
        return path
    }
}
