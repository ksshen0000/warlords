"""Main loop. One tick = one in-game hour.

hourly  : neutral AI + lord tactics/orders -> movement -> sieges / raids
6-hourly: strategic decisions for lords that need one (brain; parallel for LLMs)
daily   : economy, politics, council (votes, rulings, proposals)
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

from . import economy, movement, npc, politics
from . import warfare as WF
from .brains.base import Brain, Decision
from .brains.rule import RuleBrain
from .model import Hero, World
from .options import Option, lord_options
from .rules import B

URGENT_REPLAN = ("wait", "patrol", "recruit", "attack", "raid", "hideout")


class Job:
    """One brain call: method name + args (the last arg is the option list)."""

    def __init__(self, method: str, args: tuple, payload=None):
        self.method, self.args, self.payload = method, args, payload


class Simulation:
    def __init__(self, world: World, brain: Brain, printer=None):
        self.w = world
        self.brain = brain
        self.fallback = RuleBrain(world.seed)
        self.print = printer

    # ------------------------------------------------------------------ api
    def step(self, hours: int = 1) -> list[dict]:
        start = len(self.w.events)
        for _ in range(hours):
            self._hour()
        new = self.w.events[start:]
        if self.print:
            for ev in new:
                self.print(ev)
        return new

    # ------------------------------------------------------------- the tick
    def _hour(self) -> None:
        w = self.w
        w.hour += 1
        npc.hourly(w)
        for p in list(w.parties.values()):
            if p.alive:
                movement.move(w, p, 1.0)
        WF.siege_tick(w)
        WF.raid_tick(w)
        if w.hour % B.time.decide_every_hours == 0:
            self._decisions()
        if w.hour % 24 == 0:
            economy.daily(w)
            politics.daily(w)
            self._council()

    # ---------------------------------------------------------- brains
    def _call(self, job: Job) -> Decision:
        opts = job.args[1] if job.method != "vote" else job.args[2]
        try:
            d = getattr(self.brain, job.method)(self.w, *job.args)
            if not (0 <= d.index < len(opts)):
                raise ValueError(f"选项编号越界：{d.index}")
            return d
        except Exception as e:   # a broken brain must never crash the world
            self.w.log("brain_error", f"AI 决策出错，改用规则 AI：{e}")
            return getattr(self.fallback, job.method)(self.w, *job.args)

    def _batch(self, jobs: list[Job]) -> list[Decision]:
        if self.brain.parallel and len(jobs) > 1:
            with ThreadPoolExecutor(max_workers=min(8, len(jobs))) as ex:
                return list(ex.map(self._call, jobs))
        return [self._call(j) for j in jobs]

    # --------------------------------------------------------- decisions
    def _needs_decision(self, h: Hero) -> bool:
        w = self.w
        p = w.hero_party(h.id)
        if h.captive_of or p is None or not p.alive:
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
        return o["age"] >= B.time.replan_after_hours

    def _decisions(self) -> None:
        w = self.w
        heroes = [h for h in w.heroes.values() if self._needs_decision(h)]
        if not heroes:
            return
        jobs = [Job("decide", (h, lord_options(w, h))) for h in heroes]
        for job, d in zip(jobs, self._batch(jobs)):
            h, opts = job.args
            self._apply_order(h, opts[d.index], d)

    def _apply_order(self, h: Hero, o: Option, d: Decision) -> None:
        w = self.w
        p = w.hero_party(h.id)
        if p is None:
            return
        old = p.order
        if d.speech:
            h.last_speech = d.speech
        if o.type == "gather_army":
            aid = politics.gather_army(w, h)
            p.order = None if aid else {"type": "wait", "target": None, "age": 0, "reason": d.reason}
            if aid and d.speech:
                w.log("speech", f"{h.name}：「{d.speech}」", hero=h.id)
            return
        if o.type == "disband_army":
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
        jobs = []
        for d in w.decisions.values():
            if d.resolved:
                continue
            ctx = politics.decision_context(w, d)
            opts = [Option("vote", o["id"], o["label"]) for o in d.options]
            for h in w.kingdom_heroes(d.kingdom, free_only=True):
                if h.id not in d.votes and h.id != w.kingdoms[d.kingdom].ruler:
                    jobs.append(Job("vote", (h, ctx, opts, None), payload=d))
        for job, dec in zip(jobs, self._batch(jobs)):
            h, _ctx, opts, _t = job.args
            job.payload.votes[h.id] = {"option": opts[dec.index].target,
                                       "weight": round(politics.vote_weight(h), 2), "reason": dec.reason}
            if dec.speech:
                h.last_speech = dec.speech
        # 2) the ruler rules once the deadline has passed
        for d in list(w.decisions.values()):
            if d.resolved or d.deadline > w.hour:
                continue
            k = w.kingdoms[d.kingdom]
            if not k.alive or (d.kind == "fief" and w.settlements[d.subject].faction != d.kingdom) or \
                    (d.kind in ("war", "peace") and (not w.kingdoms[d.subject].alive or
                                                     (d.kind == "war") == (d.subject in k.wars))):
                d.resolved = True
                continue
            r = w.heroes[k.ruler]
            opts = [Option("vote", o["id"], o["label"]) for o in d.options]
            dec = self._call(Job("vote", (r, politics.decision_context(w, d), opts, politics.tally(d))))
            choice = opts[dec.index].target
            politics.resolve(w, d, choice, dec.reason)
            if dec.speech:
                r.last_speech = dec.speech
            if d.kind == "peace" and choice == "yes":
                self._peace_offer(d.kingdom, d.subject)
        # 3) new proposals (each lord considers it about once a week)
        props = []
        for h in w.heroes.values():
            if h.captive_of or not w.kingdoms[h.kingdom].alive or h.influence < B.politics.peace_proposal_cost:
                continue
            if (sum(map(ord, h.id)) + w.day) % 7:
                continue
            opts = politics.proposal_options(w, h)
            if len(opts) > 1:
                props.append(Job("propose", (h, opts)))
        for job, dec in zip(props, self._batch(props)):
            h, opts = job.args
            if opts[dec.index].type != "none":
                politics.apply_proposal(w, h, opts[dec.index], dec.reason)

    def _peace_offer(self, from_kid: str, to_kid: str) -> None:
        w = self.w
        if to_kid not in w.kingdoms[from_kid].wars:
            return
        other = w.heroes[w.kingdoms[to_kid].ruler]
        opts, info = politics.peace_offer_options(w, from_kid, to_kid)
        ctx = (f"{w.kingdoms[from_kid].name}遣使求和。你方视角的战争分数{info['score']:+.0f}"
               f"（正数表示你方占优），已交战{w.day - w.kingdoms[to_kid].wars[from_kid]['since']}天。")
        dec = self._call(Job("vote", (other, ctx, opts, None)))
        if opts[dec.index].type == "accept":
            payer = None
            if info["tribute"]:
                payer = from_kid if info["score"] > 0 else to_kid
            politics.make_peace(w, from_kid, to_kid, info["tribute"], payer)
        else:
            said = dec.speech or dec.reason
            w.log("peace_rejected", f"{w.kingdoms[to_kid].name}拒绝了{w.kingdoms[from_kid].name}的求和"
                  + (f"——{other.name}：「{said}」" if said else ""), a=from_kid, b=to_kid)
