#!/bin/zsh
# 开机自启动的查看 / 开关（命令行版，等价于菜单里的「开机自启动」开关）。
#
# 用法：
#   Scripts/autostart.sh          # 查看状态
#   Scripts/autostart.sh on       # 开启
#   Scripts/autostart.sh off      # 关闭
#
# 注意：这个脚本操作的是**真实的** ~/Library/LaunchAgents。
# 自检（--selftest 等）走的是临时隔离目录，不会碰这里。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 优先用打包后的 .app（登记的就是它，开机启动的也是它）；
# 没有 .app 时退回构建产物，方便开发期试用。
APP="$ROOT/dist/WhaleWidget.app"
if [[ -d "$APP" ]]; then
  BIN="$APP/Contents/MacOS/WhaleWidget"
else
  BIN="$ROOT/.build/release/WhaleWidget"
  echo "（未找到 dist/WhaleWidget.app，使用构建产物 $BIN）"
fi

if [[ ! -x "$BIN" ]]; then
  echo "❌ 找不到可执行文件：$BIN" >&2
  echo "   先跑 Scripts/package_app.sh release" >&2
  exit 1
fi

"$BIN" --autostart "${1:-status}"
exit $?
