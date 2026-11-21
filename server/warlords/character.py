"""Character progression (Warband's character sheet): level and experience, four attributes, skills capped
by their attribute, and weapon proficiencies that grow with use in the 3D battles. Numbers in
rules/character.toml. The same record serves the player (w.player["char"]) and the companions
(w.player["companions"][id]["char"], companions.py).

Party skills (tactics, pathfinding, spotting, surgery, wound treatment) take the best value in the party,
like Warband; the rest are personal.
"""
from __future__ import annotations

from .model import World
from .rules import RULES

ATTRS = ("str", "agi", "int", "cha")
PROFS = ("one_hand", "two_hand", "polearm", "bow", "crossbow")


def C() -> dict:
    return RULES.character


def skills() -> dict:
    return C().get("skills", {})


def lvl_cfg(key: str, default):
    return C().get("level", {}).get(key, default)


# ----------------------------------------------------------------- records
def new_char(background: str | None = None, extra: dict | None = None) -> dict:
    """A level-1 character. extra = {attr: {...}, skills: {...}, prof: {...}} (a background or a companion)."""
    base = dict(C().get("attributes", {}).get("start", {"str": 6, "agi": 6, "int": 5, "cha": 5}))
    bg = dict(C().get("backgrounds", {}).get(background or "", {}))
    c = {"level": 1, "xp": 0, "attr": {a: int(base.get(a, 5)) for a in ATTRS},
         "skills": {k: 0 for k in skills()}, "prof": {p: int(C().get("prof", {}).get("start", 40)) for p in PROFS},
         "points": {"attr": 0, "skill": 0}}
    for src in (bg, extra or {}):
        for a, v in src.get("attr", {}).items():
            c["attr"][a] = c["attr"].get(a, 0) + int(v)
        for k, v in src.get("skills", {}).items():
            c["skills"][k] = int(v)
        for p, v in src.get("prof", {}).items():
            c["prof"][p] = max(c["prof"].get(p, 0), int(v))
    return c


def ensure(w: World) -> None:
    """The player's character record (created with the background); new skills get level 0."""
    if not w.player.get("background"):
        return
    if "char" not in w.player:
        c = new_char(w.player["background"])
        c["points"] = {"attr": int(lvl_cfg("start_attr_points", 2)), "skill": int(lvl_cfg("start_skill_points", 3))}
        w.player["char"] = c
    for c in all_chars(w):
        for k in skills():
            c["skills"].setdefault(k, 0)
        for p in PROFS:
            c["prof"].setdefault(p, int(C().get("prof", {}).get("start", 40)))


def all_chars(w: World) -> list[dict]:
    out = [w.player["char"]] if w.player.get("char") else []
    for comp in (w.player.get("companions") or {}).values():
        if comp.get("char"):
            out.append(comp["char"])
    return out


def skill(c: dict, sk: str) -> int:
    return int(c["skills"].get(sk, 0))


