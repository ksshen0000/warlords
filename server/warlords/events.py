"""Story events on the campaign map (content/events.toml): small scripted happenings with a choice —
refugees asking to follow you, deserters, sickness in camp, a lord's feast, a recluse scholar…

Each day (when no menu is open) at most one event may fire: its conditions must hold, its own cooldown and
the global gap (balance.toml [events]) must have passed, and its daily chance must roll.

An event in the content file:
    [[event]]
    id = "refugees"
    title = "流民"
    when = ["near_kind=village", "room>=5"]          # facts below (same syntax as dialogue lines)
    chance = 0.05                                     # per day
    cooldown = 25                                     # days before it can happen again
    vars = { n = [5, 12] }                            # random ints; derived: see _vars()
    text = "……{village}……{n}……"
    [[event.option]]
    label = "收留他们（{n}人入伍，花{cost}金）"
    require = ["gold>=cost"]                          # may compare with vars
    effects = { gold = "-cost", recruit = "n", renown = 1 }
    result = "……"                                     # logged to the chronicle

Effects: gold (number or ±var), renown, recruit (n, tier 1, culture of the nearby place), recruit2 (tier 2),
recruit_wounded (tier-1 men who join wounded), recruit_bandit, rel_owner (the nearby place's lord),
rel_kingdom (every lord of that kingdom), heal (share of wounded who recover), sicken (share of the healthy
who fall ill), desert (share of the healthy who leave).
"""
from __future__ import annotations

import random
import tomllib
import os

from . import content as C
from . import troops as T
from .common import dist
from .data import CULTURES
from .model import World
from .rules import B

PID = "player"
_cache: list[dict] | None = None


def load() -> list[dict]:
    global _cache
    if _cache is None:
        path = os.path.join(C.CONTENT_DIR, "events.toml")
        _cache = tomllib.load(open(path, "rb")).get("event", []) if os.path.exists(path) else []
    return _cache


def _near(w: World, p):
    cands = [s for s in w.settlements.values() if s.kind in ("village", "town", "castle")]
    s = min(cands, key=lambda s: dist(s.pos, p.pos))
    return s if dist(s.pos, p.pos) < B.events.near_range else None


def facts(w: World) -> tuple[dict, dict]:
    from . import player as P
    p = P.party(w)
    near = _near(w, p)
    owner = w.heroes.get(near.owner) if near and near.owner else None
    healthy = T.healthy(p.troops)
    wounded = T.wounded(p.troops)
    biome = w.terrain.biome_at(*p.pos)
    me_k = w.player.get("kingdom")
    f = {
        "gold": p.gold, "renown": w.player["renown"], "troops": healthy, "wounded": wounded,
        "room": P.limit(w) - T.total(p.troops),
        "status": "vassal" if me_k else ("merc" if w.player.get("contract") else "free"),
        "near_kind": near.kind if near else "", "near_culture": near.culture if near else "",
        "inside": bool(p.inside), "biome": biome,
        "homeland": bool(near and w.player.get("origin") in w.kingdoms
                         and near.culture == w.kingdoms[w.player["origin"]].culture),
        "owner_rel": owner.rel(PID) if owner else 0, "has_owner": bool(owner),
        "same_realm": bool(owner and me_k and owner.kingdom == me_k),
        "at_war": bool(w.player.get("wars")) or bool(me_k and w.kingdoms[me_k].wars),
        "unpaid": p.gold < T.upkeep(p.troops) * 2,
        "day": w.day,
    }
    fill = {
        "place": near.name if near else "", "village": near.name if near else "",
        "lord": owner.name if owner else "", "culture": CULTURES[near.culture]["name"] if near else "",
        "kingdom": w.kingdoms[near.faction].name if near and near.faction in w.kingdoms else "",
    }
    return f, fill


