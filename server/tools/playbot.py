"""试玩机器人：像一个普通玩家那样从头玩（自动结算战斗），记录成长的里程碑，用来检查流程节奏。

    cd server && .venv/bin/python -m tools.playbot --seed 3 --origin zhao --background lowborn --days 120

打法（大致是战团玩家的正常路线）：进城招募 → 打听差事（剿匪、追剿匪帮、送信、运货）→ 打劫路的土匪 →
名望够了先签义从契约 → 再向君主称臣 → 随本国出征、自己找敌国关塞围攻 → 争取封地。
"""
from __future__ import annotations

import argparse
import math

from warlords import player as P
from warlords import quests as Q
from warlords import troops as T
from warlords.ai import AIRouter
from warlords.rules import B
from warlords.scenario import default_world
from warlords.sim import Simulation

log: list[tuple[int, str]] = []
seen: set[str] = set()


def note(w, key: str, text: str) -> None:
    if key not in seen:
        seen.add(key)
        log.append((w.day, text))


def power(w):
    return w.party_power(P.party(w))


def handle_menu(w, sim) -> None:
    m = P.menu(w)
    if m is None:
        return
    p = P.party(w)
    ids = {o["id"]: o for o in m["options"] if o["enabled"]}
    t = m["type"]
    if t in ("notice",):
        P.act(w, "ok", {})
        return
    if t == "captive":
        act = "recruit" if "recruit" in ids else "ransom" if "ransom" in ids else "leave"
        P.act(w, act, {})
        note(w, "captive", f"第一次俘获敌将（{m['title']}），选择{act}")
        return
    if t == "battle":
        P.act(w, "autoresolve", {})
        return
    if t == "event":
        # an ordinary player takes the first thing on offer that he can afford
        o = next(o for o in m["options"] if o["enabled"])
        P.act(w, "choose", {"choice": o["choice"]})
        note(w, f"ev{w.day}", f"事件：{m['title']}·{o['label'][:24]}")
        return
    if t == "assault_ready":
        P.act(w, "assault", {})                 # the bot never plays 3D: storm by auto-resolve
        note(w, f"assault{w.day}", f"下令强攻：{m['title']}")
        return
    if t == "request_fief":
        P.act(w, "request", {})
        note(w, f"req{w.day}", f"当面请封：{m['title']}")
        return
    if t == "summon":
        P.act(w, "follow_army", {})
        note(w, f"summon{w.day}", f"应召随军：{m['title']}")
        return
    if t == "quest":
        acc = [o for o in m["options"] if o["id"] == "accept" and o["enabled"]]
        # prefer jobs a small band can do: letters and goods first, then bandits, then hideouts if strong
        def rank(o):
            lab = o["label"]
            strong = power(w) > 110
            if "剿灭匪巢" in lab:
                return 0 if strong else 9
            if "追剿" in lab:
                return 1 if power(w) > 60 else 9
            if "运" in lab:
                return 2 if p.gold > 800 else 9
            return 3
        acc.sort(key=rank)
        if acc and rank(acc[0]) < 9:
            P.act(w, "accept", {"choice": acc[0]["choice"]})
            note(w, "quest_first", f"接下第一件差事：{acc[0]['label']}")
        else:
            P.act(w, "back", {})
        return
    if t == "talk":
        if "vassal" in ids:
            P.act(w, "vassal", {})
            note(w, "vassal", f"向{m['title'][1:-2]}称臣（名望{w.player['renown']:.0f}）")
        elif "merc" in ids and not w.player.get("contract") and w.player["renown"] >= 25:
            P.act(w, "merc", {})
            note(w, "merc", f"签下义从契约：{m['title']}")
        P.act(w, "back", {})
        return
    if t == "encounter":
        if m["initiator"] == "them":
            q = w.parties[m["party"]]
            if w.party_power(q) < power(w) * 1.1:
                P.act(w, "fight", {})
            elif "pay" in ids:
                P.act(w, "pay", {})
            else:
                P.act(w, "flee", {})
            return
        q = w.parties[m["party"]]
        if "talk" in ids and not w.hostile(p, q):
            P.act(w, "talk", {"hero": q.hero})            # e.g. delivering a letter
        elif "attack" in ids and w.hostile(p, q) and w.party_power(q) < power(w) * 0.9:
            P.act(w, "attack", {})
        elif "absorb" in ids:
            P.act(w, "absorb", {})
            note(w, "refugee", "收编流民")
        else:
            P.act(w, "leave", {})
        return
    if t == "settlement":
        s = w.settlements[m["id"]]
        key = (s.id, w.hour)
        if w.player.get("_visit_key") != key:
            w.player["_visit_key"] = key
            w.player["_visit_done"] = []
        done = w.player["_visit_done"]

        def once(tag):
            if tag in done:
                return False
            done.append(tag)
            return True
        for o in m["options"]:
            if o["id"] == "deliver" and o["enabled"]:
                P.act(w, "deliver", {"choice": o["choice"]})
                return
        if "recruit" in ids and p.gold > 600 + T.upkeep(p.troops) * 10 and once("recruit"):
            P.act(w, "recruit", {})
        # sell goods nobody asked us for (leftovers from failed deliveries)
        wanted = {q["good"] for q in Q.active(w) if q["kind"] == "goods"}
        if s.kind == "town" and once("sell"):
            for g, n in list(p.cargo.items()):
                if n > 0 and g not in wanted:
                    P.act(w, "sell", {"good": g, "qty": n})
        if "sell_prisoners" in ids:
            P.act(w, "sell_prisoners", {})
        # buy goods for a delivery job
        for q in Q.active(w):
            if q["kind"] == "goods" and s.kind == "town" and s.id != q["target"]:
                need = q["qty"] - p.cargo.get(q["good"], 0)
                if need > 0 and P.cargo_cap(p) - sum(p.cargo.values()) >= need:
                    P.act(w, "buy", {"good": q["good"], "qty": need})
        if "quests" in ids and len(Q.active(w)) < 2 and once("quests"):
            P.act(w, "quests", {})
            return
        # meet the realm's ruler here to get hired / sworn in
        for o in m["options"]:
            if o["id"] == "talk" and o["enabled"]:
                h = w.heroes[o["hero"]]
                if w.kingdoms[h.kingdom].ruler == h.id and not w.player.get("kingdom") and once("talk" + h.id):
                    P.act(w, "talk", {"hero": h.id})
                    return
        if "besiege" in ids and (power(w) > 600 or s.siege) and once("besiege"):
            P.act(w, "besiege", {})
            note(w, "siege", f"开始围攻{s.name}")
            return
        if "attack_hideout" in ids and power(w) > 110 and once("hideout"):
            P.act(w, "attack_hideout", {})
            return
        if T.wounded(p.troops) > T.healthy(p.troops) * 0.5 and once("rest"):
            P.act(w, "rest", {})
            return
        P.act(w, "leave", {})


