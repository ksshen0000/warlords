"""The player's own equipment (Warband's inventory screen): four weapon slots + head + body + horse,
a bag of spare items, the smith's shop in towns, and loot after victories.

Items are defined in rules/items.toml; a weapon or shield item points at its combat numbers in
rules/battle.toml ([weapons.*] / [shields.*]) and may override a few of them. The 3D battle gets the
equipped items as a loadout (see loadout()), which the client resolves against battle.toml.

State (w.player):
  equip     {slot: item id or None}   slots: w1..w4, head, body, horse
  bag       {item id: count}
  smith     {settlement id: {"period": n, "delta": {item id: +sold / -bought}}}
"""
from __future__ import annotations

import random

from .data import BACKGROUNDS, TROOPS
from .model import World
from .rules import RULES

WEAPON_SLOTS = ("w1", "w2", "w3", "w4")
SLOTS = WEAPON_SLOTS + ("head", "body", "horse")
WEAPON_TYPES = ("melee", "ranged", "shield")
TYPE_NAMES = {"melee": "近战", "ranged": "弓弩", "shield": "盾", "head": "头盔", "body": "身甲", "horse": "坐骑"}
GEAR_MENUS = ("equip", "smith")


def items() -> dict:
    return RULES.items.get("items", {})


def cfg(key: str, default):
    return RULES.items.get("equipment", {}).get(key, default)


def item(iid: str) -> dict:
    return items().get(iid, {})


def name(iid: str) -> str:
    return str(item(iid).get("name", iid))


def fits(iid: str, slot: str) -> bool:
    t = item(iid).get("type")
    return t in WEAPON_TYPES if slot in WEAPON_SLOTS else t == slot


def _combat(it: dict) -> dict:
    """Combat numbers of a weapon / shield item: battle.toml base + the item's overrides."""
    table = "shields" if it.get("type") == "shield" else "weapons"
    d = dict(RULES.battle.get(table, {}).get(it.get("base", ""), {}))
    for k, v in it.items():
        if k not in ("type", "base", "price", "tier", "cultures", "name"):
            d[k] = v
    return d


def describe(iid: str) -> str:
    """One line of stats for the inventory screen."""
    it = item(iid)
    t = it.get("type")
    if t in ("head", "body"):
        return f"护甲 {it.get('armor', 0)}"
    if t == "horse":
        s = f"{'具装 · ' if it.get('kind') == 'barded' else ''}速度 ×{float(it.get('speed', 1.0)):.2f} · 马体 {it.get('hp', 110)}"
        return s + (f" · 马铠 {it['armor']}" if it.get("armor") else "")
    c = _combat(it)
    if t == "shield":
        return f"盾面 {float(c.get('size', 0.55)):.2f}" + (" · 马上只能背着" if c.get("mount") is False else "")
    if t == "ranged":
        kind = "弩" if c.get("kind") == "crossbow" else "弓"
        s = f"{kind} · 伤害 {c.get('damage', 0)} · {'上弦' if kind == '弩' else '拉弓'} {float(c.get('draw', 0.9)):.1f}秒 · 箭 {c.get('ammo', 0)}"
        if c.get("mount") is False:
            s += " · 马上不能用"
        elif c.get("kind") == "crossbow" and c.get("mount_reload") is False:
            s += " · 马上不能上弦"
        return s
    parts = []
    if c.get("damage") and not c.get("thrust_only"):
        parts.append(f"砍 {c['damage']}")
    if c.get("thrust"):
        parts.append(f"刺 {c['thrust']}")
    parts.append(f"长 {float(c.get('reach', 1.4)):.2f}")
    parts.append(f"速 {float(c.get('speed', 1.0)):.2f}")
    if int(c.get("hands", 1)) >= 2:
        parts.append("双手")
    if c.get("couch"):
        parts.append("可端枪冲刺")
    if c.get("mount") is False:
        parts.append("马上不能用")
    return " · ".join(parts)


# ----------------------------------------------------------------- state
def ensure(w: World) -> None:
    """Give the player an equipment record (from the family background's starting kit)."""
    if "equip" in w.player:
        return
    w.player["equip"] = {s: None for s in SLOTS}
    w.player["bag"] = {}
    bg = BACKGROUNDS.get(w.player.get("background") or "", {})
    for iid in bg.get("equip", ["sword", "round", "leather_cap", "leather"]):
        if iid in items():
            _put_on(w, iid)


