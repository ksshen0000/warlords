"""Enumerate the legal strategic options for a lord (or army leader).

Every brain picks from this list by index, so even an LLM can never issue an
illegal order. Each option carries the facts a sensible commander would weigh.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from . import troops as T
from .data import KIND_NAMES
from .common import dist, fort_days, realm_sees
from .data import BANDIT_TYPES, GOODS
from .model import Hero, Party, World, party_speed
from .rules import B

MAX_DAYS = 10.0


@dataclass
class Option:
    type: str
    target: str | None
    label: str
    info: dict = field(default_factory=dict)


def army_power(w: World, p: Party) -> float:
    if not p.army or p.army not in w.armies:
        return w.party_power(p)
    a = w.armies[p.army]
    total = 0.0
    for hid in [a.leader] + a.members:
        q = w.hero_party(hid)
        if q and q.army == p.army:
            total += w.party_power(q)
    return total


def threat_near(w: World, side: str, pos, radius: float = 150.0) -> float:
    return sum(w.party_power(q) for q in w.parties.values()
               if q.alive and q.kind in ("lord", "merc") and not q.inside
               and w.at_war(side, w.side_of(q)) and dist(q.pos, pos) < radius)


def _days(w: World, p: Party, place: str) -> float:
    return round(w.travel_days(p, place), 1)


def lord_options(w: World, h: Hero) -> list[Option]:
    from .economy import party_limit
    from .politics import army_candidates

    p = w.hero_party(h.id)
    if p is None:
        return [Option("wait", None, "原地待命")]
    opts: list[Option] = []
    k = w.kingdoms[h.kingdom]
    side = h.kingdom
    n = T.healthy(p.troops)
    my = army_power(w, p)
    leader_of_army = bool(p.army and p.army in w.armies and w.armies[p.army].leader == h.id)
    lim = party_limit(w, h.id)

    # ---- recruit
    if h.gold > 250 and T.total(p.troops) < lim - 5:
        cands = []
        for s in w.settlements.values():
            if s.kind not in ("town", "castle", "village") or len(s.volunteers) < 2 or s.siege:
                continue
            if w.at_war(side, s.faction) or s.raided_until > w.hour or dist(s.pos, p.pos) > 400:
                continue
            d = _days(w, p, s.id)
            if d <= MAX_DAYS:
                cands.append((d, s))
        for d, s in sorted(cands, key=lambda x: x[0] - 0.15 * len(x[1].volunteers))[:3]:
            opts.append(Option("recruit", s.id, f"前往{s.name}招募（{len(s.volunteers)}名志愿兵，{d}天）",
                               {"days": d, "count": len(s.volunteers)}))

    # ---- defend own realm
    dcands = []
    for s in w.kingdom_settlements(side, ("town", "castle")):
        d = _days(w, p, s.id)
        if d > MAX_DAYS:
            continue
        enemy = 0.0
        if s.siege:
            enemy = sum(w.party_power(q) for q in w.parties.values()
                        if q.alive and q.mode == "siege" and q.memo.get("siege") == s.id)
        dcands.append((0 if s.siege else 1, d, s, enemy))
    for _pri, d, s, enemy in sorted(dcands, key=lambda x: (x[0], x[1]))[:4]:
        tag = f"【正被围攻，敌军战力{enemy:.0f}，攻城进度{s.siege['progress']:.0%}】" if s.siege else ""
        mine = "（你的封地）" if s.owner == h.id else ""
        opts.append(Option("defend", s.id, f"驻防/支援{s.name}{mine}{tag}（{d}天）",
                           {"days": d, "sieged": bool(s.siege), "enemy_power": enemy, "own_fief": s.owner == h.id}))

    can_fight = n >= 25 and (not p.army or leader_of_army)
    if can_fight and k.wars:
        # ---- besiege
        bc = []
        for s in w.settlements.values():
            if s.kind not in ("town", "castle") or not w.at_war(side, s.faction):
                continue
            d = _days(w, p, s.id)
            if d > MAX_DAYS:
                continue
            inside = sum(w.party_power(q) for q in w.parties.values() if q.alive and q.inside == s.id
                         and w.side_of(q) == s.faction)
            defense = (T.power(s.garrison) + s.militia) * (1 + B.siege.wall_bonus_per_level * s.walls) + inside
            allies = sum(w.party_power(q) for q in w.parties.values() if q.alive and q.mode == "siege"
                         and q.memo.get("siege") == s.id and w.side_of(q) == side and q is not p)
            home = fort_days(w, s.id, side)
            bc.append((d, s, defense, allies, threat_near(w, side, s.pos), home))
        for d, s, defense, allies, threat, home in sorted(bc, key=lambda x: x[2] / max(1, my) + x[0] * 0.3 + x[5] * 0.4)[:4]:
            extra = f"，友军已在围城（战力{allies:.0f}）" if allies else ""
            extra += f"，附近敌军战力{threat:.0f}" if threat else ""
            extra += f"，离本国最近的城池{home:.1f}天" + ("（孤悬在外，难以守住）" if home > B.ai.far_target_free_days * 2 else "")
            opts.append(Option("besiege", s.id,
                               f"围攻{s.name}（{w.kingdoms[s.faction].name}{KIND_NAMES[s.kind]}，"
                               f"城防战力约{defense:.0f}{extra}，{d}天）",
                               {"days": d, "defense": defense, "ally_power": allies, "threat": threat,
                                "kind": s.kind, "prosperity": s.prosperity, "from_home": home}))
        # ---- raid villages
        rc = []
        for s in w.settlements.values():
            if s.kind != "village" or not w.at_war(side, s.faction) or s.raided_until > w.hour:
                continue
            if dist(s.pos, p.pos) > 600:
                continue
            d = _days(w, p, s.id)
            if d <= 5:
                rc.append((d, s, threat_near(w, side, s.pos, 120)))
        for d, s, threat in sorted(rc, key=lambda x: x[0])[:3]:
            good = GOODS.get(s.produce or "grain", ("?",))[0]
            opts.append(Option("raid", s.id,
                               f"劫掠{s.name}（{w.kingdoms[s.faction].name}村庄，产{good}，民兵{int(s.militia)}"
                               + (f"，附近敌军战力{threat:.0f}" if threat else "") + f"，{d}天）",
                               {"days": d, "militia": s.militia, "threat": threat, "prosperity": s.prosperity}))

    # ---- attack nearby parties (enemy lords, caravans, villagers, bandits)
    if n >= 15 and (not p.army or leader_of_army):
        ac = []
        for q in w.parties.values():
            if not q.alive or q.inside or q is p or not w.hostile(p, q):
                continue
            dd = dist(q.pos, p.pos)
            if dd > 170 or not realm_sees(w, side, q, [p]):
                continue                                  # only enemies the realm's scouts can actually see
            if dd <= 170:
                ac.append((dd, q))
        for dd, q in sorted(ac, key=lambda x: x[0])[:5]:
            qp = w.party_power(q)
            d = round(dd / (party_speed(w, p) * 24), 1)
            if q.kind == "lord":
                who = f"{w.heroes[q.hero].name}的部队"
            elif q.kind == "caravan":
                value = sum(c * GOODS[g][1] for g, c in q.cargo.items()) + q.gold
                who = f"{q.name}（{w.kingdoms[q.faction].name if q.faction in w.kingdoms else ''}商队，财货约{value:.0f}金）"
            elif q.kind == "bandit":
                who = f"一伙{q.name}"
            elif q.kind == "player":
                who = "玩家（一位冒险者）的部队"
            else:
                who = q.name
            opts.append(Option("attack", q.id, f"袭击{who}（{T.healthy(q.troops)}人，战力{qp:.0f}，约{d}天）",
                               {"days": d, "enemy_power": qp, "kind": q.kind}))

    # ---- hideouts
    if n >= 30 and (not p.army or leader_of_army):
        hc = []
        for s in w.settlements.values():
            if s.kind == "hideout" and s.active and dist(s.pos, p.pos) < 500:
                d = _days(w, p, s.id)
                if d <= 5:
                    hc.append((d, s))
        for d, s in sorted(hc, key=lambda x: x[0])[:2]:
            opts.append(Option("hideout", s.id, f"清剿匪巢{s.name}（{BANDIT_TYPES[s.bandit_type][0]}，"
                                                f"约{T.healthy(s.garrison)}人，{d}天）",
                               {"days": d, "enemy_power": T.power(s.garrison) * 1.15}))

    # ---- patrol own lands
    if not p.army:
        for s in w.fiefs_of(h.id)[:2]:
            d = _days(w, p, s.id)
            bandits = sum(1 for q in w.parties.values() if q.alive and q.kind == "bandit" and dist(q.pos, s.pos) < 120)
            opts.append(Option("patrol", s.id, f"在{s.name}一带巡逻（附近土匪{bandits}伙，{d}天）",
                               {"days": d, "bandits": bandits}))

    # ---- logistics
    pris = sum(p.prisoners.values())
    wr = T.wounded(p.troops) / max(1, T.total(p.troops))
    town = None
    if pris >= 5 or wr > 0.3:
        for s in w.settlements.values():
            if s.kind == "town" and s.faction == side and not s.siege:
                d = _days(w, p, s.id)
                if town is None or d < town[0]:
                    town = (d, s)
    if pris >= 5 and town:
        opts.append(Option("sell", town[1].id, f"押送{pris}名俘虏到{town[1].name}出售（{town[0]}天）",
                           {"days": town[0], "prisoners": pris}))
    if wr > 0.3 and town:
        opts.append(Option("rest", town[1].id, f"去{town[1].name}休整养伤（伤员{wr:.0%}，{town[0]}天）",
                           {"days": town[0], "wounded": wr}))
    if h.gold > 3200 and len(h.caravans) < 2 and not p.army:
        towns = [s for s in w.kingdom_settlements(side, ("town",)) if not s.siege]
        if towns:
            s = min(towns, key=lambda s: dist(s.pos, p.pos))
            opts.append(Option("caravan", s.id, f"在{s.name}出资1500金组建商队（现有{len(h.caravans)}支）",
                               {"days": _days(w, p, s.id)}))

    # ---- armies
    if not p.army and k.wars and (k.ruler == h.id or h.influence >= 90):
        cands = army_candidates(w, h)
        cost = B.politics.army_base_cost + B.politics.army_member_cost * len(cands)
        if cands and h.influence >= cost:
            cp = sum(w.party_power(w.hero_party(c.id)) for c in cands)
            opts.append(Option("gather_army", None,
                               f"召集军团（{'、'.join(c.name for c in cands)}，合计战力{cp + my:.0f}，耗费影响力{cost}）",
                               {"power": cp + my, "cost": cost}))
    if leader_of_army:
        a = w.armies[p.army]
        opts.append(Option("disband_army", None, f"解散军团（军心{a.cohesion:.0f}）", {"cohesion": a.cohesion}))

    opts.append(Option("wait", None, "原地休整待命", {"days": 0}))
    return opts
