#!/bin/zsh
# 稳定性探针：检查挂件进程是否存活、是否产生新的崩溃报告。
# 用法：Scripts/status.sh
set -u

COUNT=$(pgrep -f "WhaleWidget" | wc -l | tr -d ' ')
echo "running_processes=$COUNT"

LATEST=$(ls -t "$HOME"/Library/Logs/DiagnosticReports/WhaleWidget-*.ips 2>/dev/null | head -1)
if [[ -n "$LATEST" ]]; then
  echo "newest_crash=$(basename "$LATEST")"
  /usr/bin/python3 - "$LATEST" <<'PY'
import json, pathlib, sys
raw = pathlib.Path(sys.argv[1]).read_text()
d = json.loads(raw.split("\n", 1)[1])
print("  exception:", (d.get("exception") or {}).get("type"), (d.get("exception") or {}).get("signal"))
for t in d.get("threads", []):
    if t.get("triggered"):
        for fr in t.get("frames", [])[:12]:
            img = d["usedImages"][fr["imageIndex"]]
            print("   ", img.get("name"), fr.get("symbol") or hex(fr.get("imageOffset", 0)))
PY
else
  echo "newest_crash=none"
fi

echo "--- ledger ---"
/usr/bin/python3 - <<'PY'
import json, pathlib, os
p = pathlib.Path.home() / ".whale-widget-mac" / "ledger.json"
if not p.exists():
    print("no ledger")
    raise SystemExit
d = json.loads(p.read_text())
book = d["books"][d["active"]]
row = book["days"][d["date"]]
print("date:", d["date"], "| balance:", d["lastBalance"], "| today:", d["todayUsage"])
print("observations:", row["firstAt"], "->", row["lastAt"])
PY

echo "--- panel interaction ---"
/usr/bin/python3 - <<'PY'
import json, pathlib
p = pathlib.Path.home() / ".whale-widget-mac" / "config.json"
if not p.exists():
    print("no config")
    raise SystemExit
c = json.loads(p.read_text())
# 锁定 = 整块窗口 click-through（挂件本身不可交互），
# 不透明度越小越淡。排查「挂件点不动 / 看不见」先看这两项。
print("locked:", c.get("locked", False), "（True 时挂件不响应鼠标，需从菜单栏 🐋 解锁）")
print("opacity:", c.get("opacity", 1.0), "（缺失 = 1.0）")
print("snapEnabled:", c.get("snapEnabled", True))
# 位置与朝向：lastSide 由几何推导（left = 已翻转），
# 排查「拖到边上没吸附 / 没翻转」时先看这三个值是否自洽。
print("position: x=%s y=%s lastSide=%s" % (
    c.get("lastX"), c.get("lastY"), c.get("lastSide")))
PY
