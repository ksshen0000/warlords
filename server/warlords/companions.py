"""Companions (Warband's heroes in the tavern): named people (rules/companions.toml) who sit in a town's
tavern until hired, then ride with you — they fight in your 3D battles (knocked out, never killed; they
need a few days to recover), share the battle experience, grow and get equipped like you (character.py,
gear.py with who = their id), lend the party their best skills, draw a daily wage, and have opinions:
some of your deeds please or anger them, some of them cannot stand each other. A companion whose morale
falls too low leaves, and turns up in another tavern a month later.

State: w.player["companions"][id] = {id, name, title, culture, troop, state: tavern|party|left,
    where (town id while in a tavern), char, equip, morale, wounded_until (day), since (day), back (day)}
"""
from __future__ import annotations

from . import character as CH
from .model import World
from .rules import RULES

PID = "player"


def C() -> dict:
    return RULES.companions


def roster() -> dict:
    return C().get("companions", {})


def rule(key: str, default):
    return C().get("rules", {}).get(key, default)


def comps(w: World) -> dict:
    return w.player.setdefault("companions", {})


def _towns(w: World) -> list:
    return sorted((s for s in w.settlements.values() if s.kind == "town"), key=lambda s: s.id)


def ensure(w: World) -> None:
    """Everyone in the roster has a record; new ones (and a new campaign's) start in a tavern."""
    if not w.player:
        return
    from . import gear as G
    cs = comps(w)
    towns = _towns(w)
    for cid, d in roster().items():
        if cid in cs:
            continue
        rng = w.rng
        home = [s for s in towns if s.culture == d.get("culture")] or towns
        c = {"id": cid, "name": d["name"], "title": d.get("title", ""), "culture": d.get("culture", ""),
             "troop": d.get("troop", "zhou_t1"), "state": "tavern", "where": rng.choice(home).id if home else None,
             "char": CH.new_char(None, d), "equip": {s: None for s in G.SLOTS}, "morale": float(rule("start_morale", 60)),
             "wounded_until": 0, "since": w.day, "back": 0}
        cs[cid] = c
        for iid in d.get("equip", []):
            if iid in G.items():
                G._put_on(w, iid, None, cid)
    for c in cs.values():
        for k in CH.skills():
            c["char"]["skills"].setdefault(k, 0)


def in_party(w: World) -> list[dict]:
    return [c for c in comps(w).values() if c["state"] == "party"]


def fit(w: World, c: dict) -> bool:
    return c["state"] == "party" and int(c.get("wounded_until", 0)) <= w.day


def at(w: World, sid: str) -> list[dict]:
    return [c for c in comps(w).values() if c["state"] == "tavern" and c.get("where") == sid]


def _say(w: World, c: dict, text: str) -> None:
    w.log("companion", f"{c['name']}：{text}", player=True)


# ----------------------------------------------------------------- daily
def daily(w: World) -> None:
    ensure(w)
    p = w.parties.get(PID)
    if p is None:
        return
    rng = w.rng
    towns = _towns(w)
    start = float(rule("start_morale", 60))
    party = in_party(w)
    # wages
    due = sum(int(roster().get(c["id"], {}).get("wage", 5)) for c in party)
    if due:
        if p.gold >= due:
            p.gold -= due
        else:
            for c in party:
                c["morale"] -= float(rule("unpaid", 8))
            if party:
                w.log("companion", "你发不出同伴的薪水，大家都很不满", player=True)
    ids = {c["id"] for c in party}
    for c in comps(w).values():
        d = roster().get(c["id"], {})
        if c["state"] == "party":
            c["morale"] += (start - c["morale"]) * 0.05 * float(rule("drift", 1.0))
            if d.get("rival") and d["rival"] in ids:
                c["morale"] -= float(rule("rival_per_day", 0.6))
                if rng.random() < 0.04:
                    _say(w, c, f"我实在受不了{comps(w)[d['rival']]['name']}，你要是还留着那个人，我迟早要走。")
            if c["morale"] < float(rule("leave_below", 15)):
                c["state"] = "left"
                c["back"] = w.day + int(rule("return_days", 30))
                c["where"] = None
                w.log("companion", f"{c['name']}对你失望透顶，不辞而别。", player=True)
        elif c["state"] == "tavern":
            if w.day - int(c.get("since", 0)) >= int(rule("move_days", 12)) and towns and rng.random() < 0.3:
                c["where"] = rng.choice(towns).id
                c["since"] = w.day
        elif c["state"] == "left" and w.day >= int(c.get("back", 0)) and towns:
            c["state"] = "tavern"
            c["where"] = rng.choice(towns).id
            c["since"] = w.day
            c["morale"] = start


