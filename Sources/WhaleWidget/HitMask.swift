import AppKit
import Foundation

/// 挂件的「可交互区域」遮罩：只覆盖**角色本体真正有像素**的地方。
///
/// 两点设计约束：
/// 1. **不是矩形** —— 外接矩形会把大块透明区域也算成可交互，挡住桌面点击；
/// 2. **只含角色本体** —— 气泡是纯展示（点它不推进序列），菜单按钮由 SwiftUI
///    自行响应，都不计入。这样遮罩之外的一切都能 click-through 到桌面。
struct HitMask {

    /// 遮罩分辨率（等于面板边长，按像素查表）
    let resolution: Int
    private let words: [UInt64]
    private let wordsPerRow: Int

    // MARK: - 构建

    /// 烘焙遮罩。
    ///
    /// - Parameters:
    ///   - panelSide: 面板边长（像素）
    ///   - whaleImage: 角色图
    ///   - whaleRect: 角色图在面板中的归一化矩形（0…1）
    static func bake(panelSide: CGFloat,
                     whaleImage: NSImage?,
                     whaleRect: CGRect) -> HitMask? {
        let n = max(32, min(1024, Int(panelSide.rounded())))
        guard n > 0 else { return nil }

        // 角色图 → alpha 位图（先栅格化到它自己的矩形尺寸，再查表）
        var bits = [UInt8](repeating: 0, count: n * n)
        if let image = whaleImage {
            let x0 = Int((whaleRect.minX * CGFloat(n)).rounded())
            let y0 = Int((whaleRect.minY * CGFloat(n)).rounded())
            let w = max(1, Int((whaleRect.width * CGFloat(n)).rounded()))
            let h = max(1, Int((whaleRect.height * CGFloat(n)).rounded()))
            if let raster = rasterize(image, width: w, height: h) {
                for ty in 0..<h {
                    let py = y0 + ty
                    guard py >= 0, py < n else { continue }
                    for tx in 0..<w {
                        let px = x0 + tx
                        guard px >= 0, px < n else { continue }
                        if raster.alpha(atX: tx, y: ty) { bits[py * n + px] = 1 }
                    }
                }
            }
        }

        return HitMask.build(resolution: n, bits: bits)
    }

    private static func build(resolution: Int, bits: [UInt8]) -> HitMask {
        let wordsPerRow = (resolution + 63) / 64
        var words = [UInt64](repeating: 0, count: wordsPerRow * resolution)
        for y in 0..<resolution {
            for x in 0..<resolution where bits[y * resolution + x] != 0 {
                words[y * wordsPerRow + x / 64] |= (1 << UInt64(x % 64))
            }
        }
        return HitMask(resolution: resolution, words: words,
                       wordsPerRow: wordsPerRow)
    }

    // MARK: - 查询

    /// 命中测试。坐标原点在面板左上（与 SwiftUI 一致），`x`/`y` 已按镜像翻转。
    func contains(x: CGFloat, y: CGFloat, panelSide: CGFloat) -> Bool {
        let n = CGFloat(resolution)
        let px = Int((x / panelSide * n).rounded(.down))
        let py = Int((y / panelSide * n).rounded(.down))
        guard px >= 0, px < resolution, py >= 0, py < resolution else { return false }
        return words[py * wordsPerRow + px / 64] & (1 << UInt64(px % 64)) != 0
    }

    /// 覆盖率（0…1），仅用于自检与说明。
    var coverage: Double {
        var set = 0
        for w in words { set += w.nonzeroBitCount }
        return Double(set) / Double(resolution * resolution)
    }

    // MARK: - 栅格化

    /// 图像的 alpha 点阵。
    final class Raster {
        let width: Int
        let height: Int
        private let bits: [UInt8]

        init(width: Int, height: Int, bits: [UInt8]) {
            self.width = width
            self.height = height
            self.bits = bits
        }

        func alpha(atX x: Int, y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            return bits[y * width + x] != 0
        }
    }

    /// 把 NSImage 画进指定尺寸的位图，取出 alpha 通道（阈值化）。
    /// 用 alpha > 24 作为「有像素」的判据，过滤掉几乎全透明的抗锯齿边缘。
    ///
    /// 行序说明：这里刻意用 `NSBitmapImageRep.colorAt(x:y:)` 取像素 ——
    /// 它的原点在**左上**，与 SwiftUI `Image` 的绘制方向一致。
    /// 若改读 `bitmapData` 裸缓冲，行序是自下而上的（NSGraphicsContext 原点在左下），
    /// 烘焙出来的遮罩会整体上下翻转，与画面里的图案错位
    /// —— 这正是之前「遮罩有 4 处虚报、且都在下半部」的原因。
    private static func rasterize(_ image: NSImage, width: Int, height: Int) -> Raster? {
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: width * 4, bitsPerPixel: 32) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high

        // 必须先清空再画：`NSBitmapImageRep(bitmapDataPlanes: nil, …)` 拿到的是
        // 未初始化的缓冲区，而 `image.draw(…, operation: .sourceOver)` 只在有像素处
        // 覆盖。不清空的话，透明区域的 alpha 会残留分配到的垃圾值，
        // 烘焙出零星的假像素 —— 表现为「遮罩有 4 处虚报」，很难靠肉眼定位。
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.flushGraphics()

        var bits = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let alpha = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
                bits[y * width + x] = alpha > (24.0 / 255.0) ? 1 : 0
            }
        }
        return Raster(width: width, height: height, bits: bits)
    }
}
