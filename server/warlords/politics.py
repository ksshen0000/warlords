"""Internal politics & diplomacy: council decisions (war, peace, fiefs) with votes
and a ruler's final say, armies, ransoms, defections, mercenary contracts,
tributes and kingdom collapse."""
from __future__ import annotations

from . import movement as M
from . import troops as T
from .common import destroy_party, dist, nearest_settlement
from .data import CAPTIVE_RECRUIT, KIND_NAMES, PEDIGREE, PEDIGREE_NAMES, PEDIGREE_WEIGHT, TOWN_MIN_PEDIGREE
from .model import BANDIT, DEAD, Decision, Hero, World
from .options import Option
from .rules import B


# ------------------------------------------------------------ helpers
def pedigree_of(w: World, hid: str) -> str:
    if hid == "player":
        return w.player.get("pedigree") or "low"
    return PEDIGREE.get(hid, "mid")


def pedigree_rank(w: World, hid: str) -> float:
    return float(B.pedigree.rank.get(pedigree_of(w, hid), 2))


def town_allowed(w: World, kid: str, hid: str) -> bool:
    """周: a lowborn general, however brave, is not given a city (only frontier fortresses)."""
    need = TOWN_MIN_PEDIGREE.get(kid) or ""
    if not need or hid == w.kingdoms[kid].ruler:
        return True
    return pedigree_rank(w, hid) >= float(B.pedigree.rank.get(need, 0))


def ruler(w: World, kid: str) -> Hero:
    return w.heroes[w.kingdoms[kid].ruler]


def open_decision_exists(w: World, kid: str, kind: str, subject: str) -> bool:
    return any(not d.resolved and d.kingdom == kid and d.kind == kind and d.subject == subject
               for d in w.decisions.values())


def vote_weight(h: Hero) -> float:
    return 1.0 + h.influence / 100


# ------------------------------------------------------- proposals
def proposal_options(w: World, h: Hero) -> list[Option]:
    k = w.kingdoms[h.kingdom]
    opts = [Option("none", None, "暂不提议")]
    if h.captive_of:
        return opts
    my = w.kingdom_strength(k.id)
    for oid, o in w.kingdoms.items():
        if oid == k.id or not o.alive:
            continue
        their = w.kingdom_strength(oid)
        if oid in k.wars:
            war = k.wars[oid]
            days = w.day - war["since"]
            if days >= B.politics.min_war_days and h.influence >= B.politics.peace_proposal_cost \
                    and not open_decision_exists(w, k.id, "peace", oid):
                opts.append(Option("propose_peace", oid,
                                   f"提议与{o.name}议和（已交战{days}天，战争分数{war['score']:+.0f}，"
                                   f"伤亡 我{war['losses'][0]}/敌{war['losses'][1]}，实力 {my:.0f} vs {their:.0f}）",
                                   {"days": days, "score": war["score"], "ratio": my / max(1, their)}))
        elif k.truces.get(oid, 0) <= w.day and h.influence >= B.politics.war_proposal_cost \
                and not open_decision_exists(w, k.id, "war", oid):
            border = _border_fiefs(w, k.id, oid)
            opts.append(Option("propose_war", oid,
                               f"提议向{o.name}宣战（实力 {my:.0f} vs {their:.0f}，接壤据点{border}，"
                               f"本国现有战争{len(k.wars)}场，你对其君主好感{h.rel(o.ruler):+d}）",
                               {"ratio": my / max(1, their), "border": border, "wars": len(k.wars),
                                "rel": h.rel(o.ruler), "share": fief_share(w, oid)}))
    return opts


def fief_share(w: World, kid: str) -> float:
    total = sum(1 for s in w.settlements.values() if s.kind in ("town", "castle"))
    return len(w.kingdom_settlements(kid, ("town", "castle"))) / max(1, total)


def hegemon(w: World) -> str | None:
    """The kingdom holding more than the doctrine's share of all fiefs, if any."""
    best = max((k for k in w.kingdoms.values() if k.alive), key=lambda k: fief_share(w, k.id), default=None)
    return best.id if best and fief_share(w, best.id) > B.ai.hegemon_share else None