def react(w: World, kind: str) -> None:
    """Your deed (raid, execute, release, victory, defeat, loot) as the companions see it."""
    m = float(C().get("morale", {}).get(kind, 0))
    if not m:
        return
    for c in in_party(w):
        d = roster().get(c["id"], {})
        if kind in d.get("likes", []):
            c["morale"] = min(100.0, c["morale"] + m)
            if m >= 6 and w.rng.random() < 0.5:
                _say(w, c, {"release": "放人一条生路，这才是仁义之师。", "execute": "斩得好！看谁还敢与我们为敌。",
                            "raid": "刀口舔血，就该这样过日子。"}.get(kind, "痛快！"))
        elif kind in d.get("dislikes", []):
            c["morale"] = max(0.0, c["morale"] - m)
            if m >= 6:
                _say(w, c, {"raid": "劫掠百姓，与盗匪何异？我跟着你不是为了干这种事。",
                            "execute": "杀降不祥。这样下去，我们会失尽人心。",
                            "release": "放虎归山，迟早要后悔。", "defeat": "又输了……带兵的人得想想办法了。"}.get(kind, "我不喜欢这样。"))


# ----------------------------------------------------------------- battle
def battle_entries(w: World) -> list[dict]:
    """The companions fit to fight, as heroes of your side in a 3D battle."""
    from . import gear as G
    out = []
    for c in in_party(w):
        if not fit(w, c):
            continue
        lo = G.loadout(w, c["id"])
        lo["char"] = CH.battle_stats(c["char"])
        out.append({"name": c["name"], "troop": c["troop"], "loadout": lo, "companion": c["id"]})
    return out


def apply_outcomes(w: World, outcomes: dict) -> None:
    """After a 3D battle: {companion id: "fine" | "wounded" | "killed" | "routed"}; anyone knocked out rests."""
    for cid, o in (outcomes or {}).items():
        c = comps(w).get(cid)
        if c and c["state"] == "party" and o in ("wounded", "killed"):
            c["wounded_until"] = w.day + int(rule("wound_days", 3))
            w.log("companion", f"{c['name']}在战斗中被打倒，需要养伤 {int(rule('wound_days', 3))} 天", player=True)


def captured(w: World) -> None:
    """You were taken: the companions scatter (Warband) and turn up in taverns later."""
    for c in in_party(w):
        c["state"] = "left"
        c["back"] = w.day + 10 + w.rng.randint(0, 10)
        c["where"] = None


# ----------------------------------------------------------------- menus
def _summary(c: dict) -> str:
    ch = c["char"]
    sk = [f"{CH.skills()[k]['name']}{v}" for k, v in sorted(ch["skills"].items(), key=lambda kv: -kv[1]) if v][:5]
    attr = " ".join(f"{C_ATTR[a]}{ch['attr'][a]}" for a in CH.ATTRS)
    return f"{ch['level']} 级 · {attr} · 擅长：{'、'.join(sk) or '无'}"


