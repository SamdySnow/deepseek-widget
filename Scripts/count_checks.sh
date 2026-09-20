#!/bin/zsh
# 统计各测试入口的断言数量（通过 / 失败），用于更新 checkpoint 与 README。
#
# 为什么单独写个脚本：直接 `./Scripts/verify.sh | grep -c` 会因为子进程缓冲
# 而丢输出（本项目反复踩过），所以每个入口都把输出落到文件再统计。
#
# 用法：Scripts/count_checks.sh [输出目录]
#
# 注意：`grep -c '✅'` 数的是**行数**，而每行恰好一条断言
# （detail 里的 emoji 不参与，因为详情用的是「—」分隔）。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="./.build/release/WhaleWidget"
OUT="${1:-/tmp/whale-count}"

if [[ ! -x "$BIN" ]]; then
  echo "❌ 未找到 $BIN，先跑 swift build -c release" >&2
  exit 1
fi
mkdir -p "$OUT"

NSUnbufferedIO=YES "$BIN" --selftest             > "$OUT/selftest.log" 2>&1
NSUnbufferedIO=YES "$BIN" --hitcheck             > "$OUT/hitcheck.log" 2>&1
NSUnbufferedIO=YES "$BIN" --render "$OUT/render" > "$OUT/render.log"   2>&1
NSUnbufferedIO=YES "$BIN" --e2e                  > "$OUT/e2e.log"      2>&1

total=0
# grep -c 在无匹配时返回非 0，用 `|| true` 避免 set -e 把它当失败。
for entry in "selftest:$OUT/selftest.log" \
             "hitcheck:$OUT/hitcheck.log" \
             "render:$OUT/render.log" \
             "e2e:$OUT/e2e.log"; do
  name="${entry%%:*}"
  file="${entry#*:}"
  pass=$(grep -c '✅' "$file") || pass=0
  fail=$(grep -c '❌' "$file") || fail=0
  printf '%-9s 通过 %3d  失败 %3d\n' "$name" "$pass" "$fail"
  total=$((total + pass + fail))
done
echo "-----------------------------"
echo "合计 $total 项"
echo "详细输出：$OUT"
