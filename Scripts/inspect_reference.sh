#!/bin/zsh
# 查看参考实现（DSH 插件）的点击序列语义与默认队列，用于对齐行为。
# 用法：Scripts/inspect_reference.sh
set -u

P="$HOME/.dsh/profiles/web/node_modules/dsh-whale-widget"
if [[ ! -d "$P" ]]; then
  echo "未找到参考实现：$P"
  exit 0
fi

echo "=== 默认泡泡 / 队列相关定义 ==="
grep -n "首次点击泡" "$P/lib/index.js" | head -20

echo
echo "=== 推进序列的核心函数 ==="
grep -n "function .*[Nn]ext.*[Bb]ubble\|function .*advance\|queueIndex\|seqIndex" "$P/lib/index.js" | head -20

echo
echo "=== 前端点击处理 ==="
grep -n "advanceOnTap\|点击序列\|queueStep" "$P/assets/whale-widget.js" | head -20
