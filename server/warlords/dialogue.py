"""Talking to lords without an LLM: Warband-style topics answered from the pre-authored dialogue bank
(content/dialogue*.toml, see content.py). When the "dialogue" AI component is on, the player can also type
freely (player.talk); the topics stay available either way.

Each topic: the player's question (button label and chat line), the facts the lines can test, and what
happens afterwards (relation change, opening the lord's quest list, ...).
"""
from __future__ import annotations

from . import content as C
from .common import dist
from .data import CULTURES, TITLES
from .model import World
from .rules import B

PID = "player"
# how the player addresses a ruler (by kingdom); lords are 将军
HONORIFIC = {"zhou": "陛下", "zhao": "陛下", "yan": "大单于", "liang": "明公", "shu": "大王", "rou": "可汗"}

# topic id -> player's line ({ruler_title} etc. filled from the same table as the lord's answer)
QUESTIONS = {
    "news": "近来局势如何？",
    "about_me": "{you}可曾听说过在下？",
    "about_ruler": "{you}如何看待{ruler_title}？",
    "ask_work": "可有用得着在下的地方？",
    "flatter": "久闻{you}威名，今日得见，幸甚。",
    "whereabouts": "可知{target}眼下在何处？",
}


def _place(w: World, pos) -> str:
    s = min((s for s in w.settlements.values() if s.kind not in ("hideout",)), key=lambda s: dist(s.pos, pos))
    return s.name + ("城中" if dist(s.pos, pos) < 3 else "一带")


def facts(w: World, h) -> tuple[dict, dict]:
    """(conditions the lines can test, values for {placeholders})."""
    from .politics import pedigree_of
    k = w.kingdoms[h.kingdom]
    ruler = w.heroes.get(k.ruler)
    me_k, me_c = w.player.get("kingdom"), w.player.get("contract")
    status = "vassal" if me_k else "merc" if me_c else "free"
    hp = w.parties.get(h.party) if h.party else None
    siege = w.settlements.get(hp.memo.get("siege")) if hp and hp.memo.get("siege") else None
    army = next((a for a in w.armies.values() if a.leader == h.id or h.id in a.members), None)
    enemies = sorted(k.wars, key=lambda e: k.wars[e].get("since", 0))
    fiefs = w.fiefs_of(h.id)
    t = h.traits
    f = {
        "culture": h.culture, "rel": h.rel(PID), "status": status,
        "ruler": k.ruler == h.id, "same_realm": h.kingdom in (me_k, me_c),
        "player_enemy": h.kingdom in w.player.get("wars", []),
        "met": bool(w.player["chats"].get(h.id)), "renown": w.player["renown"],
        "aggression": t.get("aggression", 0), "caution": t.get("caution", 0),
        "honor": t.get("honor", 0), "greed": t.get("greed", 0),
        "pedigree": pedigree_of(w, h.id), "player_pedigree": w.player.get("pedigree") or "low",
        "at_war": bool(enemies), "wars": len(enemies), "besieging": bool(siege), "in_army": bool(army),
        "army_leader": bool(army and army.leader == h.id), "fiefs": len(fiefs),
        "ruler_rel": ruler.rel(h.id) if ruler and ruler.id != h.id else 0,
        "winning": bool(enemies) and k.wars[enemies[0]].get("score", 0) > 0,
        "player_fiefs": len(w.fiefs_of(PID)),
    }
    fill = {
        "name": h.name, "kingdom": k.name, "ruler": ruler.name if ruler else "",
        "ruler_title": TITLES.get(k.id, "君主"), "culture": CULTURES[h.culture]["name"],
        "enemy": w.kingdoms[enemies[0]].name if enemies else "", "siege": siege.name if siege else "",
        "fief": fiefs[0].name if fiefs else "", "here": _place(w, hp.pos) if hp else "",
        "renown": f"{w.player['renown']:.0f}",
        "you": HONORIFIC.get(k.id, "大王") if k.ruler == h.id else "将军",
    }
    return f, fill


def topics(w: World, h) -> list[dict]:
    """Topic buttons for the talk menu."""
    f, fill = facts(w, h)
    out = [{"topic": "news"}, {"topic": "about_me"}]
    if not f["ruler"]:
        out.append({"topic": "about_ruler"})
    out.append({"topic": "ask_work"})
    if not f["player_enemy"]:
        out.append({"topic": "flatter"})
    for q in w.player.get("quests", []):
        if q["kind"] == "letter" and q["target"] != h.id and q["target"] in w.heroes:
            out.append({"topic": "whereabouts", "target": q["target"]})
    for o in out:
        tf = dict(fill, target=w.heroes[o["target"]].name if "target" in o else "")
        o["label"] = QUESTIONS[o["topic"]].format(**tf)
    return out


def greet(w: World, h) -> str:
    f, fill = facts(w, h)
    return C.pick("greet", f, fill, seed=f"{w.seed}:{h.id}:{w.day}") or "幸会。"


def say(w: World, h, topic: str, target: str | None = None) -> tuple[str, int, str | None]:
    """The lord's answer to a topic: (reply, relation change, follow-up: 'quests' or None)."""
    f, fill = facts(w, h)
    seed = f"{w.seed}:{h.id}:{w.day}:{target or ''}"
    attitude, follow = 0, None
    if topic == "whereabouts" and target in w.heroes:
        t = w.heroes[target]
        tp = w.parties.get(t.party) if t.party else None
        f["knows"] = bool(tp) and (t.kingdom == h.kingdom or dist(tp.pos, w.parties[h.party].pos) < 400
                                   if h.party in w.parties else False)
        f["captive"] = bool(t.captive_of)
        fill.update(target=t.name, place=_place(w, tp.pos) if tp else "")
    elif topic == "flatter":
        last = w.player.setdefault("flattered", {}).get(h.id, -99)
        f["recent"] = w.day - last < B.dialogue.flatter_cooldown_days
        if not f["recent"]:
            w.player["flattered"][h.id] = w.day
            # vain and greedy lords enjoy it; proud men of honour see through it
            if f["greed"] - f["honor"] >= 0 and f["rel"] < B.dialogue.flatter_max_rel:
                attitude = 1
                f["pleased"] = True
    elif topic == "ask_work":
        towns = [s for s in w.fiefs_of(h.id) if s.kind in ("town", "castle")]
        f["has_fief"] = bool(towns)
        f["enough_rel"] = f["rel"] >= B.quests.min_relation
        if towns and f["enough_rel"]:
            follow = "quests"
    reply = C.pick(topic, f, fill, seed=seed) or "……"
    return reply, attitude, follow