def _put_on(w: World, iid: str, slot: str | None = None) -> str:
    """Put an item into a slot (an error message, or "" on success). Whatever it replaces goes to the bag."""
    eq = w.player["equip"]
    t = item(iid).get("type")
    if t is None:
        return "没有这件东西"
    if slot is not None and not fits(iid, slot):
        return f"{name(iid)}不能放在{slot_name(slot)}"
    if slot is None:
        if t in WEAPON_TYPES:
            # a second shield / bow replaces the first: one of each is all a man can use
            same = next((s for s in WEAPON_SLOTS if t in ("shield", "ranged") and eq.get(s) and item(eq[s]).get("type") == t), None)
            slot = same or next((s for s in WEAPON_SLOTS if not eq.get(s)), None)
            if slot is None:
                return "武器四格都满了，先卸下一件"
        else:
            slot = t
    if t in ("shield", "ranged"):
        clash = next((s for s in WEAPON_SLOTS if s != slot and eq.get(s) and item(eq[s]).get("type") == t), None)
        if clash:
            # only one shield / one bow at a time: the old one goes into the bag
            _bag_add(w, eq[clash], 1)
            eq[clash] = None
    old = eq.get(slot)
    if old:
        _bag_add(w, old, 1)
    eq[slot] = iid
    return ""


def _bag_add(w: World, iid: str, n: int) -> None:
    bag = w.player["bag"]
    bag[iid] = bag.get(iid, 0) + n
    if bag[iid] <= 0:
        del bag[iid]


def slot_name(slot: str) -> str:
    return str(RULES.items.get("slot_names", {}).get(slot, slot))


# ----------------------------------------------------------------- battle
def loadout(w: World) -> dict:
    """The 3D battle loadout of the player's character from what is equipped (client: rules.gd loadout())."""
    ensure(w)
    eq = w.player["equip"]
    out: dict = {"melee": [], "armor": 0, "head_armor": 0}
    look = {}
    for s in WEAPON_SLOTS:
        iid = eq.get(s)
        if not iid or not item(iid):
            continue
        it = item(iid)
        spec = {k: v for k, v in it.items() if k not in ("type", "price", "tier", "cultures")}
        if it["type"] == "melee":
            out["melee"].append(spec)
        elif it["type"] == "ranged":
            out["ranged"] = spec
        elif it["type"] == "shield":
            out["shield"] = spec
    # no melee weapon at all: the client hands him a club (bare fists would be Warband's answer)
    for s, key in (("head", "head_armor"), ("body", "armor")):
        iid = eq.get(s)
        if iid and item(iid):
            out[key] = int(item(iid).get("armor", 0))
            look[s] = int(item(iid).get("tier", 1))
        else:
            look[s] = 0
    hid = eq.get("horse")
    if hid and item(hid):
        h = item(hid)
        out.update(horse=h.get("kind", "horse"), horse_hp=float(h.get("hp", 110)),
                   horse_speed=float(h.get("speed", 1.0)), horse_armor=float(h.get("armor", 6)))
    out["look"] = look
    return out


# ----------------------------------------------------------------- the smith
def _period(w: World) -> int:
    return w.day // max(1, int(cfg("restock_days", 7)))


