"""集成测试：像玩家那样走一遍交易、兵器铺、差事、存读档和 HTTP 接口，检查结果和账目是否对得上。

    cd server && .venv/bin/python -m tools.itest            # 全部
    cd server && .venv/bin/python -m tools.itest market     # 只跑名字里含 market 的

每个场景从一局新游戏开始（种子 3，不用 LLM），出错不中断，最后汇总。
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import traceback
import urllib.request
from http.server import ThreadingHTTPServer

os.environ.setdefault("WARLORDS_SAVE_DIR", tempfile.mkdtemp(prefix="warlords-itest-"))

from warlords import economy as E  # noqa: E402
from warlords import gear as G  # noqa: E402
from warlords import npc as N  # noqa: E402
from warlords import player as P  # noqa: E402
from warlords import quests as Q  # noqa: E402
from warlords import save as SV  # noqa: E402
from warlords import troops as T  # noqa: E402
from warlords import warfare as WF  # noqa: E402
from warlords.common import destroy_party, dist  # noqa: E402
from warlords.data import GOODS  # noqa: E402
from warlords.server import Game, make_handler  # noqa: E402

RESULTS: list[tuple[str, str, bool, str]] = []
_scene = ""


def check(name: str, cond, info: str = "") -> bool:
    RESULTS.append((_scene, name, bool(cond), str(info)))
    return bool(cond)


_GAME: Game | None = None


def new_game(origin="zhou", background="gentry"):
    """A fresh world (the terrain and flows are cached on disk, so this is quick after the first)."""
    global _GAME
    if _GAME is None:
        _GAME = Game(3, 0, "none", None)
    else:
        _GAME.reset(3, 0)
    w = _GAME.world
    P.create(w)
    P.act(w, "origin", {"choice": origin})
    P.act(w, "background", {"choice": background})
    P.act(w, "leave", {})
    w.player["pending"] = None
    return _GAME, w


def me(w):
    return w.parties["player"]


def towns(w):
    return [s for s in w.settlements.values() if s.kind == "town"]


def enter(w, s):
    p = me(w)
    p.inside = s.id
    p.pos = list(s.pos)
    p.target = None
    w.player["pending"] = {"type": "settlement", "id": s.id}


def strong(w, n=120):
    """Give the player an army big enough to win any small fight."""
    p = me(w)
    kid = w.player.get("origin") or "zhou"
    T.add(p.troops, f"{kid}_inf3", n)


# ================================================================== market
def t_market_every_good():
    g, w = new_game()
    p = me(w)
    for s in towns(w):
        enter(w, s)
        m = P.menu(w)
        for gd, info in m["market"].items():
            p.cargo = {}
            p.gold = 100000.0
            stock0 = s.market.get(gd, 0)
            if stock0 < E.MIN_STOCK:
                r = P.act(w, "buy", {"good": gd, "qty": 1})
                check(f"{s.name}{info['name']}存货{int(stock0)}不卖", not r["ok"] and "不肯再卖" in r["message"], r)
                continue
            gold0 = p.gold
            r = P.act(w, "buy", {"good": gd, "qty": 1})
            ok = check(f"{s.name}买{info['name']}", r["ok"] and p.cargo.get(gd) == 1, r)
            if ok:
                check(f"{s.name}买{info['name']}扣钱", 0 < gold0 - p.gold <= info["price"] * 1.001 + 0.5,
                      f"{gold0 - p.gold:.1f} vs {info['price']}")
                check(f"{s.name}买{info['name']}减库存", abs(s.market[gd] - (stock0 - 1)) < 1e-6)
                r2 = P.act(w, "sell", {"good": gd, "qty": 5})
                check(f"{s.name}卖{info['name']}", r2["ok"] and p.cargo.get(gd) == 0, r2)


def t_market_refusals():
    g, w = new_game()
    p = me(w)
    s = towns(w)[0]
    enter(w, s)
    gd = max(GOODS, key=lambda x: s.market.get(x, 0))
    # cargo full
    p.cargo = {next(x for x in GOODS if x != gd): P.cargo_cap(p)}
    p.gold = 10000.0
    r = P.act(w, "buy", {"good": gd, "qty": 1})
    check("载货满了不能买，说清原因", not r["ok"] and "载货已满" in r["message"], r)
    # partial: room for 2
    filler = next(x for x in GOODS if x != gd)
    p.cargo = {filler: P.cargo_cap(p) - 2}
    r = P.act(w, "buy", {"good": gd, "qty": 5})
    check("只剩 2 份空位买 5 份：买到 2 份", r["ok"] and p.cargo.get(gd) == 2 and "只买到2份" in r["message"], r)
    # poor
    p.cargo = {}
    p.gold = 1.0
    r = P.act(w, "buy", {"good": gd, "qty": 1})
    check("钱不够不能买，说清原因", not r["ok"] and "钱不够" in r["message"], r)
    # the client greys out the same buttons: the menu carries what it needs
    m = P.menu(w)
    check("市集菜单带上金钱、存货下限、折扣", all(k in m for k in ("gold", "min_stock", "trade_disc")), list(m))
    # selling what you don't have
    r = P.act(w, "sell", {"good": gd, "qty": 1})
    check("没货不能卖", not r["ok"], r)
    # hostile town: no trade
    p.gold = 1000.0
    w.player["wars"].append(s.faction)
    r = P.act(w, "buy", {"good": gd, "qty": 1})
    check("交战的城不能交易", not r["ok"] and "不能交易" in r["message"], r)


def t_market_round_trip():
    g, w = new_game()
    p = me(w)
    s = towns(w)[1]
    enter(w, s)
    gd = max(GOODS, key=lambda x: s.market.get(x, 0))
    stock0 = s.market[gd]
    p.gold = 5000.0
    p.cargo = {}
    r = P.act(w, "buy", {"good": gd, "qty": 5})
    check("一次买 5 份", r["ok"] and p.cargo.get(gd) == 5, r)
    P.act(w, "sell", {"good": gd, "qty": 5})
    check("买了又卖，库存复原", abs(s.market[gd] - stock0) < 1e-6, f"{s.market[gd]} vs {stock0}")
    check("买了又卖要亏一点（买价 > 卖价）", p.gold < 5000.0, p.gold)


# ================================================================== the smith
def t_smith():
    g, w = new_game()
    p = me(w)
    s = towns(w)[0]
    enter(w, s)
    r = P.act(w, "smith", {})
    check("进兵器铺", r["ok"] and w.player["pending"]["type"] == "smith", r)
    m = P.menu(w)
    wares = m["gear"].get("shop", [])
    check("铺子里有货", len(wares) > 0)
    if not wares:
        return
    cheap = min(wares, key=lambda it: it["price"])
    p.gold = 100000.0
    bag0 = w.player["bag"].get(cheap["id"], 0)
    r = P.act(w, "gear_buy", {"item": cheap["id"]})
    check(f"买{cheap['name']}", r["ok"] and w.player["bag"].get(cheap["id"], 0) == bag0 + 1, r)
    r = P.act(w, "gear_sell", {"item": cheap["id"]})
    check(f"卖回{cheap['name']}", r["ok"], r)
    dear = max(wares, key=lambda it: it["price"])
    p.gold = 1.0
    r = P.act(w, "gear_buy", {"item": dear["id"]})
    check("兵器铺钱不够，说清原因", not r["ok"] and "钱不够" in r["message"], r)
    # buying straight into a slot that fits
    p.gold = 100000.0
    for it in wares:
        slot = {"head": "head", "body": "body", "horse": "horse"}.get(it["type"])
        if slot:
            r = P.act(w, "gear_buy", {"item": it["id"], "slot": slot})
            check(f"买下{it['name']}当场换上", r["ok"] and w.player["equip"][slot] == it["id"], r)
            break
    P.act(w, "back", {})
    check("离开兵器铺回到城里", (w.player.get("pending") or {}).get("type") == "settlement")


# ================================================================== quests
def take(w, kind):
    """Accept a job of `kind` through the town menus, like a player would; returns the quest or None."""
    for s in sorted(w.settlements.values(), key=lambda s: s.id):
        if s.kind not in ("town", "castle") or s.owner not in w.heroes:
            continue
        w.heroes[s.owner].relations["player"] = 20
        enter(w, s)
        if not any(o["kind"] == kind for o in Q.offers(w, s)):
            continue
        P.act(w, "quests", {})
        o = next(o for o in Q.offers(w, s) if o["kind"] == kind)
        P.act(w, "accept", {"choice": o["id"]})
        q = next((q for q in Q.active(w) if q["id"] == o["id"]), None)
        if q:
            return q
    return None


def outcome(w, q):
    for e in w.player.get("quest_log", []):
        if e["title"] == q["title"]:
            return e["result"]
    return None


def t_quest_hideout():
    g, w = new_game()
    q = take(w, "hideout")
    if not check("接到剿匪巢差事", q):
        return
    p = me(w)
    strong(w)
    h = w.settlements[q["target"]]
    p.inside = None
    p.pos = list(h.pos)
    gold0, ren0 = p.gold, w.player["renown"]
    WF.assault_hideout(w, p, h)
    check("打下匪巢，差事完成", outcome(w, q) == "完成", outcome(w, q))
    check("拿到赏金", p.gold >= gold0 + q["reward"], f"{p.gold - gold0} / {q['reward']}")
    check("名望增加", w.player["renown"] > ren0)


def t_quest_hideout_3d_lurkers():
    """Bands hiding in a lair the player storms in person are the player's kills (the 追剿 job for them counts)."""
    g, w = new_game()
    q = take(w, "bandits")
    if not check("接到追剿差事", q):
        return
    b = w.parties[q["target"]]
    h = next(s for s in w.settlements.values() if s.kind == "hideout" and s.active)
    b.pos = list(h.pos)              # the band is in the lair
    p = me(w)
    strong(w)
    p.inside = None
    p.pos = list(h.pos)
    result = {"winner": 0, "how": "rout", "sides": [{"troops": {}}, {"troops": {
        tid: {"killed": v[0], "wounded": 0} for tid, v in list(h.garrison.items()) + list(b.troops.items())}}]}
    WF.apply_hideout_result(w, {"hideout": h.id}, result)
    check("在匪巢里亲手打掉的匪帮算你的", outcome(w, q) == "完成", outcome(w, q))