def _border_fiefs(w: World, a: str, b: str) -> int:
    mine = w.kingdom_settlements(a, ("town", "castle"))
    theirs = w.kingdom_settlements(b, ("town", "castle"))
    return sum(1 for s in theirs if any(dist(s.pos, m.pos) < 260 for m in mine))


def apply_proposal(w: World, h: Hero, opt: Option, reason: str = "") -> Decision | None:
    if opt.type == "none":
        return None
    kind = "war" if opt.type == "propose_war" else "peace"
    cost = B.politics.war_proposal_cost if kind == "war" else B.politics.peace_proposal_cost
    if h.influence < cost:
        return None
    h.influence -= cost
    other = w.kingdoms[opt.target].name
    label_yes = f"向{other}宣战" if kind == "war" else f"与{other}议和"
    d = Decision(w.new_id("dc"), h.kingdom, kind, opt.target, h.id, w.hour, w.hour + 24,
                 [{"id": "yes", "label": f"支持：{label_yes}"}, {"id": "no", "label": "反对"}])
    d.note = reason
    w.decisions[d.id] = d
    w.log("decision_opened", f"{h.name}在{w.kingdoms[h.kingdom].name}朝议上提议{label_yes}" +
          (f"——「{reason}」" if reason else ""), decision=d.id, kingdom=h.kingdom, hero=h.id)
    return d


def open_fief_decision(w: World, s, contributors: list[str]) -> None:
    kid = s.faction
    cands: list[str] = []
    for hid in contributors:
        if hid == "player":
            cands.append(hid)
        elif hid and hid not in cands and w.heroes[hid].kingdom == kid:
            cands.append(hid)
    pw = PEDIGREE_WEIGHT.get(kid, 0.5)
    landless = sorted((h for h in w.kingdom_heroes(kid) if h.id not in cands and h.captive_of != DEAD),
                      key=lambda h: (len(w.fiefs_of(h.id)), -(h.renown + pw * 30 * pedigree_rank(w, h.id))))
    for h in landless[:2]:
        cands.append(h.id)
    r = w.kingdoms[kid].ruler
    if r not in cands:
        cands.append(r)
    if s.kind == "town":
        barred = [hid for hid in cands if not town_allowed(w, kid, hid)]
        cands = [hid for hid in cands if hid not in barred]
        if "player" in barred:
            w.log("player", f"{w.kingdoms[kid].name}朝议议{s.name}归属：你出身{PEDIGREE_NAMES[pedigree_of(w, 'player')]}，"
                            f"门第不够，未能列入候选（周制：城只封给次门以上，寒门只能守关塞）", player=True)
        for hid in barred:
            if hid != "player":
                w.heroes[hid].remember(w.day, f"攻下{s.name}有功，却因门第寒微不得受封")
                w.heroes[hid].adjust_rel(r, -3)
    opts = []
    for hid in cands[:5]:
        tag = "，攻城功臣" if hid in contributors else ""
        ped = PEDIGREE_NAMES.get(pedigree_of(w, hid), "")
        if hid == "player":
            opts.append({"id": hid, "label": f"封给玩家（新晋封臣，{ped}，现有封地{len(w.fiefs_of(hid))}处，声望"
                                             f"{w.player.get('renown', 0):.0f}{tag}）"})
            continue
        h = w.heroes[hid]
        opts.append({"id": hid, "label": f"封给{h.name}（{ped}，现有封地{len(w.fiefs_of(hid))}处，声望{h.renown}{tag}）"})
    d = Decision(w.new_id("dc"), kid, "fief", s.id, None, w.hour, w.hour + 24, opts)
    w.decisions[d.id] = d
    w.log("decision_opened", f"{w.kingdoms[kid].name}朝议商议{s.name}的归属", decision=d.id, kingdom=kid)


def decision_context(w: World, d: Decision) -> str:
    k = w.kingdoms[d.kingdom]
    if d.kind == "fief":
        s = w.settlements[d.subject]
        return f"{k.name}朝议正在决定新攻下的{KIND_NAMES[s.kind]}「{s.name}」封给谁。"
    other = w.kingdoms[d.subject].name
    who = w.heroes[d.proposer].name if d.proposer else "有人"
    what = f"向{other}宣战" if d.kind == "war" else f"与{other}议和"
    extra = f"提案理由：「{d.note}」" if d.note else ""
    return f"{who}在{k.name}朝议上提议{what}。{extra}"


