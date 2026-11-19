"""Small helpers shared by the simulation modules."""
from __future__ import annotations

import math

from . import troops as T
from .model import BANDIT, Party, Settlement, World


def nearest_settlement(w: World, pos, pred) -> Settlement | None:
    best, bd = None, float("inf")
    for s in w.settlements.values():
        if pred(s):
            d = (s.pos[0] - pos[0]) ** 2 + (s.pos[1] - pos[1]) ** 2
            if d < bd:
                best, bd = s, d
    return best


def safe_haven(w: World, p: Party, kinds=("town", "castle")) -> Settlement | None:
    """Nearest settlement this party may enter and that is not under siege."""
    side = w.side_of(p)

    def ok(s: Settlement) -> bool:
        if s.kind not in kinds or s.siege:
            return False
        if side == BANDIT:
            return s.kind == "hideout" and s.active
        if p.kind in ("lord", "merc") and side in w.kingdoms:
            return s.faction == side
        return not w.at_war(side, s.faction) if side in w.kingdoms else True
    if side == BANDIT:
        kinds = ("hideout",)
    return nearest_settlement(w, p.pos, ok)


def destroy_party(w: World, p: Party) -> None:
    if p.kind == "bandit" and w.player.get("quests"):
        from .quests import on_party_destroyed
        on_party_destroyed(w, p.id, bool(w.player.get("_battle_by_player")))
    p.alive = False
    p.target = None
    if p.hero:
        h = w.heroes[p.hero]
        if h.party == p.id:
            h.party = None
    if p.owner and p.owner in w.heroes and p.id in w.heroes[p.owner].caravans:
        w.heroes[p.owner].caravans.remove(p.id)
    if p.army and p.army in w.armies:
        a = w.armies[p.army]
        if p.hero in a.members:
            a.members.remove(p.hero)
    if p.contract and p.contract in w.kingdoms and p.id in w.kingdoms[p.contract].mercenaries:
        w.kingdoms[p.contract].mercenaries.remove(p.id)
    w.parties.pop(p.id, None)


def war_entry(w: World, a: str, b: str) -> dict | None:
    k = w.kingdoms.get(a)
    return k.wars.get(b) if k else None


def add_war_score(w: World, winner: str, loser: str, amount: float, losses_w: int = 0, losses_l: int = 0) -> None:
    ew, el = war_entry(w, winner, loser), war_entry(w, loser, winner)
    if ew is not None:
        ew["score"] = round(ew["score"] + amount, 1)
        ew["losses"][0] += losses_w
        ew["losses"][1] += losses_l
    if el is not None:
        el["score"] = round(el["score"] - amount, 1)
        el["losses"][0] += losses_l
        el["losses"][1] += losses_w


def party_label(w: World, p: Party) -> str:
    if p.hero:
        return w.heroes[p.hero].name
    return p.name


def is_free_hero_party(w: World, p: Party) -> bool:
    return p.kind == "lord" and p.hero is not None and w.heroes[p.hero].captive_of is None


def size(p: Party) -> int:
    return T.healthy(p.troops)


def dist(a, b) -> float:
    return math.hypot(a[0] - b[0], a[1] - b[1])


# ------------------------------------------------------------------ sight
def is_night(w: World) -> bool:
    from .rules import B
    h = w.hour % 24
    return h >= B.vision.night_start or h < B.vision.night_end


def sight(w: World, p: Party) -> float:
    """How far an AI party can see (the player's own radius is player.vision)."""
    from .rules import B
    v = B.vision
    cls = T.class_counts(p.troops)
    total = max(1, sum(cls.values()))
    r = v.npc_base + v.cavalry_bonus * cls["cav"] / total
    return r * (v.night_factor if is_night(w) else 1.0)


def realm_sees(w: World, kid: str, q: Party, extra: list | None = None) -> bool:
    """Kingdom intelligence: q is within sight of one of the realm's parties or fortresses."""
    from .rules import B
    for s in w.settlements.values():
        if s.faction != kid:
            continue
        r = B.vision.fort_watch if s.kind in ("town", "castle") else B.vision.village_watch if s.kind == "village" else 0
        if r and dist(s.pos, q.pos) <= r:
            return True
    for p in (extra or []) + [x for x in w.parties.values() if x.alive and x.faction == kid and not x.inside
                              and x.kind in ("lord", "caravan", "villager")]:
        if dist(p.pos, q.pos) <= sight(w, p):
            return True
    return False


# ------------------------------------------------------------- distances
def fort_days(w: World, sid: str, kid: str) -> float:
    """Days an ordinary party needs from settlement `sid` to the nearest town/castle of realm `kid`
    (follows roads, passes and fords — the real map distance, not a straight line)."""
    from .rules import B
    best = math.inf
    for s in w.kingdom_settlements(kid, ("town", "castle")):
        best = min(best, w.terrain.travel_cost(sid, *s.pos))
    return best / (B.movement.base_speed * 24) if best < math.inf else 99.0


def realm_days(w: World, a: str, b: str) -> float:
    """How far apart two realms are: days between their closest pair of towns/castles."""
    return min((fort_days(w, s.id, a) for s in w.kingdom_settlements(b, ("town", "castle"))), default=99.0)
