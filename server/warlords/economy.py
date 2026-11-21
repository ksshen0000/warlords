"""Production, markets, caravan trade, villagers, taxes, wages, recruiting, upgrades."""
from __future__ import annotations

from . import movement as M
from . import troops as T
from .common import nearest_settlement
from .data import BANDIT_TYPES, GOODS, TROOPS
from .model import Party, Settlement, World
from .rules import B, RULES

# per-culture workshop goods and troop-class preference live in rules/units.toml [cultures.*]
WORKSHOP = {c: v.get("workshop", "cloth") for c, v in RULES.units["cultures"].items()}
CLASS_PREF = {c: dict(v.get("class_pref", {})) for c, v in RULES.units["cultures"].items()}


def party_limit(w: World, hero_id: str) -> int:
    h = w.heroes[hero_id]
    lim = B.troops.party_limit_base + h.renown // 4 + 12 * len(w.fiefs_of(hero_id))
    if w.kingdoms[h.kingdom].ruler == hero_id:
        lim += 40
    return min(260, lim)


def market_town(w: World, v: Settlement) -> Settlement | None:
    b = w.settlements.get(v.bound)
    if b and b.kind == "town" and not b.siege and not w.at_war(v.faction, b.faction):
        return b
    return nearest_settlement(w, v.pos, lambda s: s.kind == "town" and not s.siege
                              and not w.at_war(v.faction, s.faction))


# ---------------------------------------------------------------- trade
def sell(w: World, town: Settlement, good: str, n: int) -> float:
    got = 0.0
    for _ in range(n):
        pr = w.price(town, good)
        got += pr
        town.market[good] = town.market.get(good, 0) + 1
    town.trade_income += got * B.economy.tariff
    return got * (1 - B.economy.tariff)


def buy(w: World, town: Settlement, good: str, n: int, budget: float) -> tuple[int, float]:
    bought, spent = 0, 0.0
    for _ in range(n):
        if town.market.get(good, 0) < 3:
            break
        pr = w.price(town, good)
        if spent + pr > budget:
            break
        spent += pr
        bought += 1
        town.market[good] -= 1
    return bought, spent


def caravan_at_town(w: World, p: Party, town: Settlement) -> None:
    """Sell everything, pick the most profitable next market, buy for it."""
    income = 0.0
    for g, n in list(p.cargo.items()):
        if n > 0:
            income += sell(w, town, g, n)
    p.cargo = {}
    p.gold += income
    side = w.side_of(p)
    best = None
    for d in w.settlements.values():
        if d.kind != "town" or d.id == town.id or d.siege or w.at_war(side, d.faction):
            continue
        cost = w.terrain.travel_cost(d.id, *town.pos)
        if cost > 1100:
            continue
        for g in GOODS:
            margin = w.price(d, g) * 0.92 - w.price(town, g)
            if margin <= 1:
                continue
            score = margin * min(B.economy.caravan_capacity, town.market.get(g, 0) - 3) - cost * 0.6
            if best is None or score > best[0]:
                best = (score, d, g)
    budget = max(0.0, p.gold - 250)
    if best and best[0] > 0:
        _, dest, g = best
        n, spent = buy(w, town, g, B.economy.caravan_capacity, budget)
        p.gold -= spent
        if n:
            p.cargo[g] = n
        # fill spare room with a second good if it also pays
        room = B.economy.caravan_capacity - n
        if room > 5:
            g2 = max(GOODS, key=lambda x: w.price(dest, x) * 0.92 - w.price(town, x) if x != g else -999)
            if w.price(dest, g2) * 0.92 - w.price(town, g2) > 2:
                n2, spent2 = buy(w, town, g2, room, max(0.0, p.gold - 250))
                p.gold -= spent2
                if n2:
                    p.cargo[g2] = n2
    else:
        towns = [s for s in w.settlements.values() if s.kind == "town" and s.id != town.id
                 and not w.at_war(side, s.faction) and not s.siege]
        dest = w.rng.choice(towns) if towns else town
    p.memo["dest"] = dest.id
    p.memo["profit"] = round(income)
    # profits go to the owner (or the town guild -> prosperity)
    if p.gold > 2600:
        surplus = p.gold - 1500
        p.gold = 1500.0
        if p.owner and p.owner in w.heroes:
            w.heroes[p.owner].gold += surplus
        else:
            town.prosperity = min(100.0, town.prosperity + surplus / 400)


def recruit(w: World, p: Party, s: Settlement) -> int:
    if not p.hero:
        return 0
    h = w.heroes[p.hero]
    room = party_limit(w, p.hero) - T.total(p.troops)
    n = 0
    keep = []
    for tid in s.volunteers:
        cost = B.troops.recruit_cost.t1 if TROOPS[tid]["tier"] <= 1 else B.troops.recruit_cost.t2
        if room > 0 and h.gold >= cost + 100:
            T.add(p.troops, tid, 1)
            h.gold -= cost
            room -= 1
            n += 1
        else:
            keep.append(tid)
    s.volunteers = keep
    if n:
        w.log("recruit", f"{h.name}在{s.name}招募了{n}名新兵（现有{T.healthy(p.troops)}人）", party=p.id, settlement=s.id)
    return n


