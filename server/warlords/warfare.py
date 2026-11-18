"""Battles on the map, sieges, village raids, hideout assaults, captures."""
from __future__ import annotations

from . import movement as M
from . import troops as T
from .battle import Unit, report, resolve
from .common import add_war_score, destroy_party, dist, safe_haven
from .data import GOODS, TERRAIN, TROOPS
from .model import BANDIT, NEUTRAL, Party, Settlement, World
from .rules import B

JOIN_RADIUS = 18.0
HOLDS_PRISONERS = ("lord", "merc", "hunter", "player")


def _unit(w: World, p: Party) -> Unit:
    tac = w.heroes[p.hero].tactics if p.hero else (1 if p.kind in ("merc", "hunter") else 0)
    wr = B.battle.wound_rate
    bonus = B.player.battle_bonus if p.kind == "player" else 1.0
    return Unit(w.heroes[p.hero].name if p.hero else p.name, p.troops, tac, p.id, p.hero,
                wr.get(p.kind, wr.default), bonus)


def _army_mates(w: World, p: Party, center) -> list[Party]:
    if not p.army or p.army not in w.armies:
        return []
    a = w.armies[p.army]
    out = []
    for hid in [a.leader] + a.members:
        q = w.hero_party(hid)
        if q and q is not p and q.alive and not q.inside and dist(q.pos, center) < 30:
            out.append(q)
    return out


def gather_sides(w: World, att: Party, dfn: Party) -> tuple[list[Party], list[Party]]:
    center = dfn.pos
    A, D = [att] + _army_mates(w, att, center), [dfn] + _army_mates(w, dfn, center)
    for q in list(w.parties.values()):
        if not q.alive or q.inside or q in A or q in D or q.mode == "flee":
            continue
        if q.kind in ("caravan", "villager", "player") or T.healthy(q.troops) == 0:
            continue
        if dist(q.pos, center) > JOIN_RADIUS:
            continue
        if w.hostile(q, dfn) and not w.hostile(q, att):
            A.append(q)
        elif w.hostile(q, att) and not w.hostile(q, dfn):
            D.append(q)
    return A, D


def _names(w: World, ps: list[Party]) -> str:
    names = [w.heroes[p.hero].name if p.hero else p.name for p in ps]
    if len(names) > 3:
        return "、".join(names[:3]) + f"等{len(names)}支部队"
    return "、".join(names)


def _place_name(w: World, pos) -> str:
    best = min(w.settlements.values(), key=lambda s: dist(s.pos, pos) if s.kind != "hideout" or s.active else 1e9)
    d = dist(best.pos, pos)
    return best.name if d < 8 else f"{best.name}附近"


def field_battle(w: World, att: Party, dfn: Party) -> dict:
    A, D = gather_sides(w, att, dfn)
    pos = list(dfn.pos)
    biome = w.terrain.biome_at(*pos)
    au, du = [_unit(w, p) for p in A], [_unit(w, p) for p in D]
    res = resolve(w.rng, au, du, biome)
    rep = report(res, au, du)
    win, lose = (A, D) if res.winner == "attacker" else (D, A)
    place = _place_name(w, pos)
    text = (f"{place}之战：{_names(w, A)}（{res.attacker_start}人）攻击{_names(w, D)}（{res.defender_start}人）"
            f"——{'攻方' if res.winner == 'attacker' else '守方'}获胜，伤亡 {res.attacker_losses}:{res.defender_losses}")
    ev = w.log("battle", text, pos=pos, attackers=[p.id for p in A], defenders=[p.id for p in D],
               sides=[w.side_of(A[0]), w.side_of(D[0])], kinds=[A[0].kind, D[0].kind],
               place=place, terrain=TERRAIN[biome][1], report=rep,
               player=any(p.kind == "player" for p in A + D))
    lose_rows = rep["defender"] if res.winner == "attacker" else rep["attacker"]
    if res.winner == "attacker":
        aftermath(w, win, lose, lose_rows, res.defender_losses, res.attacker_losses, rep, ev)
    else:
        aftermath(w, win, lose, lose_rows, res.attacker_losses, res.defender_losses, rep, ev)
    return ev


