"""Load the rule documents in rules/*.toml.

    from .rules import B        # balance numbers:  B.siege.wall_bonus_per_level
    from .rules import RULES    # everything:       RULES.units, RULES.world, RULES.doctrine

The directory can be overridden with WARLORDS_RULES. `reload()` re-reads the
files in place, so a running server picks up balance changes without restarting.
"""
from __future__ import annotations

import os
import tomllib
from pathlib import Path

RULES_DIR = Path(os.environ.get("WARLORDS_RULES", Path(__file__).resolve().parent.parent / "rules"))


class NS:
    """Attribute access over a dict (nested dicts become NS too); missing keys raise clearly."""

    def __init__(self, d: dict, path: str = ""):
        object.__setattr__(self, "_d", d)
        object.__setattr__(self, "_path", path)

    def __getattr__(self, k):
        try:
            v = self._d[k]
        except KeyError:
            raise AttributeError(f"规则文档缺少配置项：{self._path}{k}") from None
        return NS(v, f"{self._path}{k}.") if isinstance(v, dict) else v

    def __getitem__(self, k):
        return self.__getattr__(k)

    def get(self, k, default=None):
        v = self._d.get(k, default)
        return NS(v, f"{self._path}{k}.") if isinstance(v, dict) else v

    def raw(self) -> dict:
        return self._d


class Rules:
    def __init__(self):
        self.load()

    def load(self) -> None:
        def read(name):
            with open(RULES_DIR / f"{name}.toml", "rb") as f:
                return tomllib.load(f)
        self.balance_raw = read("balance")
        self.units = read("units")
        self.world = read("world")
        self.doctrine = read("doctrine").get("rule", [])
        B.__init__(self.balance_raw, "balance.")

    def doctrine_for(self, kingdom: str, hero: str, use: str) -> list[dict]:
        rules = [r for r in self.doctrine
                 if r.get("scope", "all") in ("all", kingdom, hero) and use in r.get("use", [use])]
        return sorted(rules, key=lambda r: -r.get("priority", 0))


B = NS({})
RULES = Rules()


def reload() -> None:
    """Re-read balance and doctrine (content/world changes need a new game)."""
    RULES.load()
