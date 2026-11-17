"""Hourly behaviour: neutral parties (bandits, caravans, villagers, bounty hunters,
mercenaries) and the tactical layer + order execution for lords."""
from __future__ import annotations

import math

from . import economy as E
from . import movement as M
from . import troops as T
from . import warfare as WF
from .common import destroy_party, dist, nearest_settlement, safe_haven
from .model import Party, World

SIGHT = 55.0


def _nearby(w: World, p: Party, radius: float):
    for q in w.parties.values():
        if q is p or not q.alive or q.inside:
            continue
        d = dist(p.pos, q.pos)
        if d <= radius:
            yield d, q


def _threat(w: World, p: Party, radius: float = 40.0, margin: float = 1.15):
    """Most dangerous hostile party nearby that could beat us."""
    if p.army:
        return None
    mine = w.party_power(p)
    friends = sum(w.party_power(q) for d, q in _nearby(w, p, 20) if not w.hostile(p, q)
                  and q.kind in ("lord", "merc", "hunter"))
    best = None
    for d, q in _nearby(w, p, radius):
        if not w.hostile(p, q) or q.kind in ("caravan", "villager") or q.mode == "flee":
            continue
        if q.kind == "hunter" and p.kind != "bandit":
            continue
        qp = w.party_power(q)
        if qp > (mine + friends) * margin and (best is None or qp > best[1]):
            best = (q, qp)
    return best[0] if best else None


def _prey(w: World, p: Party, radius: float, ratio: float, kinds=None):
    mine = w.party_power(p)
    best = None
    for d, q in _nearby(w, p, radius):
        if not w.hostile(p, q) or (kinds and q.kind not in kinds):
            continue
        if q.inside:
            continue
        qp = w.party_power(q)
        if qp * ratio < mine:
            score = d - (40 if q.kind in ("caravan", "villager") else 0)
            if best is None or score < best[0]:
                best = (score, q)
    return best[1] if best else None


def _engage_if_contact(w: World, p: Party) -> bool:
    if p.target and p.target["kind"] == "party" and p.mode in ("chase",):
        q = w.parties.get(p.target["id"])
        if q and q.alive and not q.inside and w.hostile(p, q) and dist(p.pos, q.pos) <= M.CONTACT:
            WF.field_battle(w, p, q)
            return True
    return False


def _leave_settlement(w: World, p: Party) -> None:
    if p.inside:
        s = w.settlements[p.inside]
        p.inside = None
        p.pos = list(w.terrain.nearest_passable(s.pos[0], s.pos[1], 2))


def _patrol_point(w: World, p: Party, center, radius: float):
    tr = w.terrain
    for _ in range(12):
        a = w.rng.uniform(0, math.tau)
        r = w.rng.uniform(radius * 0.3, radius)
        x, y = center[0] + math.cos(a) * r, center[1] + math.sin(a) * r
        if tr.passable(x, y) and tr.line_passable(p.pos[0], p.pos[1], x, y):
            return x, y
    return None


# ------------------------------------------------------------- bandits
def bandit(w: World, p: Party) -> None:
    if _engage_if_contact(w, p):
        return
    th = _threat(w, p, 45, 0.9)
    if th:
        home = w.settlements.get(p.home)
        M.flee_from(w, p, th.pos, home.id if home and home.active else None)
        p.memo["flee_until"] = w.hour + 6
        return
    if p.mode == "flee" and p.memo.get("flee_until", 0) > w.hour:
        return
    if p.mode == "chase":
        q = w.parties.get(p.target["id"]) if p.target else None
        if q and q.alive and not q.inside and dist(q.pos, p.pos) < 90 and w.hour < p.memo.get("chase_until", 0):
            return
    prey = _prey(w, p, SIGHT, 1.25)
    if prey:
        M.set_party(p, prey.id, "chase")
        p.memo["chase_until"] = w.hour + 14
        return
    if p.mode in ("idle", "chase", "flee") or not p.target or M.arrived(w, p):
        home = w.settlements.get(p.home)
        center = home.pos if home and home.active else p.pos
        if p.mode == "move" and M.arrived(w, p):
            p.mode = "idle"
            p.timer = w.rng.randint(2, 8)
        if p.mode == "idle":
            p.timer -= 1
            if p.timer > 0:
                return
        pt = _patrol_point(w, p, center, 110)
        if pt:
            M.set_point(p, *pt)


