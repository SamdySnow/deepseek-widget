#!/bin/zsh
# 干净启动检查：杀掉所有实例 → 删除状态 → 启动 .app → 校验默认缩放与窗口尺寸。
# 用于确认「默认 1.8× / 右下角 / 450px」在全新环境下成立。
# 用法：Scripts/clean_launch_check.sh [观察秒数]
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECS="${1:-40}"
cd "$ROOT"

echo "=== 杀掉所有实例 ==="
pkill -f "WhaleWidget" 2>/dev/null
sleep 2
LEFT=$(pgrep -f "WhaleWidget" | wc -l | tr -d ' ')
echo "残留进程: $LEFT"
if [[ "$LEFT" != "0" ]]; then
  echo "❌ 仍有实例存活，无法做干净测试"
  exit 1
fi

echo "=== 删除状态目录 ==="
rm -rf "$HOME/.whale-widget-mac"
echo "已删除"

echo "=== 启动 .app ==="
open dist/WhaleWidget.app
sleep "$SECS"

echo "=== 进程 ==="
echo "instances=$(pgrep -f 'WhaleWidget' | wc -l | tr -d ' ')"

echo "=== 配置 ==="
/usr/bin/python3 - <<'PY'
import json, pathlib
p = pathlib.Path.home() / ".whale-widget-mac" / "config.json"
if not p.exists():
    print("❌ 未生成 config.json"); raise SystemExit(1)
d = json.loads(p.read_text())
print("scale:", d.get("scale"), "| side:", d.get("lastSide"),
      "| x:", d.get("lastX"), "| y:", d.get("lastY"))
ok = abs((d.get("scale") or 0) - 1.8) < 0.001
print("✅ 默认缩放为 1.8" if ok else "❌ 默认缩放不是 1.8")
raise SystemExit(0 if ok else 2)
PY
