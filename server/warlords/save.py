"""Campaign saves (Warband's save / load): the whole World minus its terrain, gzip-pickled to
~/.local/share/warlords/saves/<slot>.sav (override with WARLORDS_SAVE_DIR).

The terrain is rebuilt from the seed on load (it is cached on disk anyway). Saves stay loadable when the
code grows: every dataclass object gets its missing fields filled with their defaults, and the player
record is topped up by the modules that own it (gear.ensure, character.ensure…).

Only load saves this game wrote: pickle runs code from the file it reads.
"""
from __future__ import annotations

import dataclasses
import gzip
import os
import pickle
import re
import time

from .model import World

VERSION = 1
SLOTS = ["auto", "1", "2", "3", "4", "5"]
SLOT_NAMES = {"auto": "自动存档"}


def save_dir() -> str:
    d = os.environ.get("WARLORDS_SAVE_DIR") or os.path.join(
        os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share"), "warlords", "saves")
    os.makedirs(d, exist_ok=True)
    return d


def _path(slot: str) -> str:
    if slot not in SLOTS:
        raise ValueError(f"没有这个存档位：{slot}")
    return os.path.join(save_dir(), f"{slot}.sav")


def summary(w: World) -> dict:
    """What a slot shows in the list (stored in the file's header, read without unpickling the world)."""
    from .data import BACKGROUNDS, CULTURES
    from .player import PID
    p = w.parties.get(PID)
    pl = w.player or {}
    origin = pl.get("origin")
    k = w.kingdoms.get(origin) if origin else None
    who = "未创建角色"
    if pl.get("background"):
        who = f"{CULTURES[k.culture]['name'] if k else ''}{BACKGROUNDS.get(pl['background'], {}).get('name', '')}"
    lvl = (pl.get("char") or {}).get("level")
    return {"day": w.day, "hour": w.hour % 24, "seed": w.seed, "who": who, "level": lvl,
            "gold": round(p.gold) if p else 0, "troops": sum(v[0] + v[1] for v in p.troops.values()) if p else 0,
            "renown": round(pl.get("renown", 0)), "saved_at": time.time()}


def save(w: World, slot: str) -> dict:
    meta = summary(w)
    terrain = w.terrain
    w.terrain = None                           # rebuilt from the seed on load
    try:
        body = pickle.dumps(w, protocol=pickle.HIGHEST_PROTOCOL)
    finally:
        w.terrain = terrain
    path = _path(slot)
    tmp = path + ".tmp"
    with gzip.open(tmp, "wb", compresslevel=5) as f:
        pickle.dump({"version": VERSION, "meta": meta}, f, protocol=pickle.HIGHEST_PROTOCOL)
        f.write(body)
    os.replace(tmp, path)                      # never leave a half-written save behind
    return meta


def load(slot: str) -> World:
    from .terrain import generate
    path = _path(slot)
    if not os.path.exists(path):
        raise FileNotFoundError("这个存档位是空的")
    with gzip.open(path, "rb") as f:
        head = pickle.load(f)
        if int(head.get("version", 0)) > VERSION:
            raise ValueError("存档来自更新版本的游戏")
        w = pickle.load(f)
    w.terrain = generate(w.seed)
    for s in w.settlements.values():            # as scenario.default_world does after generating
        w.terrain.places[s.id] = tuple(s.pos)
    w.terrain.precompute_flows(f"{w.seed}")
    upgrade(w)
    return w


def listing() -> list[dict]:
    out = []
    for slot in SLOTS:
        path = os.path.join(save_dir(), f"{slot}.sav")
        row = {"slot": slot, "name": SLOT_NAMES.get(slot, f"存档 {slot}"), "empty": True}
        if os.path.exists(path):
            try:
                with gzip.open(path, "rb") as f:
                    row.update(pickle.load(f)["meta"], empty=False)
            except Exception:
                row.update(empty=False, broken=True)
        out.append(row)
    return out


# ------------------------------------------------------------------ old saves, new code
def _fill(obj) -> None:
    for f in dataclasses.fields(obj):
        if f.name in obj.__dict__:
            continue
        if f.default is not dataclasses.MISSING:
            setattr(obj, f.name, f.default)
        elif f.default_factory is not dataclasses.MISSING:
            setattr(obj, f.name, f.default_factory())


def upgrade(w: World) -> None:
    """Give objects saved by an older build the fields the current code expects."""
    _fill(w)
    for group in (w.kingdoms, w.heroes, w.parties, w.settlements, w.armies, w.decisions):
        for obj in group.values():
            _fill(obj)
    if w.player:
        from . import gear
        gear.ensure(w)
        try:
            from . import character
            character.ensure(w)
            from . import companions
            companions.ensure(w)
        except ImportError:
            pass


def valid_slot(slot: str) -> bool:
    return bool(re.fullmatch(r"auto|[1-5]", slot or ""))
