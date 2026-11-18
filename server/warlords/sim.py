"""Main loop. One tick = one in-game hour.

hourly  : deliver AI answers -> neutral AI + lord tactics/orders -> movement -> player -> sieges / raids
N-hourly: strategic decisions for lords that need one (via the AI router, possibly async LLM)
daily   : economy, politics, council (votes, rulings, proposals)

Time stops while the player has a menu open (entering a town, an encounter...).
"""
from __future__ import annotations

from . import economy, movement, npc, player, politics
from . import warfare as WF
from .ai import AIRouter
from .brains.base import Decision
from .model import Hero, World
from .options import Option, lord_options
from .rules import B

URGENT_REPLAN = ("wait", "patrol", "recruit", "attack", "raid", "hideout")


class Simulation:
    def __init__(self, world: World, router: AIRouter, printer=None):
        self.w = world
        self.ai = router
        self.print = printer
        self._thinking: set[str] = set()          # heroes with a decision in flight
        self._voting: set[tuple[str, str]] = set()
        self._ruling: set[str] = set()
        self._proposing: set[str] = set()

    # ------------------------------------------------------------------ api
    def blocked(self) -> bool:
        return bool(self.w.player and self.w.player.get("pending"))

    def step(self, hours: int = 1) -> list[dict]:
        start = len(self.w.events)
        for _ in range(hours):
            if self.blocked():
                break
            self._hour()
        self.ai.poll()
        new = self.w.events[start:]
        if self.print:
            for ev in new:
                self.print(ev)
        return new

    # ------------------------------------------------------------- the tick
    def _hour(self) -> None:
        w = self.w
        w.hour += 1
        self.ai.poll()
        npc.hourly(w)
        for p in list(w.parties.values()):
            if p.alive:
                movement.move(w, p, 1.0)
        player.after_move(w)
        WF.siege_tick(w)
        WF.raid_tick(w)
        if w.hour % B.time.decide_every_hours == 0:
            self._decisions()
            self.ai.flush()
        if w.hour % 24 == 0:
            economy.daily(w)
            politics.daily(w)
            player.daily(w)
            self._council()
            self.ai.flush()

    # --------------------------------------------------------- decisions
    def _needs_decision(self, h: Hero) -> bool:
        w = self.w
        p = w.hero_party(h.id)
        if h.id in self._thinking or h.captive_of or p is None or not p.alive:
            return False
        if p.army and p.army in w.armies and w.armies[p.army].leader != h.id:
            return False
        if p.mode in ("siege", "raid"):
            return False
        o = p.order
        if o is None:
            return True
        if o["type"] == "retreat" and p.mode == "flee":
            return False
        if o["type"] in URGENT_REPLAN and any(s.siege for s in w.fiefs_of(h.id)):
            return o["age"] >= B.time.urgent_replan_hours   # own fief besieged: rethink quickly
        return o["age"] >= self.ai.setting("replan_after_hours")

    def _component(self, h: Hero) -> str:
        w = self.w
        p = w.hero_party(h.id)
        leads = bool(p and p.army and p.army in w.armies and w.armies[p.army].leader == h.id)
        return "ruler_strategy" if w.kingdoms[h.kingdom].ruler == h.id or leads else "lord_strategy"

    def _decisions(self) -> None:
        w = self.w
        for h in [h for h in w.heroes.values() if self._needs_decision(h)]:
            opts = lord_options(w, h)
            self._thinking.add(h.id)
            self.ai.submit(self._component(h), "decide", (h, opts),
                           lambda d, h=h, opts=opts: self._on_decided(h, opts, d))

    def _on_decided(self, h: Hero, opts: list[Option], d: Decision) -> None:
        self._thinking.discard(h.id)
        p = self.w.hero_party(h.id)
        if h.captive_of or p is None or not p.alive or p.mode in ("siege", "raid"):
            return   # the world moved on while the lord was thinking
        if p.army and p.army in self.w.armies and self.w.armies[p.army].leader != h.id:
            return
        self._apply_order(h, opts[d.index], d)

    def _apply_order(self, h: Hero, o: Option, d: Decision) -> None:
        w = self.w
        p = w.hero_party(h.id)
        old = p.order
        if d.speech:
            h.last_speech = d.speech
        if o.type == "gather_army":
            aid = None if p.army else politics.gather_army(w, h)
            p.order = None if aid else {"type": "wait", "target": None, "age": 0, "reason": d.reason}
            if aid and d.speech:
                w.log("speech", f"{h.name}：「{d.speech}」", hero=h.id)
            return
        if o.type == "disband_army":
            if p.army:
                WF.disband_army(w, p.army, "统帅下令")
            p.order = None
            return
        p.order = {"type": o.type, "target": o.target, "age": 0, "reason": d.reason, "label": o.label}
        p.memo.pop("chase", None)
        npc._apply_order_target(w, p)
        changed = not old or old.get("type") != o.type or old.get("target") != o.target
        if changed and o.type != "wait":
            w.log("order", f"{h.name}决定：{o.label}" + (f"——{d.reason}" if d.reason else ""),
                  hero=h.id, order=o.type, target=o.target)
            if d.speech:
                w.log("speech", f"{h.name}：「{d.speech}」", hero=h.id)

    # ----------------------------------------------------------- council
    def _council(self) -> None:
        w = self.w
        # 1) lords vote on open decisions
        for d in list(w.decisions.values()):
            if d.resolved:
                continue
            ctx = politics.decision_context(w, d)
            opts = [Option("vote", o["id"], o["label"]) for o in d.options]
            for h in w.kingdom_heroes(d.kingdom, free_only=True):
                key = (d.id, h.id)
                if h.id in d.votes or h.id == w.kingdoms[d.kingdom].ruler or key in self._voting:
                    continue
                self._voting.add(key)
                self.ai.submit("council_vote", "vote", (h, ctx, opts, None),
                               lambda dec, d=d, h=h, opts=opts, key=key: self._on_vote(d, h, opts, dec, key))
        # 2) the ruler rules once the deadline has passed
        for d in list(w.decisions.values()):
            if d.resolved or d.deadline > w.hour or d.id in self._ruling:
                continue
            if not self._still_valid(d):
                d.resolved = True
                continue
            r = w.heroes[w.kingdoms[d.kingdom].ruler]
            opts = [Option("vote", o["id"], o["label"]) for o in d.options]
            self._ruling.add(d.id)
            self.ai.submit("council_ruling", "vote", (r, politics.decision_context(w, d), opts, politics.tally(d)),
                           lambda dec, d=d, r=r, opts=opts: self._on_ruling(d, r, opts, dec))
        # 3) new proposals (each lord considers it about once a week)
        for h in w.heroes.values():
            if h.captive_of or not w.kingdoms[h.kingdom].alive or h.influence < B.politics.peace_proposal_cost:
                continue
            if (sum(map(ord, h.id)) + w.day) % 7 or h.id in self._proposing:
                continue
            opts = politics.proposal_options(w, h)
            if len(opts) > 1:
                self._proposing.add(h.id)
                self.ai.submit("council_propose", "propose", (h, opts),
                               lambda dec, h=h, opts=opts: self._on_propose(h, opts, dec))

    def _still_valid(self, d) -> bool:
        w = self.w
        k = w.kingdoms[d.kingdom]
        if not k.alive:
            return False
        if d.kind == "fief":
            return w.settlements[d.subject].faction == d.kingdom
        return w.kingdoms[d.subject].alive and (d.kind == "war") != (d.subject in k.wars)

    def _on_vote(self, d, h, opts, dec: Decision, key) -> None:
        self._voting.discard(key)
        if d.resolved or h.captive_of:
            return
        d.votes[h.id] = {"option": opts[dec.index].target, "weight": round(politics.vote_weight(h), 2),
                         "reason": dec.reason}
        if dec.speech:
            h.last_speech = dec.speech

    def _on_ruling(self, d, r, opts, dec: Decision) -> None:
        self._ruling.discard(d.id)
        if d.resolved or not self._still_valid(d):
            d.resolved = True
            return
        choice = opts[dec.index].target
        politics.resolve(self.w, d, choice, dec.reason)
        if dec.speech:
            r.last_speech = dec.speech
        if d.kind == "peace" and choice == "yes":
            self._peace_offer(d.kingdom, d.subject)

    def _on_propose(self, h, opts, dec: Decision) -> None:
        self._proposing.discard(h.id)
        o = opts[dec.index]
        if o.type == "none" or h.captive_of:
            return
        k = self.w.kingdoms[h.kingdom]
        if not self.w.kingdoms[o.target].alive or (o.type == "propose_war") == (o.target in k.wars):
            return      # the situation changed while the lord was thinking
        if politics.open_decision_exists(self.w, h.kingdom, "war" if o.type == "propose_war" else "peace", o.target):
            return
        politics.apply_proposal(self.w, h, o, dec.reason)

    def _peace_offer(self, from_kid: str, to_kid: str) -> None:
        w = self.w
        if to_kid not in w.kingdoms[from_kid].wars:
            return
        other = w.heroes[w.kingdoms[to_kid].ruler]
        opts, info = politics.peace_offer_options(w, from_kid, to_kid)
        ctx = (f"{w.kingdoms[from_kid].name}遣使求和。你方视角的战争分数{info['score']:+.0f}"
               f"（正数表示你方占优），已交战{w.day - w.kingdoms[to_kid].wars[from_kid]['since']}天。")

        def done(dec: Decision) -> None:
            if to_kid not in w.kingdoms[from_kid].wars:
                return
            if opts[dec.index].type == "accept":
                payer = None
                if info["tribute"]:
                    payer = from_kid if info["score"] > 0 else to_kid
                politics.make_peace(w, from_kid, to_kid, info["tribute"], payer)
            else:
                said = dec.speech or dec.reason
                w.log("peace_rejected", f"{w.kingdoms[to_kid].name}拒绝了{w.kingdoms[from_kid].name}的求和"
                      + (f"——{other.name}：「{said}」" if said else ""), a=from_kid, b=to_kid)
        self.ai.submit("peace_offer", "vote", (other, ctx, opts, None), done)