def tally(d: Decision) -> dict[str, float]:
    t: dict[str, float] = {o["id"]: 0.0 for o in d.options}
    for v in d.votes.values():
        t[v["option"]] = t.get(v["option"], 0.0) + v["weight"]
    return t


def resolve(w: World, d: Decision, choice: str, reason: str = "") -> None:
    k = w.kingdoms[d.kingdom]
    r = w.heroes[k.ruler]
    t = tally(d)
    majority = max(t, key=t.get) if t else choice
    d.result = choice
    d.resolved = True
    label = next((o["label"] for o in d.options if o["id"] == choice), choice)
    tally_txt = "，".join(f"{o['label'].split('（')[0]} {t.get(o['id'], 0):.1f}" for o in d.options)
    overruled = choice != majority and t.get(majority, 0) > t.get(choice, 0)
    if overruled:
        r.influence = max(0.0, r.influence - B.politics.overrule_influence_cost)
        for hid, v in d.votes.items():
            if v["option"] == majority:
                w.heroes[hid].adjust_rel(r.id, -4)
                w.heroes[hid].remember(w.day, f"{r.name}无视朝议多数意见")
    w.log("decision_resolved",
          f"{k.name}朝议表决（{tally_txt}）——{r.name}裁决：{label}" + ("【违背多数】" if overruled else "") +
          (f"——「{reason}」" if reason else ""),
          decision=d.id, kingdom=k.id, result=choice, overruled=overruled)
    if d.kind == "war" and choice == "yes":
        declare_war(w, k.id, d.subject)
    elif d.kind == "fief":
        grant_fief(w, d, choice)


def grant_fief(w: World, d: Decision, hid: str) -> None:
    s = w.settlements[d.subject]
    if s.faction != d.kingdom:
        return
    s.owner = hid
    for vid in s.villages:
        w.settlements[vid].owner = hid
    r = w.kingdoms[d.kingdom].ruler
    if hid == "player":
        w.log("fief_granted", f"朝议决定把{s.name}封给你！", settlement=s.id, hero=hid, kingdom=d.kingdom, player=True)
        return
    h = w.heroes[hid]
    h.adjust_rel(r, 8)
    h.influence += 5
    h.remember(w.day, f"获封{s.name}")
    for o in d.options:
        if o["id"] != hid:
            loser = w.heroes[o["id"]]
            loser.adjust_rel(r, -5)
            if d.votes.get(loser.id, {}).get("option") == loser.id:
                loser.adjust_rel(hid, -4)
                loser.remember(w.day, f"争夺{s.name}失败，封地给了{h.name}")
    if hid == r and len(w.fiefs_of(r)) > 2:
        for o in w.kingdom_heroes(d.kingdom):
            if o.id != r:
                o.adjust_rel(r, -2)
    w.log("fief_granted", f"{s.name}封给了{h.name}", settlement=s.id, hero=hid, kingdom=d.kingdom)


# ------------------------------------------------------ war & peace
def declare_war(w: World, a: str, b: str) -> None:
    ka, kb = w.kingdoms[a], w.kingdoms[b]
    ka.wars[b] = {"since": w.day, "score": 0.0, "losses": [0, 0]}
    kb.wars[a] = {"since": w.day, "score": 0.0, "losses": [0, 0]}
    ka.last_offensive = kb.last_offensive = w.day
    ruler(w, b).adjust_rel(ka.ruler, -20)
    for h in w.kingdom_heroes(b):
        h.remember(w.day, f"{ka.name}向我国宣战")
    w.log("war", f"{ka.name}向{kb.name}宣战！", a=a, b=b)


def peace_offer_options(w: World, from_kid: str, to_kid: str) -> tuple[list[Option], dict]:
    ka, kb = w.kingdoms[from_kid], w.kingdoms[to_kid]
    score = kb.wars[from_kid]["score"]          # from the receiver's point of view
    tribute = 0
    if abs(score) > 30:
        tribute = int(min(B.politics.tribute_max, abs(score) / B.politics.tribute_score_divisor))
    terms = ""
    if tribute and score > 0:
        terms = f"，{ka.name}每日向你方支付岁贡{tribute}金，为期{B.politics.tribute_days}天"
    elif tribute:
        terms = f"，你方每日向{ka.name}支付岁贡{tribute}金，为期{B.politics.tribute_days}天"
    opts = [Option("accept", from_kid, f"接受和约{terms}"), Option("reject", from_kid, "拒绝，继续作战")]
    return opts, {"score": score, "tribute": tribute}


