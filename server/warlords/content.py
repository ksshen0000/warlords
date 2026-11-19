"""Pre-authored content (server/content/*.toml): dialogue lines, and later quest texts and story events.

The shipped game reads this locally and never needs an LLM. The content itself is drafted with an LLM at
development time (tools/author.py) and reviewed before it lands here.

A line looks like
    [[line]]
    topic = "greet"
    culture = "zhou"                       # optional: only lords of this culture say it
    when = ["rel>=10", "ruler"]            # optional: all conditions must hold
    text = "足下来了。孤正想找人说说话。"

Picking: of the lines whose conditions hold, the most specific ones win (higher `priority`, then more
conditions, then a culture-specific line over a generic one);
among those one is chosen by a seed that is stable for (lord, topic, day), so re-opening a menu doesn't
reshuffle the answer.

Conditions (facts are computed by the caller, see dialogue.facts):
    name           the fact is truthy                     e.g. ruler, at_war, met
    !name          the fact is falsy
    name>=N / name<=N / name=V                            e.g. rel>=10, status=vassal, honor>=1
"""
from __future__ import annotations

import os
import random
import re
import tomllib
import zlib

CONTENT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "content")

_cache: dict[str, list[dict]] = {}
_COND = re.compile(r"^(!?)([a-z_]+)(?:(>=|<=|=)(.+))?$")


def load(kind: str = "dialogue") -> list[dict]:
    """All [[line]] entries of content/<kind>*.toml (several files may share a prefix)."""
    if kind in _cache:
        return _cache[kind]
    out: list[dict] = []
    if os.path.isdir(CONTENT_DIR):
        for fn in sorted(os.listdir(CONTENT_DIR)):
            if fn.startswith(kind) and fn.endswith(".toml"):
                with open(os.path.join(CONTENT_DIR, fn), "rb") as f:
                    out.extend(tomllib.load(f).get("line", []))
    _cache[kind] = out
    return out


def reload() -> None:
    _cache.clear()


def _holds(cond: str, facts: dict) -> bool:
    m = _COND.match(cond.strip())
    if not m:
        return False
    neg, name, op, val = m.groups()
    v = facts.get(name)
    if op is None:
        ok = bool(v)
        return not ok if neg else ok
    if op == "=":
        ok = str(v) == val
    else:
        try:
            x, y = float(v if v is not None else 0), float(val)
        except ValueError:
            return False
        ok = x >= y if op == ">=" else x <= y
    return not ok if neg else ok


class _Safe(dict):
    def __missing__(self, key):
        return "{" + key + "}"


def pick(topic: str, facts: dict, fill: dict, seed: str = "", kind: str = "dialogue") -> str | None:
    """One line for `topic` matching `facts`, with {placeholders} filled from `fill` (None if nothing fits)."""
    culture = facts.get("culture")
    lines = load(kind)
    if facts.get("ruler"):
        # a ruler speaks as a ruler: if the bank has ruler lines for this topic, only those are eligible
        own = [ln for ln in lines if ln.get("topic") == topic and "ruler" in ln.get("when", [])
               and (not ln.get("culture") or ln.get("culture") == culture)]
        if own:
            lines = own
    best, best_score = [], (-1,)
    for ln in lines:
        if ln.get("topic") != topic:
            continue
        c = ln.get("culture")
        if c and c != culture:
            continue
        conds = ln.get("when", [])
        if not all(_holds(x, facts) for x in conds):
            continue
        score = (int(ln.get("priority", 0)), len(conds), 1 if c else 0)   # most specific situation first
        if score > best_score:
            best, best_score = [ln], score
        elif score == best_score:
            best.append(ln)
    if not best:
        return None
    rng = random.Random(zlib.crc32(f"{seed}:{topic}".encode()))
    ln = rng.choices(best, [float(x.get("weight", 1)) for x in best])[0]
    return ln["text"].format_map(_Safe(fill))
