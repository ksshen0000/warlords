from .base import Brain, Decision
from .rule import RuleBrain

BRAINS = ["rule", "claude", "openai", "deepseek"]


def make_brain(name: str, seed: int = 0, model: str | None = None, effort: str = "low") -> Brain:
    """Create a brain by name. LLM brains fall back to the rule brain on any failure."""
    fallback = RuleBrain(seed)
    if name == "rule":
        return fallback
    if name == "claude":
        from .claude import ClaudeBrain
        return ClaudeBrain(model=model or "claude-opus-5-5", effort=effort, fallback=fallback)
    if name in ("openai", "deepseek"):
        from .openai_compat import OpenAICompatBrain
        return OpenAICompatBrain(provider=name, model=model, fallback=fallback)
    raise ValueError(f"未知的 AI 类型：{name}")


__all__ = ["BRAINS", "Brain", "Decision", "RuleBrain", "make_brain"]
