#!/bin/zsh
# 构建并只显示错误/警告（过滤掉已知的 ld search-path 噪声）。
# 存在的理由：直接 `swift build | grep ...` 在嵌套引号下很容易被 shell 拆错，
# 而 `swift build` 的原始输出又长（大量 ld 提示）会把有用信息淹掉。
# 用法：Scripts/build.sh [debug|release]
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${1:-release}"

LOG="/tmp/whale-build-$$.log"
if ! swift build -c "$CONFIG" > "$LOG" 2>&1; then
  echo "❌ 构建失败："
  grep -E "error:" "$LOG" | head -30
  exit 1
fi

# ld 的 search-path 提示来自 CLT + 完整 Xcode 并存的环境，与本项目无关
issues=$(grep -iE "error:|warning:" "$LOG" | grep -v "search path" || true)
if [[ -n "$issues" ]]; then
  echo "⚠️ 有警告："
  echo "$issues" | head -30
else
  echo "✅ 构建通过，0 error / 0 warning（已忽略 ld 的 search-path 提示）"
fi
rm -f "$LOG"