def make_peace(w: World, a: str, b: str, tribute: int, payer: str | None) -> None:
    ka, kb = w.kingdoms[a], w.kingdoms[b]
    ka.wars.pop(b, None)
    kb.wars.pop(a, None)
    ka.truces[b] = kb.truces[a] = w.day + B.politics.truce_days
    if tribute and payer:
        payee = b if payer == a else a
        w.kingdoms[payer].tributes[payee] = {"amount": tribute, "until": w.day + B.politics.tribute_days}
    # prisoner exchange
    for h in w.heroes.values():
        if (h.kingdom == a and h.captive_of == b) or (h.kingdom == b and h.captive_of == a):
            release_hero(w, h, "和约释放")
    for s in w.settlements.values():
        if s.siege and {s.faction, s.siege["kingdom"]} == {a, b}:
            s.siege = None
    terms = ""
    if tribute and payer:
        terms = f"，{w.kingdoms[payer].name}每日支付岁贡{tribute}金"
    w.log("peace", f"{ka.name}与{kb.name}签订和约{terms}", a=a, b=b)


# ------------------------------------------------------------ armies
def army_candidates(w: World, leader: Hero) -> list[Hero]:
    lp = w.hero_party(leader.id)
    if not lp:
        return []
    out = []
    for h in w.kingdom_heroes(leader.kingdom, free_only=True):
        p = w.hero_party(h.id)
        if h.id == leader.id or not p or p.army or p.mode in ("siege", "raid"):
            continue
        if dist(p.pos, lp.pos) < 320 and T.healthy(p.troops) >= 20:
            out.append(h)
    out.sort(key=lambda h: dist(w.hero_party(h.id).pos, lp.pos))
    return out[:4]


def gather_army(w: World, leader: Hero) -> str | None:
    members = army_candidates(w, leader)
    cost = B.politics.army_base_cost + B.politics.army_member_cost * len(members)
    if not members or leader.influence < cost:
        return None
    leader.influence -= cost
    from .model import Army
    aid = w.new_id("ar")
    w.armies[aid] = Army(aid, leader.kingdom, leader.id, [h.id for h in members], 100.0, w.hour)
    lp = w.hero_party(leader.id)
    lp.army = aid
    for h in members:
        p = w.hero_party(h.id)
        p.army = aid
        p.order = {"type": "follow", "target": leader.id, "age": 0, "reason": "响应召集"}
        M.set_party(p, lp.id, "follow")
        h.remember(w.day, f"应召加入{leader.name}的军团")
    w.log("army_formed", f"{leader.name}召集军团：{'、'.join(h.name for h in members)}应召",
          army=aid, kingdom=leader.kingdom, hero=leader.id)
    return aid


# ------------------------------------------------------- captives
def release_hero(w: World, h: Hero, why: str, near=None) -> None:
    from .scenario import culture_army, new_lord_party
    at = w.settlements.get(h.captive_at) if h.captive_at else None
    h.captive_of = None
    h.captive_at = None
    h.captive_days = 0
    if near is None:
        near = at.pos if at else [600, 400]
    home = nearest_settlement(w, near,
                              lambda s: s.faction == h.kingdom and s.kind in ("town", "castle"))
    if home is None:
        home = nearest_settlement(w, near,
                                  lambda s: s.kind == "town" and not w.at_war(h.kingdom, s.faction))
    if home is None:
        return
    p = new_lord_party(w, h, home, 0)
    p.troops = culture_army(h.culture, 12, w.rng, 0.3)
    w.log("release", f"{h.name}获释（{why}），回到{home.name}", hero=h.id)


