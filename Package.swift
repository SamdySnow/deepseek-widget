// swift-tools-version:5.9
import Foundation
import PackageDescription

// 仅装了 Command Line Tools 时，SwiftUI 的宏插件（libSwiftUIMacros）找不到。
// 若机器上存在完整 Xcode，就把它的宏插件目录显式传给编译器。
let xcodePluginPath = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

let swiftSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: xcodePluginPath)
    ? [.unsafeFlags(["-plugin-path", xcodePluginPath])]
    : []

// 不参与编译的顶层内容：脚本、打包产物、文档、图标源文件等。
// 不参与编译的顶层内容：脚本、打包产物、文档、图标源文件等。
//
// 两点注意事项：
// 1. 只列出**确实存在**的路径 —— SwiftPM 对不存在的 exclude 项会发出
//    "Invalid Exclude … File not found" 警告（`dist/` 在首次构建前并不存在）。
// 2. 判断存在性要用**绝对路径**：manifest 的求值 CWD 不保证是仓库根目录
//    （IDE 可能从工作区上级启动 SwiftPM），用相对路径会漏判，
//    于是文件没被排除，构建时冒出 "found N file(s) which are unhandled"。
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

let candidateExcludes = [
    "Scripts",            // 打包 / 校验脚本
    "dist",               // package_app.sh 的打包产物
    ".build",             // 构建中间产物（通常已被 SwiftPM 忽略，写上更保险）
    ".vscode",
    "Resources/Info.plist",
    "Resources/AppIcon.icns",   // 由 package_app.sh 单独拷进 .app
    "README.md",
    "checkpoint.md",
]

let excludes = candidateExcludes.filter {
    FileManager.default.fileExists(
        atPath: packageRoot.appendingPathComponent($0).path)
}

let package = Package(
    name: "WhaleWidget",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WhaleWidget", targets: ["WhaleWidget"])
    ],
    targets: [
        .executableTarget(
            name: "WhaleWidget",
            path: ".",
            exclude: excludes,
            sources: ["Sources/WhaleWidget"],
            resources: [.copy("Resources/assets")],
            swiftSettings: swiftSettings
        )
    ]
)
