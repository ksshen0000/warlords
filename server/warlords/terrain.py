"""The campaign map: a simplified China drawn from rules/geography.toml (coast, plateau, mountain
ranges with passes, deserts, rivers with fords) plus noise for detail; settlement sites, roads,
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

W, H = 1920, 1280                 # world units (≈ km); the map is a simplified China, see geography.toml
RC = 4                      # render cell size (world units)
RW, RH = W // RC, H // RC   # 480 x 320 render grid
NC = 8                      # navigation cell size
NW, NH = W // NC, H // NC   # 240 x 160 nav grid
INF = float("inf")
CACHE_VERSION = 11  # bump whenever generation (geography, sites, kingdoms) changes

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
        self.fords: list[list[float]] = []    # [x, y] of each ford across a great river
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
        n = max(1, int(d / (NC * 0.25)))         # dense enough not to slip past a blocked cell's corner
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
                # the place is within reach — but only head straight for it if nothing (a river, a
                # mountain) is in between; otherwise keep following the flow field (e.g. via a ford)
                if self.line_passable(x, y, *self.places[place]):
                    return self.places[place]
                break
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


# -------------------------------------------------------------- generator
def _fingerprint() -> str:
    """Short hash of the rule data that shapes the generated map (geography, realms' sites, bandit
    lairs), so editing geography.toml / world.toml / units.toml never loads a stale cached map."""
    import hashlib
    key = repr((D.KINGDOMS, sorted(D.SITES.items()), sorted(D.LAYOUT.items()), repr(D.GEO),
                sorted((k, sorted(v[2])) for k, v in D.BANDIT_TYPES.items())))
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


# ---------------------------------------------------------- geography
def geo(lon: float, lat: float) -> tuple[float, float]:
    """[longitude, latitude] -> world (x east, y south), using geography.toml [extent]."""
    (l0, l1), (b0, b1) = D.GEO["extent"]["lon"], D.GEO["extent"]["lat"]
    return (lon - l0) / (l1 - l0) * W, (b1 - lat) / (b1 - b0) * H


def to_geo(x: float, y: float) -> tuple[float, float]:
    (l0, l1), (b0, b1) = D.GEO["extent"]["lon"], D.GEO["extent"]["lat"]
    return l0 + x / W * (l1 - l0), b1 - y / H * (b1 - b0)


def _deg() -> float:
    """world units per degree (roughly the same both ways)"""
    (l0, l1), _ = D.GEO["extent"]["lon"], D.GEO["extent"]["lat"]
    return W / (l1 - l0)


def _poly(points) -> list[tuple[float, float]]:
    return [geo(p[0], p[1]) for p in points]


def _inside(x: float, y: float, poly: list) -> bool:
    inside = False
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi + 1e-12) + xi:
            inside = not inside
        j = i
    return inside


def _seg_dist(px, py, ax, ay, bx, by) -> float:
    dx, dy = bx - ax, by - ay
    L = dx * dx + dy * dy
    t = 0.0 if L == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / L))
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


def _line_dist(px, py, pts) -> float:
    return min(_seg_dist(px, py, *pts[i], *pts[i + 1]) for i in range(len(pts) - 1))


def _bbox(pts, pad):
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return min(xs) - pad, min(ys) - pad, max(xs) + pad, max(ys) + pad


def _climate(lon: float, lat: float, n1: float, n2: float) -> int:
    """Biome of open country by region (a simplified China, see geography.toml)."""
    if lat >= 41.3 and lon < 119.0:                         # Mongolian steppe
        return D.MEADOW if n1 > 0.64 else D.STEPPE
    if lon >= 119.0 and lat >= 41.0:                        # Manchuria
        if lat > 44.8 and n1 > 0.55:
            return D.TAIGA
        return D.FOREST if n1 > 0.56 else D.MEADOW if n1 > 0.42 else D.STEPPE
    if lon < 103.5 and lat > 36.4:                          # Hexi corridor oases
        return D.MEADOW if n1 > 0.66 else D.DESERT if n1 < 0.4 else D.STEPPE
    if lat >= 38.3 and lon < 114.0:                         # northern Shanxi / Ordos rim
        return D.HILLS if n2 > 0.62 else D.STEPPE
    if 104.0 <= lon <= 111.5 and 34.75 <= lat < 38.3:       # loess plateau
        return D.HILLS if n2 > 0.47 else D.STEPPE if n1 < 0.45 else D.PLAINS
    if lat >= 32.8:                                         # Central Plain, Guanzhong, Hebei
        return D.FOREST if n1 > 0.72 else D.MEADOW if n1 > 0.57 else D.PLAINS
    if lon < 109.5 and lat < 29.6:                          # Yungui hills
        return D.HILLS if n2 > 0.4 else D.FOREST
    if lat < 29.6:                                          # hills south of the Yangtze
        return D.HILLS if n2 > 0.55 else D.FOREST if n1 > 0.48 else D.MEADOW
    # Jianghuai and Jiangnan: wet, green
    if n1 > 0.74 and lon > 111.0:
        return D.MARSH
    return D.FOREST if n1 > 0.6 else D.PLAINS if n1 < 0.34 else D.MEADOW


def _generate(seed: int) -> Terrain:
    rng = random.Random(seed * 7919 + 13)
    t = Terrain(seed)
    s = seed * 31 + 5
    G = D.GEO
    deg = _deg()
    t.sea_level = 0.3
    sea = t.sea_level
    coast = _poly(G["coast"])
    plateau = _poly(G["plateau"])
    cn = float(G["extent"].get("coast_noise", 0.18)) * deg
    lakes = [(*geo(l[0], l[1]), l[2] * deg, l[3] * deg) for l in G.get("lakes", [])]
    ranges = []
    for r in G.get("ranges", []):
        pts = _poly(r["points"])
        w = float(r["width"]) * deg
        ranges.append((r.get("kind", "mountain"), pts, w, [geo(*p) for p in r.get("passes", [])], _bbox(pts, w * 1.3)))
    deserts = []
    for d in G.get("deserts", []):
        pts = _poly(d["points"])
        deserts.append(({"desert": D.DESERT, "dunes": D.DUNES, "marsh": D.MARSH}[d["kind"]], pts, _bbox(pts, cn)))

    t.height = [0.0] * (RW * RH)
    for y in range(RH):
        for x in range(RW):
            i = y * RW + x
            px, py = (x + 0.5) * RC, (y + 0.5) * RC
            lon, lat = to_geo(px, py)
            n1 = _fbm(x / 26.0, y / 26.0, s + 3, 4)
            n2 = _fbm(x / 13.0, y / 13.0, s + 7, 3)
            jx = px + (_fbm(x / 9.0, y / 9.0, s + 11, 3) - 0.5) * 2 * cn
            jy = py + (_fbm(x / 9.0, y / 9.0, s + 13, 3) - 0.5) * 2 * cn
            land = _inside(jx, jy, coast)
            if land:
                for lx, ly, rx, ry in lakes:
                    if ((jx - lx) / rx) ** 2 + ((jy - ly) / ry) ** 2 < 1.0:
                        land = False
                        break
            if not land:
                t.height[i] = sea - 0.04 - 0.2 * n2
                t.biome[i] = D.WATER
                continue
            elev = 0.06 + 0.08 * n2
            b = _climate(lon, lat, n1, n2)
            if b == D.HILLS:
                elev += 0.16
            # mountain ranges (with gaps at the passes)
            ridge, hill = 0.0, 0.0
            for kind, pts, w, passes, (x0, y0, x1, y1) in ranges:
                if not (x0 <= px <= x1 and y0 <= py <= y1):
                    continue
                d = _line_dist(jx, jy, pts)
                ww = w * (0.8 + 0.4 * n2)
                if d >= ww:
                    continue
                v = (1 - d / ww) ** 1.2
                if kind == "mountain" and any(math.hypot(px - qx, py - qy) < 0.3 * deg for qx, qy in passes):
                    hill = max(hill, v)               # a pass: rough but passable
                elif kind == "mountain":
                    ridge = max(ridge, v)
                else:
                    hill = max(hill, v)
            if _inside(jx, jy, plateau):
                # a high, mostly brown plateau with scattered snowy peaks
                ridge = max(ridge, 0.5 + 0.5 * max(0.0, n2 - 0.58) / 0.42)
            if ridge > 0.3:
                b = D.MOUNTAIN
                elev = 0.55 + 0.35 * ridge + 0.1 * n2
            elif hill > 0.25 or ridge > 0.0:
                b = D.HILLS
                elev = max(elev, 0.25 + 0.25 * max(hill, ridge))
            else:
                for kind_b, pts, (x0, y0, x1, y1) in deserts:
                    if x0 <= jx <= x1 and y0 <= jy <= y1 and _inside(jx, jy, pts):
                        b = kind_b if not (kind_b == D.DUNES and n2 < 0.3) else D.DESERT
                        break
            t.biome[i] = b
            t.height[i] = sea + 0.02 + elev * (1 - sea - 0.03)
    # deep water away from the coast; beaches along it
    for y in range(RH):
        for x in range(RW):
            i = y * RW + x
            near_land = near_sea = False
            for dx in (-2, -1, 0, 1, 2):
                for dy in (-2, -1, 0, 1, 2):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < RW and 0 <= ny < RH:
                        j = ny * RW + nx
                        if t.height[j] >= sea:
                            near_land = True
                        else:
                            near_sea = True
            if t.height[i] < sea:
                if not near_land:
                    t.biome[i] = D.DEEP_WATER
            elif near_sea and t.biome[i] in (D.PLAINS, D.MEADOW, D.FOREST, D.STEPPE, D.MARSH) \
                    and _fbm(x / 6.0, y / 6.0, s + 17, 2) > 0.45 and _is_coast(t, x, y):
                t.biome[i] = D.BEACH

    _shape_basin(t, s)
    _carve_rivers(t)
    _build_nav(t)
    _place_sites(t, rng)
    _build_roads(t)
    _slow_fords(t)
    return t


def _is_coast(t: Terrain, x: int, y: int) -> bool:
    for dx, dy, _w in _N8[:4]:
        nx, ny = x + dx, y + dy
        if 0 <= nx < RW and 0 <= ny < RH and t.biome[ny * RW + nx] in (D.WATER, D.DEEP_WATER):
            return True
    return False


# ------------------------------------------------- basin & rivers
def _shape_basin(t: Terrain, s: int) -> None:
    """Ring the Sichuan basin with mountains, leaving a few passes (geography.toml [basin])."""
    b = D.GEO.get("basin")
    if not b:
        return
    deg = _deg()
    cx, cy = geo(*b["center"])
    rx, ry = b["radius"][0] * deg, b["radius"][1] * deg
    t.basin = (cx, cy, rx, ry)
    passes = [math.radians(a) for a in b.get("passes", [-90, 0])]
    hill_h = t.sea_level + 0.3
    for y in range(RH):
        for x in range(RW):
            i = y * RW + x
            px, py = (x + 0.5) * RC, (y + 0.5) * RC
            dx, dy = (px - cx) / rx, (py - cy) / ry
            d = math.hypot(dx, dy) + (_fbm(x / 9.0, y / 9.0, s + 41, 2) - 0.5) * 0.18
            if d > 1.15:
                continue
            ang = math.atan2(dy, dx)
            gap = min(abs((ang - a + math.pi) % math.tau - math.pi) for a in passes)
            if 0.86 < d < 1.15:
                if gap < 0.17:                       # a pass: rough hills, but passable
                    t.biome[i] = D.HILLS
                    t.height[i] = max(t.height[i], hill_h)
                else:
                    t.biome[i] = D.MOUNTAIN
                    t.height[i] = max(t.height[i], 0.75 + 0.15 * (1 - abs(d - 1.0) / 0.15))
            elif d <= 0.86:
                # the basin floor is green and hilly
                n = _fbm(x / 14.0, y / 14.0, s + 43, 3)
                t.biome[i] = D.FOREST if n > 0.58 else D.HILLS if n < 0.4 else D.MEADOW
                t.height[i] = t.sea_level + (0.22 if t.biome[i] == D.HILLS else 0.1)


def _cells_near_line(pts, radius: float):
    """render cells whose centre is within `radius` world units of the polyline"""
    out = set()
    for (ax, ay), (bx, by) in zip(pts, pts[1:]):
        x0 = max(0, int((min(ax, bx) - radius) // RC))
        x1 = min(RW - 1, int((max(ax, bx) + radius) // RC))
        y0 = max(0, int((min(ay, by) - radius) // RC))
        y1 = min(RH - 1, int((max(ay, by) + radius) // RC))
        for cy in range(y0, y1 + 1):
            for cx in range(x0, x1 + 1):
                if _seg_dist((cx + 0.5) * RC, (cy + 0.5) * RC, ax, ay, bx, by) <= radius:
                    out.add(cy * RW + cx)
    return out


def _carve_rivers(t: Terrain) -> None:
    """Rivers from geography.toml: ordinary rivers are wadeable (slow); the great stretches of the
    Yellow River and the Yangtze are open water that can only be crossed at their fords."""
    sea = t.sea_level
    for r in D.GEO.get("rivers", []):
        raw = _poly(r["points"])
        wide_from = int(r.get("wide_from", len(raw))) if r.get("great") else len(raw)
        narrow = _chaikin(raw[:wide_from + 1], 2) if wide_from > 0 else []
        wide = _chaikin(raw[wide_from:], 2) if wide_from < len(raw) - 1 else []
        if len(narrow) > 1:
            for c in _cells_near_line(narrow, RC * 0.6):
                if t.height[c] >= sea:
                    t.river[c] = 1
            t.rivers.append({"points": narrow, "width": 4.0 if r.get("great") else 2.6, "name": r["name"]})
        if not wide:
            continue
        half = float(r.get("half_width", 2.0)) * RC
        water = set()
        for c in _cells_near_line(wide, half):
            if t.biome[c] not in (D.WATER, D.DEEP_WATER):
                water.add(c)
                t.biome[c] = D.WATER
                t.height[c] = sea - 0.012
        for fx, fy in (geo(*f) for f in r.get("fords", [])):
            # snap to the river, then lay a sandbar / ferry landing across it
            c0 = min(water, key=lambda c: math.hypot((c % RW + 0.5) * RC - fx, (c // RW + 0.5) * RC - fy), default=None)
            if c0 is None:
                continue
            ox, oy = (c0 % RW + 0.5) * RC, (c0 // RW + 0.5) * RC
            for c in water:
                if math.hypot((c % RW + 0.5) * RC - ox, (c // RW + 0.5) * RC - oy) <= half + RC * 1.6:
                    t.biome[c] = D.BEACH
                    t.height[c] = sea + 0.004
                    t.river[c] = 1
            t.fords.append([round(ox, 1), round(oy, 1)])


def _slow_fords(t: Terrain) -> None:
    """Crossing a great river is slow even where a road leads to the ford."""
    for fx, fy in t.fords:
        for dy in range(-3, 4):
            for dx in range(-3, 4):
                x, y = fx + dx * NC, fy + dy * NC
                if 0 <= x < W and 0 <= y < H and math.hypot(dx, dy) * NC <= 14:
                    i = t.ncell(x, y)
                    if t.speed[i] > 0:
                        t.speed[i] = min(t.speed[i], D.FORD_SPEED)


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
    """Cities and castles at their real places (world.toml sites), nudged onto good ground;
    villages scattered around them; bandit hideouts at the places named in geography.toml."""
    first = D.SITES[D.KINGDOMS[0][0]][0]
    start = t.ncell(*t.nearest_passable(*geo(first[2], first[3]), 12))
    main = _land_component(t, start)

    def ok_site(x, y, bad=(D.MARSH, D.DUNES, D.BEACH)):
        if not (0 <= x < W and 0 <= y < H) or t.ncell(x, y) not in main or t.speed_at(x, y) <= 0:
            return False
        if t.biome_at(x, y) in bad or t.river[min(RH - 1, int(y // RC)) * RW + min(RW - 1, int(x // RC))]:
            return False
        # keep clear of mountains/water right next to the walls
        for ox, oy in ((8, 0), (-8, 0), (0, 8), (0, -8)):
            if not t.passable(x + ox, y + oy):
                return False
        return True

    def nudge(x, y, test, reach=48.0):
        if test(x, y):
            return x, y
        best = None
        for r in range(2, int(reach) + 1, 2):
            for k in range(max(8, r)):
                a = k / max(8, r) * math.tau
                qx, qy = x + math.cos(a) * r, y + math.sin(a) * r
                if test(qx, qy):
                    best = (qx, qy)
                    break
            if best:
                return best
        return None

    fortified = []   # (kingdom, culture, kind, pos, name)
    for kid, _name, culture, _color in D.KINGDOMS:
        for name, kind, lon, lat in D.SITES[kid]:
            p = nudge(*geo(lon, lat), ok_site) or t.nearest_passable(*geo(lon, lat), 10)
            fortified.append((kid, culture, kind, p, name))

    villages = []    # (bound index, pos)
    taken = [f[3] for f in fortified]
    for fi, (_kid, _cul, kind, pos, _n) in enumerate(fortified):
        want = int(D.LAYOUT.get("villages_per_town", 2)) if kind == "town" else int(D.LAYOUT.get("villages_per_castle", 1))
        for _ in range(500):
            if want == 0:
                break
            a, r = rng.uniform(0, math.tau), rng.uniform(20, 40)
            x, y = pos[0] + math.cos(a) * r, pos[1] + math.sin(a) * r
            if ok_site(x, y, bad=(D.DUNES,)) and all(math.dist((x, y), o) > 16 for o in taken):
                villages.append((fi, (x, y)))
                taken.append((x, y))
                want -= 1

    def lair_ok(x, y):
        if not (0 <= x < W and 0 <= y < H) or t.ncell(x, y) not in main or t.speed_at(x, y) <= 0:
            return False
        if min(math.dist((x, y), f[3]) for f in fortified) < 55:
            return False
        if villages and min(math.dist((x, y), v[1]) for v in villages) < 26:
            return False
        return all(math.dist((x, y), h[1]) > 60 for h in hideouts)

    hideouts = []    # (bandit type, pos, name)
    for name, lon, lat in D.GEO.get("hideouts", []):
        p = nudge(*geo(lon, lat), lair_ok, reach=40.0)
        if p is None:
            continue
        b = t.biome_at(*p)
        btype = next((k for k, v in D.BANDIT_TYPES.items() if b in v[2]), None) or next(iter(D.BANDIT_TYPES))
        hideouts.append((btype, p, name))

    t.sites = {"fortified": fortified, "villages": villages, "hideouts": hideouts}


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
            if d < 420:
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
