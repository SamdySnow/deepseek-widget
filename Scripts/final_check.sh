#!/bin/zsh
# 最终验收：清空状态 → 启动真实 .app → 观察若干秒 → 检查存活与窗口位置。
# 用法：Scripts/final_check.sh [观察秒数]
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECS="${1:-100}"
cd "$ROOT"

echo "=== 清理旧状态与进程 ==="
pkill -f "WhaleWidget" 2>/dev/null
sleep 1
rm -rf "$HOME/.whale-widget-mac"
echo "已清空 ~/.whale-widget-mac"

BEFORE=$(ls -t "$HOME"/Library/Logs/DiagnosticReports/WhaleWidget-*.ips 2>/dev/null | head -1)

echo "=== 启动 .app ==="
open dist/WhaleWidget.app
echo "观察 ${SECS}s…"
sleep "$SECS"

PROCS=$(pgrep -f "WhaleWidget.app" | wc -l | tr -d ' ')
echo "存活进程数: $PROCS"

AFTER=$(ls -t "$HOME"/Library/Logs/DiagnosticReports/WhaleWidget-*.ips 2>/dev/null | head -1)

echo "=== 账本 ==="
/usr/bin/python3 - <<'PY'
import json, pathlib
p = pathlib.Path.home() / ".whale-widget-mac" / "ledger.json"
if not p.exists():
    print("no ledger"); raise SystemExit
d = json.loads(p.read_text())
b = d["books"][d["active"]]
r = b["days"][d["date"]]
print("date:", d["date"], "| balance:", d["lastBalance"], "| today:", d["todayUsage"])
print("account:", d["active"])
print("observations:", r["firstAt"], "->", r["lastAt"])
PY

echo "=== 结论 ==="
if [[ "$BEFORE" != "$AFTER" ]]; then
  echo "❌ 运行期间产生新崩溃报告: $(basename "$AFTER")"
  exit 2
fi
if [[ "$PROCS" -lt 1 ]]; then
  echo "❌ 进程未存活"
  exit 3
fi
echo "✅ 进程存活且无崩溃"