# ------------------------------------------------------------ caravans
def caravan(w: World, p: Party) -> None:
    if p.inside:
        p.timer -= 1
        if p.timer > 0:
            return
        dest = p.memo.get("dest")
        s = w.settlements.get(dest)
        if not s or s.siege or w.at_war(w.side_of(p), s.faction):
            E.caravan_at_town(w, p, w.settlements[p.inside])
            dest = p.memo.get("dest")
        _leave_settlement(w, p)
        M.set_place(p, dest)
        return
    th = _threat(w, p, 45, 0.85)
    if th:
        haven = safe_haven(w, p, ("town", "castle"))
        M.flee_from(w, p, th.pos, haven.id if haven else None)
        p.memo["flee_until"] = w.hour + 5
        return
    if p.mode == "flee":
        if p.memo.get("flee_until", 0) > w.hour and not M.arrived(w, p):
            return
        p.mode = "move"
        if p.memo.get("dest") in w.settlements:
            M.set_place(p, p.memo["dest"])
    if p.target and p.target["kind"] == "place" and M.arrived(w, p):
        s = w.settlements[p.target["id"]]
        if s.kind == "town" and not w.at_war(w.side_of(p), s.faction):
            p.inside = s.id
            p.target = None
            p.mode = "inside"
            p.timer = w.rng.randint(3, 8)
            E.caravan_at_town(w, p, s)
        else:
            p.memo["dest"] = None
            p.inside = None
            towns = [t for t in w.settlements.values() if t.kind == "town" and not w.at_war(w.side_of(p), t.faction)]
            if towns:
                M.set_place(p, min(towns, key=lambda t: dist(t.pos, p.pos)).id)
    elif not p.target:
        home = w.settlements.get(p.home)
        M.set_place(p, p.memo.get("dest") or (home.id if home else None))


# ------------------------------------------------------------ villagers
def villager(w: World, p: Party) -> None:
    th = _threat(w, p, 35, 0.5)
    if th:
        haven = w.settlements.get(p.home) if p.memo.get("returning") else None
        M.flee_from(w, p, th.pos, haven.id if haven else None)
        p.memo["flee_until"] = w.hour + 4
        return
    if p.mode == "flee":
        if p.memo.get("flee_until", 0) > w.hour:
            return
        p.mode = "move"
        p.target = None
    if not p.target:
        if p.memo.get("returning"):
            M.set_place(p, p.home)
        else:
            v = w.settlements.get(p.home)
            town = E.market_town(w, v) if v else None
            if town:
                M.set_place(p, town.id)
            else:
                destroy_party(w, p)
        return
    if p.target["kind"] == "place" and M.arrived(w, p):
        s = w.settlements[p.target["id"]]
        if s.id == p.home:
            destroy_party(w, p)
        elif s.kind == "town":
            E.villager_arrive(w, p, s)


# ------------------------------------------------------- bounty hunters
def hunter(w: World, p: Party) -> None:
    if p.inside:
        p.timer -= 1
        if p.timer <= 0:
            _leave_settlement(w, p)
        return
    if _engage_if_contact(w, p):
        return
    if p.target and p.target["kind"] == "place" and M.arrived(w, p):
        s = w.settlements[p.target["id"]]
        if s.kind == "hideout" and s.active:
            WF.assault_hideout(w, p, s)
            return
        if s.kind == "town":
            E.sell_prisoners(w, p, s)
            p.inside, p.target, p.mode, p.timer = s.id, None, "inside", w.rng.randint(6, 18)
            return
    if sum(p.prisoners.values()) >= 10 or T.healthy(p.troops) < 10:
        if not (p.target and p.target["kind"] == "place" and w.settlements[p.target["id"]].kind == "town"):
            town = nearest_settlement(w, p.pos, lambda s: s.kind == "town" and not s.siege)
            if town:
                M.set_place(p, town.id)
        return
    if p.mode == "chase" and p.target:
        q = w.parties.get(p.target["id"])
        if q and q.alive and dist(q.pos, p.pos) < 220:
            return
    prey = _prey(w, p, 220, 1.3, ("bandit",))
    if prey:
        M.set_party(p, prey.id, "chase")
        return
    if not p.target or M.arrived(w, p) or p.mode == "idle":
        mine = w.party_power(p)
        lair = nearest_settlement(w, p.pos, lambda s: s.kind == "hideout" and s.active
                                  and T.power(s.garrison) * 1.3 < mine and dist(s.pos, p.pos) < 300)
        if lair:
            M.set_place(p, lair.id)
            return
        pt = _patrol_point(w, p, p.pos, 160)
        if pt:
            M.set_point(p, *pt)