C_ATTR = {"str": "力", "agi": "敏", "int": "智", "cha": "魅"}
LIKE_TXT = {"raid": "劫掠村庄", "execute": "斩杀俘虏的将军", "release": "释放俘虏的将军", "victory": "打胜仗",
            "defeat": "打败仗", "loot": "战后发财"}


def menu(w: World, pend: dict) -> dict:
    ensure(w)
    c = comps(w).get(pend.get("id", ""))
    d = roster().get(c["id"], {}) if c else {}
    if c is None:
        return {"type": "companion", "title": "同伴", "text": "这个人已经不在了。", "options": [_opt("back", "返回")]}
    p = w.parties.get(PID)
    lines = [f"{c['title']}。", d.get("story", ""), "", _summary(c)]
    likes = "、".join(LIKE_TXT.get(k, k) for k in d.get("likes", []))
    dislikes = "、".join(LIKE_TXT.get(k, k) for k in d.get("dislikes", []))
    opts = []
    if c["state"] == "tavern":
        cost, wage = int(d.get("hire", 300)), int(d.get("wage", 6))
        lines.append(f"想请{c['name']}入伙：先付 {cost} 金，此后每天 {wage} 金薪水。")
        opts.append(_opt("hire", f"招募{c['name']}（{cost} 金，日薪 {wage}）", bool(p and p.gold >= cost),
                         "" if p and p.gold >= cost else "钱不够"))
    else:
        mood = c["morale"]
        lines.append(f"士气 {mood:.0f}（{'满意' if mood >= 60 else '尚可' if mood >= 35 else '不满，再低就要走'}）"
                     + (f" · 养伤还要 {int(c['wounded_until']) - w.day} 天" if int(c.get("wounded_until", 0)) > w.day else ""))
        if likes:
            lines.append(f"喜欢：{likes}")
        if dislikes:
            lines.append(f"反感：{dislikes}")
        rival = roster().get(d.get("rival", ""), {}).get("name")
        if rival:
            lines.append(f"和{rival}合不来")
        opts.append(_opt("dismiss", f"让{c['name']}离队（装备随人带走）"))
    opts.append(_opt("back", "返回"))
    return {"type": "companion", "id": c["id"], "title": c["name"], "text": "\n".join(lines), "options": opts}


def _opt(oid: str, label: str, enabled: bool = True, hint: str = "") -> dict:
    return {"id": oid, "label": label, "enabled": enabled, "hint": hint}


def act(w: World, pend: dict, action: str, data: dict) -> dict:
    c = comps(w).get(pend.get("id", ""))
    p = w.parties.get(PID)
    if action == "back" or c is None:
        w.player["pending"] = pend.get("back")
        return {"ok": True}
    d = roster().get(c["id"], {})
    if action == "hire" and c["state"] == "tavern":
        cost = int(d.get("hire", 300))
        if not p or p.gold < cost:
            return {"ok": False, "message": "钱不够"}
        p.gold -= cost
        c.update(state="party", where=None, since=w.day, morale=float(rule("start_morale", 60)), wounded_until=0)
        w.log("companion", f"{c['name']}（{c['title']}）加入了你的队伍", player=True)
        w.player["pending"] = pend.get("back")
        return {"ok": True, "message": f"{c['name']}入伙了（按 C / I 可以给同伴加点、换装）"}
    if action == "dismiss" and c["state"] == "party":
        towns = _towns(w)
        c.update(state="tavern", where=w.rng.choice(towns).id if towns else None, since=w.day)
        w.log("companion", f"{c['name']}离开了你的队伍", player=True)
        w.player["pending"] = pend.get("back")
        return {"ok": True}
    return {"ok": False, "message": "现在不能这么做"}


def view(w: World) -> list[dict]:
    out = []
    for c in comps(w).values():
        if c["state"] == "party":
            out.append({"id": c["id"], "name": c["name"], "title": c["title"], "level": c["char"]["level"],
                        "morale": round(c["morale"]), "wounded": max(0, int(c.get("wounded_until", 0)) - w.day)})
    return out