def recruit_chance(w: World, h: Hero, captor_kid: str, by_player: bool = False) -> float:
    """How likely a captive general is to swear himself to his captor's kingdom."""
    k = w.kingdoms.get(h.kingdom)
    if k is None or (k.alive and k.ruler == h.id) or captor_kid == h.kingdom or captor_kid not in w.kingdoms:
        return 0.0
    c = B.capture.recruit_base - 0.08 * h.traits.get("honor", 0)
    if k.alive:
        c += max(0, -h.rel(k.ruler)) / 200          # a grudge against his own lord
    else:
        c += 0.25                                   # nothing left to be loyal to
    c += h.rel("player" if by_player else w.kingdoms[captor_kid].ruler) / 200
    c += CAPTIVE_RECRUIT.get(captor_kid, 0.0)
    if w.fiefs_of(h.id):
        c -= B.capture.recruit_fief_penalty
    if by_player:
        c += min(B.capture.recruit_dread_max, w.player.get("dread", 0) * B.capture.recruit_dread)
    return max(0.02, min(0.85, c))


def recruit_captive(w: World, h: Hero, kid: str, near=None) -> None:
    """The captive swears himself to `kid`. His fiefs stay behind with his old lord."""
    old = w.kingdoms[h.kingdom]
    for s in w.fiefs_of(h.id):
        s.owner = old.ruler
        for vid in s.villages:
            w.settlements[vid].owner = old.ruler
    if old.alive:
        defect(w, h, kid)
    else:
        h.kingdom = kid
        h.adjust_rel(w.kingdoms[kid].ruler, 15)
    h.remember(w.day, f"兵败被俘，降了{w.kingdoms[kid].name}")
    w.log("recruit_captive", f"被俘的{h.name}归降了{w.kingdoms[kid].name}", hero=h.id, kingdom=kid)
    release_hero(w, h, "归降", near=near)


def succession(w: World, kid: str, why: str) -> Hero | None:
    """Pick a new ruler (the most renowned free general of the realm)."""
    k = w.kingdoms[kid]
    pool = w.kingdom_heroes(kid, free_only=True) or w.kingdom_heroes(kid)
    pool = [h for h in pool if h.id != k.ruler]
    if not pool:
        return None
    # the royal house comes first everywhere; beyond that, renown and (where it counts) pedigree
    new = max(pool, key=lambda h: h.renown + h.influence / 4 + (200 if pedigree_of(w, h.id) == "royal" else 0)
              + 20 * pedigree_rank(w, h.id) * PEDIGREE_WEIGHT.get(kid, 0.5))
    k.ruler = new.id
    for o in w.kingdom_heroes(kid):
        if o.id != new.id:
            o.adjust_rel(new.id, w.rng.randint(-6, 4))
    new.remember(w.day, f"{why}，被拥立为{k.name}之主")
    w.log("succession", f"{why}，{new.name}被拥立为{k.name}之主", hero=new.id, kingdom=kid)
    return new


def execute_hero(w: World, h: Hero, by: str = "player") -> None:
    k = w.kingdoms[h.kingdom]
    was_ruler = k.ruler == h.id
    h.captive_of = DEAD
    h.captive_at = None
    h.party = None
    for c in h.caravans:
        if c in w.parties:
            w.parties[c].owner = None
    heir = succession(w, k.id, f"{h.name}被斩") if was_ruler else None
    lord = heir.id if heir else k.ruler
    for s in w.fiefs_of(h.id):
        s.owner = lord
        for vid in s.villages:
            w.settlements[vid].owner = lord
    clan = h.name[:2] if h.name[:2] in ("拓延", "赤云", "屈赫", "郁久", "乞伏") else h.name[:1]
    for o in w.heroes.values():
        if o.id == h.id or o.captive_of == DEAD:
            continue
        if o.kingdom == h.kingdom:
            o.adjust_rel(by, B.capture.execute_relation)
            o.remember(w.day, f"{h.name}被{'玩家' if by == 'player' else by}斩首")
        if o.name.startswith(clan):
            o.adjust_rel(by, B.capture.execute_family)
            o.remember(w.day, f"同族{h.name}被{'玩家' if by == 'player' else by}所杀，此仇必报")
    w.log("execution", f"{h.name}被斩首" + ("，" + k.name + "国中震动" if was_ruler else ""), hero=h.id,
          kingdom=k.id, player=by == "player")


