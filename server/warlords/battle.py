"""Auto-resolved battles: troop classes, rock-paper-scissors matchups, terrain,
culture bonuses, walls, luck, wounded vs. killed, morale breaks."""
from __future__ import annotations

import random
from dataclasses import dataclass, field

from . import troops as T
from .data import CULTURES, MATCHUP, TERRAIN_BATTLE, TROOPS
from .rules import B

EXPOSURE = {0: 1.6, 1: 1.4, 2: 1.1, 3: 0.8, 4: 0.55}


@dataclass
class Unit:
    label: str
    roster: dict                  # mutated in place
    tactics: int = 0
    party: str | None = None
    hero: str | None = None
    wound_rate: float = 0.6       # share of casualties that are wounded instead of killed
    start: dict = field(default_factory=dict)
    killed: dict = field(default_factory=dict)
    wounded: dict = field(default_factory=dict)


@dataclass
class Result:
    winner: str                   # attacker | defender
    rounds: list[dict]
    attacker_start: int
    defender_start: int
    attacker_losses: int = 0      # killed + wounded in this battle
    defender_losses: int = 0
    attacker_killed: int = 0
    defender_killed: int = 0
    defender_bonus: float = 1.0
    terrain: int = 0


def _class_power(units: list[Unit], terrain: int, bonus: float) -> dict[str, float]:
    tmod = TERRAIN_BATTLE.get(terrain, {})
    out = {"inf": 0.0, "arc": 0.0, "cav": 0.0}
    for u in units:
        tac = 1 + B.battle.tactics_bonus * u.tactics
        for tid, (h, _w) in u.roster.items():
            if h <= 0:
                continue
            t = TROOPS[tid]
            cb = CULTURES.get(t["culture"], {}).get("bonus", {}).get(t["cls"], 1.0)
            out[t["cls"]] += h * t["power"] * cb * tmod.get(t["cls"], 1.0) * tac * bonus
    return out


def _shares(units: list[Unit]) -> dict[str, float]:
    c = {"inf": 0, "arc": 0, "cav": 0}
    for u in units:
        for tid, (h, _w) in u.roster.items():
            c[TROOPS[tid]["cls"]] += h
    n = sum(c.values()) or 1
    return {k: v / n for k, v in c.items()}


def _damage(cp: dict, enemy_shares: dict) -> float:
    total = 0.0
    for cls, p in cp.items():
        m = 1.0 + sum(enemy_shares[d] * (MATCHUP.get(cls, {}).get(d, 1.0) - 1.0) for d in enemy_shares)
        total += p * m
    return total


def _count(units: list[Unit]) -> int:
    return sum(T.healthy(u.roster) for u in units)


def _avg_power(units: list[Unit]) -> float:
    n = _count(units)
    return sum(T.power(u.roster) for u in units) / n if n else 1.0


def _apply(rng: random.Random, units: list[Unit], hits: int) -> tuple[int, int]:
    killed = wounded = 0
    for _ in range(hits):
        slots = [(u, tid) for u in units for tid, (h, _w) in u.roster.items() if h > 0]
        if not slots:
            break
        weights = [u.roster[tid][0] * EXPOSURE[TROOPS[tid]["tier"]] for u, tid in slots]
        u, tid = rng.choices(slots, weights)[0]
        u.roster[tid][0] -= 1
        if rng.random() < u.wound_rate:
            u.roster[tid][1] += 1
            u.wounded[tid] = u.wounded.get(tid, 0) + 1
            wounded += 1
        else:
            u.killed[tid] = u.killed.get(tid, 0) + 1
            killed += 1
    return killed, wounded


def resolve(rng: random.Random, attackers: list[Unit], defenders: list[Unit],
            terrain: int = 3, defender_bonus: float = 1.0) -> Result:
    for u in attackers + defenders:
        u.start = {tid: v[0] for tid, v in u.roster.items() if v[0] > 0}
    a0, d0 = _count(attackers), _count(defenders)
    res = Result("defender", [], a0, d0, defender_bonus=defender_bonus, terrain=terrain)
    cfg = B.battle
    for r in range(1, cfg.max_rounds + 1):
        al, dl = rng.lognormvariate(0, cfg.luck_sigma), rng.lognormvariate(0, cfg.luck_sigma)
        pa = _damage(_class_power(attackers, terrain, 1.0), _shares(defenders)) * al
        pd = _damage(_class_power(defenders, terrain, defender_bonus), _shares(attackers)) * dl
        hits_d = round(pa * cfg.damage_rate / _avg_power(defenders))
        hits_a = round(pd * cfg.damage_rate / _avg_power(attackers))
        dk, dw = _apply(rng, defenders, hits_d)
        ak, aw = _apply(rng, attackers, hits_a)
        res.attacker_losses += ak + aw
        res.defender_losses += dk + dw
        res.attacker_killed += ak
        res.defender_killed += dk
        ac, dc = _count(attackers), _count(defenders)
        res.rounds.append({"round": r, "attacker": ac, "defender": dc,
                           "attacker_lost": ak + aw, "defender_lost": dk + dw,
                           "attacker_luck": round(al, 2), "defender_luck": round(dl, 2),
                           "attacker_power": round(pa), "defender_power": round(pd)})
        if dc == 0:
            res.winner = "attacker"
            break
        if ac == 0:
            res.winner = "defender"
            break
        sa = sum(T.power(u.roster) for u in attackers)
        sd = sum(T.power(u.roster) for u in defenders) * defender_bonus
        ratio = sa / max(sd, 1e-6)
        a_break = ac < cfg.attacker_break * a0 or (r >= 2 and ratio < 0.35)
        d_break = dc < cfg.defender_break * d0 or (r >= 2 and ratio > 1 / 0.35)
        if a_break and not d_break:
            res.winner = "defender"
            break
        if d_break and not a_break:
            res.winner = "attacker"
            break
        if a_break and d_break:
            res.winner = "attacker" if ratio > 1 else "defender"
            break
    for u in attackers + defenders:
        T.prune(u.roster)
    return res


def report(res: Result, attackers: list[Unit], defenders: list[Unit]) -> dict:
    def side(units):
        out = []
        for u in units:
            rows = []
            for tid in sorted(set(u.start) | set(u.killed) | set(u.wounded),
                              key=lambda t: (-TROOPS[t]["tier"], t)):
                rows.append({"id": tid, "name": TROOPS[tid]["name"], "tier": TROOPS[tid]["tier"],
                             "cls": TROOPS[tid]["cls"], "start": u.start.get(tid, 0),
                             "killed": u.killed.get(tid, 0), "wounded": u.wounded.get(tid, 0)})
            out.append({"label": u.label, "party": u.party, "hero": u.hero, "tactics": u.tactics,
                        "rows": rows})
        return out
    return {"winner": res.winner, "defender_bonus": res.defender_bonus, "terrain": res.terrain,
            "attacker_start": res.attacker_start, "defender_start": res.defender_start,
            "attacker_losses": res.attacker_losses, "defender_losses": res.defender_losses,
            "attacker_killed": res.attacker_killed, "defender_killed": res.defender_killed,
            "attacker": side(attackers), "defender": side(defenders), "rounds": res.rounds}
