import AppKit
import Foundation

/// 资源加载：优先从 SPM 资源 bundle 读取，其次回退到源码目录（便于 swift run 联调）。
enum Assets {

    static let bundleName = "WhaleWidget_WhaleWidget.bundle"

    /// 资源目录。
    static let directory: URL? = {
        // 1) .app 包内：Contents/Resources/WhaleWidget_WhaleWidget.bundle/assets
        if let res = Bundle.main.resourceURL {
            let inApp = res.appendingPathComponent(bundleName).appendingPathComponent("assets")
            if FileManager.default.fileExists(atPath: inApp.path) { return inApp }
            let direct = res.appendingPathComponent("assets")
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
        }
        // 2) swift run：可执行文件同级的资源 bundle
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().resolvingSymlinksInPath()
        let candidates = [
            exeDir.appendingPathComponent(bundleName).appendingPathComponent("assets"),
            exeDir.appendingPathComponent("assets"),
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c.path) { return c }
        // 3) 源码目录兜底
        let src = URL(fileURLWithPath: #filePath)          // .../Sources/WhaleWidget/Assets.swift
            .deletingLastPathComponent()                    // .../Sources/WhaleWidget
            .deletingLastPathComponent()                    // .../Sources
            .deletingLastPathComponent()                    // 仓库根目录
            .appendingPathComponent("Resources/assets")
        if FileManager.default.fileExists(atPath: src.path) { return src }
        return nil
    }()

    static func url(_ name: String) -> URL? {
        guard let dir = directory else { return nil }
        let u = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func data(_ name: String) -> Data? {
        guard let u = url(name) else { return nil }
        return try? Data(contentsOf: u)
    }

    static func image(_ name: String) -> NSImage? {
        guard let u = url(name) else { return nil }
        return NSImage(contentsOf: u)
    }

    /// 小鲸鱼本体（cut-out 图，气泡由代码绘制）。
    static var whaleImage: NSImage? { image("DSniang1.png") }
    /// 备用整图（兼容旧版）
    static var whaleFallbackImage: NSImage? { image("DSniang02.png") }
}