def respawn_heroes(w: World) -> None:
    from .scenario import culture_army, new_lord_party
    for h in w.heroes.values():
        if h.captive_of or h.party or not w.kingdoms[h.kingdom].alive:
            continue
        home = nearest_settlement(w, [600, 400], lambda s: s.faction == h.kingdom and s.kind in ("town", "castle")
                                  and s.owner == h.id) or \
            nearest_settlement(w, [600, 400], lambda s: s.faction == h.kingdom and s.kind in ("town", "castle"))
        if home is None:
            continue
        p = new_lord_party(w, h, home, 0)
        p.troops = culture_army(h.culture, 15, w.rng, 0.3)
        w.log("release", f"{h.name}在{home.name}重整旗鼓", hero=h.id)


# ---------------------------------------------------------- daily
def daily(w: World) -> None:
    rng = w.rng
    day = w.day
    for k in w.kingdoms.values():
        if not k.alive:
            continue
        for kid in [x for x, d in k.truces.items() if d <= day]:
            del k.truces[kid]
        for payee, t in list(k.tributes.items()):
            if t["until"] < day or not w.kingdoms[payee].alive:
                del k.tributes[payee]
                continue
            r, pr = ruler(w, k.id), ruler(w, payee)
            pay = min(t["amount"], max(0.0, r.gold))
            r.gold -= pay
            pr.gold += pay
    for h in w.heroes.values():
        if h.captive_of:
            continue
        fiefs = w.fiefs_of(h.id)
        h.influence = min(500.0, h.influence + 0.3 + 0.4 * len(fiefs))
        k = w.kingdoms[h.kingdom]
        if k.ruler == h.id:
            h.influence = min(800.0, h.influence + 1.5)
            continue
        if not fiefs and rng.random() < 0.18 + 0.06 * max(0, h.traits["greed"]):
            h.adjust_rel(k.ruler, -1)
        elif fiefs and h.traits["honor"] > 0 and rng.random() < 0.1:
            h.adjust_rel(k.ruler, 1)

    # armies
    for aid, a in list(w.armies.items()):
        leader = w.heroes[a.leader]
        a.members = [m for m in a.members if w.hero_party(m) and w.hero_party(m).army == aid]
        a.cohesion -= B.politics.army_cohesion_decay + B.politics.army_cohesion_per_member * len(a.members)
        leader.influence -= 0.4 * len(a.members)
        if a.cohesion <= 0 or not a.members or leader.influence < 0 or not w.hero_party(a.leader):
            from .warfare import disband_army
            leader.influence = max(0.0, leader.influence)
            disband_army(w, aid, "军心涣散" if a.cohesion <= 0 else "")

    # captives: escape / ransom
    for h in list(w.heroes.values()):
        if not h.captive_of or h.captive_of == DEAD:
            continue
        h.captive_days += 1
        if h.captive_of == BANDIT:
            if h.captive_days >= rng.randint(3, 7):
                h.gold *= 0.8
                release_hero(w, h, "向土匪交了赎金")
            continue
        if h.captive_of == "__player":
            if h.captive_days >= B.player.ransom_days:
                payer = ruler(w, h.kingdom) if w.kingdoms[h.kingdom].alive else h
                ransom = B.capture.ransom_base + h.renown * B.capture.ransom_per_renown
                ransom = min(ransom, max(0.0, payer.gold))
                payer.gold -= ransom
                if "player" in w.parties:
                    w.parties["player"].gold += ransom
                h.adjust_rel("player", -5)
                w.log("ransom", f"{payer.name}向你支付了{ransom:.0f}金，赎回了{h.name}", hero=h.id, player=True)
                release_hero(w, h, "被赎回")
            continue
        if rng.random() < B.capture.escape_chance:
            release_hero(w, h, "越狱逃脱")
            continue
        captor = h.captive_of
        if captor in w.kingdoms and w.kingdoms[captor].alive and rng.random() < B.capture.ai_recruit_daily \
                and rng.random() < recruit_chance(w, h, captor):
            recruit_captive(w, h, captor)
            continue
        if w.kingdoms[h.kingdom].alive and h.kingdom != h.captive_of:
            payer = ruler(w, h.kingdom)
            ransom = B.capture.ransom_base + h.renown * B.capture.ransom_per_renown
            if payer.id != h.id and payer.captive_of is None and payer.gold > ransom * 2.5 \
                    and rng.random() < B.capture.ransom_chance:
                payer.gold -= ransom
                ruler(w, h.captive_of).gold += ransom
                h.adjust_rel(payer.id, 6)
                w.log("ransom", f"{payer.name}支付{ransom}金赎回了{h.name}", hero=h.id, payer=payer.id)
                release_hero(w, h, "被赎回")
    respawn_heroes(w)

    # mercenaries
    for p in list(w.parties.values()):
        if not p.alive or p.kind != "merc":
            continue
        if p.contract:
            k = w.kingdoms.get(p.contract)
            fee = T.upkeep(p.troops) * 1.3
            r = ruler(w, p.contract) if k and k.alive else None
            if not k or not k.alive or not k.wars or r is None or r.gold < fee:
                why = "战事已平" if k and not k.wars else "雇主付不起佣金"
                if k and p.id in k.mercenaries:
                    k.mercenaries.remove(p.id)
                w.log("merc_left", f"{p.name}与{k.name if k else '雇主'}的合约终止（{why}）", party=p.id)
                p.contract = None
                p.faction = None
                p.order = None
                M.stop(p)
            else:
                r.gold -= fee
                p.gold += fee
        else:
            for k in sorted(w.kingdoms.values(), key=lambda k: -ruler(w, k.id).gold if k.alive else 0):
                r = ruler(w, k.id) if k.alive else None
                if r and k.wars and not k.mercenaries and r.gold > 4500 and rng.random() < 0.25:
                    p.contract = k.id
                    p.faction = k.id
                    k.mercenaries.append(p.id)
                    w.log("merc_hired", f"{k.name}雇佣了{p.name}（{T.healthy(p.troops)}人）", party=p.id, kingdom=k.id)
                    break

    _loyalty(w)
    if day % 10 == 0:
        _defections(w)
    _collapse(w)


