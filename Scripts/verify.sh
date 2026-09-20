#!/bin/zsh
# 全量验证：自检 + 离屏渲染校验 + 打包。
# 用法：Scripts/verify.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== 1. 构建 ==="
if ! swift build -c release > /tmp/whale-build.log 2>&1; then
  echo "构建失败："
  grep -E "error:" /tmp/whale-build.log | head -20
  exit 1
fi
echo "构建成功"

echo
echo "=== 2. 自检（凭据 / 计价 / 记账 / 定位 / 资源 / 接口）==="
./.build/release/WhaleWidget --selftest
SELF=$?

echo
echo "=== 3. 交互路由校验（点本体出泡 / 点菜单按钮弹菜单）==="
./.build/release/WhaleWidget --hitcheck
HIT=$?

echo
echo "=== 4. 端到端校验（真实窗口 + 合成鼠标事件）==="
./.build/release/WhaleWidget --e2e
E2E=$?

echo
echo "=== 5. 离屏渲染校验 ==="
./.build/release/WhaleWidget --render /tmp/whale-render
REND=$?

echo
echo "=== 6. 打包 .app ==="
./Scripts/package_app.sh release > /tmp/whale-package.log 2>&1
PKG=$?
if [[ $PKG -eq 0 ]]; then
  du -sh dist/WhaleWidget.app
else
  tail -5 /tmp/whale-package.log
fi

echo
if [[ $SELF -eq 0 && $HIT -eq 0 && $E2E -eq 0 && $REND -eq 0 && $PKG -eq 0 ]]; then
  echo "✅ 全部验证通过"
  exit 0
fi
echo "❌ 有步骤失败（selftest=$SELF hitcheck=$HIT e2e=$E2E render=$REND package=$PKG）"
exit 1
