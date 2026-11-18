from .base import Brain, Decision
from .rule import RuleBrain

PROVIDERS = ["deepseek", "openai", "claude"]


def make_llm(provider: str, model: str | None = None, effort: str = "low"):
    """Create an LLM brain (raises RuntimeError if the key is missing)."""
    if provider == "claude":
        from .claude import ClaudeBrain
        return ClaudeBrain(model=model or "claude-opus-5-5", effort=effort, fallback=None)
    if provider in ("openai", "deepseek"):
        from .openai_compat import OpenAICompatBrain
        return OpenAICompatBrain(provider=provider, model=model, fallback=None)
    raise ValueError(f"未知的 LLM 提供商：{provider}")


__all__ = ["PROVIDERS", "Brain", "Decision", "RuleBrain", "make_llm"]
