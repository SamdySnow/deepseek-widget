#!/bin/zsh
# 把构建 + 各测试入口的结果写进一个文件，供人 / 工具直接读取。
# 存在的理由：长任务在 sync 终端里会丢 stdout（本项目反复踩到），
# 落盘再读是唯一稳的方式。
# 用法：Scripts/report.sh [输出文件]
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${1:-$ROOT/build-report.txt}"
: > "$OUT"

log() { echo "$@" >> "$OUT"; }

log "=== 构建 ==="
if swift build -c release > /tmp/whale-b.log 2>&1; then
  issues=$(grep -iE "error:|warning:" /tmp/whale-b.log | grep -v "search path" || true)
  if [[ -n "$issues" ]]; then
    log "⚠️ 有警告："; log "$issues"
  else
    log "✅ 0 error / 0 warning（忽略 ld 的 search-path 提示）"
  fi
else
  log "❌ 构建失败："; grep -E "error:" /tmp/whale-b.log | head -30 >> "$OUT"
  exit 1
fi

BIN="./.build/release/WhaleWidget"
for entry in selftest hitcheck e2e; do
  log ""
  log "=== $entry ==="
  NSUnbufferedIO=YES "$BIN" "--$entry" > "/tmp/whale-$entry.log" 2>&1
  pass=$(grep -c '✅' "/tmp/whale-$entry.log") || pass=0
  fail=$(grep -c '❌' "/tmp/whale-$entry.log") || fail=0
  log "通过 $pass / 失败 $fail"
  if [[ "$fail" != "0" ]]; then
    grep '❌' "/tmp/whale-$entry.log" >> "$OUT"
  fi
done

log ""
log "=== render ==="
NSUnbufferedIO=YES "$BIN" --render /tmp/whale-render > /tmp/whale-render.log 2>&1
pass=$(grep -c '✅' /tmp/whale-render.log) || pass=0
fail=$(grep -c '❌' /tmp/whale-render.log) || fail=0
log "通过 $pass / 失败 $fail"
[[ "$fail" != "0" ]] && grep '❌' /tmp/whale-render.log >> "$OUT"

log ""
log "报告已写入 $OUT"
