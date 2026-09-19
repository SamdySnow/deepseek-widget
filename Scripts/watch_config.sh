#!/bin/zsh
# 观察启动后 config.json 的变化，用于定位「缩放被意外改写」的来源。
# 用法：Scripts/watch_config.sh [观察秒数]
set -u

SECS="${1:-30}"
CFG="$HOME/.whale-widget-mac/config.json"

pkill -f "WhaleWidget" 2>/dev/null
sleep 2
rm -rf "$HOME/.whale-widget-mac"

open /Users/samdy/Coding/deepseek-widget/dist/WhaleWidget.app

echo "t(s)  scale            side   x     y      mtime"
for i in $(seq 1 "$SECS"); do
  if [[ -f "$CFG" ]]; then
    /usr/bin/python3 - "$CFG" "$i" <<'PY'
import json, pathlib, sys, datetime
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text())
mt = datetime.datetime.fromtimestamp(p.stat().st_mtime).strftime("%H:%M:%S")
print(f'{sys.argv[2]:>4}  {d["scale"]:<16.6f} {d["lastSide"]:<6} {d["lastX"]:<5} {d["lastY"]:<6} {mt}')
PY
  else
    echo "$i  (尚无 config.json)"
  fi
  sleep 1
done
