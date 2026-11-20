"""Walking round a town, castle or village in 3D (Warband's "take a walk around the streets").

The settlement menu offers "在城中走走"; the client then builds the place (client/battle/scripts/town.gd)
and puts a person wherever one of the menu's options is done: the lord before his hall, the market clerk
among the stalls, volunteers in the square, the innkeeper, the arena master, the gaoler. Walking up to one
and pressing F sends that menu option back as an ordinary act(), so everything the menu can do, the walk
can do, with the same rules (player.act handles the "walk" pending by falling back to the settlement).
"""
from __future__ import annotations

import zlib

from .data import KINGDOMS, TERRAIN, TROOPS
from .model import Settlement, World

PID = "player"

# the tiles on a culture's roofs
ROOFS = {"zhou": "#39424e", "yan": "#5a4232", "zhao": "#4b4038", "liang": "#6b5236", "shu": "#3d4a3b",
         "rou": "#6a5b42"}
LABELS = {"town": "在城中走走（3D）", "castle": "在堡中走走（3D）", "village": "在村里走走（3D）"}


def label(s: Settlement) -> str:
    return LABELS.get(s.kind, "四处走走（3D）")


def _troop(*cands: str) -> str:
    return next((t for t in cands if t in TROOPS), "villager")


def setup(w: World, s: Settlement, options: list[dict]) -> dict:
    """The 3D scene for the client: layout seed, people, and one spot per settlement-menu option."""
    from .player import party
    from .warfare import BIOME_FIELD, _hero_entry
    from .rules import B
    colors = {k[0]: k[3] for k in KINGDOMS}
    kcol = colors.get(s.faction, "#8a8a8a")
    owner = w.heroes.get(s.owner)
    village = s.kind == "village"
    spots = []
    vols: list[str] = []
    for o in options:
        oid = o["id"]
        sp = {"action": oid, "label": o["label"], "enabled": bool(o["enabled"]), "hint": o.get("hint", "")}
        for k in ("hero", "choice"):
            if o.get(k) is not None:
                sp[k] = o[k]
        if oid == "talk":
            h = w.heroes[o["hero"]]
            is_owner = h.id == s.owner
            sp.update(where="square" if village else "hall", npc=h.name, role="守将" if is_owner else "将军",
                      troop=_troop(f"{h.culture}_cav4", f"{h.culture}_inf3"), color=colors.get(h.kingdom, kcol), armed=True)
        elif oid == "quests":
            here = any(x.get("hero") == s.owner for x in options if x["id"] == "talk")
            sp.update(where="hall", npc=owner.name if here else f"{owner.name}的主簿", role="守将" if here else "府衙",
                      troop=_troop(f"{owner.culture}_cav4") if here else "villager",
                      color=colors.get(owner.kingdom, kcol), armed=here)
        elif oid == "manage":
            sp.update(where="hall", npc="家宰", role="你的封地", troop="villager", color="#6a5a48")
        elif oid in ("trade", "deliver"):
            sp.update(where="market", npc="市令", role="市集", troop="villager", color="#9a7a4a")
        elif oid == "sell_prisoners":
            sp.update(where="inn", npc="赎金掮客", role="俘虏买卖", troop="villager", color="#5a4a5a")
        elif oid == "recruit":
            sp.update(where="square", npc="乡老" if village else "募兵的伍长", role="志愿兵",
                      troop="villager" if village else _troop(f"{s.culture}_inf2"), color="#7a6a50" if village else kcol)
            vols = list(s.volunteers)[:8]
        elif oid == "captive":
            sp.update(where="prison", npc="狱卒", role="牢城", troop=_troop(f"{s.culture}_t1"), color="#5a5a5a")
        elif oid == "arena":
            sp.update(where="arena", npc="擂台主", role="擂台", troop="villager", color="#7a5a3a")
        elif oid == "rest":
            sp.update(where="inn", npc="村正" if village else "店家", role="歇脚" if village else "客舍",
                      troop="villager", color="#6a6a5a")
        else:
            continue                                   # leave, walk, raid…: not something a person offers
        spots.append(sp)
    p = party(w)
    me = dict(_hero_entry(w, p))
    lo = dict(me.get("loadout", {}))
    lo.pop("horse", None)
    me["loadout"] = lo
    mk = w.player.get("kingdom")
    seed = zlib.crc32(s.id.encode()) % 100000
    h = w.hour % 24
    n = {"town": 12 + int(s.prosperity / 8), "castle": 6, "village": 6 + int(s.prosperity / 25)}.get(s.kind, 8)
    kind_name = {"town": "城", "castle": "堡", "village": "村"}.get(s.kind, "")
    kname = w.kingdoms[s.faction].name if s.faction in w.kingdoms else "无主"
    sub = f"{kind_name} · {kname}" + (f" · 守将{owner.name}" if owner and s.owner != PID else (" · 你的封地" if s.owner == PID else ""))
    return {
        "town": {"kind": s.kind if s.kind in ("town", "castle", "village") else "village", "seed": seed,
                 "walls": int(getattr(s, "walls", 1) or 1), "roof": ROOFS.get(s.culture, "#3f444c")},
        "terrain": BIOME_FIELD.get(TERRAIN[w.terrain.biome_at(*s.pos)][0], "plains"), "seed": seed,
        "night": not (B.vision.night_end <= h < B.vision.night_start), "dismounted": True, "player_side": 0,
        "place": s.name, "subtitle": sub, "settlement": s.id,
        "sides": [{"name": "你", "color": colors.get(mk, "#3f6fb0"), "hero": me, "troops": {}}],
        "crowd": {"troop": "villager", "n": min(n, 26), "color": "#8a7a5a",
                  "guards": _troop(f"{s.culture}_inf2", "militia"), "guard_n": 0 if s.kind == "village" else 4,
                  "guard_color": kcol},
        "spots": spots, "volunteers": vols, "rumors": rumors(w),
        "rooms": [] if s.kind == "village" else ["hall", "inn"],
    }


RUMOR_TYPES = ("war", "peace", "conquest", "siege_start", "defection", "rebellion", "kingdom_destroyed",
               "succession", "execution", "fief_granted", "army_formed", "raid", "hideout_new", "unrest", "starvation")


def rumors(w: World, days: int = 30, n: int = 8) -> list[str]:
    """What travellers in the tavern talk about: the latest news of the realm (the chronicle, retold)."""
    out: list[str] = []
    per_type: dict[str, int] = {}
    for ev in reversed(w.events):
        if ev.get("day", 0) < w.day - days or len(out) >= n:
            break
        if ev.get("type") in RUMOR_TYPES and ev.get("text") and not ev.get("player"):
            if per_type.get(ev["type"], 0) >= 2:
                continue
            per_type[ev["type"]] = per_type.get(ev["type"], 0) + 1
            t = str(ev["text"]).rstrip("。！")
            ago = w.day - int(ev.get("day", w.day))
            when = "前两天" if ago <= 2 else ("前些日子" if ago <= 10 else "上个月")
            out.append(f"听说{when}，{t}。")
    return out