def sell_prisoners(w: World, p: Party, town: Settlement) -> float:
    n = sum(p.prisoners.values())
    if not n:
        return 0.0
    gold = 0.0
    bounty = 0.0
    for tid, k in p.prisoners.items():
        gold += k * (8 + 10 * TROOPS[tid]["tier"])
        if TROOPS[tid]["culture"] == "bandit":
            bounty += k * B.bandits.bounty_per_bandit
    p.prisoners = {}
    total = gold + bounty
    if p.hero:
        w.heroes[p.hero].gold += total
        who = w.heroes[p.hero].name
    else:
        p.gold += total
        who = p.name
    w.log("prisoners_sold", f"{who}在{town.name}出售了{n}名俘虏，得{int(total)}金" + (f"（含剿匪赏金{int(bounty)}）" if bounty else ""),
          party=p.id, settlement=town.id)
    return total


def villager_arrive(w: World, p: Party, town: Settlement) -> None:
    value = 0.0
    for g, n in p.cargo.items():
        value += sell(w, town, g, n)
    p.cargo = {}
    home = w.settlements.get(p.home)
    if home:
        home.prosperity = min(60.0, home.prosperity + value / 500)
        owner = w.heroes.get(home.owner)
        if owner:
            owner.gold += value * 0.1
    M.set_place(p, p.home)
    p.memo["returning"] = True


