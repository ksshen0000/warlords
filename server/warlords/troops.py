"""Troop rosters: {troop_id: [healthy, wounded]}."""
from __future__ import annotations

import random

from .data import CLASS_NAMES, TROOPS

Roster = dict[str, list[int]]


def add(r: Roster, tid: str, n: int, wounded: int = 0) -> None:
    if n <= 0 and wounded <= 0:
        return
    e = r.setdefault(tid, [0, 0])
    e[0] += n
    e[1] += wounded


def healthy(r: Roster) -> int:
    return sum(v[0] for v in r.values())


def wounded(r: Roster) -> int:
    return sum(v[1] for v in r.values())


def total(r: Roster) -> int:
    return sum(v[0] + v[1] for v in r.values())


def power(r: Roster) -> float:
    return sum(TROOPS[t]["power"] * v[0] for t, v in r.items())


def class_counts(r: Roster) -> dict[str, int]:
    out = {"inf": 0, "arc": 0, "cav": 0}
    for t, v in r.items():
        out[TROOPS[t]["cls"]] += v[0]
    return out


def upkeep(r: Roster) -> float:
    return sum(TROOPS[t]["upkeep"] * (v[0] + v[1]) for t, v in r.items())


def cav_fraction(r: Roster) -> float:
    n = healthy(r)
    return class_counts(r)["cav"] / n if n else 0.0


def prune(r: Roster) -> None:
    for t in [t for t, v in r.items() if v[0] <= 0 and v[1] <= 0]:
        del r[t]


def merge(dst: Roster, src: Roster) -> None:
    for t, v in src.items():
        add(dst, t, v[0], v[1])


def take_healthy(r: Roster, n: int, rng: random.Random, low_tier_first: bool = True) -> Roster:
    """Remove n healthy troops (preferring low tiers) and return them as a roster."""
    out: Roster = {}
    order = sorted(r, key=lambda t: TROOPS[t]["tier"], reverse=not low_tier_first)
    for t in order:
        if n <= 0:
            break
        k = min(n, r[t][0])
        r[t][0] -= k
        n -= k
        add(out, t, k)
    prune(r)
    return out


def heal(r: Roster, rate: float, rng: random.Random) -> int:
    healed = 0
    for v in r.values():
        if v[1] > 0:
            k = sum(1 for _ in range(v[1]) if rng.random() < rate)
            v[1] -= k
            v[0] += k
            healed += k
    return healed


def describe(r: Roster, with_wounded: bool = True) -> str:
    rows = sorted(r.items(), key=lambda kv: (-TROOPS[kv[0]]["tier"], kv[0]))
    parts = []
    for t, (h, w) in rows:
        if h or (w and with_wounded):
            s = f"{TROOPS[t]['name']}{h}"
            if w and with_wounded:
                s += f"(+{w}伤)"
            parts.append(s)
    return "、".join(parts) or "无"


def describe_classes(r: Roster) -> str:
    c = class_counts(r)
    return "、".join(f"{CLASS_NAMES[k]}{v}" for k, v in c.items() if v) or "无"


def to_list(r: Roster) -> list[dict]:
    return [{"id": t, "name": TROOPS[t]["name"], "tier": TROOPS[t]["tier"], "cls": TROOPS[t]["cls"],
             "healthy": v[0], "wounded": v[1]}
            for t, v in sorted(r.items(), key=lambda kv: (-TROOPS[kv[0]]["tier"], kv[0])) if v[0] or v[1]]
