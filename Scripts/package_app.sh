#!/bin/zsh
# 把 swift build 产物打包成 WhaleWidget.app（含图标与资源），可直接双击运行。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/dist/WhaleWidget.app"

cd "$ROOT"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/WhaleWidget"
BUNDLE="$(swift build -c "$CONFIG" --show-bin-path)/WhaleWidget_WhaleWidget.bundle"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WhaleWidget"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# 资源包（图片/音效）随 app 一起分发
if [[ -d "$BUNDLE" ]]; then
  cp -R "$BUNDLE" "$APP/Contents/Resources/"
else
  echo "!! 未找到资源 bundle，资产可能缺失" >&2
fi

# 应用图标
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - "$APP" 2>/dev/null || echo "!! ad-hoc 签名失败（可忽略）"

echo "==> 完成: $APP"
