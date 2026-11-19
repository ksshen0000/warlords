"""Offline rule-based brain: scores every option using the lord's personality."""
from __future__ import annotations

import random

from .. import troops as T
from ..economy import party_limit
from ..model import World
from ..options import Option, army_power
from ..data import PEDIGREE_WEIGHT, RAID_BIAS, SIEGE_BIAS
from ..politics import fief_share, hegemon, pedigree_rank
from ..rules import B
from .base import Brain, Decision


class RuleBrain(Brain):
    name = "rule"

    def __init__(self, seed: int = 0):
        self.rng = random.Random(seed * 17 + 3)

    # ------------------------------------------------------------- orders
    def _score(self, w: World, h, o: Option) -> float:
        t = h.traits
        p = w.hero_party(h.id)
        my = army_power(w, p)
        n = T.healthy(p.troops)
        i = o.info
        d = i.get("days", 0)
        k = w.kingdoms[h.kingdom]
        if o.type == "recruit":
            need = max(0.0, 1 - T.total(p.troops) / party_limit(w, h.id))
            return need * 12 + (5 if n < 35 else 0) + 0.2 * i["count"] - d * 1.0
        if o.type == "defend":
            if i["sieged"]:
                ratio = my / max(1.0, i["enemy_power"])
                if ratio < 0.5:
                    return -2 + t["honor"] - d
                return 9 + 2 * t["honor"] + (5 if i["own_fief"] else 0) + 3 * min(ratio, 1.5) - d * 0.8
            return 0.6 + (1.5 if i["own_fief"] else 0) - d * 0.5
        if o.type == "besiege":
            ratio = (my + 0.8 * i["ally_power"]) / max(1.0, i["defense"])
            s = (min(ratio, 2.2) - 1.15 + 0.25 * t["aggression"] - 0.2 * t["caution"]) * 7
            s += 3 if i["ally_power"] else 0
            s += 0.8 * t["greed"] if i["kind"] == "town" else 0
            danger = i["threat"] / max(1.0, my + i["ally_power"])
            s -= max(0.0, danger - 0.7) * (5 + t["caution"])
            s += min(5.0, (w.day - k.last_offensive) / 6)
            # near_before_far: a town far from our own lands can't be held or relieved
            s -= B.ai.far_target_weight * max(0.0, i.get("from_home", 0.0) - B.ai.far_target_free_days)
            s += SIEGE_BIAS.get(h.kingdom, 0.0)
            return s - d * 0.7
        if o.type == "raid":
            s = 2 + 1.2 * t["aggression"] + t["greed"] - 2.5 * t["honor"] - d * 0.8 + RAID_BIAS.get(h.kingdom, 0.0)
            if i["threat"] > my * 0.8:
                s -= 6
            if i["militia"] * 1.3 > my:
                s -= 5
            return s
        if o.type == "attack":
            ratio = my / max(1.0, i["enemy_power"])
            kind = i["kind"]
            if kind in ("lord", "merc"):
                s = (min(ratio, 3) - 1.4 + 0.25 * t["aggression"]) * 5
            elif kind == "caravan":
                s = (3 + 1.5 * t["greed"] - 1.5 * t["honor"]) if ratio > 1.5 else -5
            elif kind == "villager":
                s = (1 + t["greed"] - 2 * t["honor"]) if ratio > 2 else -5
            else:  # bandits
                s = 2 + t["honor"] + (min(ratio, 4) - 1.5) * 2
            return s - d * 1.0
        if o.type == "hideout":
            ratio = my / max(1.0, i["enemy_power"])
            return (min(ratio, 3) - 1.5) * 2 + 0.7 * t["honor"] - 1 - d * 0.8
        if o.type == "patrol":
            return 1 + 0.8 * i["bandits"] + 0.5 * t["honor"] - d * 0.5
        if o.type == "sell":
            return 3 + i["prisoners"] / 10 - d * 0.5
        if o.type == "rest":
            return i["wounded"] * 12 - d * 0.5
        if o.type == "caravan":
            return 3 + 2 * t["greed"] - d * 0.4
        if o.type == "gather_army":
            return 4 + 1.5 * t["aggression"] - 0.5 * t["caution"] + (2 if k.ruler == h.id else 0)
        if o.type == "disband_army":
            return 6 if i["cohesion"] < 25 else -5
        return 0.3  # wait

    def decide(self, w, hero, options):
        scored = [(self._score(w, hero, o) + self.rng.uniform(0, 1.0), i) for i, o in enumerate(options)]
        return Decision(max(scored)[1])

    # ---------------------------------------------------------- politics
    def _war_desire(self, w: World, h, info: dict, target: str) -> float:
        """doctrine: avoid_multi_front, balance_of_power (weights in balance.toml [ai])."""
        a = B.ai
        t = h.traits
        k = w.kingdoms[h.kingdom]
        # being stronger helps, but a much weaker victim is not endlessly more attractive (no dogpiling)
        s = (min(info["ratio"], a.war_ratio_cap) - 1) * a.war_strength_weight + 0.6 * t["aggression"] - info["rel"] / 25
        s += 0.3 * info["border"] - 1.5
        s += min(2.5, (w.day - k.last_offensive) / a.war_peace_boredom_days) - a.war_per_extra_front * info["wars"]
        share = fief_share(w, target)
        others = sum(1 for e in w.kingdoms[target].wars if e != k.id)
        s -= a.war_dogpile_penalty * others          # lips_and_teeth: don't pile onto a beaten realm
        s -= a.war_distance_weight * max(0.0, info.get("far", 0.0) - a.war_distance_free_days)   # near_before_far
        if share > a.hegemon_share:
            s += a.hegemon_war_bonus * (share - a.hegemon_share) * 3
        return s

    def _peace_desire(self, w: World, h, info: dict, enemy: str) -> float:
        """doctrine: peace_when_stalemate, loser_seek_peace, avoid_multi_front, balance_of_power."""
        a = B.ai
        t = h.traits
        k = w.kingdoms[h.kingdom]
        s = info["days"] * a.peace_per_war_day - 0.5 * t["aggression"] + 0.5 * t["caution"]
        s += -info["score"] * a.peace_loss_eagerness if info["score"] < 0 else -info["score"] * a.peace_win_greed
        s += (1 if info["ratio"] < 0.8 else 0) + a.peace_per_extra_front * (len(k.wars) - 1)
        hg = hegemon(w)
        if hg and hg not in (k.id, enemy):
            s += a.hegemon_peace_bonus
        if hg == enemy:
            s -= a.hegemon_peace_bonus
        return s

    def propose(self, w, hero, options):
        best, best_s = 0, 1.0
        for i, o in enumerate(options):
            if o.type == "propose_war":
                s = self._war_desire(w, hero, o.info, o.target)
                if s > best_s and self.rng.random() < 0.35:
                    best, best_s = i, s
            elif o.type == "propose_peace":
                s = self._peace_desire(w, hero, o.info, o.target)
                if s > max(best_s, 1.2) and self.rng.random() < 0.5:
                    best, best_s = i, s
        return Decision(best)

    def vote(self, w, hero, context, options, tally):
        t = hero.traits
        ids = [o.target for o in options]
        if ids and ids[0] in ("yes", "no"):
            d = self._find_decision(w, hero, context)
            want = 0.0
            if d is not None:
                k = w.kingdoms[hero.kingdom]
                other = d.subject
                my, their = w.kingdom_strength(k.id), w.kingdom_strength(other)
                if d.kind == "war":
                    info = {"ratio": my / max(1, their), "rel": hero.rel(w.kingdoms[other].ruler), "wars": len(k.wars),
                            "border": 1}
                    want = self._war_desire(w, hero, info, other) + 1.0
                else:
                    war = k.wars.get(other, {"since": w.day, "score": 0})
                    info = {"days": w.day - war["since"], "score": war["score"], "ratio": my / max(1, their)}
                    want = self._peace_desire(w, hero, info, other)
                if d.proposer:
                    want += hero.rel(d.proposer) / 40
            choice = 0 if want > 0.3 else 1
            if tally is not None:
                choice = self._rule(hero, ids, tally, choice)
            return Decision(choice)
        if ids and ids[0] in ("accept", "reject") or (options and options[0].type == "accept"):
            k = w.kingdoms[hero.kingdom]
            enemy = options[0].target
            war = k.wars.get(enemy, {"since": w.day, "score": 0})
            my, their = w.kingdom_strength(k.id), w.kingdom_strength(enemy)
            days = w.day - war["since"]
            tribute = int(min(220, abs(war["score"]) / 2.5)) if abs(war["score"]) > 30 else 0
            gain = tribute if war["score"] > 0 else -tribute      # we receive tribute when winning
            info = {"days": days, "score": war["score"], "ratio": my / max(1, their)}
            s = self._peace_desire(w, hero, info, enemy) + gain * B.ai.peace_tribute_weight
            s += (1 - my / max(1, their)) * 1.5
            return Decision(0 if s > B.ai.peace_accept_threshold else 1)
        # fief: candidates are hero ids
        best, best_s = 0, -1e9
        for i, hid in enumerate(ids):
            n_fiefs = len(w.fiefs_of(hid))
            if hid == hero.id:
                # grabbing yet another town when you already hold two makes enemies at court
                # a ruler has the crown's revenue: he hands conquests to his vassals more readily than a lord would
                base = B.ai.fief_ruler_self if w.kingdoms[hero.kingdom].ruler == hero.id else 8
                s = base + 3 * t["greed"] - 1.5 * t["honor"] - B.ai.fief_self_per_fief * max(0, n_fiefs - 1)
            else:
                s = hero.rel(hid) / 10 + (3 + t["honor"] if "功臣" in options[i].label else 0)
                s -= n_fiefs * 0.8
                if n_fiefs == 0 and "功臣" in options[i].label:
                    s += B.ai.fief_landless_contributor     # a landless man who bled for it deserves it
                if "当面请封" in options[i].label:
                    s += B.ai.fief_request_weight          # asked the ruler in person (Warband: ask for the fief)
            # 门第: in 周 a high-born claimant is favoured, in 燕/蜀 it hardly matters
            s += B.pedigree.vote_weight * PEDIGREE_WEIGHT.get(hero.kingdom, 0.5) * (pedigree_rank(w, hid) - 2)
            s += self.rng.uniform(0, 1)
            if s > best_s:
                best, best_s = i, s
        if tally is not None:
            best = self._rule(hero, ids, tally, best)
        return Decision(best)

    def _rule(self, hero, ids, tally, own_choice: int) -> int:
        majority = max(range(len(ids)), key=lambda i: tally.get(ids[i], 0))
        if own_choice == majority:
            return own_choice
        t = hero.traits
        p = 0.3 + 0.15 * max(t["aggression"], t["greed"]) - 0.15 * t["honor"]
        return own_choice if self.rng.random() < p else majority

    @staticmethod
    def _find_decision(w, hero, context):
        for d in w.decisions.values():
            if not d.resolved and d.kingdom == hero.kingdom and d.kind in ("war", "peace") \
                    and w.kingdoms[d.subject].name in context:
                return d
        return None