# ---------------------------------------------------------------- daily
def daily(w: World) -> None:
    rng = w.rng
    hour = w.hour
    E = B.economy
    for s in w.settlements.values():
        s.tax_today = 0.0
        if s.kind == "village":
            if s.raided_until > hour or s.siege:
                continue
            s.stock += s.prosperity / E.village_production_divisor
            s.prosperity = min(60.0, s.prosperity + 0.05)
            s.militia = min(15 + s.prosperity / 3, s.militia + 1)
            out = any(q.alive and q.kind == "villager" and q.home == s.id for q in w.parties.values())
            if s.stock >= 12 and not out:
                town = market_town(w, s)
                if town:
                    pid = w.new_id("vl")
                    troops: dict = {}
                    T.add(troops, "villager", 6 + int(s.prosperity / 6))
                    q = Party(pid, "villager", f"{s.name}村民", s.faction, list(s.pos), troops, home=s.id,
                              cargo={s.produce or "grain": int(s.stock)})
                    s.stock -= int(s.stock)
                    w.parties[pid] = q
                    M.set_place(q, town.id)
            b = w.settlements.get(s.bound)
            if b and b.kind == "castle":
                b.food = min(120.0, b.food + 1.5)
            elif b and b.kind == "town" and not b.siege:
                b.food = min(200.0, b.food + s.prosperity / E.village_tithe_divisor)   # grain tithe to the granary
        elif s.kind == "town":
            s.produce = s.produce or WORKSHOP.get(s.culture, "cloth")
            s.market[s.produce] = s.market.get(s.produce, 0) + 1.5
            need = E.grain_need_base + s.prosperity * E.grain_need_per_prosperity
            if s.siege is None:
                s.market["grain"] = s.market.get("grain", 0) + E.farmland_grain   # farmland outside the walls
            grain = s.market.get("grain", 0)
            if grain >= need:
                s.market["grain"] = grain - need
                if s.market["grain"] > need * 4:
                    s.food = min(200.0, s.food + 1)
                    s.market["grain"] -= 1
                s.prosperity = min(100.0, s.prosperity + E.prosperity_growth)
            else:
                s.market["grain"] = 0
                s.food -= need - grain
                if s.food <= 0:
                    s.food = 0
                    s.prosperity = max(5.0, s.prosperity - E.starvation_prosperity_loss)
                    T.take_healthy(s.garrison, max(1, T.healthy(s.garrison) // 30), rng)
                    if rng.random() < 0.2:
                        w.log("starvation", f"{s.name}粮食断绝，城中饥荒", settlement=s.id)
            for g in GOODS:
                if g == "grain":
                    continue
                use = s.prosperity / 260
                if s.market.get(g, 0) >= use:
                    s.market[g] -= use
                    s.prosperity = min(100.0, s.prosperity + 0.03)
            if s.siege is None:
                s.tax_today = s.prosperity * E.town_tax_per_prosperity + s.trade_income
            s.trade_income = 0.0
        elif s.kind == "castle":
            s.food -= 0.5 + T.healthy(s.garrison) / 40
            if s.food <= 0:
                s.food = 0
                T.take_healthy(s.garrison, max(1, T.healthy(s.garrison) // 25), rng)
            elif s.siege is None:
                s.tax_today = float(E.castle_tax)
        if s.kind in ("town", "castle", "village") and len(s.volunteers) < 6 and rng.random() < 0.55:
            tier2 = s.kind == "town" and s.prosperity > 60 and rng.random() < 0.2
            s.volunteers.append(f"{s.culture}_{'inf2' if tier2 else 't1'}")
        if s.kind in ("town", "castle"):
            T.heal(s.garrison, 0.3, rng)
            if s.siege is None:
                s.militia = min((50 if s.kind == "town" else 30), s.militia + 0.5)
                for tid in [t for t in s.garrison if TROOPS[t]["tier"] == 1]:
                    k = sum(1 for _ in range(s.garrison[tid][0]) if rng.random() < 0.03)
                    if k:
                        s.garrison[tid][0] -= k
                        T.add(s.garrison, rng.choice(TROOPS[tid]["upgrades"]), k)
                T.prune(s.garrison)

    # income & wages
    for s in w.settlements.values():
        owner = w.heroes.get(s.owner) if s.owner else None
        if not owner:
            continue
        if s.kind == "village" and s.raided_until <= hour:
            owner.gold += s.prosperity * E.village_tax_per_hearth
        else:
            owner.gold += s.tax_today
        if s.kind in ("town", "castle"):
            owner.gold -= T.upkeep(s.garrison) * E.garrison_upkeep_share
    for k in w.kingdoms.values():
        if k.alive and k.ruler in w.heroes:
            w.heroes[k.ruler].gold += E.ruler_stipend
    for p in list(w.parties.values()):
        if not p.alive:
            continue
        rate = B.troops.heal_rate_settlement if p.inside else B.troops.heal_rate_field
        if p.kind == "player":
            from .character import party as _party_skill
            rate *= 1.0 + _party_skill(w, "wound_treatment")      # 疗伤
        T.heal(p.troops, min(0.95, rate), rng)
        if p.kind == "lord" and p.hero:
            h = w.heroes[p.hero]
            if not w.fiefs_of(h.id):
                h.gold += E.landless_stipend
            h.gold -= T.upkeep(p.troops)
            if h.gold < 0:
                h.gold = 0.0
                n = max(1, T.healthy(p.troops) // 25)
                T.take_healthy(p.troops, n, rng)
                w.log("desertion", f"{h.name}发不出军饷，{n}名士兵开小差", party=p.id, hero=h.id)
            _train(w, p, h)
        elif p.kind == "merc" and not p.contract:
            p.gold -= T.upkeep(p.troops) * 0.3

    # bandit hideouts
    active = [s for s in w.settlements.values() if s.kind == "hideout" and s.active]
    for s in active:
        mine = sum(1 for q in w.parties.values() if q.alive and q.kind == "bandit" and q.home == s.id)
        if mine < B.bandits.max_parties_per_hideout and rng.random() < B.bandits.spawn_chance:
            from .scenario import new_bandits
            new_bandits(w, s)
        if T.healthy(s.garrison) < 25:
            from .scenario import bandit_band
            T.merge(s.garrison, bandit_band(s.bandit_type, 2, rng))
    if len(active) < B.bandits.max_active_hideouts:
        dormant = [s for s in w.settlements.values() if s.kind == "hideout" and not s.active and s.timer <= hour]
        if dormant and rng.random() < B.bandits.reactivate_chance:
            from .scenario import bandit_band
            s = rng.choice(dormant)
            s.active = True
            s.garrison = bandit_band(s.bandit_type, rng.randint(14, 24), rng)
            w.log("hideout_new", f"一伙{BANDIT_TYPES[s.bandit_type][0]}在{s.name}落草为寇",
                  settlement=s.id, pos=list(s.pos))

    # keep the neutral economy alive
    towns = [s for s in w.settlements.values() if s.kind == "town"]
    from .scenario import new_caravan, new_hunters
    for t in towns:
        has = any(q.alive and q.kind == "caravan" and q.home == t.id and not q.owner for q in w.parties.values())
        if not has and not t.siege and rng.random() < E.caravan_respawn_chance:
            new_caravan(w, t.id, None)
    if sum(1 for q in w.parties.values() if q.alive and q.kind == "hunter") < B.neutral.bounty_hunters and rng.random() < 0.15:
        new_hunters(w, rng.choice(towns))


def _train(w: World, p: Party, h) -> None:
    rng = w.rng
    pref = CLASS_PREF.get(h.culture, {})
    counts = T.class_counts(p.troops)
    total = sum(counts.values()) or 1
    for tid, v in list(p.troops.items()):
        p.xp[tid] = p.xp.get(tid, 0) + v[0] * (1 + 0.5 * h.tactics)
    for tid in list(p.troops):
        t = TROOPS[tid]
        if not t["upgrades"] or p.troops[tid][0] <= 0:
            continue
        n = min(p.troops[tid][0], int(p.xp.get(tid, 0) // t["xp"]))
        n = min(n, int(max(0.0, h.gold - 300) // t["upgrade_cost"]))
        if n <= 0:
            continue
        opts = t["upgrades"]
        weights = [pref.get(TROOPS[o]["cls"], 1.0) / (0.3 + counts[TROOPS[o]["cls"]] / total) for o in opts]
        for _ in range(n):
            o = rng.choices(opts, weights)[0]
            p.troops[tid][0] -= 1
            T.add(p.troops, o, 1)
        p.xp[tid] -= n * t["xp"]
        h.gold -= n * t["upgrade_cost"]
    T.prune(p.troops)
