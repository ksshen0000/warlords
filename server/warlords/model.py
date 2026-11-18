"""World data model (v2: continuous map, neutral parties, politics).

Everything dynamic lives here and serializes to JSON via World.to_dict();
the static terrain goes to the client once via World.map_dict().
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

from . import troops as T
from .data import GOODS, TROOPS
from .rules import B
from .terrain import Terrain

BANDIT = "__bandit"
NEUTRAL = "__neutral"
PLAYER = "__player"
DEAD = "__dead"                # Hero.captive_of of an executed general


@dataclass
class Kingdom:
    id: str
    name: str
    culture: str
    color: str
    ruler: str
    alive: bool = True
    # enemy id -> {"since": day, "score": float (+ = we're winning), "losses": [ours, theirs]}
    wars: dict[str, dict] = field(default_factory=dict)
    truces: dict[str, int] = field(default_factory=dict)          # kingdom -> day truce ends
    tributes: dict[str, dict] = field(default_factory=dict)       # payee -> {"amount", "until"}
    last_offensive: int = 0
    mercenaries: list[str] = field(default_factory=list)          # party ids under contract


@dataclass
class Hero:
    id: str
    name: str
    kingdom: str
    culture: str
    traits: dict[str, int]
    persona: str
    tactics: int
    gold: float = 0.0
    influence: float = 0.0
    renown: int = 0
    relations: dict[str, int] = field(default_factory=dict)
    memory: list[str] = field(default_factory=list)
    party: str | None = None
    captive_of: str | None = None       # kingdom id (or BANDIT)
    captive_at: str | None = None       # settlement id where held
    captive_days: int = 0
    caravans: list[str] = field(default_factory=list)
    last_speech: str = ""

    def rel(self, other: str) -> int:
        return self.relations.get(other, 0)

    def adjust_rel(self, other: str, delta: int) -> None:
        if other != self.id:
            self.relations[other] = max(-100, min(100, self.rel(other) + delta))

    def remember(self, day: int, text: str, keep: int = 14) -> None:
        self.memory.append(f"第{day}天：{text}")
        del self.memory[:-keep]


@dataclass
class Party:
    id: str
    kind: str                     # lord | caravan | villager | bandit | hunter | merc
    name: str
    faction: str | None           # kingdom id; BANDIT; or None for neutrals
    pos: list[float]
    troops: dict[str, list[int]] = field(default_factory=dict)
    hero: str | None = None       # leading hero (lords)
    owner: str | None = None      # caravan owner hero (None = town guild)
    home: str | None = None       # settlement / hideout id
    contract: str | None = None   # mercenaries: kingdom that hired them
    prisoners: dict[str, int] = field(default_factory=dict)
    gold: float = 0.0
    cargo: dict[str, int] = field(default_factory=dict)
    order: dict | None = None     # strategic order {type, target, age, reason}
    target: dict | None = None    # movement target {kind: place|party|point, id, pos}
    mode: str = "idle"            # idle|move|siege|raid|inside|flee|chase|follow
    inside: str | None = None     # settlement id while inside walls
    army: str | None = None
    xp: dict[str, float] = field(default_factory=dict)
    timer: float = 0.0
    memo: dict = field(default_factory=dict)
    alive: bool = True


@dataclass
class Settlement:
    id: str
    name: str
    kind: str                     # town | castle | village | hideout
    pos: list[float]
    culture: str
    faction: str | None
    owner: str | None             # hero id
    bound: str | None = None      # village -> its town/castle
    villages: list[str] = field(default_factory=list)
    garrison: dict[str, list[int]] = field(default_factory=dict)
    militia: float = 0.0
    walls: int = 0
    prosperity: float = 0.0       # towns/castles: prosperity; villages: hearth
    loyalty: float = 70.0         # towns/castles: 0..100, low loyalty may rebel
    food: float = 0.0
    market: dict[str, float] = field(default_factory=dict)
    produce: str | None = None
    stock: float = 0.0
    volunteers: list[str] = field(default_factory=list)
    raided_until: int = 0         # hour
    siege: dict | None = None     # {"kingdom", "progress", "since"}
    bandit_type: str | None = None
    active: bool = True
    timer: float = 0.0
    trade_income: float = 0.0     # tariffs collected today
    tax_today: float = 0.0


@dataclass
class Army:
    id: str
    kingdom: str
    leader: str                   # hero id
    members: list[str]            # hero ids (excluding leader)
    cohesion: float = 100.0
    created: int = 0


@dataclass
class Decision:
    id: str
    kingdom: str
    kind: str                     # war | peace | fief
    subject: str                  # target kingdom or settlement
    proposer: str | None
    created: int
    deadline: int                 # hour when the ruler resolves it
    options: list[dict]           # [{"id", "label"}]
    votes: dict[str, dict] = field(default_factory=dict)   # hero -> {"option", "weight", "reason"}
    result: str | None = None
    resolved: bool = False
    note: str = ""


@dataclass
class World:
    seed: int
    terrain: Terrain
    hour: int = 0
    kingdoms: dict[str, Kingdom] = field(default_factory=dict)
    heroes: dict[str, Hero] = field(default_factory=dict)
    parties: dict[str, Party] = field(default_factory=dict)
    settlements: dict[str, Settlement] = field(default_factory=dict)
    armies: dict[str, Army] = field(default_factory=dict)
    decisions: dict[str, Decision] = field(default_factory=dict)
    events: list[dict] = field(default_factory=list)
    rng: random.Random = field(default_factory=random.Random)
    counter: int = 0
    player: dict = field(default_factory=dict)     # see player.py

    # ------------------------------------------------------------ basics
    @property
    def day(self) -> int:
        return self.hour // 24

    def new_id(self, prefix: str) -> str:
        self.counter += 1
        return f"{prefix}{self.counter}"

    def log(self, kind: str, text: str, **data) -> dict:
        ev = {"day": self.day, "hour": self.hour, "type": kind, "text": text, **data}
        self.events.append(ev)
        return ev

    # -------------------------------------------------------- diplomacy
    def at_war(self, a: str | None, b: str | None) -> bool:
        if not a or not b or a == b:
            return False
        if a == BANDIT or b == BANDIT:
            return True
        if PLAYER in (a, b):
            other = b if a == PLAYER else a
            return other in self.player.get("wars", [])
        ka = self.kingdoms.get(a)
        return bool(ka and b in ka.wars)

    def side_of(self, p: Party) -> str:
        if p.kind == "bandit":
            return BANDIT
        if p.kind == "player":
            return self.player.get("kingdom") or self.player.get("contract") or PLAYER
        if p.kind == "merc":
            return p.contract or NEUTRAL
        if p.kind == "hunter":
            return NEUTRAL
        return p.faction or NEUTRAL

    def hostile(self, a: Party, b: Party) -> bool:
        sa, sb = self.side_of(a), self.side_of(b)
        if sa == sb:
            return False
        if BANDIT in (sa, sb):
            return True
        if NEUTRAL in (sa, sb):
            return False
        if (a.kind == "player" and b.memo.get("ignore_player_until", 0) > self.hour) or \
                (b.kind == "player" and a.memo.get("ignore_player_until", 0) > self.hour):
            return False
        return self.at_war(sa, sb)

    def hostile_to_settlement(self, p: Party, s: Settlement) -> bool:
        side = self.side_of(p)
        if s.kind == "hideout":
            return side != BANDIT
        if side == BANDIT:
            return s.kind == "village"
        if s.kind == "hideout":
            return True
        return self.at_war(side, s.faction)

    # ----------------------------------------------------------- lookups
    def kingdom_settlements(self, kid: str, kinds=("town", "castle", "village")) -> list[Settlement]:
        return [s for s in self.settlements.values() if s.faction == kid and s.kind in kinds]

    def kingdom_heroes(self, kid: str, free_only: bool = False) -> list[Hero]:
        return [h for h in self.heroes.values()
                if h.kingdom == kid and h.captive_of != DEAD and (not free_only or h.captive_of is None)]

    def fiefs_of(self, hero_id: str) -> list[Settlement]:
        return [s for s in self.settlements.values() if s.owner == hero_id and s.kind in ("town", "castle")]

    def hero_party(self, hero_id: str) -> Party | None:
        h = self.heroes[hero_id]
        return self.parties.get(h.party) if h.party else None

    def party_power(self, p: Party) -> float:
        bonus = 1.0
        if p.hero:
            bonus += B.battle.tactics_bonus * self.heroes[p.hero].tactics
        elif p.kind == "player":
            bonus = B.player.battle_bonus
        return T.power(p.troops) * bonus

    def kingdom_strength(self, kid: str) -> float:
        s = sum(self.party_power(p) for p in self.parties.values()
                if p.alive and p.kind in ("lord", "merc") and self.side_of(p) == kid)
        s += 0.5 * sum(T.power(st.garrison) for st in self.kingdom_settlements(kid, ("town", "castle")))
        return s

    def dist(self, a, b) -> float:
        return math.hypot(a[0] - b[0], a[1] - b[1])

    def travel_days(self, p: Party, place: str) -> float:
        cost = self.terrain.travel_cost(place, *p.pos)
        if cost == float("inf"):
            return 99.0
        return cost / (party_speed(self, p) * 24)

    # ------------------------------------------------------------ market
    def price(self, s: Settlement, good: str) -> float:
        base = GOODS[good][1]
        want = 6 + s.prosperity / 8          # stock the town would like to hold
        stock = s.market.get(good, 0.0)
        return round(base * max(0.35, min(3.0, (want / (stock + want * 0.35)) ** 0.7)), 1)

    # ------------------------------------------------------ serialization
    def map_dict(self) -> dict:
        return self.terrain.to_client()

    def to_dict(self) -> dict:
        def kingdom(k: Kingdom):
            return {"id": k.id, "name": k.name, "color": k.color, "culture": k.culture, "ruler": k.ruler,
                    "alive": k.alive, "wars": k.wars, "truces": k.truces, "tributes": k.tributes,
                    "strength": round(self.kingdom_strength(k.id)), "mercenaries": k.mercenaries,
                    "fiefs": len(self.kingdom_settlements(k.id, ("town", "castle")))}

        def hero(h: Hero):
            return {"id": h.id, "name": h.name, "kingdom": h.kingdom, "culture": h.culture,
                    "traits": h.traits, "persona": h.persona, "tactics": h.tactics, "gold": round(h.gold),
                    "influence": round(h.influence), "renown": h.renown, "relations": h.relations,
                    "memory": h.memory[-8:], "party": h.party, "captive_of": h.captive_of,
                    "captive_at": h.captive_at, "captive_days": h.captive_days,
                    "caravans": h.caravans, "last_speech": h.last_speech}

        def party(p: Party):
            tgt = None
            if p.target:
                tgt = p.target.get("pos")
                if p.target["kind"] == "place":
                    tgt = self.terrain.places.get(p.target["id"])
                elif p.target["kind"] == "party" and p.target["id"] in self.parties:
                    tgt = self.parties[p.target["id"]].pos
            return {"id": p.id, "kind": p.kind, "name": p.name, "side": self.side_of(p),
                    "faction": p.faction, "hero": p.hero, "owner": p.owner, "home": p.home,
                    "contract": p.contract, "pos": [round(p.pos[0], 1), round(p.pos[1], 1)],
                    "size": T.healthy(p.troops), "wounded": T.wounded(p.troops),
                    "power": round(self.party_power(p)), "troops": T.to_list(p.troops),
                    "prisoners": sum(p.prisoners.values()), "gold": round(p.gold),
                    "cargo": {k: v for k, v in p.cargo.items() if v}, "mode": p.mode,
                    "order": p.order, "target_pos": tgt, "inside": p.inside, "army": p.army,
                    "speed": round(party_speed(self, p) * 24)}

        def settlement(s: Settlement):
            d = {"id": s.id, "name": s.name, "kind": s.kind, "pos": s.pos, "culture": s.culture,
                 "faction": s.faction, "owner": s.owner, "bound": s.bound, "villages": s.villages,
                 "garrison": T.to_list(s.garrison), "garrison_size": T.healthy(s.garrison),
                 "garrison_power": round(T.power(s.garrison)), "militia": round(s.militia),
                 "walls": s.walls, "prosperity": round(s.prosperity), "food": round(s.food),
                 "loyalty": round(s.loyalty),
                 "produce": s.produce, "stock": round(s.stock), "volunteers": s.volunteers,
                 "raided": s.raided_until > self.hour, "siege": s.siege, "active": s.active,
                 "bandit_type": s.bandit_type}
            if s.kind == "town":
                d["market"] = {g: {"stock": round(s.market.get(g, 0)), "price": self.price(s, g)} for g in GOODS}
            return d

        return {
            "seed": self.seed, "hour": self.hour, "day": self.day,
            "kingdoms": {k: kingdom(v) for k, v in self.kingdoms.items()},
            "heroes": {k: hero(v) for k, v in self.heroes.items()},
            "parties": {k: party(v) for k, v in self.parties.items() if v.alive},
            "settlements": {k: settlement(v) for k, v in self.settlements.items()},
            "armies": {k: vars(v) for k, v in self.armies.items()},
            "decisions": {k: vars(v) for k, v in self.decisions.items()
                          if not v.resolved or self.hour - v.deadline < 24 * 10},
            "goods": {g: v[0] for g, v in GOODS.items()},
        }


# ------------------------------------------------------------- movement
def _size_speed(r) -> float:
    m = B.movement
    n = T.healthy(r) + 0.5 * T.wounded(r)
    return max(m.min_size_factor, 1.12 - n * m.size_penalty_per_troop) * (1 + m.cavalry_bonus * T.cav_fraction(r))


def party_speed(w: World, p: Party) -> float:
    m = B.movement
    prisoners = max(0.8, 1 - sum(p.prisoners.values()) / 300)
    sp = m.base_speed * m.kind_speed.get(p.kind, 1.0) * _size_speed(p.troops) * prisoners
    if p.army and p.army in w.armies:
        # an army moves at its slowest member's pace
        a = w.armies[p.army]
        for hid in [a.leader] + a.members:
            q = w.hero_party(hid)
            if q and q is not p and q.army == p.army:
                sp = min(sp, m.base_speed * _size_speed(q.troops))
        sp *= 0.95
    return sp


def troop_name(tid: str) -> str:
    return TROOPS[tid]["name"]
