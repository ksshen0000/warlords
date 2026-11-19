"""Continuous movement over the terrain (flow fields for places, direct lines nearby)."""
from __future__ import annotations

import math

from .model import Party, World, party_speed
from .terrain import NC

ARRIVE = 3.0       # distance at which a place counts as reached
CONTACT = 4.5      # distance at which two parties engage


def set_place(p: Party, place: str) -> None:
    p.target = {"kind": "place", "id": place}
    p.mode = "move"


def set_party(p: Party, other: str, mode: str = "chase") -> None:
    p.target = {"kind": "party", "id": other}
    p.mode = mode


def set_point(p: Party, x: float, y: float, mode: str = "move") -> None:
    p.target = {"kind": "point", "pos": [x, y]}
    p.mode = mode


def stop(p: Party) -> None:
    p.target = None
    if p.mode in ("move", "chase", "flee", "follow"):
        p.mode = "idle"


def target_pos(w: World, p: Party):
    t = p.target
    if not t:
        return None
    if t["kind"] == "place":
        return w.terrain.places.get(t["id"])
    if t["kind"] == "party":
        q = w.parties.get(t["id"])
        if not q or not q.alive:
            return None
        if q.inside:
            s = w.settlements.get(q.inside)      # "__captive" etc. = unreachable
            return tuple(s.pos) if s else None
        return tuple(q.pos)
    return tuple(t["pos"])


def arrived(w: World, p: Party) -> bool:
    tp = target_pos(w, p)
    if tp is None:
        return False
    lim = CONTACT if p.target["kind"] == "party" else ARRIVE
    return math.hypot(tp[0] - p.pos[0], tp[1] - p.pos[1]) <= lim


def _nearest_place(w: World, pos) -> str:
    best, bd = None, float("inf")
    for pid, pp in w.terrain.places.items():
        s = w.settlements.get(pid)
        if s is not None and s.kind == "hideout" and not s.active:
            continue
        d = (pp[0] - pos[0]) ** 2 + (pp[1] - pos[1]) ** 2
        if d < bd:
            best, bd = pid, d
    return best


def _goal(w: World, p: Party, look: int = 4):
    t = p.target
    tr = w.terrain
    x, y = p.pos
    if t["kind"] == "place":
        return tr.waypoint(t["id"], x, y, look)
    tp = target_pos(w, p)
    if tp is None:
        return None
    if math.hypot(tp[0] - x, tp[1] - y) < 160 and tr.line_passable(x, y, tp[0], tp[1]):
        return tp
    # route via the flow field of the place nearest the target
    key = (round(tp[0] / 40), round(tp[1] / 40))
    if p.memo.get("route_key") != key:
        p.memo["route_key"] = key
        p.memo["route_place"] = _nearest_place(w, tp)
    return tr.waypoint(p.memo["route_place"], x, y, look)


def move(w: World, p: Party, hours: float = 1.0) -> None:
    if p.inside or not p.target or p.mode in ("siege", "raid", "idle"):
        return
    tr = w.terrain
    base = party_speed(w, p)
    left = hours
    for _ in range(16):
        if left <= 1e-4 or arrived(w, p):
            break
        goal = _goal(w, p)
        if goal is None:
            stop(p)
            break
        dx, dy = goal[0] - p.pos[0], goal[1] - p.pos[1]
        d = math.hypot(dx, dy)
        if d < 1e-3:
            tp = target_pos(w, p)
            if tp is not None and math.hypot(tp[0] - p.pos[0], tp[1] - p.pos[1]) < NC * 2:
                p.pos[0], p.pos[1] = tp[0], tp[1]      # the last few steps clip a blocked corner: just get there
            elif p.target.get("kind") == "point" and not arrived(w, p):
                stop(p)          # the point can't be reached from here (across a river…): pick another
            break
        sp = base * max(0.25, tr.speed_at(*p.pos))
        step = min(d, NC * 0.9, sp * left)
        nx, ny = p.pos[0] + dx / d * step, p.pos[1] + dy / d * step
        if not tr.passable(nx, ny):
            # cutting a corner clipped a blocked cell (river bank, ford, mountain edge): follow the
            # flow field one cell at a time instead of snapping back (which made parties jitter in place)
            g1 = _goal(w, p, 1)
            if g1 is not None:
                dx1, dy1 = g1[0] - p.pos[0], g1[1] - p.pos[1]
                d1 = math.hypot(dx1, dy1)
                if d1 > 1e-3:
                    s1 = min(d1, step)
                    nx, ny = p.pos[0] + dx1 / d1 * s1, p.pos[1] + dy1 / d1 * s1
            if not tr.passable(nx, ny):
                # slide along the obstacle: move on one axis only (whichever gets closer to the goal)
                ux, uy = dx / d * step, dy / d * step
                opts = [(p.pos[0] + ux, p.pos[1]), (p.pos[0], p.pos[1] + uy)]
                opts = [o for o in opts if tr.passable(*o)]
                if opts:
                    nx, ny = min(opts, key=lambda o: math.hypot(goal[0] - o[0], goal[1] - o[1]))
                else:
                    nx, ny = tr.nearest_passable(nx, ny, 2)
                    if not tr.passable(nx, ny):
                        break
        p.pos[0], p.pos[1] = nx, ny
        left -= step / sp


def flee_from(w: World, p: Party, threat_pos, safe_place: str | None) -> None:
    """Run to a safe place if it isn't behind the threat, otherwise straight away."""
    if safe_place:
        sp = w.terrain.places[safe_place]
        to_safe = (sp[0] - p.pos[0], sp[1] - p.pos[1])
        to_threat = (threat_pos[0] - p.pos[0], threat_pos[1] - p.pos[1])
        if to_safe[0] * to_threat[0] + to_safe[1] * to_threat[1] <= 0 or \
                math.hypot(*to_safe) < math.hypot(*to_threat):
            p.target = {"kind": "place", "id": safe_place}
            p.mode = "flee"
            return
    dx, dy = p.pos[0] - threat_pos[0], p.pos[1] - threat_pos[1]
    d = math.hypot(dx, dy) or 1.0
    tr = w.terrain
    for ang in (0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5):
        c, s = math.cos(ang), math.sin(ang)
        vx, vy = (dx * c - dy * s) / d, (dx * s + dy * c) / d
        tx, ty = p.pos[0] + vx * 60, p.pos[1] + vy * 60
        if tr.passable(tx, ty) and tr.line_passable(p.pos[0], p.pos[1], tx, ty):
            set_point(p, tx, ty, "flee")
            return
    if safe_place:
        p.target = {"kind": "place", "id": safe_place}
        p.mode = "flee"