def _vars(ev: dict, rng: random.Random, f: dict) -> dict:
    v: dict = {}
    for k, r in ev.get("vars", {}).items():
        v[k] = rng.randint(int(r[0]), int(r[1])) if isinstance(r, list) else r
    n = int(v.get("n", 0))
    if "n" in v:
        v["n"] = n = min(n, max(1, int(f.get("room", n)))) if ev.get("cap_room", True) else n
    # derived amounts (per head, or per man in the band)
    for k in ("cost", "gain", "half"):
        per = ev.get(f"{k}_per", None)
        if per is not None:
            base = n if ev.get(f"{k}_of", "n") == "n" else int(f.get("troops", 0))
            v[k] = max(1, int(base * float(per)))
    if "cost" in v and "half" not in v:
        v["half"] = max(1, int(v["cost"]) // 2)
    return v


def daily(w: World) -> None:
    from . import player as P
    p = P.party(w)
    if p is None or w.player.get("pending") or P.captive(w) or w.player.get("following"):
        return
    st = w.player.setdefault("events", {"last": -99, "cd": {}})
    if w.day - st["last"] < B.events.min_gap_days:
        return
    rng = random.Random(f"{w.seed}:ev:{w.day}")
    f, fill = facts(w)
    evs = load()[:]
    rng.shuffle(evs)
    for ev in evs:
        if w.day < int(st["cd"].get(ev["id"], -1)):
            continue
        if not all(C._holds(c, f) for c in ev.get("when", [])):
            continue
        if rng.random() >= float(ev.get("chance", 0.03)) * B.events.chance_scale:
            continue
        v = _vars(ev, rng, f)
        st["last"] = w.day
        st["cd"][ev["id"]] = w.day + int(ev.get("cooldown", 20))
        w.player["pending"] = {"type": "event", "id": ev["id"], "vars": v, "fill": fill}
        return


def _event(eid: str) -> dict | None:
    return next((e for e in load() if e["id"] == eid), None)


def _fmt(text: str, pend: dict) -> str:
    return text.format_map(C._Safe({**pend.get("fill", {}), **{k: str(x) for k, x in pend.get("vars", {}).items()}}))


def _ok(opt: dict, f: dict, v: dict) -> bool:
    facts_v = {**f, **v}
    for c in opt.get("require", []):
        # "gold>=cost": compare a fact with a var
        for op in (">=", "<="):
            if op in c:
                a, b = c.split(op)
                if b in v:
                    c = f"{a}{op}{v[b]}"
        if not C._holds(c, facts_v):
            return False
    return True


def menu(w: World, pend: dict) -> dict:
    ev = _event(pend["id"])
    if ev is None:
        return {"type": "notice", "title": "", "text": "", "options": [{"id": "ok", "label": "继续", "enabled": True, "hint": ""}]}
    f, _fill = facts(w)
    opts = []
    for i, o in enumerate(ev.get("option", [])):
        ok = _ok(o, f, pend.get("vars", {}))
        opts.append({"id": "choose", "label": _fmt(o["label"], pend), "enabled": ok,
                     "hint": "" if ok else _fmt(o.get("why", "做不到"), pend), "choice": i})
    return {"type": "event", "title": ev.get("title", ""), "text": _fmt(ev["text"], pend), "options": opts}


def choose(w: World, pend: dict, i: int) -> dict:
    from . import player as P
    ev = _event(pend["id"])
    w.player["pending"] = None
    if ev is None or not (0 <= i < len(ev.get("option", []))):
        return {"ok": True}
    o = ev["option"][i]
    f, _fill = facts(w)
    v = pend.get("vars", {})
    if not _ok(o, f, v):
        w.player["pending"] = pend
        return {"ok": False, "message": "做不到"}
    p = P.party(w)
    rng = random.Random(f"{w.seed}:evc:{w.day}:{pend['id']}")
    near = _near(w, p)
    culture = near.culture if near else (w.kingdoms[w.player["origin"]].culture if w.player.get("origin") in w.kingdoms else "zhou")

    def val(x):
        if isinstance(x, str):
            sign = -1 if x.startswith("-") else 1
            return sign * int(v.get(x.lstrip("+-"), 0))
        return x

    eff = o.get("effects", {})
    if "gold" in eff:
        p.gold += val(eff["gold"])
    if "renown" in eff:
        w.player["renown"] = round(w.player["renown"] + float(val(eff["renown"])), 1)
    room = max(0, P.limit(w) - T.total(p.troops))
    for key, tid, wounded in (("recruit", f"{culture}_t1", False), ("recruit_wounded", f"{culture}_t1", True),
                              ("recruit2", _tier2(culture, rng), False), ("recruit_bandit", "bandit_liukou", False)):
        if key in eff:
            n = min(room, max(0, val(eff[key])))
            if n:
                T.add(p.troops, tid, 0 if wounded else n, wounded=n if wounded else 0)
                room -= n
    owner = w.heroes.get(near.owner) if near and near.owner else None
    if "rel_owner" in eff and owner:
        owner.adjust_rel(PID, int(val(eff["rel_owner"])))
    if "rel_kingdom" in eff and near and near.faction in w.kingdoms:
        for h in w.kingdom_heroes(near.faction):
            h.adjust_rel(PID, int(val(eff["rel_kingdom"])))
    if "heal" in eff:
        for e in p.troops.values():                     # roster entries are [healthy, wounded]
            k = int(round(e[1] * float(eff["heal"])))
            e[0] += k
            e[1] -= k
    if "sicken" in eff or "desert" in eff:
        share = float(eff.get("sicken", eff.get("desert", 0)))
        k = int(round(T.healthy(p.troops) * share))
        lose = T.take_healthy(p.troops, max(1 if share > 0 and T.healthy(p.troops) > 5 else 0, k), rng)
        if "sicken" in eff:
            for tid, e in lose.items():
                T.add(p.troops, tid, 0, wounded=e[0])
    T.prune(p.troops)
    text = _fmt(o.get("result", ""), pend)
    if text:
        w.log("player", f"【{ev.get('title', '')}】{text}", player=True)
    return {"ok": True, "message": text}


def _tier2(culture: str, rng: random.Random) -> str:
    from .data import TROOPS
    opts = [t for t, d in TROOPS.items() if d.get("culture") == culture and d.get("tier") == 2]
    return rng.choice(sorted(opts)) if opts else f"{culture}_t1"
