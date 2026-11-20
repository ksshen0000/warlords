"""差事 (quests), in the spirit of Mount & Blade: Warband's early game — a lord or a town asks the
player for a job; doing it brings gold, renown and the giver's goodwill, which is how a nobody becomes
someone worth hiring as a mercenary or taking as a vassal.

Kinds (numbers in rules/balance.toml [quests]):
  hideout  剿灭匪巢   clear a bandit hideout near the giver's town
  bandits  追剿匪帮   destroy a bandit band roaming near the town
  letter   送信       carry a letter to another lord (talking to him delivers it)
  goods    运送物资   bring N loads of a good the town is short of

State: w.player["quests"] = [ {id, kind, giver, town, target, good, qty, reward, renown, deadline, title, text} ]
"""
from __future__ import annotations

import random
import zlib

from .common import dist
from .data import GOODS, KIND_NAMES
from .model import World
from .rules import B

PID = "player"


def active(w: World) -> list[dict]:
    return w.player.setdefault("quests", [])


def _giver_name(w: World, q: dict) -> str:
    h = w.heroes.get(q["giver"])
    return h.name if h else w.settlements[q["town"]].name


def _say(w: World, owner, s, kind: str, default: str, **fill) -> str:
    """The giver's words for a job, from content/quests.toml in his culture's voice."""
    from . import content as C
    ruler = owner.kingdom in w.kingdoms and w.kingdoms[owner.kingdom].ruler == owner.id
    line = C.pick(kind, {"culture": owner.culture, "ruler": ruler}, dict(fill, town=s.name),
                  seed=f"{w.seed}:{s.id}:{w.day}", kind="quests") or default
    return f"{owner.name}：「{line}」"


