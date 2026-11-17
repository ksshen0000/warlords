"""Procedural continent: heightmap, biomes, rivers, settlement sites, roads,
navigation grid and per-place flow fields (cheap pathfinding for many parties).

Coordinates are world units (0..W, 0..H), y grows southwards.
"""
from __future__ import annotations

import base64
import heapq
import math
import os
import pickle
import random
from array import array

from . import data as D

W, H = 1200, 800
RC = 4                      # render cell size (world units)
RW, RH = W // RC, H // RC   # 300 x 200 render grid
NC = 8                      # navigation cell size
NW, NH = W // NC, H // NC   # 150 x 100 nav grid
INF = float("inf")
CACHE_VERSION = 5

_N8 = [(-1, 0, 1.0), (1, 0, 1.0), (0, -1, 1.0), (0, 1, 1.0),
       (-1, -1, 1.4142), (1, -1, 1.4142), (-1, 1, 1.4142), (1, 1, 1.4142)]


# ------------------------------------------------------------------ noise
def _hash(ix: int, iy: int, seed: int) -> float:
    h = (ix * 374761393 + iy * 668265263 + seed * 1442695041) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFFFFFF) / 0xFFFFFF


def _vnoise(x: float, y: float, seed: int) -> float:
    ix, iy = math.floor(x), math.floor(y)
    fx, fy = x - ix, y - iy
    sx, sy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a, b = _hash(ix, iy, seed), _hash(ix + 1, iy, seed)
    c, d = _hash(ix, iy + 1, seed), _hash(ix + 1, iy + 1, seed)
    return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy


def _fbm(x: float, y: float, seed: int, octaves: int) -> float:
    total, amp, norm, f = 0.0, 1.0, 0.0, 1.0
    for o in range(octaves):
        total += amp * _vnoise(x * f, y * f, seed + o * 101)
        norm += amp
        amp *= 0.5
        f *= 2.0
    return total / norm


def _clamp(v, lo=0.0, hi=1.0):
    return lo if v < lo else hi if v > hi else v