def cap(c: dict, sk: str) -> int:
    a = skills().get(sk, {}).get("attr", "int")
    return min(int(lvl_cfg("max_skill", 10)), int(c["attr"].get(a, 0)) // int(lvl_cfg("skill_cap_div", 3)))


def per(sk: str) -> float:
    return float(skills().get(sk, {}).get("per_level", 0.0))


def personal(w: World, sk: str) -> float:
    """The effect of a personal skill of the player."""
    c = w.player.get("char")
    return skill(c, sk) * per(sk) if c else 0.0


def party_level(w: World, sk: str) -> int:
    """A party skill: the best among you and the companions who ride with you (not wounded ones)."""
    best = skill(w.player["char"], sk) if w.player.get("char") else 0
    for comp in (w.player.get("companions") or {}).values():
        if comp.get("char") and comp.get("state") == "party" and int(comp.get("wounded_until", 0)) <= w.day:
            best = max(best, skill(comp["char"], sk))
    return best


def party(w: World, sk: str) -> float:
    return party_level(w, sk) * per(sk)


def tactics(w: World) -> int:
    return int(party(w, "tactics"))


def xp_need(level: int) -> int:
    """Total experience needed to reach `level`."""
    if level <= 1:
        return 0
    return int(float(lvl_cfg("xp_base", 300)) * (level - 1) ** float(lvl_cfg("xp_exp", 1.9)))


def add_xp(w: World, c: dict, n: float, who: str = "你") -> int:
    """Experience; returns the number of levels gained (and says so in the chronicle)."""
    if n <= 0:
        return 0
    c["xp"] = int(c["xp"] + n)
    gained = 0
    while c["level"] < int(lvl_cfg("max_level", 40)) and c["xp"] >= xp_need(c["level"] + 1):
        c["level"] += 1
        c["points"]["attr"] += int(lvl_cfg("attr_points", 1))
        c["points"]["skill"] += int(lvl_cfg("skill_points", 1))
        gained += 1
    if gained:
        w.log("level", f"{who}升到了 {c['level']} 级（按 C 打开角色，分配属性和技能点）", player=True)
    return gained


def award(w: World, n: float) -> None:
    """Experience for the party's leaders: you, and (a share) every companion riding with you."""
    if n <= 0 or not w.player.get("char"):
        return
    add_xp(w, w.player["char"], n)
    share = float(C().get("xp", {}).get("companion_share", 0.8))
    for comp in (w.player.get("companions") or {}).values():
        if comp.get("char") and comp.get("state") == "party":
            add_xp(w, comp["char"], n * share, comp.get("name", "同伴"))


def award_battle(w: World, power: float, won: bool) -> None:
    x = C().get("xp", {})
    n = power * float(x.get("battle_per_enemy_power", 3.0))
    if w.player.get("_in_person"):
        n *= float(x.get("in_person", 1.5))
    if not won:
        n *= float(x.get("loss_share", 0.25))
    award(w, n)


def gain_prof(c: dict, hits: dict) -> dict:
    """Weapon proficiency from hits in a 3D battle: {kind: hits} -> {kind: gained}."""
    pc = C().get("prof", {})
    mx = float(pc.get("max", 300))
    out = {}
    for kind, n in hits.items():
        if kind not in PROFS or int(n) <= 0:
            continue
        before = c["prof"].get(kind, 0)
        v = float(before)
        for _ in range(int(n)):
            v += float(pc.get("per_hit", 2.2)) * max(0.05, 1.0 - v / mx)
        c["prof"][kind] = int(min(mx, v))
        if c["prof"][kind] > before:
            out[kind] = c["prof"][kind] - before
    return out


def battle_stats(c: dict) -> dict:
    """What the 3D battle applies to this person's agent (client: Agent.setup, rules.gd loadout "char")."""
    pc = C().get("prof", {})
    return {
        "hp": skill(c, "ironflesh") * per("ironflesh"),
        "melee": 1.0 + skill(c, "power_strike") * per("power_strike"),
        "bow": 1.0 + skill(c, "power_draw") * per("power_draw"),
        "shield": skill(c, "shield") * per("shield"),
        "foot": 1.0 + skill(c, "athletics") * per("athletics"),
        "horse": 1.0 + skill(c, "riding") * per("riding"),
        "mounted_spread": max(0.3, 1.0 - skill(c, "horse_archery") * per("horse_archery")),
        "prof": {p: int(c["prof"].get(p, 0)) for p in PROFS},
        "prof_damage": float(pc.get("damage_per_100", 0.12)),
        "prof_speed": float(pc.get("speed_per_100", 0.06)),
    }


# ----------------------------------------------------------------- the character sheet (C)
def _fmt(sk: str, lv: int) -> str:
    d = skills()[sk]
    v = lv * float(d.get("per_level", 0))
    txt = str(d.get("desc", ""))
    return (txt.replace("{v}", f"{v:g}").replace("{p}", f"{round(v * 100):d}%")
            .replace("{wage}", f"{round(lv * float(d.get('wage_per_level', 0)) * 100):d}%"))


def sheet(c: dict) -> dict:
    an = C().get("attributes", {}).get("names", {})
    pn = C().get("prof", {}).get("names", {})
    rows = []
    for sk, d in skills().items():
        lv = skill(c, sk)
        rows.append({"id": sk, "name": d.get("name", sk), "attr": an.get(d.get("attr"), ""), "level": lv,
                     "cap": cap(c, sk), "party": bool(d.get("party")), "now": _fmt(sk, lv) if lv else "—",
                     "next": _fmt(sk, lv + 1)})
    return {"level": c["level"], "xp": c["xp"], "next_xp": xp_need(c["level"] + 1), "this_xp": xp_need(c["level"]),
            "attr": [{"id": a, "name": an.get(a, a), "value": c["attr"][a]} for a in ATTRS],
            "skills": rows, "prof": [{"id": p, "name": pn.get(p, p), "value": c["prof"].get(p, 0)} for p in PROFS],
            "points": dict(c["points"])}


def spend(c: dict, kind: str, key: str) -> str:
    """Spend a point: kind attr | skill. Returns an error message or ""."""
    if kind == "attr":
        if key not in ATTRS:
            return "没有这项属性"
        if c["points"]["attr"] <= 0:
            return "没有可用的属性点"
        c["points"]["attr"] -= 1
        c["attr"][key] += 1
        return ""
    if kind == "skill":
        if key not in skills():
            return "没有这项技能"
        if c["points"]["skill"] <= 0:
            return "没有可用的技能点"
        if skill(c, key) >= cap(c, key):
            a = C()["attributes"]["names"][skills()[key]["attr"]]
            return f"{skills()[key]['name']}已到上限：先提高{a}（技能不能超过{a} ÷ {lvl_cfg('skill_cap_div', 3)}）"
        c["points"]["skill"] -= 1
        c["skills"][key] = skill(c, key) + 1
        return ""
    return "现在不能这么做"


# ----------------------------------------------------------------- the menu (C)
def char_of(w: World, who: str) -> tuple[dict | None, str]:
    if who in ("", "player"):
        return w.player.get("char"), "你"
    comp = (w.player.get("companions") or {}).get(who)
    return (comp.get("char"), comp.get("name", who)) if comp else (None, "")


def people(w: World) -> list[dict]:
    out = [{"id": "player", "name": "你"}]
    for cid, comp in (w.player.get("companions") or {}).items():
        if comp.get("state") == "party":
            out.append({"id": cid, "name": comp.get("name", cid)})
    return out


def menu(w: World, pend: dict) -> dict:
    ensure(w)
    who = pend.get("who", "player")
    c, name = char_of(w, who)
    if c is None:
        who, (c, name) = "player", char_of(w, "player")
    sh = sheet(c)
    pts = sh["points"]
    text = (f"{name} · {sh['level']} 级 · 经验 {sh['xp']} / {sh['next_xp']}"
            + (f" · 可分配：属性点 {pts['attr']}，技能点 {pts['skill']}" if pts["attr"] or pts["skill"] else ""))
    return {"type": "character", "title": "角色" if who == "player" else f"同伴：{name}", "text": text,
            "who": who, "people": people(w), "char": sh, "msg": pend.get("msg", ""), "msg_ok": pend.get("msg_ok", True),
            "options": ([{"id": "companion_talk", "label": f"与{name}交谈（来历、士气、离队）", "enabled": True}]
                        if who != "player" else []) + [{"id": "back", "label": "返回", "enabled": True}]}


def act(w: World, pend: dict, action: str, data: dict) -> dict:
    if action == "back":
        w.player["pending"] = pend.get("back")
        return {"ok": True}
    if action == "who":
        who = str(data.get("who", "player"))
        if char_of(w, who)[0] is None:
            return {"ok": False, "message": "没有这个人"}
        pend["who"] = who
        pend["msg"] = ""
        return {"ok": True}
    if action == "companion_talk":
        who = pend.get("who", "player")
        if who == "player":
            return {"ok": False, "message": "现在不能这么做"}
        w.player["pending"] = {"type": "companion", "id": who, "back": pend}
        return {"ok": True}
    if action == "spend":
        c, name = char_of(w, pend.get("who", "player"))
        if c is None:
            return {"ok": False, "message": "没有这个人"}
        err = spend(c, str(data.get("kind", "")), str(data.get("key", "")))
        pend["msg"], pend["msg_ok"] = (err, False) if err else ("", True)
        return {"ok": not err, "message": err}
    return {"ok": False, "message": "现在不能这么做"}