def aftermath(w: World, win: list[Party], lose: list[Party], lose_rows: list[dict], enemy_losses: int,
              own_losses: int, rep: dict, ev: dict) -> None:
    rng = w.rng
    captured_heroes: list[str] = []
    loot = 0.0
    prisoners: dict[str, int] = {}
    holders = [p for p in win if p.kind in HOLDS_PRISONERS and p.alive]
    enemy_power_lost = sum((r["killed"] + r["wounded"]) * TROOPS[r["id"]]["power"]
                           for u in lose_rows for r in u["rows"])
    start_size = {u["party"]: sum(r["start"] for r in u["rows"]) for u in lose_rows}

    for p in lose:
        # wounded (and some routed) troops are taken prisoner
        for tid, v in list(p.troops.items()):
            if v[1]:
                prisoners[tid] = prisoners.get(tid, 0) + v[1]
                v[1] = 0
        T.prune(p.troops)
        if p.kind == "player":
            from .player import defeated
            defeated(w, p, win)
            continue
        loot += p.gold * 0.7
        p.gold *= 0.3
        for g, n in p.cargo.items():
            loot += n * GOODS[g][1] * 0.5
        if p.kind in ("caravan", "villager", "bandit") or T.healthy(p.troops) < 4:
            for tid, v in list(p.troops.items()):
                k = v[0] // 2
                if k:
                    prisoners[tid] = prisoners.get(tid, 0) + k
            if p.hero:
                captured_heroes.append(p.hero)
            destroy_party(w, p)
            continue
        if p.hero:
            h = w.heroes[p.hero]
            loot += h.gold * 0.08
            h.gold *= 0.92
            survive = T.healthy(p.troops) / max(1, start_size.get(p.id, 1))
            if rng.random() < B.capture.base_chance + B.capture.per_loss_chance * (1 - survive):
                captured_heroes.append(p.hero)
                destroy_party(w, p)
                continue
        retreat(w, p)

    # winners: loot, xp, prisoners, renown
    total = sum(T.healthy(p.troops) for p in win) or 1
    for p in win:
        share = T.healthy(p.troops) / total
        gain = loot * share
        if p.hero:
            w.heroes[p.hero].gold += gain
        else:
            p.gold += gain
        n = T.healthy(p.troops) or 1
        for tid, v in p.troops.items():
            p.xp[tid] = p.xp.get(tid, 0) + enemy_power_lost * B.battle.xp_per_enemy_power * share * v[0] / n
    if holders:
        cap = {p.id: max(0, T.healthy(p.troops) - sum(p.prisoners.values())) for p in holders}
        for tid, n in prisoners.items():
            for p in holders:
                k = min(n, cap[p.id])
                if k:
                    p.prisoners[tid] = p.prisoners.get(tid, 0) + k
                    cap[p.id] -= k
                    n -= k
    if any(p.kind == "player" for p in win):
        from .player import on_victory
        on_victory(w, enemy_losses, lose)
    win_heroes = [w.heroes[p.hero] for p in win if p.hero]
    lose_heroes = [w.heroes[p.hero] for p in lose if p.hero]
    for h in win_heroes:
        h.renown += min(20, 2 + enemy_losses // 8)
        h.influence += min(10, 1 + enemy_losses / 15)
        for o in win_heroes:
            h.adjust_rel(o.id, 2)
        if lose_heroes:
            h.remember(w.day, f"在{ev.get('place', '')}击败{'、'.join(x.name for x in lose_heroes)}")
    for h in lose_heroes:
        h.remember(w.day, f"在{ev.get('place', '')}败给{_names(w, win)}")
        for o in win_heroes:
            h.adjust_rel(o.id, -3)
    ws, ls = w.side_of(win[0]), (w.side_of(lose[0]) if lose else None)
    if ws in w.kingdoms and ls in w.kingdoms:
        add_war_score(w, ws, ls, 2 + enemy_losses / 4, own_losses, enemy_losses)
        w.kingdoms[ws].last_offensive = w.day
    ev["loot"] = round(loot)
    ev["prisoners"] = sum(prisoners.values())
    rep["captured"] = list(captured_heroes)
    # generals beaten by the player's own party are the player's prisoners (to recruit / ransom / execute)
    by_player = any(p.kind == "player" for p in win)
    for hid in captured_heroes:
        capture_hero(w, w.heroes[hid], "__player" if by_player else ws, win_heroes[0] if win_heroes else None, ev.get("pos"))
        if by_player:
            from .player import queue_captive
            queue_captive(w, hid)


def retreat(w: World, p: Party) -> None:
    if p.kind == "player":
        p.mode, p.target = "idle", None
        p.memo.pop("siege", None)
        return
    haven = safe_haven(w, p)
    p.order = {"type": "retreat", "target": haven.id if haven else None, "age": 0, "reason": "战败撤退"}
    p.memo.pop("chase", None)
    if p.army and p.army in w.armies and p.hero and w.armies[p.army].leader == p.hero:
        disband_army(w, p.army, "统帅战败")
    if haven:
        M.set_place(p, haven.id)
        p.mode = "flee"
    else:
        M.stop(p)


def capture_hero(w: World, h, side: str, by_hero, pos) -> None:
    from .common import nearest_settlement
    if h.party and h.party in w.parties:
        destroy_party(w, w.parties[h.party])
    for a in list(w.armies.values()):
        if a.leader == h.id:
            disband_army(w, a.id, f"{h.name}被俘")
        elif h.id in a.members:
            a.members.remove(h.id)
    h.captive_of = side
    h.captive_days = 0
    h.party = None
    if side in w.kingdoms:
        prison = nearest_settlement(w, pos or [600, 400], lambda s: s.faction == side and s.kind in ("town", "castle"))
        h.captive_at = prison.id if prison else None
        captor = w.kingdoms[side].name
    else:
        h.captive_at = None
        captor = "土匪" if side == BANDIT else "你" if side == "__player" else "敌人"
    if by_hero:
        h.adjust_rel(by_hero.id, -10)
        by_hero.renown += 5
    h.remember(w.day, f"被{captor}俘虏")
    w.log("capture", f"{h.name} 被{captor}俘虏" + (f"，关押在{w.settlements[h.captive_at].name}" if h.captive_at else ""),
          hero=h.id, by=side, pos=pos)


def disband_army(w: World, aid: str, why: str = "") -> None:
    a = w.armies.pop(aid, None)
    if not a:
        return
    for hid in [a.leader] + a.members:
        q = w.hero_party(hid)
        if q and q.army == aid:
            q.army = None
            if hid != a.leader:
                q.order = None
                M.stop(q)
    w.log("army_disbanded", f"{w.heroes[a.leader].name}的军团解散" + (f"（{why}）" if why else ""),
          army=aid, kingdom=a.kingdom)


# ------------------------------------------------------------------ sieges
def start_siege(w: World, p: Party, s: Settlement) -> None:
    side = w.side_of(p)
    p.mode = "siege"
    p.memo["siege"] = s.id
    p.target = None
    if s.siege and s.siege["kingdom"] == side:
        return
    s.siege = {"kingdom": side, "progress": 0.0, "since": w.hour}
    w.kingdoms[side].last_offensive = w.day
    camp = siege_camp(w, s)
    w.log("siege_start", f"{_names(w, camp)}开始围攻{s.name}（守军{T.healthy(s.garrison)}人，民兵{int(s.militia)}）",
          settlement=s.id, kingdom=side)
    owner = w.heroes.get(s.owner)
    if owner:
        owner.remember(w.day, f"{s.name}遭到{w.kingdoms[side].name}围攻")


def siege_camp(w: World, s: Settlement) -> list[Party]:
    if not s.siege:
        return []
    return [p for p in w.parties.values() if p.alive and p.mode == "siege" and p.memo.get("siege") == s.id
            and w.side_of(p) == s.siege["kingdom"] and dist(p.pos, s.pos) < 8]


def siege_tick(w: World) -> None:
    for s in w.settlements.values():
        if not s.siege:
            continue
        camp = siege_camp(w, s)
        if not camp or not w.at_war(s.siege["kingdom"], s.faction):
            for p in camp:
                p.mode = "idle"
            w.log("siege_end", f"{s.name}之围解除", settlement=s.id)
            s.siege = None
            continue
        n = sum(T.healthy(p.troops) for p in camp)
        s.siege["progress"] = round(s.siege["progress"] + n / (s.walls * B.siege.progress_per_wall), 4)
        if s.siege["progress"] >= 1.0:
            assault(w, s, camp)


def defenders_inside(w: World, s: Settlement) -> list[Party]:
    return [p for p in w.parties.values() if p.alive and p.inside == s.id and w.side_of(p) == s.faction
            and p.kind in ("lord", "merc") and T.healthy(p.troops) > 0]


def assault(w: World, s: Settlement, camp: list[Party]) -> None:
    au = [_unit(w, p) for p in camp]
    militia = {"militia": [int(s.militia), 0]}
    inside = defenders_inside(w, s)
    du = [Unit(f"{s.name}守军", s.garrison, 1), Unit(f"{s.name}民兵", militia, 0, wound_rate=0.5)]
    du += [_unit(w, p) for p in inside]
    bonus = 1 + B.siege.wall_bonus_per_level * s.walls
    if len(w.kingdom_settlements(s.faction, ("town", "castle"))) <= B.siege.last_stand_forts:
        bonus *= 1 + B.siege.last_stand_bonus      # a realm's last strongholds fight to the death
    res = resolve(w.rng, au, du, w.terrain.biome_at(*s.pos), bonus)
    rep = report(res, au, du)
    rep["walls"] = s.walls
    s.militia = militia.get("militia", [0, 0])[0]
    kid = s.siege["kingdom"]
    old_fac = s.faction
    if res.winner == "attacker":
        ev = w.log("conquest", "", settlement=s.id, old=old_fac, new=kid, attackers=[p.id for p in camp],
                   defenders=[p.id for p in inside], pos=list(s.pos), report=rep, place=s.name,
                   player=any(p.kind == "player" for p in camp))
        conquer(w, s, camp, inside, ev, res)
    else:
        ev = w.log("assault_failed",
                   f"{_names(w, camp)}强攻{s.name}失败（伤亡 {res.attacker_losses}:{res.defender_losses}）",
                   settlement=s.id, attackers=[p.id for p in camp], pos=list(s.pos), report=rep, place=s.name,
                   player=any(p.kind == "player" for p in camp))
        s.siege = None
        if kid in w.kingdoms and old_fac in w.kingdoms:
            add_war_score(w, old_fac, kid, 10 + res.attacker_losses / 5, res.defender_losses, res.attacker_losses)
        for p in camp:
            p.mode = "idle"
            if p.hero:
                w.heroes[p.hero].remember(w.day, f"强攻{s.name}失败")
            retreat(w, p)


def conquer(w: World, s: Settlement, camp: list[Party], inside: list[Party], ev: dict, res) -> None:
    from .politics import open_fief_decision
    kid = s.siege["kingdom"]
    old_fac, old_owner = s.faction, w.heroes.get(s.owner)
    lead = None
    for p in camp:
        if p.army and p.army in w.armies:
            lead = w.hero_party(w.armies[p.army].leader)
            break
    if lead is None or lead not in camp:
        lead = max(camp, key=lambda p: w.party_power(p))
    holder = lead.hero or w.kingdoms[kid].ruler
    s.faction, s.owner = kid, holder
    s.siege = None
    s.prosperity = max(10.0, s.prosperity - B.siege.conquest_prosperity_loss)
    s.loyalty = float(B.siege.conquest_loyalty)
    s.food = min(s.food, 40.0)
    s.militia = 10.0
    s.garrison = {}
    moved = T.take_healthy(lead.troops, max(10, int(T.healthy(lead.troops) * B.siege.garrison_left_share)), w.rng)
    T.merge(s.garrison, moved)
    for vid in s.villages:
        v = w.settlements[vid]
        v.faction, v.owner = kid, holder
    bounty = 400 if s.kind == "town" else 200
    if lead.hero:
        w.heroes[lead.hero].gold += bounty
    for p in camp:
        p.mode = "idle"
        p.order = None
        if p.hero:
            h = w.heroes[p.hero]
            h.renown += 15
            h.influence += 10
            h.remember(w.day, f"攻陷{s.name}")
    if old_owner:
        old_owner.remember(w.day, f"失去了封地{s.name}")
        for p in camp:
            if p.hero:
                old_owner.adjust_rel(p.hero, -12)
    if old_fac in w.kingdoms:
        add_war_score(w, kid, old_fac, 60 if s.kind == "town" else 40, res.attacker_losses, res.defender_losses)
        w.kingdoms[kid].last_offensive = w.day
    ev["text"] = (f"{_names(w, camp)}攻陷{s.name}！{s.name}由{w.kingdoms[old_fac].name if old_fac in w.kingdoms else '?'}"
                  f"归入{w.kingdoms[kid].name}（伤亡 {res.attacker_losses}:{res.defender_losses}）")
    for p in inside:
        if p.hero:
            capture_hero(w, w.heroes[p.hero], kid, w.heroes.get(lead.hero), s.pos)
        else:
            destroy_party(w, p)
    contributors = [p.hero for p in camp if p.hero]
    if any(p.kind == "player" for p in camp) and w.player.get("kingdom") == kid:
        contributors.append("player")
    open_fief_decision(w, s, contributors)


# ------------------------------------------------------------- raids
def start_raid(w: World, p: Party, v: Settlement) -> None:
    p.mode = "raid"
    p.target = None
    p.timer = 0.0
    p.memo["raid"] = v.id
    if v.militia >= 5:
        mil = {"militia": [int(v.militia), 0]}
        au = [_unit(w, p)]
        du = [Unit(f"{v.name}民兵", mil, 0, wound_rate=0.5)]
        res = resolve(w.rng, au, du, w.terrain.biome_at(*v.pos), 1.1)
        rep = report(res, au, du)
        v.militia = mil.get("militia", [0, 0])[0]
        w.log("battle", f"{v.name}民兵抵抗{_names(w, [p])}的劫掠——{'劫掠者' if res.winner == 'attacker' else '民兵'}获胜",
              pos=list(v.pos), attackers=[p.id], defenders=[], place=v.name, report=rep,
              sides=[w.side_of(p), v.faction], kinds=[p.kind, "militia"])
        if res.winner != "attacker":
            p.mode = "idle"
            retreat(w, p)
            return
    w.log("raid_start", f"{_names(w, [p])}开始劫掠{v.name}", settlement=v.id, party=p.id, pos=list(v.pos))


def raid_tick(w: World) -> None:
    for p in list(w.parties.values()):
        if not p.alive or p.mode != "raid":
            continue
        v = w.settlements.get(p.memo.get("raid"))
        if not v or not w.hostile_to_settlement(p, v) or dist(p.pos, v.pos) > 6:
            p.mode = "idle"
            continue
        p.timer += 1
        if p.timer < B.raid.duration_hours:
            continue
        loot = v.stock * GOODS.get(v.produce or "grain", ("", 10))[1] * 0.8 + v.prosperity * 5
        v.stock = 0.0
        v.prosperity = max(5.0, v.prosperity - 8)
        v.raided_until = w.hour + 24 * B.raid.recovery_days
        v.militia = 0.0
        p.mode = "idle"
        p.order = None
        from .scenario import spawn_refugees
        spawn_refugees(w, v)
        if p.hero:
            h = w.heroes[p.hero]
            h.gold += loot
            h.renown += 2
            h.remember(w.day, f"劫掠了{v.name}")
            owner = w.heroes.get(v.owner)
            if owner:
                owner.adjust_rel(h.id, -12)
                owner.remember(w.day, f"村庄{v.name}被{h.name}劫掠")
            side = w.side_of(p)
            if side in w.kingdoms and v.faction in w.kingdoms:
                add_war_score(w, side, v.faction, 12)
        else:
            p.gold += loot
        w.log("raid", f"{_names(w, [p])}洗劫了{v.name}，掠得约{int(loot)}金", settlement=v.id, party=p.id,
              pos=list(v.pos), loot=round(loot))


# --------------------------------------------------------- hideouts
def assault_hideout(w: World, p: Party, h: Settlement) -> None:
    attackers = [p] + _army_mates(w, p, h.pos)
    au = [_unit(w, q) for q in attackers]
    lurkers = [q for q in w.parties.values() if q.alive and q.kind == "bandit" and dist(q.pos, h.pos) < 8]
    du = [Unit(f"{h.name}匪众", h.garrison, 1, wound_rate=0.45)] + [_unit(w, q) for q in lurkers]
    res = resolve(w.rng, au, du, w.terrain.biome_at(*h.pos), 1.15)
    rep = report(res, au, du)
    if res.winner == "attacker":
        loot = 250 + h.stock
        prisoners: dict = {}
        for tid, v in h.garrison.items():
            prisoners[tid] = prisoners.get(tid, 0) + v[1] + v[0] // 2
        h.garrison = {}
        h.active = False
        h.stock = 0.0
        h.timer = float(w.hour + 24 * B.bandits.hideout_respawn_days)   # earliest a new hideout may appear
        for q in lurkers:
            destroy_party(w, q)
        holders = [q for q in attackers if q.kind in HOLDS_PRISONERS]
        if holders:
            for tid, n in prisoners.items():
                holders[0].prisoners[tid] = holders[0].prisoners.get(tid, 0) + n
        for q in attackers:
            if q.hero:
                hero = w.heroes[q.hero]
                hero.gold += loot / len(attackers)
                hero.renown += 10
                hero.remember(w.day, f"剿灭匪巢{h.name}")
            else:
                q.gold += loot / len(attackers)
            q.order = None
            q.mode = "idle"
        for b in w.parties.values():
            if b.kind == "bandit" and b.home == h.id:
                b.home = None
        w.log("hideout_cleared", f"{_names(w, attackers)}剿灭了匪巢{h.name}", settlement=h.id,
              pos=list(h.pos), report=rep, attackers=[q.id for q in attackers], place=h.name,
              sides=[w.side_of(p), BANDIT], kinds=[p.kind, "hideout"], player=p.kind == "player")
    else:
        w.log("battle", f"{_names(w, attackers)}进攻匪巢{h.name}失败（伤亡 {res.attacker_losses}:{res.defender_losses}）",
              pos=list(h.pos), report=rep, attackers=[q.id for q in attackers], defenders=[], place=h.name,
              sides=[w.side_of(p), BANDIT], kinds=[p.kind, "hideout"], player=p.kind == "player")
        for q in attackers:
            retreat(w, q)


def neutral_or_bandit(side: str) -> bool:
    return side in (BANDIT, NEUTRAL)
