"""The player's party: Mount & Blade style travel, menus, encounters, trade,
recruiting, mercenary contracts / vassalage, captivity, and talking to lords.

Time only advances while the client asks for it (moving, or holding space);
whenever a menu is open (`w.player["pending"]`) the simulation refuses to step.
"""
from __future__ import annotations

from . import movement as M
from . import troops as T
from .common import dist, nearest_settlement
from .data import BACKGROUNDS, BLURBS, CLASS_NAMES, CULTURES, GOODS, KIND_NAMES, TITLES, TROOPS
from .economy import WORKSHOP
from .model import BANDIT, PLAYER, Party, World, party_speed
from .rules import B

PID = "player"
NAME = "你"


# ----------------------------------------------------------------- basics
def party(w: World) -> Party | None:
    return w.parties.get(PID)


def create(w: World) -> None:
    """Create the player's (empty) party and open character creation, Mount & Blade style:
    first the region you were born in, then your family background (rules/world.toml [backgrounds])."""
    towns = sorted((s for s in w.settlements.values() if s.kind == "town"), key=lambda s: s.id)
    p = Party(PID, "player", NAME, None, list(towns[0].pos), {}, gold=0.0)
    p.inside = towns[0].id          # hidden until creation is finished
    w.parties[PID] = p
    w.player = {"party": PID, "renown": 0, "wars": [], "kingdom": None, "contract": None, "contract_until": 0,
                "pending": {"type": "create", "step": "origin"}, "chats": {}, "captive_until": 0,
                "origin": None, "background": None, "pedigree": None}


def _creation_menu(w: World, pend: dict) -> dict:
    if pend["step"] == "origin":
        opts = []
        for kid, k in w.kingdoms.items():
            opts.append(_opt("origin", f"{CULTURES[k.culture]['name']}（{k.name}）", hint=BLURBS.get(kid, ""), choice=kid))
        return {"type": "create", "title": "你的出身", "options": opts,
                "text": "周朝崩塌已二十余年。北方诸部攻陷洛阳，周室南渡，六国并立，流民遍野。\n你生在哪里？"
                        "（出身决定你的文化、兵源和起点，也决定故国将军对你的第一印象）"}
    kid = pend["origin"]
    opts = []
    for bid, b in BACKGROUNDS.items():
        if b.get("cultures") and kid not in b["cultures"]:
            continue
        troops = "、".join(f"{TROOPS[_slot(kid, sl)]['name']}×{n}" for sl, n in b["troops"])
        opts.append(_opt("background", f"{b['name']}", hint=f"{b['desc']}（{b['gold']}金；{troops}）", choice=bid))
    opts.append(_opt("back", "重新选择出身"))
    k = w.kingdoms[kid]
    return {"type": "create", "title": "你的家世", "options": opts,
            "text": f"你生于{CULTURES[k.culture]['name']}（{k.name}）。\n你出身于怎样的人家？"}


def _slot(kid: str, slot: str) -> str:
    return f"{kid}_{slot}"


def _finish_creation(w: World, kid: str, bid: str) -> None:
    b = BACKGROUNDS[bid]
    k = w.kingdoms[kid]
    p = party(w)
    rng = w.rng
    forts = [s for s in w.settlements.values() if s.faction == kid and s.kind == "town"]
    if b.get("start") == "capital":
        start = w.settlements[f"{kid}0"]
    elif b.get("start") == "village":
        vill = [s for s in w.settlements.values() if s.faction == kid and s.kind == "village"]
        start = rng.choice(vill or forts)
    else:
        start = rng.choice(forts)
    p.pos = list(start.pos)
    p.inside = None
    p.troops = {}
    for sl, n in b["troops"]:
        T.add(p.troops, _slot(kid, sl), int(n))
    p.gold = float(b["gold"])
    for g, n in b.get("cargo", []):
        g = WORKSHOP.get(k.culture, "cloth") if g == "workshop" else g
        p.cargo[g] = p.cargo.get(g, 0) + int(n)
    w.player.update(renown=float(b.get("renown", 0)), origin=kid, background=bid, pedigree=b.get("pedigree", "low"),
                    pending={"type": "settlement", "id": start.id})
    for h in w.heroes.values():
        if h.kingdom == kid and b.get("relation"):
            h.adjust_rel(PID, int(b["relation"]))
    w.log("player", f"你以{b['name']}的身份，带着{T.healthy(p.troops)}名部众来到{start.name}（{k.name}），"
          f"在这乱世里开始闯荡。", pos=list(start.pos), player=True)


def side(w: World) -> str:
    return w.side_of(party(w))


def vision(w: World) -> float:
    """Sight radius of the player's party (map units). Parties outside it are not shown on the map."""
    p = w.parties.get(PID)
    if p is None:
        return 0.0
    v = B.vision
    cls = T.class_counts(p.troops)
    total = max(1, sum(cls.values()))
    r = v.base + v.cavalry_bonus * cls["cav"] / total + min(v.renown_bonus_max, w.player["renown"] / 10)
    h = w.hour % 24
    if h >= v.night_start or h < v.night_end:
        r *= v.night_factor
    if p.inside:
        r *= v.inside_factor
    return round(r, 1)


def limit(w: World) -> int:
    return B.player.party_limit_base + int(w.player["renown"]) // 4 + 10 * len(w.fiefs_of(PID))


def cargo_cap(p: Party) -> int:
    return B.player.cargo_base + T.healthy(p.troops)


def captive(w: World) -> bool:
    return w.player.get("captive_until", 0) > w.hour


def kingdom_name(w: World, kid) -> str:
    return w.kingdoms[kid].name if kid in w.kingdoms else "?"


def _stop(p: Party) -> None:
    p.target = None
    p.mode = "idle"


def _notice(w: World, title: str, text: str) -> None:
    w.player["pending"] = {"type": "notice", "title": title, "text": text}


