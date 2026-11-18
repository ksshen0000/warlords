"""Build the starting world on top of a generated continent."""
from __future__ import annotations

import math
import random

from . import data as D
from . import troops as T
from .model import BANDIT, Hero, Kingdom, Party, Settlement, World
from .terrain import generate

from .rules import B

FIEF_HOLDERS = D.FIEF_HOLDERS      # from rules/world.toml


def culture_army(culture: str, size: int, rng: random.Random, quality: float = 0.5) -> dict:
    """A plausible mixed roster of `size` troops of a culture. quality 0..1 shifts tiers up."""
    r: dict = {}
    weights = [
        (f"{culture}_t1", 3.0 - 2 * quality), (f"{culture}_inf2", 2.0), (f"{culture}_arc2", 1.6),
        (f"{culture}_inf3", 0.6 + 1.2 * quality), (f"{culture}_arc3", 0.5 + quality),
        (f"{culture}_cav3", 0.4 + quality), (f"{culture}_inf4", 0.1 + 0.5 * quality),
        (f"{culture}_arc4", 0.1 + 0.4 * quality), (f"{culture}_cav4", 0.05 + 0.4 * quality),
    ]
    ids, ws = zip(*weights)
    for tid in rng.choices(ids, ws, k=size):
        T.add(r, tid, 1)
    return r


