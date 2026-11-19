#!/usr/bin/env bash
# 回归测试：并行跑 N 场 AI 对战（无画面、加速），打印每场的胜负、伤亡和战斗统计。
#   battle/tests/run_battles.sh [场数=6] [额外参数，如 --terrain=hills]
set -uo pipefail
cd "$(dirname "$0")/../.."
n="${1:-6}"; shift || true
out="$(mktemp -d)"
for sd in $(seq 1 "$n"); do
  timeout 300 godot --headless --path . res://battle/battle.tscn -- --auto --fast=6 --seed="$sd" --out="$out/r$sd.json" "$@" > "$out/l$sd.log" 2>&1 &
done
wait
python3 - "$out" "$n" <<'PY'
import json, sys, os
out, n = sys.argv[1], int(sys.argv[2])
for sd in range(1, n + 1):
    p = os.path.join(out, f"r{sd}.json")
    if not os.path.exists(p):
        print(f"seed {sd}: 没有结果，见 {out}/l{sd}.log"); continue
    r = json.load(open(p))
    sides = []
    for s in r["sides"]:
        t = {k: sum(v[k] for v in s["troops"].values()) for k in ("killed", "wounded", "routed", "fine")}
        sides.append(f"{s['name']}：亡{t['killed']} 伤{t['wounded']} 逃{t['routed']} 好{t['fine']}")
    st = r["stats"]
    print(f"seed {sd} 胜方 {r['winner']} 用时 {r['time']:.0f}s | " + " | ".join(sides))
    print(f"    挥砍 {st.get('swings',0)} 接触 {st.get('melee_contact',0)} 格挡 {st.get('blocked',0)} 碰到友军 {st.get('ally_bounce',0)}"
          f" 箭 {st.get('arrow_hits',0)}/{st.get('arrows',0)}（盾挡 {st.get('arrow_shield',0)}） 误伤 {st.get('friendly_hits',0)}"
          f" 冲撞 {st.get('bump',0)} 端枪 {st.get('couch',0)} 伤害 步/射/骑 {st.get('dmg_inf',0)}/{st.get('dmg_arc',0)}/{st.get('dmg_cav',0)}")
PY