# ------------------------------------------------------------- movement
def move(w: World, target: dict) -> dict:
    p = party(w)
    if w.player.get("pending"):
        return {"ok": False, "message": "先处理当前的菜单"}
    if captive(w):
        return {"ok": False, "message": "你还是俘虏"}
    if p.mode == "siege":
        s = w.settlements.get(p.memo.pop("siege", None))
        w.log("player", f"你撤围离开了{s.name if s else '城下'}", player=True)
    if p.mode == "raid":
        p.memo.pop("raid", None)
    if p.inside:
        s = w.settlements[p.inside]
        p.inside = None
        p.pos = list(w.terrain.nearest_passable(s.pos[0], s.pos[1], 2))
    kind = target.get("kind")
    if kind == "point":
        from .terrain import H, W
        x = min(max(float(target["pos"][0]), 1.0), W - 1.0)
        y = min(max(float(target["pos"][1]), 1.0), H - 1.0)
        x, y = w.terrain.nearest_passable(x, y, 4)
        M.set_point(p, x, y)
    elif kind == "place" and target.get("id") in w.settlements:
        s = w.settlements[target["id"]]
        if s.kind == "hideout" and not s.active:
            return {"ok": False, "message": "那里已经没有土匪了"}
        if dist(p.pos, s.pos) <= M.ARRIVE:
            _stop(p)
            w.player["pending"] = {"type": "settlement", "id": s.id}
            return {"ok": True}
        M.set_place(p, s.id)
    elif kind == "party" and target.get("id") in w.parties and target["id"] != PID:
        q = w.parties[target["id"]]
        if q.inside:
            M.set_place(p, q.inside)
        else:
            M.set_party(p, q.id, "chase")
    else:
        return {"ok": False, "message": "无效的目标"}
    p.order = None
    return {"ok": True}


def after_move(w: World) -> None:
    """Called every hour after movement: arrivals, contacts, captivity."""
    p = party(w)
    if p is None:
        return
    if not captive(w) and not (w.player.get("pending") or {}).get("type") == "create":
        _spot(w, p)
    if w.player.get("captive_until") and w.hour >= w.player["captive_until"]:
        _escape(w)
        return
    if w.player.get("pending") or captive(w) or p.inside:
        return
    t = p.target
    if not t:
        return
    if t["kind"] == "place":
        if M.arrived(w, p):
            _stop(p)
            w.player["pending"] = {"type": "settlement", "id": t["id"]}
    elif t["kind"] == "party":
        q = w.parties.get(t["id"])
        if not q or not q.alive:
            _stop(p)
        elif q.inside:
            M.set_place(p, q.inside)
        elif dist(p.pos, q.pos) <= M.CONTACT:
            _stop(p)
            w.player["pending"] = {"type": "encounter", "party": q.id, "initiator": "player"}
    elif M.arrived(w, p):
        _stop(p)


def _spot(w: World, p: Party) -> None:
    """Hideouts are hidden until your scouts come within sight of them (like Warband)."""
    known = w.player.setdefault("known_hideouts", [])
    r = vision(w)
    for s in w.settlements.values():
        if s.kind != "hideout":
            continue
        if not s.active:
            if s.id in known:
                known.remove(s.id)
            continue
        if s.id not in known and dist(p.pos, s.pos) <= r:
            known.append(s.id)
            w.log("player", f"斥候来报：发现一处匪巢——{s.name}", player=True, settlement=s.id, pos=list(s.pos))


def encounter_from_ai(w: World, attacker: Party) -> bool:
    """A hostile AI party caught the player: stop time and let the player choose."""
    if w.player.get("pending") or captive(w):
        return False
    p = party(w)
    _stop(p)
    if p.inside:
        return False
    w.player["pending"] = {"type": "encounter", "party": attacker.id, "initiator": "them"}
    attacker.target = None
    return True


# ------------------------------------------------------------------ menus
def _opt(oid: str, label: str, enabled: bool = True, hint: str = "", **extra) -> dict:
    return {"id": oid, "label": label, "enabled": enabled, "hint": hint, **extra}


def _recruit_cost(tid: str) -> int:
    return B.troops.recruit_cost.t1 if TROOPS[tid]["tier"] <= 1 else B.troops.recruit_cost.t2


def _hostile_fort(w: World, s) -> bool:
    return w.at_war(side(w), s.faction)


def _war_warning(w: World, kid) -> str:
    me = side(w)
    if kid in w.kingdoms and me == PLAYER and kid not in w.player["wars"]:
        return f"这将使你与{kingdom_name(w, kid)}开战"
    return ""


def menu(w: World) -> dict | None:
    pend = w.player.get("pending")
    if not pend:
        return None
    p = party(w)
    kind = pend["type"]
    if kind == "create":
        return _creation_menu(w, pend)
    if kind == "notice":
        return {"type": "notice", "title": pend["title"], "text": pend["text"], "options": [_opt("ok", "继续")]}
    if kind == "settlement":
        return _settlement_menu(w, p, w.settlements[pend["id"]])
    if kind == "encounter":
        q = w.parties.get(pend["party"])
        if q is None or not q.alive:
            return {"type": "notice", "title": "对方已经离开", "text": "", "options": [_opt("ok", "继续")]}
        return _encounter_menu(w, p, q, pend["initiator"])
    if kind == "talk":
        return _talk_menu(w, p, w.heroes[pend["hero"]])
    if kind == "captive":
        h = w.heroes.get(pend["hero"])
        if h is None or h.captive_of != "__player":
            return {"type": "notice", "title": "俘虏已不在你手中", "text": "", "options": [_opt("ok", "继续")]}
        return _captive_menu(w, p, h)
    return None


# ------------------------------------------------------- captive generals
def captives(w: World) -> list:
    return [h for h in w.heroes.values() if h.captive_of == "__player"]


def queue_captive(w: World, hid: str) -> None:
    """A general beaten by your party: decide his fate right after the battle (or later, in a town)."""
    if w.player.get("pending") is None:
        w.player["pending"] = {"type": "captive", "hero": hid}
    else:
        w.player.setdefault("captive_queue", []).append(hid)


def _next_captive(w: World) -> None:
    q = w.player.get("captive_queue") or []
    while q and w.player.get("pending") is None:
        hid = q.pop(0)
        if w.heroes.get(hid) and w.heroes[hid].captive_of == "__player":
            w.player["pending"] = {"type": "captive", "hero": hid}