def shop(w: World, s) -> dict[str, int]:
    """What the smith of a town has for sale (regenerated every restock period; buying and selling adjust it)."""
    per = _period(w)
    rng = random.Random(f"{w.seed}:smith:{s.id}:{per}")
    cap = min(4, int(cfg("shop_tier_base", 2)) + int(s.prosperity // float(cfg("shop_tier_per", 35))))
    pool, wts = [], []
    for iid, it in items().items():
        if int(it.get("tier", 1)) > cap or int(it.get("price", 0)) <= 0:
            continue
        cults = it.get("cultures")
        wt = 1.0 if not cults else (float(cfg("culture_weight", 3.0)) if s.culture in cults else float(cfg("foreign_weight", 0.35)))
        pool.append(iid)
        wts.append(wt)
    stock: dict[str, int] = {}
    for _ in range(int(cfg("shop_size", 14))):
        if not pool:
            break
        i = rng.choices(range(len(pool)), wts)[0]
        iid = pool.pop(i)
        wts.pop(i)
        stock[iid] = 1 if item(iid)["type"] in ("horse", "body") else rng.randint(1, 2)
    led = w.player.setdefault("smith", {}).get(s.id)
    if led and led.get("period") == per:
        for iid, d in led["delta"].items():
            stock[iid] = stock.get(iid, 0) + int(d)
    return {k: v for k, v in stock.items() if v > 0 and k in items()}


def _ledger(w: World, s, iid: str, d: int) -> None:
    per = _period(w)
    led = w.player.setdefault("smith", {})
    if led.get(s.id, {}).get("period") != per:
        led[s.id] = {"period": per, "delta": {}}
    dl = led[s.id]["delta"]
    dl[iid] = dl.get(iid, 0) + d


def sell_price(iid: str) -> int:
    return int(int(item(iid).get("price", 0)) * float(cfg("sell_ratio", 0.45)))


# ----------------------------------------------------------------- loot
def loot(w: World, enemy_losses: int, losers: list) -> list[str]:
    """Pick up some of the beaten enemy's gear: items up to the tier of the troops that fell, likelier
    of their culture. Added to the bag; returns the item ids."""
    ensure(w)
    if enemy_losses <= 0:
        return []
    rng = random.Random(f"{w.seed}:loot:{w.hour}:{enemy_losses}")
    tiers, cults = [], {}
    for q in losers:
        for tid, v in q.troops.items():
            t = TROOPS.get(tid, {})
            tiers.append(int(t.get("tier", 1)))
            c = t.get("culture", "")
            cults[c] = cults.get(c, 0) + int(v[0]) + int(v[1])
    top = max(tiers, default=1)
    if any(q.kind == "lord" for q in losers):
        top += 1
    top = max(1, min(4, top))
    pool, wts = [], []
    for iid, it in items().items():
        if int(it.get("tier", 1)) > top or int(it.get("price", 0)) <= 0:
            continue
        cs = it.get("cultures")
        wt = 1.0 if not cs else (2.0 if any(c in cults for c in cs) else 0.4)
        if it["type"] == "horse":
            wt *= float(cfg("loot_horse_weight", 0.3))
        pool.append(iid)
        wts.append(wt)
    rolls = min(int(cfg("loot_rolls_max", 4)), 1 + enemy_losses // max(1, int(cfg("loot_rolls_per", 12))))
    got = []
    for _ in range(rolls):
        if pool and rng.random() < float(cfg("loot_chance", 0.45)):
            iid = rng.choices(pool, wts)[0]
            _bag_add(w, iid, 1)
            got.append(iid)
    return got


# ----------------------------------------------------------------- menu
def open_menu(w: World, kind: str, back, sid: str | None = None) -> None:
    ensure(w)
    pend = {"type": kind, "back": back}
    if sid:
        pend["id"] = sid
    w.player["pending"] = pend


def menu(w: World, pend: dict, gold: float) -> dict:
    ensure(w)
    eq = w.player["equip"]
    s = w.settlements.get(pend.get("id", "")) if pend["type"] == "smith" else None

    def row(iid, n=1):
        it = item(iid)
        return {"id": iid, "name": name(iid), "n": n, "type": it.get("type"), "type_name": TYPE_NAMES.get(it.get("type"), ""),
                "desc": describe(iid), "price": int(it.get("price", 0)), "sell": sell_price(iid), "tier": int(it.get("tier", 1)),
                "base": it.get("base", ""), "kind": it.get("kind", "")}      # base / kind: which icon to draw

    slots = []
    for sl in SLOTS:
        iid = eq.get(sl)
        slots.append({"slot": sl, "label": slot_name(sl), "item": row(iid) if iid and item(iid) else None})
    order = {t: i for i, t in enumerate(TYPE_NAMES)}
    bag = sorted((row(i, n) for i, n in w.player["bag"].items() if item(i)), key=lambda r: (order.get(r["type"], 9), -r["price"]))
    lo = loadout(w)
    mounted = bool(lo.get("horse"))
    summary = (f"头部护甲 {lo['head_armor']} · 身体护甲 {lo['armor']}"
               + (f" · 坐骑 {name(eq['horse'])}" if mounted else " · 步行")
               + f" · 金 {int(gold)}")
    m = {"type": pend["type"], "title": "装备" if s is None else f"{s.name}的兵器铺",
         "text": summary, "options": [{"id": "back", "label": "返回", "enabled": True}],
         "gear": {"slots": slots, "bag": bag, "gold": int(gold), "msg": pend.get("msg", ""), "msg_ok": pend.get("msg_ok", True),
                  # the character preview: the same loadout the 3D battle gets
                  "loadout": lo, "troop": f"{w.player.get('origin') or 'zhou'}_cav3",
                  "color": _color(w), "head_armor": lo["head_armor"], "body_armor": lo["armor"],
                  "horse": name(eq["horse"]) if mounted else ""}}
    if s is not None:
        m["gear"]["shop"] = sorted((row(i, n) for i, n in shop(w, s).items()),
                                   key=lambda r: (order.get(r["type"], 9), -r["price"]))
        m["text"] += "\n铺子里的货七天一换；卖回给铺子只给原价的%d%%。" % round(100 * float(cfg("sell_ratio", 0.45)))
    else:
        m["text"] += "\n在城里的兵器铺可以买卖装备；打了胜仗会缴获一些。"
    return m


def _color(w: World) -> str:
    from .data import KINGDOMS
    k = w.player.get("kingdom") or w.player.get("origin")
    return next((c[3] for c in KINGDOMS if c[0] == k), "#3f6fb0")


def act(w: World, pend: dict, action: str, data: dict, p) -> dict:
    """The equipment screen's drag and drop (Warband's inventory):
    equip {item, slot?}       bag -> slot (auto slot without one)
    unequip {slot}            slot -> bag
    move {from, to}           slot -> slot (swap)
    gear_buy {item, slot?}    shop -> bag, or straight into a slot
    gear_sell {item | slot}   bag or slot -> shop
    back"""
    r = _act(w, pend, action, data, p)
    if pend is w.player.get("pending"):
        pend["msg"] = r.get("message", "")
        pend["msg_ok"] = bool(r.get("ok"))
    return r


def _act(w: World, pend: dict, action: str, data: dict, p) -> dict:
    ensure(w)
    eq = w.player["equip"]
    iid = str(data.get("item", ""))
    slot = data.get("slot")
    if action == "back":
        w.player["pending"] = pend.get("back")
        return {"ok": True}
    if action == "equip":
        if w.player["bag"].get(iid, 0) <= 0:
            return {"ok": False, "message": "包里没有这件东西"}
        if slot is not None and slot not in SLOTS:
            return {"ok": False, "message": "没有这个装备格"}
        _bag_add(w, iid, -1)
        err = _put_on(w, iid, slot)
        if err:
            _bag_add(w, iid, 1)
            return {"ok": False, "message": err}
        return {"ok": True, "message": f"换上了{name(iid)}"}
    if action == "move":
        a, b = data.get("from"), data.get("to")
        if a not in SLOTS or b not in SLOTS or not eq.get(a) or a == b:
            return {"ok": False, "message": "挪不过去"}
        ia, ib = eq[a], eq.get(b)
        if not fits(ia, b) or (ib and not fits(ib, a)):
            return {"ok": False, "message": f"{name(ia)}不能放在{slot_name(b)}"}
        eq[a], eq[b] = ib, ia
        return {"ok": True, "message": ""}
    if action == "unequip":
        if slot not in SLOTS or not eq.get(slot):
            return {"ok": False, "message": "这一格是空的"}
        old = eq[slot]
        eq[slot] = None
        _bag_add(w, old, 1)
        return {"ok": True, "message": f"卸下了{name(old)}"}
    if action in ("gear_buy", "gear_sell"):
        s = w.settlements.get(pend.get("id", "")) if pend["type"] == "smith" else None
        if s is None:
            return {"ok": False, "message": "这里没有兵器铺"}
        if action == "gear_buy":
            if shop(w, s).get(iid, 0) <= 0:
                return {"ok": False, "message": "铺子里没有这件货"}
            price = int(item(iid)["price"])
            if p.gold < price:
                return {"ok": False, "message": f"钱不够（要{price}金）"}
            if slot is not None:
                if slot not in SLOTS or not fits(iid, slot):
                    return {"ok": False, "message": f"{name(iid)}不能放在{slot_name(slot)}"}
            p.gold -= price
            _ledger(w, s, iid, -1)
            _bag_add(w, iid, 1)
            if slot is not None:
                _bag_add(w, iid, -1)
                err = _put_on(w, iid, slot)
                if err:
                    _bag_add(w, iid, 1)
                    return {"ok": True, "message": f"花{price}金买下{name(iid)}，放进了包裹（{err}）"}
                return {"ok": True, "message": f"花{price}金买下{name(iid)}，当场换上"}
            return {"ok": True, "message": f"花{price}金买下{name(iid)}"}
        if slot is not None:
            if slot not in SLOTS or not eq.get(slot):
                return {"ok": False, "message": "这一格是空的"}
            iid = eq[slot]
            eq[slot] = None
        elif w.player["bag"].get(iid, 0) <= 0:
            return {"ok": False, "message": "包里没有这件东西"}
        else:
            _bag_add(w, iid, -1)
        gain = sell_price(iid)
        _ledger(w, s, iid, 1)
        p.gold += gain
        return {"ok": True, "message": f"卖掉{name(iid)}，得{gain}金"}
    return {"ok": False, "message": "现在不能这么做"}