# ---------------------------------------------------------------- terrain
class Terrain:
    def __init__(self, seed: int):
        self.seed = seed
        self.height: list[float] = []      # render grid, 0..1 (sea_level separates water)
        self.biome = bytearray(RW * RH)
        self.river = bytearray(RW * RH)    # 1 = river cell
        self.sea_level = 0.0
        self.rivers: list[dict] = []       # {"points": [[x,y]...], "width": w}
        self.roads: list[dict] = []        # {"points": [[x,y]...], "kind": "road"|"track"}
        self.speed = array("f", [0.0]) * (NW * NH)   # nav grid speed multiplier (0 = impassable)
        self.is_road = bytearray(NW * NH)
        self.sites: dict = {}              # generated placement (see _place_sites)
        self.places: dict[str, tuple[float, float]] = {}   # place id -> pos (for flow fields)
        self._flow: dict[str, array] = {}

    # ---------------------------------------------------------- queries
    @staticmethod
    def ncell(x: float, y: float) -> int:
        cx = min(NW - 1, max(0, int(x // NC)))
        cy = min(NH - 1, max(0, int(y // NC)))
        return cy * NW + cx

    @staticmethod
    def ncenter(i: int) -> tuple[float, float]:
        return ((i % NW) + 0.5) * NC, ((i // NW) + 0.5) * NC

    def speed_at(self, x: float, y: float) -> float:
        return self.speed[self.ncell(x, y)]

    def biome_at(self, x: float, y: float) -> int:
        cx = min(RW - 1, max(0, int(x // RC)))
        cy = min(RH - 1, max(0, int(y // RC)))
        return self.biome[cy * RW + cx]

    def passable(self, x: float, y: float) -> bool:
        return 0 <= x < W and 0 <= y < H and self.speed_at(x, y) > 0

    def line_passable(self, ax, ay, bx, by) -> bool:
        d = math.hypot(bx - ax, by - ay)
        n = max(1, int(d / (NC * 0.5)))
        for i in range(n + 1):
            t = i / n
            if not self.passable(ax + (bx - ax) * t, ay + (by - ay) * t):
                return False
        return True

    def nearest_passable(self, x: float, y: float, radius: int = 6) -> tuple[float, float]:
        if self.passable(x, y):
            return x, y
        best = None
        c0 = self.ncell(x, y)
        cx0, cy0 = c0 % NW, c0 // NW
        for r in range(1, radius + 1):
            for dy in range(-r, r + 1):
                for dx in range(-r, r + 1):
                    cx, cy = cx0 + dx, cy0 + dy
                    if 0 <= cx < NW and 0 <= cy < NH and self.speed[cy * NW + cx] > 0:
                        p = self.ncenter(cy * NW + cx)
                        d = math.hypot(p[0] - x, p[1] - y)
                        if best is None or d < best[0]:
                            best = (d, p)
            if best:
                return best[1]
        return x, y

    # -------------------------------------------------------- flow fields
    def flow(self, place: str) -> array:
        f = self._flow.get(place)
        if f is None:
            f = self._dijkstra(self.ncell(*self.places[place]))
            self._flow[place] = f
        return f

    def _adjacency(self) -> list:
        adj = getattr(self, "_adj", None)
        if adj is None:
            speed = self.speed
            adj = []
            for i in range(NW * NH):
                cx, cy = i % NW, i // NW
                si = speed[i] or 0.3     # allow leaving an impassable cell
                row = []
                for dx, dy, w in _N8:
                    nx, ny = cx + dx, cy + dy
                    if 0 <= nx < NW and 0 <= ny < NH:
                        j = ny * NW + nx
                        sj = speed[j]
                        if sj > 0:
                            row.append((j, w * NC * 2.0 / (si + sj)))
                adj.append(row)
            self._adj = adj
        return adj

    def _dijkstra(self, src: int) -> array:
        adj = self._adjacency()
        dist = [INF] * (NW * NH)
        dist[src] = 0.0
        pq = [(0.0, src)]
        pop, push = heapq.heappop, heapq.heappush
        while pq:
            d, i = pop(pq)
            if d > dist[i]:
                continue
            for j, c in adj[i]:
                nd = d + c
                if nd < dist[j]:
                    dist[j] = nd
                    push(pq, (nd, j))
        return array("f", dist)

    def precompute_flows(self, cache_key: str | None = None) -> None:
        """Compute (or load from disk) the flow field of every registered place."""
        path = None
        if cache_key:
            path = os.path.join(os.path.expanduser("~"), ".cache", "warlords", f"flows-v{CACHE_VERSION}-{cache_key}.pkl")
            try:
                with open(path, "rb") as f:
                    saved = pickle.load(f)
                for pid, raw in saved.items():
                    if pid in self.places:
                        a = array("f")
                        a.frombytes(raw)
                        self._flow[pid] = a
            except (OSError, pickle.PickleError, EOFError):
                pass
        missing = [pid for pid in self.places if pid not in self._flow]
        for pid in missing:
            self.flow(pid)
        if path and missing:
            try:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "wb") as f:
                    pickle.dump({pid: a.tobytes() for pid, a in self._flow.items()}, f)
            except OSError:
                pass

    def travel_cost(self, place: str, x: float, y: float) -> float:
        """Distance-equivalent cost (world units at speed 1.0) from (x,y) to a place."""
        d = self.flow(place)[self.ncell(x, y)]
        return d if d < INF else INF

    def waypoint(self, place: str, x: float, y: float, lookahead: int = 4) -> tuple[float, float]:
        """Next point to walk towards when heading for `place` (follows the flow field)."""
        f = self.flow(place)
        i = self.ncell(x, y)
        if f[i] == 0:
            return self.places[place]
        best = i
        cells = []
        for _ in range(lookahead):
            cx, cy = best % NW, best // NW
            nb, nbd = best, f[best]
            for dx, dy, _w in _N8:
                nx, ny = cx + dx, cy + dy
                if 0 <= nx < NW and 0 <= ny < NH:
                    j = ny * NW + nx
                    if f[j] < nbd:
                        nb, nbd = j, f[j]
            if nb == best:
                break
            best = nb
            cells.append(nb)
            if nbd == 0:
                return self.places[place]
        # take the farthest look-ahead cell that is reachable in a straight line
        for c in reversed(cells):
            px, py = self.ncenter(c)
            if self.line_passable(x, y, px, py):
                return px, py
        return self.ncenter(cells[0]) if cells else self.places[place]

    # ------------------------------------------------------ serialization
    def to_client(self) -> dict:
        hb = bytearray(RW * RH)
        sea = self.sea_level
        for i, h in enumerate(self.height):
            # 0..99 = water depth, 100..255 = land elevation
            if h < sea:
                hb[i] = int(_clamp((h / sea) if sea else 0) * 99)
            else:
                hb[i] = 100 + int(_clamp((h - sea) / (1 - sea)) * 155)
        return {
            "width": W, "height": H, "grid": [RW, RH], "cell": RC,
            "heights": base64.b64encode(bytes(hb)).decode(),
            "biomes": base64.b64encode(bytes(self.biome)).decode(),
            "biome_names": {k: v[1] for k, v in D.TERRAIN.items()},
            "rivers": self.rivers, "roads": self.roads,
        }


# -------------------------------------------------------------- generator
def generate(seed: int) -> Terrain:
    cache_dir = os.path.join(os.path.expanduser("~"), ".cache", "warlords")
    path = os.path.join(cache_dir, f"terrain-v{CACHE_VERSION}-{seed}.pkl")
    try:
        with open(path, "rb") as f:
            t = pickle.load(f)
            t._flow = {}
            return t
    except (OSError, pickle.PickleError, EOFError, AttributeError):
        pass
    t = _generate(seed)
    try:
        os.makedirs(cache_dir, exist_ok=True)
        flow, t._flow = t._flow, {}
        adj = t.__dict__.pop("_adj", None)
        with open(path, "wb") as f:
            pickle.dump(t, f)
        t._flow = flow
        if adj is not None:
            t._adj = adj
    except OSError:
        pass
    return t


def _generate(seed: int) -> Terrain:
    rng = random.Random(seed * 7919 + 13)
    t = Terrain(seed)
    s = seed * 31 + 5

    # ---- heights
    hs = [0.0] * (RW * RH)
    for y in range(RH):
        ny = y / RH
        for x in range(RW):
            nx = x / RW
            base = _fbm(x / 48.0, y / 48.0, s, 6)
            ridge = 1.0 - abs(_fbm(x / 70.0, y / 70.0, s + 50, 4) * 2 - 1)
            dx, dy = (nx - 0.5) / 0.5, (ny - 0.5) / 0.5
            d = math.sqrt(dx * dx * 0.85 + dy * dy * 1.1)
            h = base * 0.8 + ridge ** 6 * 0.38 + 0.32 - 0.75 * max(0.0, d - 0.42) ** 1.5
            hs[y * RW + x] = h
    srt = sorted(hs)
    sea = srt[int(len(srt) * 0.36)]
    top = srt[-1]
    land = [h for h in hs if h >= sea]
    land.sort()
    hills_lvl = land[int(len(land) * 0.85)]
    mount_lvl = land[int(len(land) * 0.95)]
    # normalise: keep sea level where it is, stretch to 0..1
    t.height = [(h - srt[0]) / (top - srt[0]) for h in hs]
    t.sea_level = (sea - srt[0]) / (top - srt[0])
    hills_n = (hills_lvl - srt[0]) / (top - srt[0])
    mount_n = (mount_lvl - srt[0]) / (top - srt[0])

    # ---- climate + biomes
    for y in range(RH):
        ny = y / RH
        for x in range(RW):
            nx = x / RW
            i = y * RW + x
            h = t.height[i]
            if h < t.sea_level:
                t.biome[i] = D.DEEP_WATER if h < t.sea_level - 0.05 else D.WATER
                continue
            hl = (h - t.sea_level) / (1 - t.sea_level)
            temp = ny + (_fbm(x / 30.0, y / 30.0, s + 9, 3) - 0.5) * 0.18 - hl * 0.15
            m = _fbm(x / 36.0, y / 36.0, s + 3, 4)
            dry = _clamp((0.42 - nx) * 2.2) * _clamp((ny - 0.38) * 2.6)
            m = m - dry * 0.55 + _clamp(nx - 0.66) * 0.5
            if h > mount_n:
                b = D.MOUNTAIN
            elif h > hills_n:
                b = D.HILLS
            elif temp < 0.27:
                b = D.TAIGA if m > 0.52 else D.SNOW
            elif hl < 0.018 and temp > 0.3:
                b = D.BEACH
            elif dry > 0.25 and m < 0.33:
                b = D.DUNES if m < 0.2 else D.DESERT
            elif m > 0.66 and hl < 0.12:
                b = D.MARSH
            elif m > 0.55:
                b = D.FOREST
            elif m < 0.38:
                b = D.STEPPE
            elif m > 0.47:
                b = D.MEADOW
            else:
                b = D.PLAINS
            t.biome[i] = b

    _make_rivers(t, rng)
    _build_nav(t)
    _place_sites(t, rng)
    _build_roads(t)
    return t


def _make_rivers(t: Terrain, rng: random.Random) -> None:
    sea = t.sea_level
    cands = [i for i in range(RW * RH)
             if t.biome[i] in (D.HILLS, D.MOUNTAIN, D.TAIGA, D.FOREST)
             and t.height[i] > sea + 0.25 * (1 - sea)]
    rng.shuffle(cands)
    sources: list[int] = []
    for c in cands:
        cx, cy = c % RW, c // RW
        if all((cx - s % RW) ** 2 + (cy - s // RW) ** 2 > 28 ** 2 for s in sources):
            sources.append(c)
        if len(sources) >= 16:
            break
    for src in sources:
        path = [src]
        seen = {src}
        cur = src
        ok = False
        for _ in range(900):
            cx, cy = cur % RW, cur // RW
            best, bh = None, INF
            for dx, dy, _w in _N8[:4]:          # 4-neighbour keeps rivers continuous
                nx, ny = cx + dx, cy + dy
                if 0 <= nx < RW and 0 <= ny < RH:
                    j = ny * RW + nx
                    if j not in seen and t.height[j] < bh:
                        best, bh = j, t.height[j]
            if best is None:
                break
            if t.river[best]:                    # join an existing river
                path.append(best)
                ok = True
                break
            path.append(best)
            seen.add(best)
            cur = best
            if t.height[best] < sea:
                ok = True
                break
        if not ok or len(path) < 30:
            continue
        for c in path:
            if t.height[c] >= sea:
                t.river[c] = 1
        pts = [[(c % RW + 0.5) * RC, (c // RW + 0.5) * RC] for c in path]
        t.rivers.append({"points": _chaikin(_simplify(pts, 7), 3), "width": 2.0 + min(3.0, len(path) / 80)})


def _build_nav(t: Terrain) -> None:
    for ny in range(NH):
        for nx in range(NW):
            sp, n, blocked, river = 0.0, 0, 0, False
            for dy in (0, 1):
                for dx in (0, 1):
                    r = (ny * 2 + dy) * RW + nx * 2 + dx
                    v = D.TERRAIN[t.biome[r]][2]
                    if v <= 0:
                        blocked += 1
                    else:
                        sp += v
                        n += 1
                    river = river or bool(t.river[r])
            i = ny * NW + nx
            if blocked >= 2 or n == 0:
                t.speed[i] = 0.0
            else:
                v = sp / n
                t.speed[i] = min(v, D.RIVER_SPEED) if river else v


def _land_component(t: Terrain, start: int) -> set[int]:
    seen = {start}
    stack = [start]
    while stack:
        i = stack.pop()
        cx, cy = i % NW, i // NW
        for dx, dy, _w in _N8:
            nx, ny = cx + dx, cy + dy
            if 0 <= nx < NW and 0 <= ny < NH:
                j = ny * NW + nx
                if j not in seen and t.speed[j] > 0:
                    seen.add(j)
                    stack.append(j)
    return seen


def _place_sites(t: Terrain, rng: random.Random) -> None:
    # main landmass = component containing the most land near the centre
    start = min((i for i in range(NW * NH) if t.speed[i] > 0),
                key=lambda i: math.dist(t.ncenter(i), (W / 2, H / 2)))
    main = _land_component(t, start)

    def ok_site(x, y, bad=(D.MARSH, D.DUNES, D.BEACH)):
        if t.ncell(x, y) not in main or t.speed_at(x, y) <= 0:
            return False
        if t.biome_at(x, y) in bad or t.river[min(RH - 1, int(y // RC)) * RW + min(RW - 1, int(x // RC))]:
            return False
        # keep clear of mountains/water right next to the walls
        for ox, oy in ((10, 0), (-10, 0), (0, 10), (0, -10)):
            if not t.passable(x + ox, y + oy):
                return False
        return True

    # Poisson-disc candidates for towns/castles
    cands: list[tuple[float, float]] = []
    for _ in range(6000):
        x, y = rng.uniform(40, W - 40), rng.uniform(40, H - 40)
        if ok_site(x, y) and all(math.dist((x, y), c) > 74 for c in cands):
            cands.append((x, y))

    kingdoms = []
    for kid, _name, culture, _color, (fx, fy) in D.KINGDOMS:
        cap = min(cands, key=lambda c: math.dist(c, (fx * W, fy * H)))
        kingdoms.append((kid, culture, cap))
    caps = {k[2] for k in kingdoms}
    owner: dict[tuple, str] = {}
    for c in cands:
        if c in caps:
            continue
        k = min(kingdoms, key=lambda k: math.dist(c, k[2]))
        owner[c] = k[0]

    fortified = []   # (kingdom, culture, kind, pos)
    for kid, culture, cap in kingdoms:
        fortified.append((kid, culture, "town", cap))
        mine = [c for c, k in owner.items() if k == kid and math.dist(c, cap) < 330]
        chosen = [cap]
        for kind in ("town", "castle", "castle", "castle"):
            if not mine:
                break
            # farthest-point sampling keeps fiefs spread across the realm
            best = max(mine, key=lambda c: min(math.dist(c, o) for o in chosen) - 0.25 * math.dist(c, cap))
            mine.remove(best)
            chosen.append(best)
            fortified.append((kid, culture, kind, best))

    villages = []    # (bound index, pos)
    taken = [f[3] for f in fortified]
    for fi, (_kid, _cul, kind, pos) in enumerate(fortified):
        want = 3 if kind == "town" else 2
        for _ in range(400):
            if want == 0:
                break
            a, r = rng.uniform(0, math.tau), rng.uniform(22, 44)
            x, y = pos[0] + math.cos(a) * r, pos[1] + math.sin(a) * r
            if ok_site(x, y, bad=(D.DUNES,)) and all(math.dist((x, y), o) > 17 for o in taken):
                villages.append((fi, (x, y)))
                taken.append((x, y))
                want -= 1

    hideout_cands = []
    for _ in range(4000):
        x, y = rng.uniform(30, W - 30), rng.uniform(30, H - 30)
        if t.ncell(x, y) not in main or t.speed_at(x, y) <= 0:
            continue
        b = t.biome_at(x, y)
        btype = next((k for k, v in D.BANDIT_TYPES.items() if b in v[2]), None)
        if btype is None:
            continue
        if min(math.dist((x, y), f[3]) for f in fortified) < 70:
            continue
        if min(math.dist((x, y), v[1]) for v in villages) < 32:
            continue
        if all(math.dist((x, y), h[1]) > 95 for h in hideout_cands):
            hideout_cands.append((btype, (x, y)))

    t.sites = {"fortified": fortified, "villages": villages, "hideouts": hideout_cands}


def _astar(t: Terrain, a: int, b: int) -> list[int]:
    bx, by = b % NW, b // NW
    g = {a: 0.0}
    prev = {}
    pq = [(0.0, a)]
    while pq:
        _f, i = heapq.heappop(pq)
        if i == b:
            break
        cx, cy = i % NW, i // NW
        gi = g[i]
        for dx, dy, w in _N8:
            nx, ny = cx + dx, cy + dy
            if not (0 <= nx < NW and 0 <= ny < NH):
                continue
            j = ny * NW + nx
            sp = t.speed[j]
            if sp <= 0 and j != b:
                continue
            if t.is_road[j]:
                cost = w * 0.45
            else:
                cost = w / max(sp, 0.2)
                if sp <= D.RIVER_SPEED:
                    cost *= 3.0          # bridges are expensive: cross rivers rarely
            ng = gi + cost
            if ng < g.get(j, INF):
                g[j] = ng
                prev[j] = i
                h = math.hypot(nx - bx, ny - by) * 0.45
                heapq.heappush(pq, (ng + h, j))
    if b not in prev and a != b:
        return []
    path, i = [b], b
    while i != a:
        i = prev[i]
        path.append(i)
    return path[::-1]


def _build_roads(t: Terrain) -> None:
    fort = [f[3] for f in t.sites["fortified"]]
    n = len(fort)
    # minimum spanning tree + each site's nearest neighbour
    edges = set()
    in_tree, rest = {0}, set(range(1, n))
    while rest:
        a, b = min(((i, j) for i in in_tree for j in rest), key=lambda e: math.dist(fort[e[0]], fort[e[1]]))
        edges.add((min(a, b), max(a, b)))
        in_tree.add(b)
        rest.discard(b)
    for i in range(n):
        near = sorted((math.dist(fort[i], fort[j]), j) for j in range(n) if j != i)
        for d, j in near[:2]:
            if d < 260:
                edges.add((min(i, j), max(i, j)))
    for a, b in sorted(edges, key=lambda e: math.dist(fort[e[0]], fort[e[1]])):
        _lay_road(t, fort[a], fort[b], "road")
    for fi, pos in t.sites["villages"]:
        _lay_road(t, pos, fort[fi], "track")


def _lay_road(t: Terrain, p, q, kind: str) -> None:
    path = _astar(t, t.ncell(*p), t.ncell(*q))
    if not path:
        return
    for c in path:
        t.is_road[c] = 1
        t.speed[c] = D.ROAD_SPEED
    pts = [list(p)] + [list(t.ncenter(c)) for c in path[1:-1]] + [list(q)]
    t.roads.append({"points": _chaikin(_simplify(pts), 2), "kind": kind})


def _simplify(pts: list, step: int = 2) -> list:
    if len(pts) <= 3:
        return pts
    return [pts[0]] + pts[1:-1:step] + [pts[-1]]


def _chaikin(pts: list, iters: int) -> list:
    for _ in range(iters):
        if len(pts) < 3:
            return pts
        out = [pts[0]]
        for a, b in zip(pts, pts[1:]):
            out.append([0.75 * a[0] + 0.25 * b[0], 0.75 * a[1] + 0.25 * b[1]])
            out.append([0.25 * a[0] + 0.75 * b[0], 0.25 * a[1] + 0.75 * b[1]])
        out.append(pts[-1])
        pts = out
    return [[round(x, 1), round(y, 1)] for x, y in pts]