def _ransom_now(w: World, h) -> float:
    k = w.kingdoms[h.kingdom]
    payer = w.heroes[k.ruler] if k.alive and k.ruler != h.id else h
    full = B.capture.ransom_base + h.renown * B.capture.ransom_per_renown
    return round(min(full * B.capture.ransom_now_share, max(0.0, payer.gold)))


def _captive_menu(w: World, p: Party, h) -> dict:
    from .politics import PEDIGREE_NAMES, pedigree_of, recruit_chance
    k = w.kingdoms[h.kingdom]
    is_ruler = k.alive and k.ruler == h.id
    lines = [f"{h.name} · {k.name}{TITLES.get(k.id, '君主') if is_ruler else '将军'} · {PEDIGREE_NAMES.get(pedigree_of(w, h.id), '')}",
             h.persona,
             f"被你关押第 {h.captive_days} 天；对你的好感 {h.rel(PID):+d}，对其主 {('（本人即君主）' if is_ruler else f'{h.rel(k.ruler):+d}')}"]
    fiefs = w.fiefs_of(h.id)
    if fiefs:
        lines.append("封地：" + "、".join(s.name for s in fiefs))
    lines.append(f"不加处置的话，{B.player.ransom_days}天后其{'国人' if is_ruler else '君主'}会来赎人。")
    opts = []
    me = w.player.get("kingdom")
    tried = h.id in w.player.setdefault("recruit_tried", [])
    if me and not is_ruler and h.kingdom != me:
        c = recruit_chance(w, h, me, by_player=True)
        opts.append(_opt("recruit", f"招降：劝他投效{kingdom_name(w, me)}（约{c:.0%}把握{'，封地会留归旧主' if fiefs else ''}）",
                         not tried, "他已经拒绝过一次了" if tried else ""))
    else:
        why = ("君主不会投降" if is_ruler else "他本就是你国的人" if me and h.kingdom == me
               else "你须先向某国称臣，才能替它招降敌将")
        opts.append(_opt("recruit", "招降", False, why))
    pay = _ransom_now(w, h)
    opts.append(_opt("ransom", f"当场索要赎金（约{pay:.0f}金）", pay > 0, "" if pay > 0 else "对方拿不出钱"))
    opts.append(_opt("release", f"无条件释放（他会记住你的宽厚，声望+{B.capture.release_renown}）"))
    others = [o for o in w.kingdom_heroes(h.kingdom) if o.id != h.id]
    opts.append(_opt("execute", f"斩首（声望{B.capture.execute_renown:+d}，威名+{B.capture.execute_dread}，"
                                f"{k.name}举国与其同族都会恨你）", bool(others), "" if others else "此国再无他人，杀之无益"))
    opts.append(_opt("leave", "暂且关押"))
    return {"type": "captive", "hero": h.id, "title": f"处置俘虏：{h.name}", "text": "\n".join(lines), "options": opts}


def _captive_act(w: World, p: Party, h, action: str) -> dict:
    from . import politics as POL
    k = w.kingdoms[h.kingdom]
    back = (w.player.get("pending") or {}).get("back")
    w.player["pending"] = back
    if action == "recruit":
        me = w.player["kingdom"]
        w.player.setdefault("recruit_tried", []).append(h.id)
        if w.rng.random() < POL.recruit_chance(w, h, me, by_player=True):
            POL.recruit_captive(w, h, me, near=p.pos)
            h.adjust_rel(PID, 20)
            w.log("player", f"{h.name}被你说动，归降了{kingdom_name(w, me)}", player=True, hero=h.id)
            _notice(w, "招降成功", f"{h.name}沉默良久，终于下拜：「愿效犬马之劳。」\n他已投效{kingdom_name(w, me)}，正在附近重整部曲。")
        else:
            h.adjust_rel(PID, -8)
            h.remember(w.day, "拒绝了玩家的招降")
            w.log("player", f"{h.name}拒绝了你的招降", player=True, hero=h.id)
            _notice(w, "招降不成", f"{h.name}冷笑一声：「败军之将，可杀不可辱。」")
        return {"ok": True}
    if action == "ransom":
        pay = _ransom_now(w, h)
        payer = w.heroes[k.ruler] if k.alive and k.ruler != h.id else h
        payer.gold -= pay
        p.gold += pay
        h.adjust_rel(PID, -2)
        w.log("ransom", f"{payer.name}向你付了{pay:.0f}金，赎回了{h.name}", hero=h.id, player=True)
        POL.release_hero(w, h, "被赎回")
        return {"ok": True, "message": f"得到{pay:.0f}金"}
    if action == "release":
        h.adjust_rel(PID, B.capture.release_relation)
        h.remember(w.day, "兵败被玩家所俘，又被无条件放回")
        w.player["renown"] = round(w.player["renown"] + B.capture.release_renown, 1)
        if k.alive:
            w.heroes[k.ruler].adjust_rel(PID, 3)
        w.log("player", f"你释放了{h.name}", player=True, hero=h.id)
        POL.release_hero(w, h, "被玩家释放")
        return {"ok": True}
    if action == "execute":
        if side(w) == PLAYER:
            declare_war(w, h.kingdom)
        w.player["renown"] = max(0.0, round(w.player["renown"] + B.capture.execute_renown, 1))
        w.player["dread"] = w.player.get("dread", 0) + B.capture.execute_dread
        POL.execute_hero(w, h, "player")
        return {"ok": True}
    return {"ok": False, "message": "未知操作"}


