"""Static game data, built from the rule documents (rules/units.toml, rules/world.toml).

Only engine-level identifiers live here (terrain codes); everything a designer
or an AI might want to change is in the TOML files.
"""
from __future__ import annotations

from .rules import RULES

# ---------------------------------------------------------------- terrain
# engine codes (stable ids used by the map arrays); names/speeds come from units.toml
DEEP_WATER, WATER, BEACH, PLAINS, MEADOW, FOREST, HILLS, MOUNTAIN, SNOW, TAIGA, DESERT, DUNES, STEPPE, MARSH = range(14)
TERRAIN_KEYS = ["deep_water", "water", "beach", "plains", "meadow", "forest", "hills", "mountain",
                "snow", "taiga", "desert", "dunes", "steppe", "marsh"]
CODE = {k: i for i, k in enumerate(TERRAIN_KEYS)}

_U = RULES.units
_T = _U["terrain"]
TERRAIN = {i: (k, _T[k]["name"], float(_T[k]["speed"])) for i, k in enumerate(TERRAIN_KEYS)}
TERRAIN_BATTLE = {i: dict(_T[k]["battle"]) for i, k in enumerate(TERRAIN_KEYS) if "battle" in _T[k]}
VILLAGE_GOODS = {i: list(_T[k]["village_goods"]) for i, k in enumerate(TERRAIN_KEYS) if "village_goods" in _T[k]}
RIVER_SPEED = float(_T["river_speed"])
ROAD_SPEED = float(_T["road_speed"])
FORD_SPEED = float(_T.get("ford_speed", 0.35))

# ------------------------------------------------------------------ goods
GOODS = {g: (v["name"], v["price"]) for g, v in _U["goods"].items()}

# ---------------------------------------------------------------- troops
_C = _U["classes"]
TIER_POWER = {int(k[1:]): v for k, v in _C["tier_power"].items()}
CLASS_POWER = dict(_C["power"])
CLASS_UPKEEP = dict(_C["upkeep"])
CLASS_NAMES = dict(_C["names"])
MATCHUP = {a: dict(v) for a, v in _C["matchup"].items()}

CULTURES = {c: {"name": v["name"], "bonus": dict(v.get("bonus", {})), "home": {CODE[t] for t in v.get("home", [])}}
            for c, v in _U["cultures"].items()}

TROOPS: dict[str, dict] = {}


def _troop(tid, name, culture, tier, cls, upgrades=()):
    TROOPS[tid] = {"id": tid, "name": name, "culture": culture, "tier": tier, "cls": cls,
                   "upgrades": list(upgrades)}


for _c, _v in _U["cultures"].items():
    _inf, _arc, _cav = _v["infantry"], _v["archers"], _v["cavalry"]
    _troop(f"{_c}_t1", _v["recruit"], _c, 1, "inf", [f"{_c}_inf2", f"{_c}_arc2"])
    _troop(f"{_c}_inf2", _inf[0], _c, 2, "inf", [f"{_c}_inf3", f"{_c}_cav3"])
    _troop(f"{_c}_inf3", _inf[1], _c, 3, "inf", [f"{_c}_inf4"])
    _troop(f"{_c}_inf4", _inf[2], _c, 4, "inf")
    _troop(f"{_c}_arc2", _arc[0], _c, 2, "arc", [f"{_c}_arc3"])
    _troop(f"{_c}_arc3", _arc[1], _c, 3, "arc", [f"{_c}_arc4"])
    _troop(f"{_c}_arc4", _arc[2], _c, 4, "arc")
    _troop(f"{_c}_cav3", _cav[0], _c, 3, "cav", [f"{_c}_cav4"])
    _troop(f"{_c}_cav4", _cav[1], _c, 4, "cav")
for _tid, _v in _U.get("troops", {}).items():
    _troop(_tid, _v["name"], _v["culture"], int(_v["tier"]), _v["cls"], _v.get("upgrades", []))


def refresh_balance() -> None:
    """(Re)compute balance-derived troop stats; called at import and after rules.reload()."""
    from .rules import B
    for t in TROOPS.values():
        t["power"] = TIER_POWER[t["tier"]] * CLASS_POWER[t["cls"]]
        t["upkeep"] = round(max(0.15, t["tier"] * B.troops.upkeep_per_tier * CLASS_UPKEEP[t["cls"]]), 2)
        t["xp"] = B.troops.xp_per_tier_squared * t["tier"] ** 2 if t["upgrades"] else 0
        t["upgrade_cost"] = B.troops.upgrade_cost_per_tier * t["tier"] * (2 if t["cls"] == "cav" else 1)


refresh_balance()

BANDIT_TYPES = {b: (v["name"], v["troop"], {CODE[t] for t in v["terrain"]}) for b, v in _U["bandits"].items()}

# ------------------------------------------------------------------ world
_W = RULES.world
SETTLEMENT_NAMES = {c: list(v) for c, v in _W["names"].items() if c != "hideouts"}
HIDEOUT_NAMES = list(_W["names"]["hideouts"])
KINGDOMS = [(k["id"], k["name"], k["culture"], k["color"], tuple(k["capital"])) for k in _W["kingdoms"]]
FIEF_HOLDERS = {k["id"]: list(k["fiefs"]) for k in _W["kingdoms"]}
RULERS = {k["id"]: k["ruler"] for k in _W["kingdoms"]}
LORDS = [(l["id"], l["name"], l["kingdom"],
          (l["traits"]["aggression"], l["traits"]["caution"], l["traits"]["honor"], l["traits"]["greed"]),
          l["persona"], l["tactics"]) for l in _W["lords"]]
INITIAL_RELATIONS = [tuple(r) for r in _W.get("relations", [])]
INITIAL_WARS = [tuple(r) for r in _W.get("wars", [])]
CARAVAN_OWNERS = list(_W.get("caravan_owners", []))
TITLES = {k["id"]: k.get("title", "君主") for k in _W["kingdoms"]}               # ruler title per kingdom
PEDIGREE = {l["id"]: l.get("pedigree", "mid") for l in _W["lords"]}
PEDIGREE_NAMES = {"royal": "宗室王族", "high": "高门", "mid": "次门", "low": "寒门", "clan": "部族贵种"}
LAYOUT = dict(_W.get("layout", {}))
BLURBS = {k["id"]: k.get("blurb", "") for k in _W["kingdoms"]}
PEDIGREE_WEIGHT = {k["id"]: float(k.get("pedigree_weight", 0.5)) for k in _W["kingdoms"]}
TOWN_MIN_PEDIGREE = {k["id"]: k.get("town_min_pedigree", "") for k in _W["kingdoms"]}
CAPTIVE_RECRUIT = {k["id"]: float(k.get("captive_recruit", 0.0)) for k in _W["kingdoms"]}
BACKGROUNDS = {b: dict(v) for b, v in _W.get("backgrounds", {}).items()}
KIND_NAMES = {"town": "城", "castle": "关塞", "village": "村落", "hideout": "匪巢"}
MERC_COMPANIES = [tuple(m) for m in _W.get("mercenaries", [])]
