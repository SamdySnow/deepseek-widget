#!/bin/zsh
# 检查挂件窗口是否完整落在屏幕可见区域内。
# 用法：Scripts/window_check.sh
set -u

cat > /tmp/whale-wincheck.swift <<'SWIFT'
import AppKit
import CoreGraphics

let visible = NSScreen.main?.visibleFrame ?? .zero
print("visible frame:", visible)

let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var found = 0
for w in list {
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
    guard owner.contains("小鲸鱼") || owner.lowercased().contains("whalewidget") else { continue }
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = b["X"] as? Double ?? 0
    let y = b["Y"] as? Double ?? 0
    let width = b["Width"] as? Double ?? 0
    let height = b["Height"] as? Double ?? 0
    found += 1
    // CGWindow 的 y 轴从屏幕顶部起算，换算成 AppKit 的底边起算
    let appKitY = (NSScreen.main?.frame.height ?? 0) - (y + height)
    let inside = x >= visible.minX && appKitY >= visible.minY
        && x + width <= visible.maxX && appKitY + height <= visible.maxY
    print("window: x=\(x) topY=\(y) w=\(width) h=\(height) -> appKitY=\(appKitY)")
    print(inside ? "  ✅ 完整位于可见区域内" : "  ❌ 有部分在屏幕外")
}
print("matched windows: \(found)")
exit(found > 0 ? 0 : 1)
SWIFT

swift /tmp/whale-wincheck.swift