# ---------------------------------------------------------- mercenaries
def merc(w: World, p: Party) -> None:
    if p.inside:
        p.timer -= 1
        if p.timer <= 0 or p.contract:
            _leave_settlement(w, p)
        return
    if _engage_if_contact(w, p):
        return
    th = _threat(w, p, 40, 1.3)
    if th:
        haven = safe_haven(w, p)
        M.flee_from(w, p, th.pos, haven.id if haven else None)
        return
    if p.mode == "chase" and p.target:
        q = w.parties.get(p.target["id"])
        if q and q.alive and not q.inside and dist(q.pos, p.pos) < 200 and w.hostile(p, q):
            return
    kinds = ("lord", "caravan", "villager", "bandit", "merc") if p.contract else ("bandit",)
    prey = _prey(w, p, 200 if p.contract else 120, 1.2, kinds)
    if prey:
        M.set_party(p, prey.id, "chase")
        return
    if not p.target or M.arrived(w, p) or p.mode == "idle":
        if p.contract:
            r = w.hero_party(w.kingdoms[p.contract].ruler)
            if r and dist(r.pos, p.pos) > 30:
                M.set_party(p, r.id, "follow")
                return
        if sum(p.prisoners.values()) > 10:
            town = nearest_settlement(w, p.pos, lambda s: s.kind == "town" and not w.at_war(w.side_of(p), s.faction))
            if town:
                M.set_place(p, town.id)
                return
        pt = _patrol_point(w, p, p.pos, 120)
        if pt:
            M.set_point(p, *pt)
    if p.target and p.target["kind"] == "place" and M.arrived(w, p):
        s = w.settlements[p.target["id"]]
        if s.kind == "town":
            E.sell_prisoners(w, p, s)
            p.inside, p.target, p.mode, p.timer = s.id, None, "inside", 12


# --------------------------------------------------------------- lords
URGENT = ("defend", "retreat")


def lord(w: World, p: Party) -> None:
    """Tactical layer (always rule-based) + execution of the strategic order."""
    h = w.heroes[p.hero]
    o = p.order or {}
    if o:
        o["age"] = o.get("age", 0) + 1
    # army members just follow the leader
    if p.army and p.army in w.armies and w.armies[p.army].leader != h.id:
        a = w.armies[p.army]
        lp = w.hero_party(a.leader)
        if p.inside and lp and lp.inside != p.inside:
            _leave_settlement(w, p)
        if lp and not p.inside:
            if lp.mode == "siege":
                s = w.settlements.get(lp.memo.get("siege"))
                if s and dist(p.pos, s.pos) < 8:
                    if p.mode != "siege":
                        WF.start_siege(w, p, s)
                    return
            if lp.inside:
                if dist(p.pos, lp.pos) < 6:
                    p.inside, p.target, p.mode = lp.inside, None, "inside"
                    return
            M.set_party(p, lp.id, "follow")
        return
    if _engage_if_contact(w, p):
        return
    if p.mode in ("siege", "raid"):
        return
    if p.inside:
        s = w.settlements[p.inside]
        if o.get("type") in ("defend", "rest") and o.get("target") == s.id and o.get("age", 0) < 48:
            return
        if s.siege and w.at_war(h.kingdom, s.siege["kingdom"]):
            return          # trapped inside: help defend the walls
        if o.get("type") in ("defend", "rest", "recruit", "sell", "caravan", "wait") or not o:
            if o.get("age", 0) >= 6 or not o:
                p.order = None
            if p.order is None:
                return
        _leave_settlement(w, p)

    # flee from overwhelming enemies (unless already locked in battle plans)
    th = _threat(w, p, 38, 1.35 + 0.15 * h.traits["aggression"] - 0.1 * h.traits["caution"])
    if th:
        haven = safe_haven(w, p)
        if p.memo.get("fleeing") != th.id:
            w.log("flee", f"{h.name}避开了{WF._names(w, [th])}的追击", party=p.id)
        p.memo["fleeing"] = th.id
        M.flee_from(w, p, th.pos, haven.id if haven else None)
        p.memo["flee_until"] = w.hour + 6
        return
    if p.mode == "flee" and p.memo.get("flee_until", 0) > w.hour and o.get("type") != "retreat":
        return
    p.memo.pop("fleeing", None)

    # opportunistic strikes on weak enemies close by
    if o.get("type") not in URGENT and o.get("type") != "attack":
        ratio = 1.6 - 0.15 * h.traits["aggression"] + 0.15 * h.traits["caution"]
        prey = _prey(w, p, 32, ratio)
        if prey and (prey.kind != "villager" or h.traits["honor"] < 1):
            if p.memo.get("chase") != prey.id:
                p.memo["chase"] = prey.id
                p.memo["chase_until"] = w.hour + 10
            if w.hour < p.memo["chase_until"]:
                M.set_party(p, prey.id, "chase")
                return
    if p.memo.get("chase") and p.mode == "chase":
        p.memo.pop("chase", None)
        p.mode = "move"
        _apply_order_target(w, p)

    _execute(w, p, h)


