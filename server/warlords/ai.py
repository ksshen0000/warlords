"""AI router: decides per call whether the LLM or the rule AI answers (by tier,
see rules/ai.toml) and runs LLM calls asynchronously.

Prompts are built on the simulation thread (they read the world); only the
network request runs in the thread pool. When an answer arrives, its callback
runs on the simulation thread and re-validates the choice against the world as
it is *now* (the game kept running while the lord was thinking).
"""
from __future__ import annotations

from concurrent.futures import Future, ThreadPoolExecutor

from .brains.base import Decision
from .brains.rule import RuleBrain
from .rules import B, RULES


class AIRouter:
    def __init__(self, world, tier: int, llm=None, wait: bool = False):
        self.w = world
        self.rule = RuleBrain(world.seed)
        self.llm = llm
        self.wait = wait                      # block until answers arrive (batch / CLI mode)
        self.jobs: list[tuple[Future, str, tuple, object, str]] = []
        self.pool = ThreadPoolExecutor(max_workers=int(RULES.llm_setting("max_concurrency", 8))) if llm else None
        self.stats = {"llm": 0, "rule": 0, "fallback": 0}
        self.set_tier(tier)

    # ------------------------------------------------------------ config
    def set_tier(self, tier: int) -> None:
        cfg = RULES.tier(tier)
        self.tier = int(tier) if str(tier) in RULES.ai.get("tiers", {}) else int(RULES.ai.get("default_tier", 0))
        self.tier_name = cfg.get("name", str(self.tier))
        self.components = set(cfg.get("components", []))
        self.overrides = dict(cfg.get("overrides", {}))

    def setting(self, key: str):
        """Balance value under [time], possibly overridden by the current tier."""
        return self.overrides.get(key, B.time[key])

    def uses_llm(self, component: str) -> bool:
        return self.llm is not None and component in self.components

    def describe(self) -> dict:
        return {"tier": self.tier, "tier_name": self.tier_name, "components": sorted(self.components),
                "llm": getattr(self.llm, "label", None), "model": getattr(self.llm, "model", None),
                "pending": len(self.jobs), "stats": dict(self.stats),
                "tiers": {k: {"name": v.get("name"), "description": v.get("description", "")}
                          for k, v in RULES.ai.get("tiers", {}).items()}}

    # ---------------------------------------------------------- dispatch
    def submit(self, component: str, method: str, args: tuple, on_done) -> None:
        """Answer `method(*args)` and call on_done(Decision) on the simulation thread."""
        if self.uses_llm(component):
            options = args[2] if method == "vote" else args[1]
            prompt = self.llm.prompt(method, self.w, *args)
            fut = self.pool.submit(self.llm.complete, prompt, len(options))
            self.jobs.append((fut, method, args, on_done, component))
            return
        self.stats["rule"] += 1
        on_done(getattr(self.rule, method)(self.w, *args))

    def poll(self, block: bool = False) -> None:
        """Deliver finished LLM answers (on the simulation thread)."""
        if not self.jobs:
            return
        keep = []
        for job in self.jobs:
            fut, method, args, on_done, _component = job
            if not block and not fut.done():
                keep.append(job)
                continue
            try:
                d = fut.result()
            except Exception:
                d = None
            if isinstance(d, Decision):
                self.stats["llm"] += 1
            else:
                self.stats["fallback"] += 1
                d = getattr(self.rule, method)(self.w, *args)
            on_done(d)
        self.jobs = keep

    def flush(self) -> None:
        """In wait mode, block until every answer (and any follow-up job) is delivered."""
        while self.wait and self.jobs:
            self.poll(block=True)

    def shutdown(self) -> None:
        if self.pool:
            self.pool.shutdown(wait=False, cancel_futures=True)