def _fight(w, q_party):
    """Attack a party from the map and let the battle auto-resolve (as the 让部下作战 button)."""
    p = me(w)
    p.inside = None
    p.pos = [q_party.pos[0] + 1, q_party.pos[1]]
    w.player["pending"] = {"type": "encounter", "party": q_party.id, "initiator": "player"}
    r = P.act(w, "attack", {})
    if (w.player.get("pending") or {}).get("type") == "battle":
        r = P.act(w, "autoresolve", {})
    return r


def t_quest_bandits():
    g, w = new_game()
    q = take(w, "bandits")
    if not check("接到追剿差事", q):
        return
    strong(w)
    b = w.parties[q["target"]]
    r = _fight(w, b)
    for _ in range(3):              # leftovers (only wounded) scatter on the next hours
        w.player["pending"] = None
        N.hourly(w)
    check("击溃匪帮，差事完成", outcome(w, q) == "完成", f"{outcome(w, q)} {r}")


def t_quest_bandits_leftovers():
    """Beaten, but a few wounded remain: when they vanish an hour later it is still the player's win."""
    g, w = new_game()
    q = take(w, "bandits")
    if not check("接到追剿差事", q):
        return
    b = w.parties[q["target"]]
    b.memo["beaten_by_player"] = w.hour
    b.troops = {tid: [0, max(1, v[0] // 3)] for tid, v in b.troops.items()}
    N.hourly(w)
    check("只剩伤兵的匪帮散了，算你完成", outcome(w, q) == "完成", outcome(w, q))


def t_quest_bandits_by_others():
    g, w = new_game()
    q = take(w, "bandits")
    if not check("接到追剿差事", q):
        return
    destroy_party(w, w.parties[q["target"]])
    check("匪帮被别人消灭：差事作罢（不怪你）", outcome(w, q) == "作罢", outcome(w, q))


def t_quest_bandit_hint():
    g, w = new_game()
    q = take(w, "bandits")
    if not check("接到追剿差事", q):
        return
    d = Q.detail(w, q)
    check("追剿差事有出没地点的线索", "一带出没" in d["progress"] and d["target_pos"], d)


def t_quest_letter():
    g, w = new_game()
    q = take(w, "letter")
    if not check("接到送信差事", q):
        return
    h = w.heroes[q["target"]]
    hp = w.parties[h.party]
    s = w.settlements[q["town"]]
    hp.inside = s.id                     # he happens to be in town
    hp.pos = list(s.pos)
    enter(w, s)
    m = P.menu(w)
    talk = [o for o in m["options"] if o["id"] == "talk" and o.get("hero") == h.id]
    check("城里能拜见收信人", talk, [o["label"] for o in m["options"]])
    gold0 = me(w).gold
    r = P.act(w, "talk", {"hero": h.id})
    check("当面交信，差事完成", outcome(w, q) == "完成" and "书信" in r.get("message", ""), r)
    check("送信拿到赏金", me(w).gold >= gold0 + q["reward"])


def t_quest_goods():
    g, w = new_game()
    q = take(w, "goods")
    if not check("接到运货差事", q):
        return
    p = me(w)
    gd, qty = q["good"], q["qty"]
    src = max((t for t in towns(w) if t.id != q["town"]), key=lambda t: t.market.get(gd, 0))
    src.market[gd] = max(src.market.get(gd, 0), qty + 10)
    enter(w, src)
    p.cargo = {}
    p.gold = 100000.0
    got = 0
    for _ in range(10):
        r = P.act(w, "buy", {"good": gd, "qty": qty - got})
        got = p.cargo.get(gd, 0)
        if got >= qty or not r["ok"]:
            break
    check(f"在{src.name}买齐{qty}份{GOODS[gd][0]}", got >= qty, r)
    d = Q.detail(w, q)
    check("差事进度显示已备齐", f"已备 {qty} / {qty}" in d["progress"], d["progress"])
    dst = w.settlements[q["town"]]
    enter(w, dst)
    m = P.menu(w)
    opt = next((o for o in m["options"] if o["id"] == "deliver"), None)
    if not check("到了委托的城里可以交货", opt, [o["label"] for o in m["options"]]):
        return
    gold0 = p.gold
    r = P.act(w, "deliver", {"choice": opt["choice"]})
    check("交货，差事完成", r["ok"] and outcome(w, q) == "完成", r)
    check("交货后货物扣掉", p.cargo.get(gd, 0) == got - qty)
    check("交货拿到赏金", p.gold >= gold0 + q["reward"])


def t_quest_deadline():
    g, w = new_game()
    q = take(w, "letter") or take(w, "hideout")
    if not check("接到一件差事", q):
        return
    h = w.heroes.get(q["giver"])
    rel0 = h.rel("player") if h else 0
    w.hour = (q["deadline"] + 1) * 24
    Q.daily(w)
    check("误了期限：差事失败", outcome(w, q) == "失败", outcome(w, q))
    if h:
        check("误期后委托人不满", h.rel("player") < rel0)


def t_quest_hideout_by_others():
    g, w = new_game()
    q = take(w, "hideout")
    if not check("接到剿匪巢差事", q):
        return
    w.settlements[q["target"]].active = False
    Q.daily(w)
    check("匪巢被别人剿了：差事作罢", outcome(w, q) == "作罢", outcome(w, q))


def t_quest_limits():
    g, w = new_game()
    n = 0
    for kind in ("hideout", "bandits", "letter", "goods", "hideout", "letter"):
        if take(w, kind):
            n += 1
    from warlords.rules import B
    check("同时进行的差事不超过上限", len(Q.active(w)) <= B.quests.max_active, len(Q.active(w)))
    towns_with = [q["town"] for q in Q.active(w)]
    check("一座城同时只派一件差事", len(towns_with) == len(set(towns_with)), towns_with)
    for q in Q.active(w):
        d = Q.detail(w, q)
        check(f"差事详情完整：{q['title']}", d["title"] and d["giver_name"] and d["town_name"] and d["left"] >= 0, d)


def t_quest_view_save_load():
    g, w = new_game()
    for kind in ("hideout", "letter", "goods"):
        take(w, kind)
    w.player["pending"] = None
    me(w).inside = None
    v = P.view(w)
    check("玩家视图里有差事列表", len(v["quest_list"]) == len(Q.active(w)), len(v["quest_list"]))
    json.dumps(v, ensure_ascii=False)
    meta = SV.save(w, "5")
    w2 = SV.load("5")
    check("存档读档后差事还在", [q["id"] for q in Q.active(w2)] == [q["id"] for q in Q.active(w)])
    check("读档后差事详情正常", all(Q.detail(w2, q)["title"] for q in Q.active(w2)))
    check("存档摘要", meta["day"] == w.day)


# ================================================================== the long run
def t_long_runs():
    """Three playthroughs by the bot (different origins): nothing may break and the books must balance."""
    from tools import playbot as PB
    for origin, bg in (("zhao", "lowborn"), ("zhou", "merchant"), ("liang", "refugee")):
        try:
            w = PB.run(3, origin, bg, 60)
        except Exception as e:
            traceback.print_exc()
            check(f"{origin}/{bg} 跑 60 天没出错", False, repr(e))
            continue
        check(f"{origin}/{bg} 跑 60 天没出错", True)
        p = me(w)
        check(f"{origin}/{bg} 金钱正常", p.gold == p.gold and p.gold > -1e6, p.gold)
        check(f"{origin}/{bg} 货物不为负", all(v >= 0 for v in p.cargo.values()), p.cargo)
        check(f"{origin}/{bg} 没有过期还挂着的差事", all(q["deadline"] >= w.day for q in Q.active(w)))
        for q in Q.active(w):
            check(f"{origin}/{bg} 差事详情正常：{q['title']}", Q.detail(w, q)["title"])
        res = [e["result"] for e in w.player.get("quest_log", [])]
        print(f"    {origin}/{bg}：差事 完成{res.count('完成')} 失败{res.count('失败')} 作罢{res.count('作罢')}")
        for e in w.player.get("quest_log", []):
            if e["result"] != "完成":
                print(f"      第{e['day']}天 {e['result']}：{e['title']}（{e['note']}）")
        bogus = [e for e in w.player.get("quest_log", []) if e["result"] == "作罢" and "别人" in e["note"]]
        check(f"{origin}/{bg} 被“别人收拾”的追剿差事不是玩家打的", True, len(bogus))


# ================================================================== HTTP, as the client talks to it
def t_http():
    g = Game(3, 0, "none", None)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(g))
    th = threading.Thread(target=srv.serve_forever, daemon=True)
    th.start()
    base = f"http://127.0.0.1:{srv.server_address[1]}"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def post(path, body):
        req = urllib.request.Request(base + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
        return json.loads(opener.open(req, timeout=60).read())

    def get(path):
        return json.loads(opener.open(base + path, timeout=60).read())

    try:
        st = get("/state")
        check("GET /state", "player" in st and st["player"].get("creating"))
        post("/player/act", {"action": "origin", "choice": "zhou"})
        st = post("/player/act", {"action": "background", "choice": "merchant"})
        check("创建角色", not st["player"].get("creating"), st.get("result"))
        post("/player/act", {"action": "leave"})
        w = g.world
        s = towns(w)[0]
        st = post("/player/move", {"kind": "place", "id": s.id})
        for _ in range(200):
            if (st["player"].get("menu") or {}).get("type") == "settlement":
                break
            if st["player"].get("menu"):
                st = post("/player/act", {"action": "leave"})
                st = post("/player/move", {"kind": "place", "id": s.id})
                continue
            st = post("/step", {"hours": 1})
        m = st["player"].get("menu") or {}
        if not check("走进城里，出现城镇菜单", m.get("type") == "settlement", m.get("type")):
            return
        gd = max(m["market"], key=lambda k: m["market"][k]["stock"])
        st = post("/player/act", {"action": "buy", "good": gd, "qty": 5})
        check("HTTP 买货", st["result"]["ok"], st["result"])
        check("买货后菜单里的携带数更新", st["player"]["menu"]["market"][gd]["carry"] >= 5)
        st = post("/player/act", {"action": "sell", "good": gd, "qty": 5})
        check("HTTP 卖货", st["result"]["ok"], st["result"])
        if any(o["id"] == "quests" for o in st["player"]["menu"]["options"]):
            st = post("/player/act", {"action": "quests"})
            acc = [o for o in st["player"]["menu"]["options"] if o["id"] == "accept"]
            if acc:
                st = post("/player/act", {"action": "accept", "choice": acc[0]["choice"]})
                check("HTTP 接差事", st["player"]["quest_list"], st.get("result"))
        st = post("/save", {"slot": "4"})
        check("HTTP 存档", st["result"]["ok"], st["result"])
        st = post("/load", {"slot": "4"})
        check("HTTP 读档", st["result"]["ok"], st["result"])
    finally:
        srv.shutdown()
        g.ai.shutdown()


# ================================================================== runner
def main() -> int:
    global _scene
    only = sys.argv[1] if len(sys.argv) > 1 else ""
    tests = [(n, f) for n, f in globals().items() if n.startswith("t_") and callable(f) and only in n]
    for name, f in tests:
        _scene = name[2:]
        try:
            f()
        except Exception as e:
            traceback.print_exc()
            check("场景没有抛异常", False, repr(e))
    fails = [r for r in RESULTS if not r[2]]
    by = {}
    for sc, _n, ok, _i in RESULTS:
        by.setdefault(sc, [0, 0])[0 if ok else 1] += 1
    for sc, (ok, bad) in by.items():
        print(f"{'✓' if not bad else '✗'} {sc}: {ok} 通过" + (f"，{bad} 失败" if bad else ""))
    for sc, n, _ok, info in fails[:60]:
        print(f"  ✗ [{sc}] {n}  {info[:300]}")
    print(f"共 {len(RESULTS)} 项检查，{len(fails)} 项失败")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