def _loyalty(w: World) -> None:
    L = B.loyalty
    rng = w.rng
    alive = [k for k in w.kingdoms.values() if k.alive]
    forts = [s for s in w.settlements.values() if s.kind in ("town", "castle")]
    fair = len(forts) / max(1, len(alive))
    held = {k.id: len(w.kingdom_settlements(k.id, ("town", "castle"))) for k in alive}
    for s in forts:
        k = w.kingdoms.get(s.faction)
        if not k or not k.alive:
            continue
        foreign = k.culture != s.culture
        drift = L.same_culture_drift
        if foreign:
            drift = L.foreign_culture_drift - L.overextension_per_fief * max(0.0, held[k.id] - fair)
        if s.food <= 0:
            drift += L.starvation_drift
        drift += L.garrison_calm_per_100 * T.healthy(s.garrison) / 100
        s.loyalty = max(0.0, min(100.0, s.loyalty + drift))
        if foreign and not s.siege and s.loyalty < L.rebellion_threshold:
            chance = L.rebellion_chance * (1 + (L.rebellion_threshold - s.loyalty) / L.rebellion_threshold)
            if rng.random() < chance:
                _rebel(w, s)


def _rebel(w: World, s) -> None:
    from .scenario import culture_army
    home = next((k for k in w.kingdoms.values() if k.alive and k.culture == s.culture), None)
    old = w.kingdoms[s.faction]
    rebels = culture_army(s.culture, 20 + int(s.prosperity / 3), w.rng, 0.3)
    if home is None or T.power(rebels) < T.power(s.garrison) * 0.8:
        lost = T.take_healthy(s.garrison, max(1, T.healthy(s.garrison) // 6), w.rng)
        s.loyalty = min(100.0, s.loyalty + 10)
        w.log("unrest", f"{s.name}爆发民变，被{old.name}守军镇压（守军损失{T.healthy(lost)}人）", settlement=s.id)
        return
    old_owner = w.heroes.get(s.owner)
    s.faction, s.owner = home.id, home.ruler
    s.garrison = rebels
    s.loyalty = 60.0
    s.siege = None
    for vid in s.villages:
        w.settlements[vid].faction, w.settlements[vid].owner = home.id, home.ruler
    for p in w.parties.values():
        if p.alive and p.inside == s.id and w.side_of(p) == old.id:
            p.inside = None
            p.pos = list(w.terrain.nearest_passable(s.pos[0], s.pos[1], 2))
    if old_owner:
        old_owner.remember(w.day, f"{s.name}的百姓起义，投向了{home.name}")
    w.log("rebellion", f"{s.name}民心尽失，百姓起义推翻{old.name}的统治，重归{home.name}！",
          settlement=s.id, old=old.id, new=home.id, pos=list(s.pos))
    open_fief_decision(w, s, [])


def _defections(w: World) -> None:
    rng = w.rng
    for h in list(w.heroes.values()):
        k = w.kingdoms[h.kingdom]
        if h.captive_of or k.ruler == h.id:
            continue
        mine = w.kingdom_strength(k.id) or 1
        landless_realm = not w.kingdom_settlements(k.id, ("town", "castle"))
        best = None
        for oid, o in w.kingdoms.items():
            if oid == k.id or not o.alive or not w.kingdom_settlements(oid, ("town", "castle")):
                continue
            score = (h.rel(o.ruler) - h.rel(k.ruler) - 10 * h.traits["honor"]
                     + (25 if not w.fiefs_of(h.id) else 0) + (40 if landless_realm else 0)
                     + 15 * (w.kingdom_strength(oid) / mine - 1))
            if best is None or score > best[0]:
                best = (score, oid)
        if best and best[0] > B.politics.defection_threshold and rng.random() < B.politics.defection_chance:
            defect(w, h, best[1])


def defect(w: World, h: Hero, new_kid: str) -> None:
    old = w.kingdoms[h.kingdom]
    new = w.kingdoms[new_kid]
    fiefs = w.fiefs_of(h.id)
    ruler(w, old.id).adjust_rel(h.id, -40)
    for o in w.kingdom_heroes(old.id):
        if o.id != h.id:
            o.adjust_rel(h.id, -20)
            o.remember(w.day, f"{h.name}背叛投敌")
    for a in list(w.armies.values()):
        if h.id in a.members:
            a.members.remove(h.id)
        if a.leader == h.id:
            from .warfare import disband_army
            disband_army(w, a.id, "统帅叛逃")
    h.kingdom = new_kid
    h.adjust_rel(new.ruler, 15)
    for o in w.kingdom_heroes(new_kid):
        if o.id != h.id:
            h.relations.setdefault(o.id, 0)
    p = w.hero_party(h.id)
    if p:
        p.faction = new_kid
        p.order = None
        p.army = None
        M.stop(p)
    for s in fiefs:
        s.faction = new_kid
        s.siege = None
        for vid in s.villages:
            w.settlements[vid].faction = new_kid
    for c in h.caravans:
        if c in w.parties:
            w.parties[c].faction = new_kid
    h.remember(w.day, f"离开{old.name}，投奔{new.name}")
    taken = f"，并带走了{'、'.join(s.name for s in fiefs)}" if fiefs else ""
    w.log("defection", f"{h.name}背弃{old.name}，投奔{new.name}{taken}！", hero=h.id, old=old.id, new=new_kid)


def _collapse(w: World) -> None:
    for k in w.kingdoms.values():
        if not k.alive or w.kingdom_settlements(k.id, ("town", "castle")):
            continue
        k.alive = False
        for o in w.kingdoms.values():
            o.wars.pop(k.id, None)
            o.truces.pop(k.id, None)
            o.tributes.pop(k.id, None)
        k.wars.clear()
        w.log("kingdom_destroyed", f"{k.name}失去了所有城池，就此覆灭", kingdom=k.id)
        for h in w.kingdom_heroes(k.id):
            alive = [x for x in w.kingdoms.values() if x.alive]
            if not alive:
                break
            dest = max(alive, key=lambda x: h.rel(x.ruler) + w.rng.random())
            h.kingdom = dest.id
            p = w.hero_party(h.id)
            if p:
                p.faction = dest.id
                p.army = None
            h.remember(w.day, f"故国{k.name}覆灭，转投{dest.name}")
            w.log("defection", f"{h.name}的故国{k.name}覆灭，转投{dest.name}", hero=h.id, new=dest.id)
        for p in list(w.parties.values()):
            if p.faction == k.id and p.kind in ("caravan", "villager"):
                destroy_party(w, p)
