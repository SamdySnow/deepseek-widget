#!/bin/zsh
# 导出当前挂件状态摘要：配置、气泡队列、账本。
# 用于排查「点击序列不对」这类与用户实际状态有关的问题。
# 用法：Scripts/dump_state.sh
set -u

DIR="${WHALE_STATE_DIR:-$HOME/.whale-widget-mac}"
echo "状态目录: $DIR"
ls -la "$DIR" 2>/dev/null || { echo "（目录不存在）"; exit 0 }

/usr/bin/python3 - "$DIR" <<'PY'
import json, pathlib, sys

d = pathlib.Path(sys.argv[1])

print("\n=== config.json ===")
p = d / "config.json"
if p.exists():
    c = json.loads(p.read_text())
    for k in ("scale", "lastSide", "lastX", "lastY", "snapEnabled",
              "menuButtonHidden", "bubbleOn", "turnCostOn", "peakStyle"):
        if k in c:
            print(f"  {k} = {c[k]}")
else:
    print("  （不存在）")

print("\n=== bubbles.json ===")
p = d / "bubbles.json"
if not p.exists():
    print("  不存在 —— 会使用内置默认配置")
    raise SystemExit

raw = p.read_text()
try:
    cfg = json.loads(raw)
except Exception as e:
    print(f"  ❌ JSON 解析失败: {e}")
    raise SystemExit

print(f"  顶层键: {sorted(cfg.keys())}")
print(f"  advanceOnTap = {cfg.get('advanceOnTap')}")
print(f"  模块库 = {len(cfg.get('library') or [])} 项")

def describe(page, label):
    variants = page.get("variants") or []
    print(f"  {label}: name={page.get('name')!r} variants={len(variants)} "
          f"weighted={page.get('weighted', False)}")
    for vi, v in enumerate(variants):
        rows = v.get("rows") or []
        print(f"    variant[{vi}] weight={v.get('weight')} 行数={len(rows)}")
        for ri, row in enumerate(rows):
            mods = [m.get("kind") for m in (row.get("modules") or [])]
            print(f"      row[{ri}] modules={mods}")

queue = cfg.get("queue") or []
print(f"  队列项数 = {len(queue)}")
describe(cfg.get("first") or {}, "first")
for i, page in enumerate(queue):
    describe(page, f"queue[{i}]")

print("\n=== 点击序列推演（按 handleTap 的语义）===")
first_name = (cfg.get("first") or {}).get("name") or "首次点击泡"
names = [first_name] + [(p.get("name") or f"队列{i+1}") for i, p in enumerate(queue)]
advance = cfg.get("advanceOnTap", True)
print(f"  advanceOnTap={advance}  →  页面序列: {' → '.join(names)} → (收起)")
if advance:
    print(f"  预期：第 1 次点击出「{names[0]}」，"
          f"第 {len(names)} 次点击出「{names[-1]}」，"
          f"第 {len(names)+1} 次点击收起")
    if len(names) == 2:
        print("  ⚠️ 队列只有 1 项：第 2 次点击会跳到队列项，第 3 次点击就收起。")
        print("     这是配置如此（不是 bug）—— 若期望更多页，请在「自定义泡泡」里加队列项。")
else:
    print("  ⚠️ advanceOnTap=false：点击只是开合，第 2 次点击就会收起。")
PY
