"""LLM brain: Claude picks one of the legal options, in character.

The model only ever returns an option index (validated in code) plus a short
reason and an in-character line, so it can't break the simulation. Any API
error / refusal / bad output falls back to the rule brain.
"""
from __future__ import annotations

import anthropic

from .base import Brain, Decision
from .llm_common import (DECISION_SCHEMA, SYSTEM_PROMPT, build_prompt, decide_prompt, parse_decision,
                         propose_prompt, vote_prompt)
from .rule import RuleBrain


class ClaudeBrain(Brain):
    name = "claude"
    parallel = True

    def __init__(self, model: str = "claude-opus-5-5", effort: str = "low",
                 fallback: Brain | None = None):
        self.client = anthropic.Anthropic()
        self.model = model
        self.effort = effort
        self.fallback = fallback or RuleBrain()
        self.calls = 0
        self.failures = 0
        self.disabled = False

    # ---- async interface used by the simulation's AI router
    def prompt(self, method: str, world, *args) -> str:
        return build_prompt(method, world, *args)

    def complete(self, prompt: str, n_options: int) -> Decision | None:
        return self._ask(prompt, n_options)

    def chat_json(self, system: str, user: str) -> dict | None:
        import json
        try:
            resp = self.client.messages.create(
                model=self.model, max_tokens=4000, system=system,
                output_config={"effort": self.effort},
                messages=[{"role": "user", "content": user}])
            text = next((b.text for b in resp.content if b.type == "text"), "")
            text = text.strip().removeprefix("```json").removeprefix("```").removesuffix("```")
            return json.loads(text)
        except (anthropic.APIError, ValueError) as e:
            print(f"[claude] 对话失败：{e}")
            return None

    def _ask(self, prompt: str, n_options: int) -> Decision | None:
        if self.disabled:
            return None
        self.calls += 1
        try:
            resp = self.client.beta.messages.create(
                model=self.model,
                max_tokens=16000,
                betas=["server-side-fallback-2026-07-01"],
                fallbacks="default",
                system=[{"type": "text", "text": SYSTEM_PROMPT,
                         "cache_control": {"type": "ephemeral"}}],
                output_config={"effort": self.effort,
                               "format": {"type": "json_schema", "schema": DECISION_SCHEMA}},
                messages=[{"role": "user", "content": prompt}],
            )
        except (anthropic.AuthenticationError, anthropic.PermissionDeniedError) as e:
            self.disabled = True
            print(f"[claude] 认证失败，本局改用规则 AI：{e.message}")
            return None
        except anthropic.RateLimitError:
            self.failures += 1
            return None
        except anthropic.APIStatusError as e:
            self.failures += 1
            if self.failures <= 3:
                print(f"[claude] API 错误 {e.status_code}: {e.message}")
            return None
        except anthropic.APIConnectionError as e:
            self.failures += 1
            if self.failures <= 3:
                print(f"[claude] 连接失败: {e}")
            return None
        if resp.stop_reason in ("refusal", "max_tokens"):
            self.failures += 1
            return None
        text = next((b.text for b in resp.content if b.type == "text"), "")
        dec = parse_decision(text, n_options)
        if dec is None:
            self.failures += 1
        return dec

    def decide(self, world, hero, options):
        return (self._ask(decide_prompt(world, hero, options), len(options))
                or self.fallback.decide(world, hero, options))

    def propose(self, world, hero, options):
        return (self._ask(propose_prompt(world, hero, options), len(options))
                or self.fallback.propose(world, hero, options))

    def vote(self, world, hero, context, options, tally):
        return (self._ask(vote_prompt(world, hero, context, options, tally), len(options))
                or self.fallback.vote(world, hero, context, options, tally))