def choose_goal(w) -> dict | None:
    p = P.party(w)
    me = P.side(w)
    # quests first
    for q in Q.active(w):
        if q["kind"] == "hideout" and power(w) > 110:
            return {"kind": "place", "id": q["target"]}
        if q["kind"] == "bandits" and q["target"] in w.parties:
            return {"kind": "party", "id": q["target"]}
        if q["kind"] == "letter":
            h = w.heroes.get(q["target"])
            if h and h.party in w.parties:
                return {"kind": "party", "id": h.party}
        if q["kind"] == "goods":
            if p.cargo.get(q["good"], 0) >= q["qty"]:
                return {"kind": "place", "id": q["target"]}
            towns = [s for s in w.settlements.values() if s.kind == "town" and s.id != q["target"]
                     and not w.at_war(me, s.faction)]
            if towns:
                towns = [s for s in towns if s.market.get(q["good"], 0) >= q["qty"]] or towns
                s = min(towns, key=lambda s: math.dist(s.pos, p.pos))
                return {"kind": "place", "id": s.id}
    # wounded: rest in a friendly town
    if T.wounded(p.troops) > T.healthy(p.troops) * 0.6:
        t = min((s for s in w.settlements.values() if s.kind == "town" and not w.at_war(me, s.faction)),
                key=lambda s: math.dist(s.pos, p.pos))
        return {"kind": "place", "id": t.id}
    # ready to serve a realm: go find a ruler
    seeking = w.player.get("_seek_since")
    if seeking is not None and w.day - seeking > 6:
        w.player["_seek_cool"] = w.day + 10            # couldn't catch him: do other things for a while
        w.player.pop("_seek_since", None)
    if not w.player.get("kingdom") and w.day >= w.player.get("_seek_cool", 0) \
            and (w.player["renown"] >= B.player.vassal_renown
                 or (w.player["renown"] >= 25 and not w.player.get("contract") and T.healthy(p.troops) >= 10)):
        cands = [k for k in w.kingdoms.values() if k.alive and k.wars and k.id not in w.player["wars"]]
        reach = 500
        if w.player["renown"] >= B.player.vassal_renown:
            # any ruler who'd take us (not at war with us, likes us well enough); the realm we serve first
            cands = [k for k in w.kingdoms.values() if k.alive and k.id not in w.player["wars"]
                     and k.ruler in w.heroes and w.heroes[k.ruler].rel("player") >= B.player.vassal_relation]
            mine = [k for k in cands if k.id == w.player.get("contract")]
            cands = mine or cands
            reach = 1000
        if cands:
            k = min(cands, key=lambda k: math.dist(w.parties[w.heroes[k.ruler].party].pos, p.pos)
                    if w.heroes[k.ruler].party in w.parties else 9e9)
            r = w.heroes[k.ruler]
            if r.party in w.parties and math.dist(w.parties[r.party].pos, p.pos) < reach:
                w.player.setdefault("_seek_since", w.day)
                return {"kind": "party", "id": r.party}
    # sworn: wait for the marshal's summons (going alone against walls is suicide); only very strong bands go alone
    if w.player.get("kingdom") and power(w) > 600:
        foes = [s for s in w.settlements.values() if s.kind in ("castle", "town") and w.at_war(me, s.faction)]
        if foes:
            s = min(foes, key=lambda s: math.dist(s.pos, p.pos))
            return {"kind": "place", "id": s.id}
    # hunt bandits nearby if strong enough
    bands = [b for b in w.parties.values() if b.alive and b.kind == "bandit" and math.dist(b.pos, p.pos) < 160
             and w.party_power(b) < power(w) * 0.8]
    if bands:
        return {"kind": "party", "id": min(bands, key=lambda b: math.dist(b.pos, p.pos)).id}
    # otherwise: a town with jobs or recruits, not the one we're in
    towns = [s for s in w.settlements.values() if s.kind in ("town", "castle") and not w.at_war(me, s.faction)
             and not any(q["town"] == s.id for q in Q.active(w))]
    if towns:
        towns.sort(key=lambda s: math.dist(s.pos, p.pos))
        here = w.player.get("_last_town")
        for s in towns:
            if s.id != here:
                w.player["_last_town"] = s.id
                return {"kind": "place", "id": s.id}
    return None


