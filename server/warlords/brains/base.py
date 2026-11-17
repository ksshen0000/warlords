from __future__ import annotations

from dataclasses import dataclass

from ..model import Hero, World
from ..options import Option


@dataclass
class Decision:
    index: int            # index into the options list
    reason: str = ""
    speech: str = ""      # optional in-character line for the log / UI


class Brain:
    """A lord's mind. Must not mutate the world (calls may run in parallel threads)."""
    name = "base"
    parallel = False

    def decide(self, world: World, hero: Hero, options: list[Option]) -> Decision:
        """Pick the next strategic order."""
        raise NotImplementedError

    def propose(self, world: World, hero: Hero, options: list[Option]) -> Decision:
        """Pick a council proposal (or 'none')."""
        raise NotImplementedError

    def vote(self, world: World, hero: Hero, context: str, options: list[Option],
             tally: dict | None) -> Decision:
        """Vote in council; with `tally` given, the hero is the ruler making the final ruling.
        Also used for answering peace offers (options accept / reject)."""
        raise NotImplementedError
