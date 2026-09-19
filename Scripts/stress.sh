#!/bin/zsh
# 构建 + 压测：一次性完成编译与稳定性回归。
# 用法：Scripts/stress.sh [压测秒数]
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECS="${1:-120}"
cd "$ROOT"

echo "=== 构建 ==="
if ! swift build -c release > /tmp/whale-build.log 2>&1; then
  echo "构建失败："
  grep -E "error:" /tmp/whale-build.log | head -20
  exit 1
fi
echo "构建成功"

echo "=== 压测 ${SECS}s ==="
pkill -f "WhaleWidget" 2>/dev/null
sleep 1

BEFORE=$(ls -t "$HOME"/Library/Logs/DiagnosticReports/WhaleWidget-*.ips 2>/dev/null | head -1)
./.build/release/WhaleWidget --stress "$SECS" > /tmp/whale-stress.log 2>&1
CODE=$?

AFTER=$(ls -t "$HOME"/Library/Logs/DiagnosticReports/WhaleWidget-*.ips 2>/dev/null | head -1)

echo "exit=$CODE"
echo "stress output:"
cat /tmp/whale-stress.log

if [[ "$BEFORE" != "$AFTER" ]]; then
  echo "❌ 压测期间产生新崩溃报告: $(basename "$AFTER")"
  exit 2
fi

if [[ $CODE -eq 0 ]]; then
  echo "✅ 压测通过，无崩溃"
else
  echo "❌ 进程异常退出（exit=$CODE）"
  exit 3
fi