def _refugee_menu_lines(w: World, p: Party, q: Party) -> tuple[list, list]:
    R = B.refugee
    n = T.healthy(q.troops)
    room = max(0, limit(w) - T.total(p.troops))
    take = min(n, room)
    grain = -(-take // R.heads_per_grain)
    has = p.cargo.get("grain", 0)
    cost = f"{grain}份粮食" if has >= grain else f"{take * R.gold_per_head}金（你没有足够的粮食）"
    dest = w.settlements.get(q.memo.get("dest"))
    lines = [f"{q.name}：{n}名逃难的村民，扶老携幼，正往{dest.name if dest else '别处'}去。",
             "收编他们可以补充兵员（只是没受过训练的乡勇）；也可以指引他们去你的封地安家，增加那里的繁荣。"]
    can = take > 0 and (has >= grain or p.gold >= take * R.gold_per_head)
    opts = [_opt("absorb", f"收编{take}人当兵（花{cost}）", can,
                 "" if can else ("部队已满" if take <= 0 else "钱粮不够"))]
    fiefs = w.fiefs_of(PID)
    if fiefs:
        f = min(fiefs, key=lambda s: dist(s.pos, q.pos))
        opts.append(_opt("resettle", f"指引他们去你的封地{f.name}安家（繁荣+{n * R.settle_prosperity:.0f}，声望+{R.resettle_renown}）",
                         q.memo.get("dest") != f.id, "他们已经在去那里的路上了"))
    else:
        opts.append(_opt("resettle", "指引他们去你的封地安家", False, "你还没有封地"))
    opts.append(_opt("leave", "离开"))
    return lines, opts


def _settlement_menu(w: World, p: Party, s) -> dict:
    kinds = KIND_NAMES
    opts = []
    lines = []
    m = {"type": "settlement", "id": s.id, "title": s.name, "kind": s.kind}
    if s.kind == "hideout":
        lines.append(f"一处{kinds[s.kind]}，盘踞着约{T.healthy(s.garrison)}名匪寇。地形险要（守方 ×1.15）。")
        opts.append(_opt("attack_hideout", f"进攻匪巢（你的战力约{w.party_power(p):.0f}，匪众约{T.power(s.garrison) * 1.15:.0f}）",
                         T.healthy(p.troops) > 0))
        opts.append(_opt("leave", "离开"))
        m.update(text="\n".join(lines), options=opts)
        return m
    owner = w.heroes.get(s.owner)
    owner_txt = "你" if s.owner == PID else (owner.name if owner else "无")
    lines.append(f"{kinds[s.kind]} · {kingdom_name(w, s.faction)} · 守将：{owner_txt}")
    hostile = _hostile_fort(w, s)
    if s.kind == "village":
        lines.append(f"繁荣 {s.prosperity:.0f} · 民兵 {s.militia:.0f} · 特产 {GOODS.get(s.produce, ('?',))[0]}"
                     + (" · 刚遭劫掠" if s.raided_until > w.hour else ""))
    else:
        lines.append(f"繁荣 {s.prosperity:.0f} · 民心 {s.loyalty:.0f} · 守军 {T.healthy(s.garrison)} · 城墙 {s.walls} 级")
        if s.siege:
            lines.append(f"正被{kingdom_name(w, s.siege['kingdom'])}围攻（攻城器械 {s.siege['progress']:.0%}）")
    if owner:
        lines.append(f"{owner.name}对你的好感：{owner.rel(PID):+d}")
    if hostile:
        lines.append("【这是敌国的地方】")
        if s.kind in ("town", "castle"):
            in_realm = side(w) in w.kingdoms
            opts.append(_opt("besiege", f"围攻{s.name}（守军战力约{(T.power(s.garrison) + s.militia) * (1 + B.siege.wall_bonus_per_level * s.walls):.0f}）",
                             in_realm and T.healthy(p.troops) >= 25,
                             "" if in_realm else "无主之人无法攻城，需先为某国效力"))
        else:
            opts.append(_opt("raid", f"劫掠{s.name}（民兵 {s.militia:.0f}）",
                             s.raided_until <= w.hour and T.healthy(p.troops) > 0))
        opts.append(_opt("leave", "离开"))
        m.update(text="\n".join(lines), options=opts)
        return m
    if s.kind == "village" and side(w) == PLAYER and s.raided_until <= w.hour:
        warn = _war_warning(w, s.faction)
        opts.append(_opt("raid", f"劫掠{s.name}", T.healthy(p.troops) > 0, warn))
    vols = s.volunteers
    cost = sum(_recruit_cost(t) for t in vols)
    room = limit(w) - T.total(p.troops)
    if vols:
        counts: dict[str, int] = {}
        for t in vols:
            counts[TROOPS[t]["name"]] = counts.get(TROOPS[t]["name"], 0) + 1
        desc = "、".join(f"{k}×{v}" for k, v in counts.items())
        opts.append(_opt("recruit", f"招募志愿兵：{desc}（共{cost}金）",
                         room > 0 and p.gold >= _recruit_cost(vols[0]),
                         "部队已满" if room <= 0 else ""))
    pris = sum(p.prisoners.values())
    if pris and s.kind == "town":
        opts.append(_opt("sell_prisoners", f"把{pris}名俘虏卖给赎金掮客"))
    if s.kind == "town":
        m["market"] = {g: {"name": GOODS[g][0], "stock": int(s.market.get(g, 0)), "price": w.price(s, g),
                           "carry": int(p.cargo.get(g, 0))} for g in GOODS}
        m["cargo_cap"] = cargo_cap(p)
        opts.append(_opt("trade", "去市集交易"))
    here = [w.heroes[q.hero] for q in w.parties.values()
            if q.alive and q.inside == s.id and q.hero and not w.hostile(p, q)]
    for h in here[:4]:
        opts.append(_opt("talk", f"拜见{h.name}（{kingdom_name(w, h.kingdom)}，好感{h.rel(PID):+d}）", hero=h.id))
    if s.kind in ("town", "castle"):
        for h in captives(w)[:4]:
            opts.append(_opt("captive", f"提审被你关押的{h.name}（{kingdom_name(w, h.kingdom)}）", hero=h.id))
    opts.append(_opt("rest", "进城休整（按住空格等待，伤员恢复更快）" if s.kind != "village" else "在村里歇脚（按住空格等待）"))
    opts.append(_opt("leave", "离开"))
    m.update(text="\n".join(lines), options=opts)
    return m


def _encounter_menu(w: World, p: Party, q: Party, initiator: str) -> dict:
    if q.kind == "refugee":
        lines, opts = _refugee_menu_lines(w, p, q)
        return {"type": "encounter", "party": q.id, "initiator": initiator, "title": q.name,
                "text": "\n".join(lines), "options": opts}
    hostile = w.hostile(p, q)
    names = {"lord": "将军部曲", "caravan": "商队", "villager": "村民", "bandit": "匪寇", "hunter": "游侠",
             "merc": "义从"}
    who = w.heroes[q.hero].name if q.hero else q.name
    mine, theirs = w.party_power(p), w.party_power(q)
    lines = [f"{who}（{names.get(q.kind, q.kind)}，{kingdom_name(w, q.faction) if q.faction in w.kingdoms else '无主'}）",
             f"对方 {T.healthy(q.troops)} 人，战力约 {theirs:.0f}；你 {T.healthy(p.troops)} 人，战力约 {mine:.0f}"]
    if q.hero:
        h = w.heroes[q.hero]
        lines.append(f"{h.name}对你的好感：{h.rel(PID):+d}")
        if h.last_speech:
            lines.append(f"「{h.last_speech}」")
    opts = []
    if initiator == "them":
        lines.insert(0, "【对方截住了你！】")
        opts.append(_opt("fight", "迎战"))
        their_speed = party_speed(w, q)
        chance = _flee_chance(w, p, q)
        opts.append(_opt("flee", f"设法脱身（约{chance:.0%}把握，速度 你{party_speed(w, p) * 24:.0f} vs 对方{their_speed * 24:.0f}）"))
        if q.kind == "bandit":
            opts.append(_opt("pay", f"破财消灾（交出{p.gold * B.player.pay_off_share:.0f}金）", p.gold > 0))
        opts.append(_opt("surrender", "投降（失去部队和部分钱财）"))
    else:
        if q.hero and not hostile:
            opts.append(_opt("talk", f"与{who}交谈", hero=q.hero))
        if hostile:
            opts.append(_opt("attack", "进攻", T.healthy(p.troops) > 0))
        else:
            allowed = side(w) == PLAYER and q.kind not in ("hunter",) and not (q.kind == "merc" and not q.contract)
            warn = _war_warning(w, q.faction) if allowed else "你所效力的国家与对方并无战事"
            opts.append(_opt("attack", "进攻", allowed and T.healthy(p.troops) > 0, warn))
        if q.hero and hostile:
            opts.append(_opt("talk", f"与{who}交谈", hero=q.hero))
        opts.append(_opt("leave", "离开"))
    return {"type": "encounter", "party": q.id, "initiator": initiator, "title": who, "text": "\n".join(lines),
            "options": opts}


def _talk_menu(w: World, p: Party, h) -> dict:
    k = w.kingdoms[h.kingdom]
    lines = [f"{h.name} · {k.name}{TITLES.get(k.id, '君主') if k.ruler == h.id else '将军'}", h.persona,
             f"对你的好感：{h.rel(PID):+d} · 你的声望：{w.player['renown']:.0f}"]
    opts = []
    if k.ruler == h.id:
        me_k, me_c = w.player.get("kingdom"), w.player.get("contract")
        at_war = h.kingdom in w.player["wars"] and me_k is None and me_c is None
        if me_k is None and me_c is None:
            pay = round(w.party_power(p) * B.player.merc_pay_per_power)
            opts.append(_opt("merc", f"作为义从为{k.name}效力（日薪{pay}金，{B.player.merc_contract_days}天）",
                             bool(k.wars) and not at_war,
                             "该国眼下没有战事" if not k.wars else ("你正与该国交战" if at_war else "")))
        if me_k is None and (me_c in (None, h.kingdom)):
            ok = w.player["renown"] >= B.player.vassal_renown and h.rel(PID) >= B.player.vassal_relation and not at_war
            opts.append(_opt("vassal", f"向{TITLES.get(k.id, '君主')}称臣，拜官受职，成为{k.name}之臣", ok,
                             "" if ok else f"需要声望≥{B.player.vassal_renown}、好感≥{B.player.vassal_relation}"))
        if me_k == h.kingdom or me_c == h.kingdom:
            opts.append(_opt("renounce", "解除契约 / 脱离该国" + ("（会失去封地）" if me_k else "")))
    opts.append(_opt("back", "告辞"))
    chat = w.player["chats"].get(h.id, [])[-12:]
    return {"type": "talk", "hero": h.id, "title": f"与{h.name}交谈", "text": "\n".join(lines),
            "options": opts, "chat": chat}


def _flee_chance(w: World, p: Party, q: Party) -> float:
    ratio = party_speed(w, p) / max(0.1, party_speed(w, q))
    return max(0.1, min(0.9, B.player.flee_base_chance + (ratio - 1) * 1.5))


# ---------------------------------------------------------------- actions
def act(w: World, action: str, data: dict) -> dict:
    from . import economy as E
    from . import warfare as WF
    pend = w.player.get("pending")
    p = party(w)
    if not pend:
        return {"ok": False, "message": "当前没有打开的菜单"}
    m = menu(w)
    opt = next((o for o in (m or {}).get("options", []) if o["id"] == action
                and (o.get("hero") is None or o.get("hero") == data.get("hero"))
                and (o.get("choice") is None or o.get("choice") == data.get("choice"))), None)
    if action not in ("buy", "sell") and (opt is None or not opt["enabled"]):
        return {"ok": False, "message": "现在不能这么做"}
    kind = pend["type"]
    if kind == "create":
        if action == "origin":
            w.player["pending"] = {"type": "create", "step": "background", "origin": data["choice"]}
        elif action == "back":
            w.player["pending"] = {"type": "create", "step": "origin"}
        elif action == "background":
            _finish_creation(w, pend["origin"], data["choice"])
        return {"ok": True}
    if action in ("ok", "leave"):
        w.player["pending"] = pend.get("back") if kind == "captive" else None
        _next_captive(w)
        return {"ok": True}
    if kind == "captive":
        r = _captive_act(w, p, w.heroes[pend["hero"]], action)
        _next_captive(w)
        return r
    if kind == "settlement" and action == "captive":
        w.player["pending"] = {"type": "captive", "hero": data["hero"], "back": pend}
        return {"ok": True}
    if kind == "encounter" and action in ("absorb", "resettle"):
        q = w.parties.get(pend["party"])
        if q is None or not q.alive:
            w.player["pending"] = None
            return {"ok": True}
        R = B.refugee
        if action == "absorb":
            take = min(T.healthy(q.troops), max(0, limit(w) - T.total(p.troops)))
            grain = -(-take // R.heads_per_grain)
            if p.cargo.get("grain", 0) >= grain:
                p.cargo["grain"] -= grain
                paid = f"{grain}份粮食"
            else:
                p.gold -= take * R.gold_per_head
                paid = f"{take * R.gold_per_head}金"
            T.add(p.troops, f"{q.memo.get('culture', 'zhou')}_t1", take)
            T.take_healthy(q.troops, take, w.rng)
            w.log("player", f"你用{paid}收编了{take}名流民", player=True)
            if T.healthy(q.troops) <= 0:
                from .common import destroy_party
                destroy_party(w, q)
            w.player["pending"] = None
            return {"ok": True, "message": f"收编了{take}人"}
        f = min(w.fiefs_of(PID), key=lambda s: dist(s.pos, q.pos))
        q.memo.update(dest=f.id, player_led=True, until=w.hour + 24 * R.days)
        M.set_place(q, f.id)
        w.log("player", f"你指引{q.name}去{f.name}安家", player=True)
        w.player["pending"] = None
        return {"ok": True}

    if kind == "settlement":
        s = w.settlements[pend["id"]]
        if action == "rest":
            p.inside = s.id
            p.mode = "inside"
            w.player["pending"] = None
            return {"ok": True}
        if action == "recruit":
            room = limit(w) - T.total(p.troops)
            keep, n = [], 0
            for tid in s.volunteers:
                c = _recruit_cost(tid)
                if room > 0 and p.gold >= c:
                    T.add(p.troops, tid, 1)
                    p.gold -= c
                    room -= 1
                    n += 1
                else:
                    keep.append(tid)
            s.volunteers = keep
            w.log("player", f"你在{s.name}招募了{n}名志愿兵", player=True)
            return {"ok": True, "message": f"招募了{n}人"}
        if action == "sell_prisoners":
            got = E.sell_prisoners(w, p, s)
            return {"ok": True, "message": f"得到{got:.0f}金"}
        if action in ("buy", "sell"):
            if s.kind != "town" or _hostile_fort(w, s):
                return {"ok": False, "message": "这里不能交易"}
            g = data.get("good")
            n = max(1, min(50, int(data.get("qty", 1))))
            if g not in GOODS:
                return {"ok": False, "message": "未知货物"}
            if action == "buy":
                room = cargo_cap(p) - sum(p.cargo.values())
                got, spent = E.buy(w, s, g, min(n, room), p.gold)
                p.gold -= spent
                if got:
                    p.cargo[g] = p.cargo.get(g, 0) + got
                return {"ok": got > 0, "message": f"买入{got}份{GOODS[g][0]}，花费{spent:.0f}金" if got else "买不到（钱、库存或载货不足）"}
            have = min(n, p.cargo.get(g, 0))
            if not have:
                return {"ok": False, "message": "你没有这种货物"}
            gain = E.sell(w, s, g, have)
            p.cargo[g] -= have
            p.gold += gain
            return {"ok": True, "message": f"卖出{have}份{GOODS[g][0]}，得{gain:.0f}金"}
        if action == "trade":
            return {"ok": True}
        if action == "talk":
            w.player["pending"] = {"type": "talk", "hero": data["hero"], "back": pend}
            return {"ok": True}
        if action == "besiege":
            w.player["pending"] = None
            WF.start_siege(w, p, s)
            return {"ok": True, "message": "围城开始：按住空格等待攻城器械完成，届时会自动强攻"}
        if action == "raid":
            if side(w) == PLAYER:
                declare_war(w, s.faction)
            w.player["pending"] = None
            WF.start_raid(w, p, s)
            return {"ok": True, "message": "劫掠开始：按住空格等待"}
        if action == "attack_hideout":
            w.player["pending"] = None
            WF.assault_hideout(w, p, s)
            return {"ok": True}

    if kind == "encounter":
        q = w.parties.get(pend["party"])
        if q is None or not q.alive:
            w.player["pending"] = None
            return {"ok": True}
        if action == "talk":
            w.player["pending"] = {"type": "talk", "hero": q.hero, "back": pend}
            return {"ok": True}
        if action == "attack":
            if not w.hostile(p, q) and side(w) == PLAYER:
                declare_war(w, q.faction)
            w.player["pending"] = None
            WF.field_battle(w, p, q)
            return {"ok": True}
        if action == "fight":
            w.player["pending"] = None
            WF.field_battle(w, q, p)
            return {"ok": True}
        if action == "flee":
            w.player["pending"] = None
            if w.rng.random() < _flee_chance(w, p, q):
                q.memo["ignore_player_until"] = w.hour + 5
                q.target = None
                w.log("player", f"你摆脱了{w.heroes[q.hero].name if q.hero else q.name}的追击", player=True)
                return {"ok": True, "message": "成功脱身"}
            w.log("player", "你没能甩掉追兵，被迫应战", player=True)
            WF.field_battle(w, q, p)
            return {"ok": True, "message": "没能脱身"}
        if action == "pay":
            amount = round(p.gold * B.player.pay_off_share)
            p.gold -= amount
            q.gold += amount
            q.memo["ignore_player_until"] = w.hour + 48
            q.target = None
            w.player["pending"] = None
            w.log("player", f"你交出{amount}金，土匪放你过去了", player=True)
            return {"ok": True}
        if action == "surrender":
            w.player["pending"] = None
            defeated(w, p, [q], surrendered=True)
            return {"ok": True}

    if kind == "talk":
        h = w.heroes[pend["hero"]]
        back = pend.get("back")
        if action == "back":
            w.player["pending"] = back if back and back["type"] == "settlement" else None
            return {"ok": True}
        if action == "merc":
            pay = round(w.party_power(p) * B.player.merc_pay_per_power)
            w.player["contract"] = h.kingdom
            w.player["contract_until"] = w.day + B.player.merc_contract_days
            w.player["contract_pay"] = pay
            w.log("player", f"你与{kingdom_name(w, h.kingdom)}签下义从契约，日薪{pay}金", player=True)
            return {"ok": True, "message": "合同已签订"}
        if action == "vassal":
            w.player["kingdom"] = h.kingdom
            w.player["contract"] = None
            p.faction = h.kingdom
            for o in w.kingdom_heroes(h.kingdom):
                o.adjust_rel(PID, 5)
            w.log("player", f"你向{h.name}称臣，拜官受职，成为{kingdom_name(w, h.kingdom)}之臣！", player=True)
            return {"ok": True, "message": "你拜官受职了"}
        if action == "renounce":
            kid = h.kingdom
            was_vassal = w.player.get("kingdom") == kid
            w.player["kingdom"] = None
            w.player["contract"] = None
            p.faction = None
            for s in w.fiefs_of(PID):
                s.owner = w.kingdoms[kid].ruler
                for vid in s.villages:
                    w.settlements[vid].owner = s.owner
            h.adjust_rel(PID, -20 if was_vassal else -5)
            w.log("player", f"你脱离了{kingdom_name(w, kid)}", player=True)
            return {"ok": True}
    return {"ok": False, "message": "未知操作"}


def declare_war(w: World, kid) -> None:
    if kid not in w.kingdoms or kid in w.player["wars"]:
        return
    w.player["wars"].append(kid)
    for h in w.kingdom_heroes(kid):
        h.adjust_rel(PID, -10)
    w.log("player_war", f"你与{w.kingdoms[kid].name}开战了！", kingdom=kid, player=True)


# ----------------------------------------------------- battle outcomes
def on_victory(w: World, enemy_losses: int, losers: list[Party]) -> None:
    gain = enemy_losses * B.player.renown_per_victory_kill
    gain += sum(5 for q in losers if q.kind == "lord")
    w.player["renown"] = round(w.player["renown"] + gain, 1)
    for q in losers:
        if q.kind == "bandit":
            # locals are grateful
            for s in w.settlements.values():
                if s.kind in ("town", "castle") and dist(s.pos, q.pos) < 120 and s.owner in w.heroes:
                    w.heroes[s.owner].adjust_rel(PID, 1)


def defeated(w: World, p: Party, winners: list[Party], surrendered: bool = False) -> None:
    lost = T.healthy(p.troops) + T.wounded(p.troops)
    gold = round(p.gold * B.player.defeat_gold_loss)
    p.gold -= gold
    for q in winners:
        q.gold += gold / max(1, len(winners))
    p.troops = {}
    p.prisoners = {}
    p.cargo = {}
    p.target = None
    p.mode = "idle"
    p.inside = "__captive"
    p.memo.pop("siege", None)
    p.memo.pop("raid", None)
    w.player["captive_until"] = w.hour + 24 * B.player.captive_days
    from .politics import release_hero
    for h in captives(w):
        release_hero(w, h, "你兵败被俘，他趁乱获释")
    w.player["captive_queue"] = []
    who = "、".join(w.heroes[q.hero].name if q.hero else q.name for q in winners[:2])
    verb = "向" + who + "投降" if surrendered else "败给了" + who
    w.log("player_defeated", f"你{verb}，失去了{lost}名士兵和{gold}金，沦为俘虏……", player=True, pos=list(winners[0].pos))


def _escape(w: World) -> None:
    p = party(w)
    w.player["captive_until"] = 0
    me = side(w)
    town = nearest_settlement(w, p.pos, lambda s: s.kind == "town" and not w.at_war(me, s.faction))
    town = town or nearest_settlement(w, p.pos, lambda s: s.kind == "town")
    p.inside = None
    p.pos = list(w.terrain.nearest_passable(town.pos[0], town.pos[1], 3))
    w.log("player", f"你趁看守不备逃了出来，来到{town.name}", player=True, pos=list(town.pos))
    _notice(w, "重获自由", f"几天的囚禁之后，你终于逃了出来，现在身在{town.name}附近。去招募些人手，重整旗鼓吧。")


# ------------------------------------------------------------------ daily
def daily(w: World) -> None:
    p = party(w)
    if p is None:
        return
    # fiefs you hold
    for s in w.fiefs_of(PID):
        p.gold += s.tax_today
        p.gold -= T.upkeep(s.garrison) * B.economy.garrison_upkeep_share
        for vid in s.villages:
            v = w.settlements[vid]
            if v.raided_until <= w.hour:
                p.gold += v.prosperity * B.economy.village_tax_per_hearth
    # mercenary pay
    kid = w.player.get("contract")
    if kid:
        k = w.kingdoms.get(kid)
        r = w.heroes.get(k.ruler) if k and k.alive else None
        pay = w.player.get("contract_pay", 0)
        if not r or w.day >= w.player.get("contract_until", 0) or r.gold < pay:
            w.player["contract"] = None
            w.log("player", f"你与{kingdom_name(w, kid)}的义从契约到期了", player=True)
        else:
            r.gold -= pay
            p.gold += pay
    if captive(w):
        return
    # wages
    p.gold -= T.upkeep(p.troops)
    if p.gold < 0:
        p.gold = 0.0
        n = max(1, T.healthy(p.troops) // 20)
        T.take_healthy(p.troops, n, w.rng)
        w.log("player", f"你发不出军饷，{n}名士兵开了小差", player=True)
    # training & automatic upgrades (balanced towards a mixed force)
    counts = T.class_counts(p.troops)
    total = sum(counts.values()) or 1
    for tid, v in list(p.troops.items()):
        p.xp[tid] = p.xp.get(tid, 0) + v[0] * 1.5
    for tid in list(p.troops):
        t = TROOPS[tid]
        if not t["upgrades"] or p.troops[tid][0] <= 0:
            continue
        n = min(p.troops[tid][0], int(p.xp.get(tid, 0) // t["xp"]), int(max(0.0, p.gold - 400) // t["upgrade_cost"]))
        if n <= 0:
            continue
        opts = t["upgrades"]
        weights = [1.0 / (0.3 + counts[TROOPS[o]["cls"]] / total) for o in opts]
        for _ in range(n):
            o = w.rng.choices(opts, weights)[0]
            p.troops[tid][0] -= 1
            T.add(p.troops, o, 1)
        p.xp[tid] -= n * t["xp"]
        p.gold -= n * t["upgrade_cost"]
    T.prune(p.troops)


# ------------------------------------------------------------- dialogue
TALK_SYSTEM = """你在一个以中国南北朝为原型的架空乱世战略游戏里扮演一位将军（或君主），正在和玩家（一支队伍的首领）当面交谈。
世界：周朝崩塌，周室南渡建康；周、燕、赵、凉、蜀、柔六国并立。这是架空世界，不提真实历史人物、民族名或朝代名，古地名可以用。
- 完全以这个角色的身份、性格、门第、处境、记忆、对玩家的好感来回答；用中文，80字以内。
- 语言半文半白：句子短，可用「末将」「足下」「孤」「朕」「尔」等称谓，不用现代口语和网络用语，也不要大段古文。
- 各国口吻：周的高门讲究风度、爱引经据典、看不起寒门与北人；燕人豪爽直接、重勇武誓言；赵人粗粝多疑、崇尚实力；
  凉人客气圆滑、常提商路与佛法；蜀人带乡土气、自尊心强、最恨被称为贼；柔人是草原游牧者，说话简短、看重马与刀。
- 你不会做出游戏规则之外的承诺（不能凭空给钱、给封地、立刻宣战）；涉及正式契约时，告诉玩家去找君主谈或留在嘴上。
- attitude：这番对话让你对玩家的好感变化，-2（被冒犯）到 +2（非常欣赏），大多数情况是 0 或 ±1。
只输出 JSON：{"reply": "……", "attitude": 0}"""


def talk(w: World, router, hero_id: str, text: str) -> dict:
    from .brains.llm_common import describe_hero
    pend = w.player.get("pending")
    if not pend or pend.get("type") != "talk" or pend.get("hero") != hero_id:
        return {"ok": False, "message": "你不在和这位将军交谈"}
    h = w.heroes[hero_id]
    text = (text or "").strip()[:200]
    if not text:
        return {"ok": False, "message": "说点什么吧"}
    history = w.player["chats"].setdefault(hero_id, [])
    reply, attitude = None, 0
    if router is not None and router.uses_llm("dialogue") and hasattr(router.llm, "chat_json"):
        p = party(w)
        me = side(w)
        status = ("无主之人" if me == PLAYER else
                  f"{kingdom_name(w, me)}的{'臣属' if w.player.get('kingdom') else '义从'}")
        bg = BACKGROUNDS.get(w.player.get("background") or "", {}).get("name", "")
        if w.player.get("origin") in w.kingdoms:
            status += f"，出身{CULTURES[w.kingdoms[w.player['origin']].culture]['name']}的{bg}"
        wars = "、".join(kingdom_name(w, k) for k in w.player["wars"]) or "无"
        about = (f"眼前的玩家：{status}，名望{w.player['renown']:.0f}，带着{T.healthy(p.troops)}人"
                 f"（{T.describe_classes(p.troops)}），与之交战的国家：{wars}。你对玩家的好感：{h.rel(PID):+d}。")
        convo = "\n".join(f"{'玩家' if r == 'player' else h.name}：{t}" for r, t in history[-10:])
        user = (f"{describe_hero(w, h)}\n\n{about}\n\n之前的对话：\n{convo or '（刚见面）'}\n\n"
                f"玩家：{text}\n\n请以{h.name}的身份回答。")
        data = router.llm.chat_json(TALK_SYSTEM, user)
        if isinstance(data, dict) and data.get("reply"):
            reply = str(data["reply"])[:200]
            try:
                attitude = max(-2, min(2, int(data.get("attitude", 0))))
            except (TypeError, ValueError):
                attitude = 0
    if reply is None:
        rel = h.rel(PID)
        reply = ("哼，尔与我无话可说。" if rel < -20 else
                 "足下请便，一路保重。" if rel < 10 else "原来是足下，幸会。有事但说无妨。")
    history.append(("player", text))
    history.append(("lord", reply))
    del history[:-24]
    if attitude:
        h.adjust_rel(PID, attitude)
    return {"ok": True, "reply": reply, "attitude": attitude, "relation": h.rel(PID)}


# -------------------------------------------------------------- view
def view(w: World) -> dict:
    p = party(w)
    if p is None:
        return {}
    rel = {h.id: h.rel(PID) for h in w.heroes.values() if h.rel(PID)}
    return {
        "party": PID, "name": NAME, "gold": round(p.gold), "renown": round(w.player["renown"]),
        "wars": list(w.player["wars"]), "kingdom": w.player.get("kingdom"), "contract": w.player.get("contract"),
        "contract_until": w.player.get("contract_until", 0), "contract_pay": w.player.get("contract_pay", 0),
        "side": side(w), "limit": limit(w), "cargo": dict(p.cargo), "cargo_cap": cargo_cap(p),
        "fiefs": [s.id for s in w.fiefs_of(PID)], "relations": rel,
        "origin": w.player.get("origin"), "background": w.player.get("background"),
        "origin_name": (f"{CULTURES[w.kingdoms[w.player['origin']].culture]['name']}（{w.kingdoms[w.player['origin']].name}）"
                        if w.player.get("origin") in w.kingdoms else ""),
        "background_name": BACKGROUNDS.get(w.player.get("background") or "", {}).get("name", ""),
        "pedigree": w.player.get("pedigree"), "creating": (w.player.get("pending") or {}).get("type") == "create",
        "captive": captive(w), "captive_until": w.player.get("captive_until", 0),
        "known_hideouts": list(w.player.get("known_hideouts", [])), "dread": w.player.get("dread", 0),
        "captives": [{"id": h.id, "name": h.name, "kingdom": h.kingdom} for h in captives(w)],
        "vision": vision(w), "night": not (B.vision.night_end <= w.hour % 24 < B.vision.night_start),
        "menu": menu(w), "moving": bool(p.target) and not p.inside,
        "busy": p.mode in ("siege", "raid"), "mode": p.mode,
        "classes": {CLASS_NAMES[k]: v for k, v in T.class_counts(p.troops).items()},
    }