def run(seed: int = 3, origin: str = "zhao", background: str = "lowborn", days: int = 120):
    """Play `days` days as the bot; returns the world (tools/itest.py checks its books)."""
    log.clear()
    seen.clear()
    w = default_world(seed)
    sim = Simulation(w, AIRouter(w, 0))
    P.act(w, "origin", {"choice": origin})
    P.act(w, "background", {"choice": background})
    p = P.party(w)
    stuck = 0
    milestones = [(30, "renown30"), (60, "renown60"), (B.player.vassal_renown, "renownV")]
    spins, last_hour = 0, -1
    status_day = -1
    while w.day < days:
        p = P.party(w)                                # re-read: the party can be rebuilt after a defeat
        if w.day % 30 == 0 and w.day != status_day:
            status_day = w.day
            note(w, f"st{w.day}", f"状态：金{p.gold:.0f} 兵{T.healthy(p.troops)}+伤{T.wounded(p.troops)} 名望{w.player['renown']:.0f}"
                                  f" 日饷{T.upkeep(p.troops):.0f} {'封臣' if w.player.get('kingdom') else '义从' if w.player.get('contract') else '无主'}"
                                  f" 食邑{len(P.villages_of(w))}")
        # guard: a bot that keeps re-entering the same town in the same hour must let time pass
        spins = spins + 1 if w.hour == last_hour else 0
        last_hour = w.hour
        if spins > 40:
            w.player["pending"] = None
            p.target = None
            sim.step(3)
            spins = 0
            continue
        if w.player.get("pending"):
            before = repr(w.player.get("pending"))[:80]
            handle_menu(w, sim)
            if repr(w.player.get("pending"))[:80] == before:
                stuck += 1
                if stuck > 5:
                    P.act(w, "leave", {}) if P.menu(w) and any(o["id"] == "leave" for o in P.menu(w)["options"]) else P.act(w, "ok", {})
                    w.player["pending"] = None if stuck > 8 else w.player["pending"]
            else:
                stuck = 0
            continue
        if P.captive(w):
            sim.step(6)
            note(w, f"captured{w.day // 30}", "被俘（战败）")
            continue
        if p.inside and T.wounded(p.troops) <= T.healthy(p.troops) * 0.15:
            g = choose_goal(w)                        # healed: back on the road
            if g:
                P.move(w, g)
        if p.mode in ("siege", "raid") or p.inside:
            sim.step(4)
            continue
        if not p.target:
            g = choose_goal(w)
            if g:
                P.move(w, g)
            else:
                sim.step(6)
                continue
        sim.step(1)
        for r, key in milestones:
            if w.player["renown"] >= r:
                note(w, key, f"名望达到{r}")
        if w.fiefs_of("player"):
            note(w, "fief", f"获得封地：{'、'.join(s.name for s in w.fiefs_of('player'))}")
    return w


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=3)
    ap.add_argument("--origin", default="zhao")
    ap.add_argument("--background", default="lowborn")
    ap.add_argument("--days", type=int, default=120)
    a = ap.parse_args()
    w = run(a.seed, a.origin, a.background, a.days)
    p = P.party(w)
    # summary
    done = sum(1 for e in w.events if e["type"] == "quest_done")
    failed = sum(1 for e in w.events if e["type"] == "quest_failed")
    wins = sum(1 for e in w.events if e["type"] == "battle" and e.get("player") and "player" in (e.get("attackers", []) + e.get("defenders", [])))
    print(f"种子{a.seed} {a.origin}/{a.background}：{a.days}天后 名望{w.player['renown']:.0f} 金{p.gold:.0f} "
          f"部队{T.healthy(p.troops)}人 差事完成{done}/失败{failed} 参战{wins}次 "
          f"身份：{'封臣' if w.player.get('kingdom') else '义从' if w.player.get('contract') else '无主'} "
          f"封地{len(w.fiefs_of('player'))}")
    for d, t in log:
        print(f"  第{d}天 {t}")
    for e in w.events:
        mine = e.get("player") and (e["type"] in ("quest_done", "quest_failed", "player_defeated", "fief_granted")
                                    or (e["type"] == "player" and any(k in e["text"] for k in ("称臣", "契约", "封地", "随", "召集"))))
        if mine or (e["type"] == "conquest" and "你" in e["text"]):
            print(f"    · 第{e['day']}天 {e['text'][:70]}")


if __name__ == "__main__":
    main()
