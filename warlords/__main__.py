"""CLI: python -m warlords --days 120 --seed 3 [--brain rule|claude|openai|deepseek] [--out runs/x]"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from . import troops as T
from .brains import BRAINS, make_brain
from .scenario import default_world
from .sim import Simulation

QUIET = {"order", "recruit", "speech", "release", "siege_end", "flee", "prisoners_sold", "desertion",
         "raid_start", "caravan_founded", "brain_error", "hideout_new"}


def summary(w) -> str:
    lines = [f"\n===== 第 {w.day} 天 ====="]
    for k in w.kingdoms.values():
        if not k.alive:
            lines.append(f"{k.name}：已覆灭")
            continue
        wars = "、".join(f"{w.kingdoms[e].name}({v['score']:+.0f})" for e, v in k.wars.items()) or "和平"
        forts = w.kingdom_settlements(k.id, ("town", "castle"))
        lines.append(f"{k.name}（{w.heroes[k.ruler].name}）：城池{len(forts)} 实力{w.kingdom_strength(k.id):.0f} "
                     f"交战：{wars}")
        for h in w.kingdom_heroes(k.id):
            p = w.hero_party(h.id)
            st = f"被俘({w.kingdoms[h.captive_of].name if h.captive_of in w.kingdoms else '土匪'})" if h.captive_of \
                else (f"{T.healthy(p.troops)}人" if p else "整编中")
            lines.append(f"   {h.name}：{st} 金{h.gold:.0f} 影响{h.influence:.0f} 封地{len(w.fiefs_of(h.id))} "
                         f"对君主{h.rel(k.ruler) if h.id != k.ruler else '—'}")
    kinds = {}
    for p in w.parties.values():
        kinds[p.kind] = kinds.get(p.kind, 0) + 1
    lines.append("地图上的部队：" + "，".join(f"{k}{v}" for k, v in sorted(kinds.items())))
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description="AI 领主沙盒模拟")
    ap.add_argument("--days", type=int, default=120)
    ap.add_argument("--seed", type=int, default=3)
    ap.add_argument("--brain", choices=BRAINS, default="rule")
    ap.add_argument("--model", default=None, help="覆盖默认模型名（各 AI 类型有各自默认值）")
    ap.add_argument("--effort", default="low", choices=["low", "medium", "high"])
    ap.add_argument("--verbose", action="store_true", help="同时打印命令/招募/台词等琐碎事件")
    ap.add_argument("--out", default="runs/latest")
    args = ap.parse_args()

    t0 = time.time()
    world = default_world(args.seed)
    try:
        brain = make_brain(args.brain, args.seed, model=args.model, effort=args.effort)
    except (RuntimeError, ImportError, ValueError) as e:
        raise SystemExit(f"无法创建 {args.brain} AI：{e}\n（LLM 依赖：uv pip install -e '.[llm]'）")
    print(f"世界生成完毕（{time.time() - t0:.1f}s）：{len(world.settlements)}处据点，{len(world.parties)}支部队")
    quiet = set(QUIET) - ({"speech"} if args.brain != "rule" else set())
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    sim = Simulation(world, brain)
    t0 = time.time()
    with open(out / "events.jsonl", "w", encoding="utf-8") as f:
        for _ in range(args.days):
            for ev in sim.step(24):
                f.write(json.dumps(ev, ensure_ascii=False) + "\n")
                if args.verbose or ev["type"] not in quiet:
                    print(f"[第{ev['day']:>3}天 {ev['hour'] % 24:02d}时] {ev['text']}")
            if world.day % 30 == 0:
                print(summary(world))
    (out / "state.json").write_text(json.dumps(world.to_dict(), ensure_ascii=False), encoding="utf-8")
    if world.day % 30:
        print(summary(world))
    if hasattr(brain, "calls"):
        print(f"\nLLM 调用 {brain.calls} 次，失败（已退回规则 AI）{brain.failures} 次")
    print(f"\n模拟耗时 {time.time() - t0:.1f}s；事件日志：{out / 'events.jsonl'}")


if __name__ == "__main__":
    main()
