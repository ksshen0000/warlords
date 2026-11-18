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
CACHE_VERSION = 7   # bump whenever generation (climate, sites, kingdoms) changes

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
        self.river_y: list = [None] * RW      # great river centre line per render column (None = no river)
        self.fords: list[list[float]] = []    # [x, y] of each ford across the great river
        self.basin: tuple | None = None       # (cx, cy, rx, ry) in world units
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
            path = os.path.join(os.path.expanduser("~"), ".cache", "warlords", f"flows-v{CACHE_VERSION}-{_fingerprint()}-{cache_key}.pkl")
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
            "rivers": self.rivers, "roads": self.roads, "fords": self.fords,
        }

    def in_basin(self, x: float, y: float) -> bool:
        if not self.basin:
            return False
        cx, cy, rx, ry = self.basin
        return ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 < 0.9 ** 2

    def region(self, x: float, y: float) -> str:
        """'basin' / 'south' / 'north' of the great river — used to keep realms on their own side."""
        if self.in_basin(x, y):
            return "basin"
        col = min(RW - 1, max(0, int(x // RC)))
        ry = self.river_y[col]
        if ry is None:
            # west of where the river leaves the basin: south of the basin's top counts as south
            return "south" if self.basin and y > self.basin[1] - self.basin[3] else "north"
        return "south" if y > ry else "north"


# -------------------------------------------------------------- generator
def _fingerprint() -> str:
    """Short hash of the rule data that shapes the generated map (kingdom seats, bandit lairs),
    so editing world.toml / units.toml never loads a stale cached map."""
    import hashlib
    key = repr((D.KINGDOMS, sorted(D.LAYOUT.items()), sorted((k, sorted(v[2])) for k, v in D.BANDIT_TYPES.items())))
    return hashlib.sha1(key.encode()).hexdigest()[:8]


def generate(seed: int) -> Terrain:
    cache_dir = os.path.join(os.path.expanduser("~"), ".cache", "warlords")
    path = os.path.join(cache_dir, f"terrain-v{CACHE_VERSION}-{_fingerprint()}-{seed}.pkl")
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
            # climate (Northern & Southern Dynasties setting, see docs/worldbuilding.md):
            # far north cold steppe, northwest desert corridor, south wet river country,
            # southwest a hilly basin, centre open plains.
            temp = ny + (_fbm(x / 30.0, y / 30.0, s + 9, 3) - 0.5) * 0.12 - hl * 0.15
            m = _fbm(x / 36.0, y / 36.0, s + 3, 4)
            dry = _clamp((0.38 - nx) * 2.6) * _clamp((0.58 - ny) * 3.0)          # northwest desert
            north = _clamp((0.32 - ny) * 3.5)                                    # northern steppe
            wet = _clamp((ny - 0.6) * 2.5)                                       # southern rivers
            sw = _clamp((0.36 - nx) * 3.0) * _clamp((ny - 0.58) * 3.0)           # southwestern basin
            m = m - dry * 0.6 - north * 0.28 + wet * 0.32 * (1 - sw)
            if h > mount_n:
                b = D.MOUNTAIN
            elif h > hills_n:
                b = D.HILLS
            elif temp < 0.07:
                b = D.SNOW
            elif temp < 0.2 and m > 0.55:
                b = D.TAIGA
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

    _shape_basin(t, s, hills_n, mount_n)
    _great_river(t, rng, s)
    _make_rivers(t, rng)
    _build_nav(t)
    _place_sites(t, rng)
    _build_roads(t)
    _slow_fords(t)
    return t


# ------------------------------------------------- basin & great river
def _shape_basin(t: Terrain, s: int, hills_n: float, mount_n: float) -> None:
    """Ring a fertile basin with mountains, leaving a few passes (rules: world.toml [layout])."""
    b = D.LAYOUT.get("basin")
    if not b:
        return
    cx, cy, rx, ry = b[0] * W, b[1] * H, b[2] * W, b[3] * H
    t.basin = (cx, cy, rx, ry)
    passes = [math.radians(a) for a in D.LAYOUT.get("basin_passes", [-90, 0])]
    for y in range(RH):
        for x in range(RW):
            i = y * RW + x
            px, py = (x + 0.5) * RC, (y + 0.5) * RC
            dx, dy = (px - cx) / rx, (py - cy) / ry
            d = math.hypot(dx, dy) + (_fbm(x / 9.0, y / 9.0, s + 41, 2) - 0.5) * 0.18
            if d > 1.12:
                continue
            if t.height[i] < t.sea_level:
                if d > 1.0:
                    continue                          # leave the coast outside the ring alone
                t.height[i] = t.sea_level + 0.05      # the basin is always dry land
                t.biome[i] = D.MEADOW
            ang = math.atan2(dy, dx)
            gap = min(abs((ang - a + math.pi) % math.tau - math.pi) for a in passes)
            if 0.86 < d < 1.12:
                if gap < 0.16:                       # a pass: rough hills, but passable
                    t.biome[i] = D.HILLS
                    t.height[i] = max(t.height[i], hills_n + 0.02)
                else:
                    t.biome[i] = D.MOUNTAIN
                    t.height[i] = max(t.height[i], mount_n + 0.03 + 0.08 * (1 - abs(d - 0.99) / 0.13))
            elif d <= 0.86 and t.biome[i] in (D.PLAINS, D.STEPPE, D.DESERT, D.DUNES, D.SNOW, D.TAIGA, D.MOUNTAIN):
                # the basin floor is green and hilly
                n = _fbm(x / 14.0, y / 14.0, s + 43, 3)
                t.biome[i] = D.FOREST if n > 0.58 else D.HILLS if n < 0.4 else D.MEADOW
                if t.biome[i] != D.HILLS:
                    t.height[i] = min(t.height[i], hills_n - 0.01)


def _great_river(t: Terrain, rng: random.Random, s: int) -> None:
    """A wide, unfordable river from the basin's east gorge to the eastern sea, crossable only
    at a few fords (rules: world.toml [layout] fords)."""
    if not t.basin:
        return
    cx, cy, rx, ry = t.basin
    x0 = int(cx // RC)
    exit_x = (cx + rx * 1.12) / RC
    target = 0.6 * H
    half = 2.6                                    # half width in render cells (~20 world units)
    span = RW - x0
    for col in range(x0, RW):
        u = (col - x0) / max(1, span)
        amp = 18.0 * min(1.0, u * 3)
        yc = cy + (target - cy) * (3 * u * u - 2 * u * u * u) \
            + amp * math.sin(col * RC / 85.0 + s) + 0.5 * amp * math.sin(col * RC / 33.0 + 2 * s)
        t.river_y[col] = yc
        wide = col > exit_x
        h = half if wide else 1.0
        for row in range(int((yc / RC) - h - 1), int((yc / RC) + h + 2)):
            if not (0 <= row < RH) or abs((row + 0.5) - yc / RC) > h:
                continue
            i = row * RW + col
            if t.height[i] < t.sea_level:
                continue
            if wide:
                t.biome[i] = D.WATER
                t.height[i] = t.sea_level - 0.012
            else:
                t.river[i] = 1                        # inside the basin: an ordinary (wadeable) river
    inner = [[(c + 0.5) * RC, t.river_y[c]] for c in range(x0, int(exit_x) + 3, 3) if t.river_y[c] is not None]
    if len(inner) > 2:
        t.rivers.append({"points": _chaikin(inner, 2), "width": 4.0})
    # fords, spread along the wide stretch where both banks are land
    n = int(D.LAYOUT.get("fords", 4))
    land_cols = [c for c in range(int(exit_x) + 8, RW - 4) if _bank_land(t, c)]
    if not land_cols:
        return
    for k in range(n):
        want = land_cols[int((k + 0.5) / n * len(land_cols))]
        col = min(land_cols, key=lambda c: abs(c - want))
        yc = t.river_y[col]
        for dc in range(-2, 3):
            c = col + dc
            for row in range(int(yc / RC - half - 2), int(yc / RC + half + 3)):
                if 0 <= c < RW and 0 <= row < RH:
                    i = row * RW + c
                    if t.biome[i] == D.WATER and t.height[i] >= t.sea_level - 0.013:
                        t.biome[i] = D.BEACH                  # a sandbar / ferry landing
                        t.height[i] = t.sea_level + 0.004
                        t.river[i] = 1
        t.fords.append([round((col + 0.5) * RC, 1), round(yc, 1)])


def _bank_land(t: Terrain, col: int) -> bool:
    yc = t.river_y[col]
    if yc is None:
        return False
    north = int(yc / RC) - 5
    south = int(yc / RC) + 5
    return 0 <= north and south < RH and t.height[north * RW + col] >= t.sea_level \
        and t.height[south * RW + col] >= t.sea_level


def _slow_fords(t: Terrain) -> None:
    """Crossing the great river is slow even where a road leads to the ford."""
    for fx, fy in t.fords:
        for dy in range(-3, 4):
            for dx in range(-2, 3):
                x, y = fx + dx * NC, fy + dy * NC
                if 0 <= x < W and 0 <= y < H:
                    i = t.ncell(x, y)
                    if t.speed[i] > 0:
                        cx, cy = t.ncenter(i)
                        ry = t.river_y[min(RW - 1, int(cx // RC))]
                        if ry is not None and abs(cy - ry) < 14:
                            t.speed[i] = min(t.speed[i], D.FORD_SPEED)


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
    def claim(c, cap):
        # realms keep to their own side of the great river and of the basin's mountains
        return math.dist(c, cap) + (220 if t.region(*c) != t.region(*cap) else 0)

    for c in cands:
        if c in caps:
            continue
        k = min(kingdoms, key=lambda k: claim(c, k[2]))
        owner[c] = k[0]
    # the basin belongs to whoever has their seat there
    basin_k = next((k for k in kingdoms if t.region(*k[2]) == "basin"), None)
    if basin_k:
        for c in cands:
            if c not in caps and t.region(*c) == "basin":
                owner[c] = basin_k[0]

    fortified = []   # (kingdom, culture, kind, pos)
    for kid, culture, cap in kingdoms:
        fortified.append((kid, culture, "town", cap))
        kinds = D.LAYOUT.get("fortified", ["town", "town", "castle", "castle"])[1:]
        mine = [c for c, k in owner.items() if k == kid and math.dist(c, cap) < 330]
        home = [c for c in mine if t.region(*c) == t.region(*cap)]
        if len(home) >= len(kinds):
            mine = home                               # stay on our side of the river / mountains
        chosen = [cap]
        for kind in kinds:
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
        want = int(D.LAYOUT.get("villages_per_town", 3)) if kind == "town" else int(D.LAYOUT.get("villages_per_castle", 2))
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