def offers(w: World, s) -> list[dict]:
    """The jobs on offer in town/castle `s` today (stable for the day, so reopening the menu shows the same)."""
    Q = B.quests
    if s.kind not in ("town", "castle") or s.owner not in w.heroes:
        return []
    if len(active(w)) >= Q.max_active or any(q["town"] == s.id for q in active(w)):
        return []
    if w.player.get("quest_refused", {}).get(s.id, -1) == w.day:
        return []
    owner = w.heroes[s.owner]
    if owner.rel(PID) < Q.min_relation:
        return []
    rng = random.Random(zlib.crc32(f"{w.seed}:{s.id}:{w.day}".encode()))
    out: list[dict] = []
    base_id = f"q{w.day}_{s.id}"
    # 剿灭匪巢: an active hideout the player could find, not too far
    taken = {q["target"] for q in active(w)}
    lairs = [h for h in w.settlements.values() if h.kind == "hideout" and h.active and dist(h.pos, s.pos) < Q.hideout_range
             and h.id not in taken]
    if lairs:
        h = min(lairs, key=lambda x: dist(x.pos, s.pos))
        out.append({"id": base_id + "h", "kind": "hideout", "giver": owner.id, "town": s.id, "target": h.id,
                    "reward": Q.hideout_gold, "renown": Q.hideout_renown, "days": Q.hideout_days,
                    "title": f"剿灭匪巢{h.name}",
                    "text": _say(w, owner, s, "hideout", f"{h.name}的贼人屡屡劫掠{s.name}的商旅，足下若能剿灭此巢，必有重谢。",
                                 lair=h.name)})
    # 追剿匪帮: a band roaming near the town
    bands = [b for b in w.parties.values() if b.alive and b.kind == "bandit" and dist(b.pos, s.pos) < Q.bandit_range
             and b.id not in taken]
    if bands:
        # the slowest band nearby (horse bandits would just outrun you)
        from .model import party_speed
        b = min(bands, key=lambda x: (party_speed(w, x), dist(x.pos, s.pos)))
        out.append({"id": base_id + "b", "kind": "bandits", "giver": owner.id, "town": s.id, "target": b.id,
                    "reward": Q.bandit_gold, "renown": Q.bandit_renown, "days": Q.bandit_days,
                    "title": f"追剿{b.name}",
                    "text": _say(w, owner, s, "bandits", f"一伙{b.name}在城外出没，百姓不敢出城。替我追上去，把他们收拾了。",
                                 band=b.name)})
    # 送信: to another lord, of any realm at peace with the giver (or of his own)
    others = [h for h in w.heroes.values() if h.id != owner.id and h.captive_of is None and h.party
              and (h.kingdom == owner.kingdom or not w.at_war(owner.kingdom, h.kingdom))]
    if others:
        t = rng.choice(others)
        far = dist(w.parties[t.party].pos, s.pos) if t.party in w.parties else 300
        gold = int(Q.letter_gold_base + far * Q.letter_gold_per_unit)
        out.append({"id": base_id + "l", "kind": "letter", "giver": owner.id, "town": s.id, "target": t.id,
                    "reward": gold, "renown": Q.letter_renown, "days": Q.letter_days,
                    "title": f"送信给{t.name}",
                    "text": _say(w, owner, s, "letter", f"这封书信务必亲手交给{w.kingdoms[t.kingdom].name}的{t.name}。",
                                 target=t.name, target_kingdom=w.kingdoms[t.kingdom].name)})
    # 运送物资: a good the town market is short of
    if s.kind == "town":
        # everyday goods only (grain, timber, salt, iron, cloth): an errand, not a fortune
        cheap = [g for g in GOODS if GOODS[g][1] <= Q.goods_max_value]
        g = min(cheap, key=lambda x: s.market.get(x, 0))
        qty = rng.randint(Q.goods_qty[0], Q.goods_qty[1])
        price = w.price(s, g)
        out.append({"id": base_id + "g", "kind": "goods", "giver": owner.id, "town": s.id, "target": s.id,
                    "good": g, "qty": qty, "reward": int(price * qty + Q.goods_bonus), "renown": Q.goods_renown,
                    "days": Q.goods_days, "title": f"运{qty}份{GOODS[g][0]}到{s.name}",
                    "text": _say(w, owner, s, "goods", f"{s.name}的{GOODS[g][0]}眼看就要断了。你若能运来{qty}份，我按市价收下，"
                                 f"另有{Q.goods_bonus}金辛苦钱。", good=GOODS[g][0], qty=qty, bonus=Q.goods_bonus)
                            + _where_to_buy(w, s, g, qty)})
    rng.shuffle(out)
    return out[:Q.offers_per_town]


def _where_to_buy(w: World, s, g: str, qty: int) -> str:
    """A hint so the job is doable: the nearest town that has enough of the good in stock."""
    have = [t for t in w.settlements.values() if t.kind == "town" and t.id != s.id and t.market.get(g, 0) >= qty]
    if not have:
        return f"（眼下各城都缺{GOODS[g][0]}，只能等村民运来）"
    t = min(have, key=lambda t: dist(t.pos, s.pos))
    return f"（打听到：{t.name}有货，约{dist(t.pos, s.pos):.0f}里，每份约{w.price(t, g):.0f}金）"


def accept(w: World, offer: dict) -> None:
    q = dict(offer)
    q["deadline"] = w.day + int(q.pop("days"))
    active(w).append(q)
    w.log("quest", f"你接下了{_giver_name(w, q)}的差事：{q['title']}（{q['deadline']}日前）", player=True,
          settlement=q["town"])


def refuse(w: World, s) -> None:
    w.player.setdefault("quest_refused", {})[s.id] = w.day


def _complete(w: World, q: dict, how: str = "") -> None:
    active(w).remove(q)
    p = w.parties.get(PID)
    if p:
        p.gold += q["reward"]
    w.player["renown"] = round(w.player["renown"] + q["renown"], 1)
    h = w.heroes.get(q["giver"])
    if h:
        h.adjust_rel(PID, B.quests.relation_gain)
        h.remember(w.day, f"玩家办妥了差事：{q['title']}")
    w.log("quest_done", f"差事完成：{q['title']}{how}——得赏{q['reward']}金，名望+{q['renown']}"
          + (f"，{h.name}对你更加器重" if h else ""), player=True, settlement=q["town"])


