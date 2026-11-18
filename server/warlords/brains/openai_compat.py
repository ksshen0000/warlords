"""LLM brain for OpenAI-compatible Chat Completions APIs (OpenAI, DeepSeek, ...).

Uses JSON mode (response_format={"type": "json_object"}), which both OpenAI and
DeepSeek support; the expected shape is spelled out in the prompt and validated
in code. Any failure falls back to the rule brain.

Environment:
    OPENAI_API_KEY   / OPENAI_MODEL   / OPENAI_BASE_URL / OPENAI_REASONING_EFFORT (low; "none" to omit)
    DEEPSEEK_API_KEY / DEEPSEEK_MODEL / DEEPSEEK_BASE_URL
    <KEY>_FILE (e.g. DEEPSEEK_API_KEY_FILE) or server/local.toml [llm] key_file: read the key from a file
"""
from __future__ import annotations

import os

import openai

from .base import Brain, Decision
from ..rules import RULES
from .llm_common import SYSTEM_PROMPT, build_prompt, decide_prompt, parse_decision, propose_prompt, vote_prompt
from .rule import RuleBrain

PROVIDERS = {
    "openai": {
        "label": "OpenAI",
        "key_env": "OPENAI_API_KEY",
        "model_env": "OPENAI_MODEL",
        "default_model": "gpt-5-mini",
        "base_url_env": "OPENAI_BASE_URL",
        "default_base_url": None,
        "token_param": "max_completion_tokens",
        # picking one numbered option needs little reasoning; keeps each game day fast
        "extra": {"reasoning_effort": "low"},
        "effort_env": "OPENAI_REASONING_EFFORT",
    },
    "deepseek": {
        "label": "DeepSeek",
        "key_env": "DEEPSEEK_API_KEY",
        "model_env": "DEEPSEEK_MODEL",
        "default_model": "deepseek-flash",
        "base_url_env": "DEEPSEEK_BASE_URL",
        "default_base_url": "https://api.deepseek.com",
        "token_param": "max_tokens",
    },
}

JSON_INSTRUCTION = """
输出格式：只输出一个 JSON 对象，不要输出其他任何文字，例如：
{"choice": 3, "reason": "趁敌军主力在外，夺下空虚的关塞", "speech": "城门已开，随我冲锋！"}
其中 choice 是所选选项的编号（整数）。"""


def load_key(provider: str) -> str:
    """API key from the environment, a <KEY>_FILE env var, or local.toml's key_file."""
    cfg = PROVIDERS[provider]
    key = os.environ.get(cfg["key_env"], "").strip()
    path = os.environ.get(cfg["key_env"] + "_FILE")
    if not key and not path and RULES.llm_setting("provider") == provider:
        path = RULES.llm_setting("key_file")
    if not key and path:
        try:
            with open(os.path.expanduser(path), encoding="utf-8") as f:
                key = f.read().strip()
        except OSError as e:
            raise RuntimeError(f"无法读取 API key 文件 {path}：{e.strerror}") from None
    if not key:
        raise RuntimeError(f"未设置 {cfg['key_env']}（或 {cfg['key_env']}_FILE / local.toml 的 key_file）")
    return key


class OpenAICompatBrain(Brain):
    parallel = True

    def __init__(self, provider: str = "openai", model: str | None = None,
                 fallback: Brain | None = None, max_output_tokens: int = 3000):
        if provider not in PROVIDERS:
            raise ValueError(f"未知的提供商：{provider}")
        cfg = PROVIDERS[provider]
        api_key = load_key(provider)
        self.name = provider
        self.label = cfg["label"]
        configured = RULES.llm_setting("model") if RULES.llm_setting("provider") == provider else None
        self.model = model or os.environ.get(cfg["model_env"]) or configured or cfg["default_model"]
        self.client = openai.OpenAI(
            api_key=api_key,
            base_url=os.environ.get(cfg["base_url_env"]) or cfg["default_base_url"],
        )
        self.token_kw = {cfg["token_param"]: max_output_tokens, **cfg.get("extra", {})}
        if cfg.get("effort_env") and os.environ.get(cfg["effort_env"]):
            self.token_kw["reasoning_effort"] = os.environ[cfg["effort_env"]]
        if self.token_kw.get("reasoning_effort") == "none":
            del self.token_kw["reasoning_effort"]   # for models without reasoning
        if provider == "deepseek" and not RULES.llm_setting("thinking", False):
            self.token_kw["extra_body"] = {"thinking": {"type": "disabled"}}
        self.fallback = fallback or RuleBrain()
        self.calls = 0
        self.failures = 0
        self.disabled = False

    # ---- async interface used by the simulation's AI router
    def prompt(self, method: str, world, *args) -> str:
        return build_prompt(method, world, *args)

    def complete(self, prompt: str, n_options: int) -> Decision | None:
        """Thread-safe: talks to the API only, never touches the world."""
        return self._ask(prompt, n_options)

    def chat_json(self, system: str, user: str) -> dict | None:
        """One JSON-mode completion (used for free-form dialogue)."""
        import json
        if self.disabled:
            return None
        try:
            resp = self.client.chat.completions.create(
                model=self.model, response_format={"type": "json_object"},
                messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
                **self.token_kw)
            return json.loads(resp.choices[0].message.content or "")
        except (openai.APIError, ValueError, IndexError, TypeError) as e:
            self._warn(f"对话失败：{e}")
            return None

    def _warn(self, msg: str) -> None:
        if self.failures <= 3:
            print(f"[{self.name}] {msg}")

    def _ask(self, prompt: str, n_options: int) -> Decision | None:
        if self.disabled:
            return None
        self.calls += 1
        try:
            resp = self.client.chat.completions.create(
                model=self.model,
                messages=[
                    {"role": "system", "content": SYSTEM_PROMPT + JSON_INSTRUCTION},
                    {"role": "user", "content": prompt},
                ],
                response_format={"type": "json_object"},
                **self.token_kw,
            )
        except (openai.AuthenticationError, openai.PermissionDeniedError) as e:
            self.disabled = True
            print(f"[{self.name}] 认证失败，本局改用规则 AI：{e.message}")
            return None
        except openai.NotFoundError as e:
            self.disabled = True
            print(f"[{self.name}] 模型 {self.model} 不可用，本局改用规则 AI：{e.message}")
            return None
        except openai.RateLimitError:
            self.failures += 1
            self._warn("触发限流，本次改用规则 AI")
            return None
        except openai.APIStatusError as e:
            self.failures += 1
            self._warn(f"API 错误 {e.status_code}: {e.message}")
            return None
        except openai.APIConnectionError as e:
            self.failures += 1
            self._warn(f"连接失败: {e}")
            return None
        choice = resp.choices[0] if resp.choices else None
        if choice is None or choice.finish_reason == "length" or not choice.message.content:
            self.failures += 1
            self._warn("返回内容为空或被截断")
            return None
        dec = parse_decision(choice.message.content, n_options)
        if dec is None:
            self.failures += 1
            self._warn(f"无法解析返回内容：{choice.message.content[:80]}")
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