def bandit_band(btype: str, size: int, rng: random.Random) -> dict:
    r: dict = {}
    tid = D.BANDIT_TYPES[btype][1]
    boss = max(1, size // 10)
    T.add(r, "bandit_boss", boss)
    T.add(r, tid, size - boss)
    return r


def new_caravan(w: World, home: str, owner: str | None) -> Party:
    s = w.settlements[home]
    pid = w.new_id("cv")
    troops: dict = {}
    T.add(troops, "caravan_guard", w.rng.randint(10, 16))
    T.add(troops, f"{s.culture}_inf2", w.rng.randint(4, 8))
    name = f"{w.heroes[owner].name}的商队" if owner else f"{s.name}商队"
    p = Party(pid, "caravan", name, s.faction, list(s.pos), troops, owner=owner, home=home,
              gold=1500.0 if owner else 1200.0)
    w.parties[pid] = p
    if owner:
        w.heroes[owner].caravans.append(pid)
    return p


def new_bandits(w: World, hideout: Settlement, size: int | None = None) -> Party:
    pid = w.new_id("bd")
    size = size or w.rng.randint(10, 28)
    bname = D.BANDIT_TYPES[hideout.bandit_type][0]
    p = Party(pid, "bandit", bname, BANDIT, list(hideout.pos), bandit_band(hideout.bandit_type, size, w.rng),
              home=hideout.id, gold=float(w.rng.randint(20, 120)))
    w.parties[pid] = p
    return p


def spawn_refugees(w: World, v: Settlement) -> Party | None:
    """A raided village empties onto the roads: 流民 walking to the nearest town of their realm."""
    from .common import nearest_settlement
    R = B.refugee
    n = int(R.size_base + v.prosperity * R.size_per_prosperity)
    if n <= 0:
        return None
    dest = nearest_settlement(w, v.pos, lambda s: s.kind == "town" and s.faction == v.faction and not s.siege) \
        or nearest_settlement(w, v.pos, lambda s: s.kind == "town" and not s.siege)
    if dest is None:
        return None
    pid = w.new_id("rf")
    troops: dict = {}
    T.add(troops, "villager", n)
    p = Party(pid, "refugee", f"{v.name}流民", None, list(v.pos), troops, home=v.id, gold=float(w.rng.randint(5, 40)))
    p.memo.update({"culture": v.culture, "until": w.hour + 24 * R.days, "dest": dest.id, "origin": v.faction})
    w.parties[pid] = p
    return p


def new_hunters(w: World, town: Settlement) -> Party:
    pid = w.new_id("bh")
    troops: dict = {}
    T.add(troops, "hunter", w.rng.randint(14, 22))
    T.add(troops, f"{town.culture}_arc2", w.rng.randint(4, 8))
    p = Party(pid, "hunter", "赏金猎人", None, list(town.pos), troops, home=town.id, gold=300.0)
    w.parties[pid] = p
    return p


def new_lord_party(w: World, hero: Hero, at: Settlement, size: int) -> Party:
    pid = w.new_id("lp")
    p = Party(pid, "lord", f"{hero.name}的部队", hero.kingdom, list(at.pos),
              culture_army(hero.culture, size, w.rng, 0.45), hero=hero.id, home=at.id)
    w.parties[pid] = p
    hero.party = pid
    return p


def default_world(seed: int = 0, with_player: bool = True) -> World:
    terrain = generate(seed)
    rng = random.Random(seed)
    w = World(seed=seed, terrain=terrain, rng=rng)

    for kid, name, culture, color, _cap in D.KINGDOMS:
        w.kingdoms[kid] = Kingdom(kid, name, culture, color, ruler=D.RULERS[kid])
    for a, b in D.INITIAL_WARS:
        w.kingdoms[a].wars[b] = {"since": 0, "score": 0.0, "losses": [0, 0]}
        w.kingdoms[b].wars[a] = {"since": 0, "score": 0.0, "losses": [0, 0]}

    # heroes
    for hid, name, kid, (ag, ca, ho, gr), persona, tactics in D.LORDS:
        k = w.kingdoms[kid]
        w.heroes[hid] = Hero(hid, name, kid, k.culture,
                             {"aggression": ag, "caution": ca, "honor": ho, "greed": gr}, persona, tactics,
                             gold=1600.0 + 500 * gr + rng.randint(0, 400),
                             influence=150.0 if k.ruler == hid else 40.0 + rng.randint(0, 30),
                             renown=60 if k.ruler == hid else 20)
    for h in w.heroes.values():
        for o in w.heroes.values():
            if o.id != h.id and o.kingdom == h.kingdom:
                h.relations[o.id] = 10
    for a, b, v in D.INITIAL_RELATIONS:
        w.heroes[a].relations[b] = v

    # fortified settlements
    names = {c: list(v) for c, v in D.SETTLEMENT_NAMES.items()}
    counters: dict[str, int] = {}
    fort_ids = []
    for kid, culture, kind, pos in terrain.sites["fortified"]:
        i = counters.get(kid, 0)
        counters[kid] = i + 1
        sid = f"{kid}{i}"
        town = kind == "town"
        s = Settlement(sid, names[culture].pop(0), kind, [round(pos[0], 1), round(pos[1], 1)], culture, kid,
                       FIEF_HOLDERS[kid][i] if i < len(FIEF_HOLDERS[kid]) else w.kingdoms[kid].ruler,
                       garrison=culture_army(culture, B.siege.town_garrison if town else B.siege.castle_garrison, rng,
                                              0.35 if town else 0.55),
                       militia=40.0 if town else 25.0, walls=(3 if i == 0 else 2) if town else 3,
                       prosperity=float(rng.randint(60, 90)) if town else float(rng.randint(25, 40)),
                       food=140.0 if town else 90.0, loyalty=float(B.loyalty.start))
        if town:
            s.market = {g: float(rng.randint(6, 18)) for g in D.GOODS}
        s.volunteers = [f"{culture}_t1"] * rng.randint(3, 5) + [f"{culture}_inf2"] * rng.randint(0, 1)
        w.settlements[sid] = s
        fort_ids.append(sid)

    # villages
    vnames = {c: v[8:] for c, v in D.SETTLEMENT_NAMES.items()}
    for fi, pos in terrain.sites["villages"]:
        bound = w.settlements[fort_ids[fi]]
        biome = terrain.biome_at(*pos)
        goods = D.VILLAGE_GOODS.get(biome, ["grain"])
        vid = f"{bound.id}v{len(bound.villages)}"
        pool = vnames[bound.culture]
        name = pool.pop(0) if pool else f"{bound.name}村"
        v = Settlement(vid, name, "village", [round(pos[0], 1), round(pos[1], 1)], bound.culture, bound.faction,
                       bound.owner, bound=bound.id, militia=15.0, prosperity=float(rng.randint(20, 45)),
                       produce=rng.choice(goods), stock=float(rng.randint(0, 6)))
        v.volunteers = [f"{bound.culture}_t1"] * rng.randint(2, 5)
        bound.villages.append(vid)
        w.settlements[vid] = v
        if bound.kind == "town":
            bound.market[v.produce] = bound.market.get(v.produce, 0) + 10

    # bandit hideouts: a spread of types, some dormant for later respawns
    cands = list(terrain.sites["hideouts"])
    rng.shuffle(cands)
    by_type: dict[str, list] = {}
    for bt, pos in cands:
        by_type.setdefault(bt, []).append(pos)
    chosen = []
    n_hide = int(D.LAYOUT.get("hideouts", 14))
    while len(chosen) < n_hide and any(by_type.values()):
        for bt in list(by_type):
            if by_type[bt] and len(chosen) < n_hide:
                chosen.append((bt, by_type[bt].pop()))
    hn = list(D.HIDEOUT_NAMES)
    for i, (bt, pos) in enumerate(chosen):
        hid = f"hide{i}"
        s = Settlement(hid, (hn[i] if i < len(hn) else f"匪巢{i}"), "hideout",
                       [round(pos[0], 1), round(pos[1], 1)], "bandit", BANDIT, None, bandit_type=bt,
                       active=i < B.bandits.max_active_hideouts, garrison=bandit_band(bt, rng.randint(14, 24), rng))
        w.settlements[hid] = s

    for s in w.settlements.values():
        terrain.places[s.id] = tuple(s.pos)
    terrain.precompute_flows(f"{seed}")

    # lord parties
    for h in w.heroes.values():
        fiefs = w.fiefs_of(h.id)
        home = fiefs[0] if fiefs else w.settlements[f"{h.kingdom}0"]
        new_lord_party(w, h, home, rng.randint(55, 85) + (25 if w.kingdoms[h.kingdom].ruler == h.id else 0))

    # neutral & economic parties
    for s in list(w.settlements.values()):
        if s.kind == "town":
            new_caravan(w, s.id, None)
    for hid in D.CARAVAN_OWNERS:
        town = next((s for s in w.fiefs_of(hid) if s.kind == "town"), w.settlements[f"{w.heroes[hid].kingdom}0"])
        new_caravan(w, town.id, hid)
        w.heroes[hid].gold -= 1000
    for s in w.settlements.values():
        if s.kind == "hideout" and s.active:
            for _ in range(rng.randint(1, 2)):
                new_bandits(w, s)
    towns = [s for s in w.settlements.values() if s.kind == "town"]
    for town in rng.sample(towns, 3):
        new_hunters(w, town)
    for (name, troop), town in zip(D.MERC_COMPANIES, rng.sample(towns, len(D.MERC_COMPANIES))):
        pid = w.new_id("mc")
        troops: dict = {}
        T.add(troops, troop, rng.randint(25, 35))
        T.add(troops, "merc_arc", rng.randint(10, 18))
        T.add(troops, "merc_inf", rng.randint(10, 18))
        w.parties[pid] = Party(pid, "merc", name, None, list(town.pos), troops, home=town.id, gold=500.0)
    if with_player:
        from .player import create
        create(w)
    return w


def nearest(w: World, pos, pred) -> Settlement | None:
    best = None
    for s in w.settlements.values():
        if pred(s):
            d = math.dist(pos, s.pos)
            if best is None or d < best[0]:
                best = (d, s)
    return best[1] if best else None