def _cancel(w: World, q: dict, why: str) -> None:
    """The job went away through no fault of yours: no reward, no blame."""
    active(w).remove(q)
    w.log("quest_failed", f"差事作罢：{q['title']}（{why}）", player=True, settlement=q["town"])


def _fail(w: World, q: dict, why: str) -> None:
    active(w).remove(q)
    h = w.heroes.get(q["giver"])
    if h:
        h.adjust_rel(PID, -B.quests.relation_loss)
        h.remember(w.day, f"玩家没办成差事：{q['title']}")
    w.log("quest_failed", f"差事失败：{q['title']}（{why}）", player=True, settlement=q["town"])


# ------------------------------------------------------------------ hooks
def on_hideout_cleared(w: World, hid: str) -> None:
    for q in list(active(w)):
        if q["kind"] == "hideout" and q["target"] == hid:
            _complete(w, q)


def on_party_destroyed(w: World, pid: str, by_player: bool) -> None:
    for q in list(active(w)):
        if q["kind"] == "bandits" and q["target"] == pid:
            if by_player:
                _complete(w, q)
            else:
                _cancel(w, q, "那伙贼人被别人收拾了")


def on_talk(w: World, hid: str) -> str:
    """Meeting a lord delivers any letter for him; returns a line for the talk menu."""
    for q in list(active(w)):
        if q["kind"] == "letter" and q["target"] == hid:
            _complete(w, q, "（书信已当面交到）")
            return f"你把{_giver_name(w, q)}的书信交给了{w.heroes[hid].name}。"
    return ""


def deliverable(w: World, s) -> list[dict]:
    p = w.parties.get(PID)
    return [q for q in active(w) if q["kind"] == "goods" and q["target"] == s.id and p
            and p.cargo.get(q["good"], 0) >= q["qty"]]


def deliver(w: World, q: dict) -> None:
    p = w.parties[PID]
    p.cargo[q["good"]] -= q["qty"]
    s = w.settlements[q["target"]]
    s.market[q["good"]] = s.market.get(q["good"], 0) + q["qty"]
    _complete(w, q, f"（交付{q['qty']}份{GOODS[q['good']][0]}）")


def daily(w: World) -> None:
    for q in list(active(w)):
        if w.day > q["deadline"]:
            _fail(w, q, "逾期")
            continue
        if q["kind"] == "hideout" and not w.settlements[q["target"]].active:
            _cancel(w, q, "匪巢已被别人剿灭")
        elif q["kind"] == "letter":
            h = w.heroes.get(q["target"])
            if h is None or h.captive_of:
                _cancel(w, q, "收信人已不在人世" if h and h.captive_of == "__dead" else "收信人被俘了")


def describe(w: World, q: dict) -> str:
    """One line for the player panel."""
    left = q["deadline"] - w.day
    where = ""
    if q["kind"] == "hideout":
        where = f"（{w.settlements[q['target']].name}）"
    elif q["kind"] == "bandits":
        b = w.parties.get(q["target"])
        where = "（去向不明）" if not b else ""
    elif q["kind"] == "letter":
        h = w.heroes.get(q["target"])
        where = f"（{w.kingdoms[h.kingdom].name}将军）" if h else ""
    elif q["kind"] == "goods":
        have = w.parties[PID].cargo.get(q["good"], 0) if PID in w.parties else 0
        where = f"（已备{min(have, q['qty'])}/{q['qty']}）"
    return f"{q['title']}{where} · 赏{q['reward']}金 · 剩{left}天 · 委托人{_giver_name(w, q)}（{KIND_NAMES.get(w.settlements[q['town']].kind, '')}{w.settlements[q['town']].name}）"