def _apply_order_target(w: World, p: Party) -> None:
    o = p.order
    if not o:
        M.stop(p)
        return
    t, tgt = o["type"], o.get("target")
    if t in ("recruit", "defend", "besiege", "raid", "hideout", "sell", "rest", "caravan", "retreat") and tgt:
        if tgt in w.settlements:
            M.set_place(p, tgt)
    elif t == "attack" and tgt in w.parties:
        M.set_party(p, tgt, "chase")
    elif t == "patrol" and tgt in w.settlements:
        pt = _patrol_point(w, p, w.settlements[tgt].pos, 80)
        if pt:
            M.set_point(p, *pt)
    elif t == "wait":
        M.stop(p)


def _execute(w: World, p: Party, h) -> None:
    o = p.order
    if not o:
        return
    t, tgt = o["type"], o.get("target")
    if t == "attack":
        q = w.parties.get(tgt)
        if not q or not q.alive or not w.hostile(p, q) or o["age"] > 30:
            p.order = None
            M.stop(p)
            return
        if not p.target or p.target.get("id") != tgt:
            M.set_party(p, tgt, "chase")
        return
    if t == "patrol":
        if o["age"] > 48:
            p.order = None
            return
        if not p.target or M.arrived(w, p) or p.mode == "idle":
            _apply_order_target(w, p)
        return
    if t == "wait":
        if o["age"] > 12:
            p.order = None
        return
    if not p.target or p.mode == "idle":
        _apply_order_target(w, p)
    if not M.arrived(w, p):
        return
    s = w.settlements.get(tgt)
    if s is None:
        p.order = None
        return
    if t == "besiege":
        if w.hostile_to_settlement(p, s) and s.kind in ("town", "castle"):
            WF.start_siege(w, p, s)
        else:
            p.order = None
    elif t == "raid":
        if w.hostile_to_settlement(p, s) and s.raided_until <= w.hour:
            WF.start_raid(w, p, s)
        else:
            p.order = None
    elif t == "hideout":
        if s.active:
            WF.assault_hideout(w, p, s)
        p.order = None
    elif t in ("recruit", "sell", "rest", "defend", "caravan", "retreat"):
        friendly = not w.at_war(h.kingdom, s.faction)
        if t == "recruit" and friendly:
            E.recruit(w, p, s)
        if s.kind in ("town", "castle") and s.faction == h.kingdom:
            if t in ("sell", "recruit", "rest", "defend") and s.kind == "town":
                E.sell_prisoners(w, p, s)
            if t == "caravan" and h.gold > 1600:
                from .scenario import new_caravan
                c = new_caravan(w, s.id, h.id)
                h.gold -= 1500
                w.log("caravan_founded", f"{h.name}在{s.name}组建了商队", party=c.id, hero=h.id)
            p.inside, p.target, p.mode = s.id, None, "inside"
            o["age"] = 0
            if t in ("recruit", "sell", "caravan", "retreat"):
                o["age"] = 40      # brief stop, then re-plan soon
        else:
            p.order = None
            M.stop(p)


def hourly(w: World) -> None:
    for p in list(w.parties.values()):
        if not p.alive:
            continue
        if T.healthy(p.troops) == 0 and p.kind != "lord":
            destroy_party(w, p)
            continue
        k = p.kind
        if k == "bandit":
            bandit(w, p)
        elif k == "caravan":
            caravan(w, p)
        elif k == "villager":
            villager(w, p)
        elif k == "hunter":
            hunter(w, p)
        elif k == "merc":
            merc(w, p)
        elif k == "lord" and p.hero:
            lord(w, p)
