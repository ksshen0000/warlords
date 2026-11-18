"""Prompt building shared by every LLM brain (Claude, OpenAI, DeepSeek...).

The world is described in plain Chinese, the relevant doctrine entries from
rules/doctrine.toml are attached, and the model returns a numbered choice.
"""
from __future__ import annotations

import json

from .. import troops as T
from ..common import dist
from ..model import Hero, World
from ..options import Option
from ..politics import fief_share
from ..data import KIND_NAMES, PEDIGREE, PEDIGREE_NAMES, TITLES
from ..rules import RULES
from .base import Decision

SYSTEM_PROMPT = """你在一个以中国南北朝为原型的架空乱世战略沙盒中扮演一位将军（或君主），替他/她做决定。

这个世界：
- 一统天下的周朝在诸王之乱中崩塌，北方诸部攻陷洛阳，周室南渡建康，据大江以守。如今周、燕、赵、凉、蜀、柔六国并立，坞堡林立，流民遍野。
- 各国有城、关塞和村落。将军率领部曲在连续的地图上行军：道路快、森林沼泽慢、小河难渡、山地不可通行。大江横贯南北，只能经几处渡口过江，大军渡江很慢；蜀所在的盆地四面环山，只有几处隘口进出。
- 战斗自动结算，有随机性：兵力、兵种（步兵克骑兵、射手克步兵、骑兵克射手）、兵种等级、地形和统帅能力都有影响。
- 攻城要先围困数日造攻城器械，城墙让守军更强；敌方援军可能赶来解围。新攻下的城池由朝议推举分封，君主拥有最终裁决权。
- 异族统治、饥荒、过度扩张会让城池民心低落，民心过低会叛乱、回归故国。
- 战败的将军可能被俘，需要赎金或越狱才能脱身；部队每天要发军饷，欠饷会有逃兵；封地和商队提供收入。
- 朝议中，将军可以提议宣战或议和并表态；将军之间有好感度，长期受冷落的将军可能叛投他国——乱世之中，倒戈并不稀奇。
- 流寇、山贼、江贼、马贼、商队、村民、游侠和义从也在地图上活动。
- 这是架空世界：不要提及真实历史人物、真实民族名或真实朝代（如「东晋」「前燕」），古地名可以照常使用。

你的任务：
- 完全以这个角色的身份、性格、处境、记忆和人际关系来思考，而不是追求冷冰冰的最优解。
- 「行事准则」是你所在世界的常识和王国传统，通常应当遵循；违背时要有符合人物性格的理由。
- 只能从给出的编号选项中选一个。
- reason：一句话说明你的考虑（中文，40字内）。
- speech：这个角色此刻会说的一句台词（中文，30字内，半文半白、符合人物身份与口吻，不用现代口语）。
"""

DECISION_SCHEMA = {
    "type": "object",
    "properties": {
        "choice": {"type": "integer", "description": "所选选项的编号"},
        "reason": {"type": "string"},
        "speech": {"type": "string"},
    },
    "required": ["choice", "reason", "speech"],
    "additionalProperties": False,
}

TRAIT_NAMES = {"aggression": "好战", "caution": "谨慎", "honor": "荣誉", "greed": "贪婪"}
ORDER_NAMES = {"recruit": "招募", "besiege": "围攻", "defend": "驻防", "attack": "追击", "raid": "劫掠",
               "hideout": "剿匪", "patrol": "巡逻", "sell": "出售俘虏", "rest": "休整", "caravan": "组建商队",
               "wait": "待命", "retreat": "撤退", "follow": "随军"}


def _where(w: World, pos) -> str:
    s = min((s for s in w.settlements.values() if s.kind != "hideout"), key=lambda s: dist(s.pos, pos))
    d = dist(s.pos, pos)
    terrain = w.terrain.biome_at(*pos)
    from ..data import TERRAIN
    return f"{s.name}{'城内' if d < 3 else '附近'}（{TERRAIN[terrain][1]}）"


def describe_hero(w: World, h: Hero) -> str:
    k = w.kingdoms[h.kingdom]
    ruler = w.heroes[k.ruler]
    traits = "，".join(f"{TRAIT_NAMES[t]}{v:+d}" for t, v in h.traits.items())
    title = TITLES.get(k.id, "君主")
    who = (f"你是{k.name}的{title}（本国君主）。" if ruler.id == h.id else
           f"你效忠于{k.name}{title}{ruler.name}（你对其好感{h.rel(ruler.id):+d}）。")
    who += f"门第：{PEDIGREE_NAMES.get(PEDIGREE.get(h.id, 'mid'), '次门')}。"
    lines = [f"今天是第{w.day}天。", f"你是【{h.name}】，{h.persona}", f"性格：{traits}；统御{h.tactics}。{who}",
             f"金币{h.gold:.0f}，影响力{h.influence:.0f}，声望{h.renown}。"]
    p = w.hero_party(h.id)
    if p:
        order = p.order
        task = ORDER_NAMES.get(order["type"], order["type"]) if order else "无"
        if order and order.get("target") in w.settlements:
            task += f"（{w.settlements[order['target']].name}）"
        lines.append(f"部队：{T.healthy(p.troops)}人（伤员{T.wounded(p.troops)}），{T.describe_classes(p.troops)}；"
                     f"精锐构成：{T.describe(p.troops, with_wounded=False)[:80]}。战力{w.party_power(p):.0f}。"
                     f"俘虏{sum(p.prisoners.values())}人。位置：{_where(w, p.pos)}。当前任务：{task}。")
        if p.army and p.army in w.armies:
            a = w.armies[p.army]
            lines.append(f"你{'统领' if a.leader == h.id else '隶属于'}{w.heroes[a.leader].name}的军团"
                         f"（成员{len(a.members) + 1}人，军心{a.cohesion:.0f}）。")
        near = []
        for q in w.parties.values():
            if q.alive and q is not p and not q.inside and dist(q.pos, p.pos) < 120 and w.hostile(p, q) \
                    and q.kind in ("lord", "merc", "bandit", "player"):
                who = "玩家（一支流亡队伍的首领）" if q.kind == "player" else (w.heroes[q.hero].name if q.hero else q.name)
                near.append(f"{who}（{T.healthy(q.troops)}人，"
                            f"战力{w.party_power(q):.0f}，约{dist(q.pos, p.pos):.0f}里）")
        if near:
            lines.append("附近的敌对部队：" + "；".join(near[:4]))
    fiefs = w.fiefs_of(h.id)
    if fiefs:
        fs = []
        for s in fiefs:
            raided = sum(1 for v in s.villages if w.settlements[v].raided_until > w.hour)
            fs.append(f"{s.name}（{KIND_NAMES[s.kind]}，守军{T.healthy(s.garrison)}，"
                      f"繁荣{s.prosperity:.0f}，民心{s.loyalty:.0f}，存粮{s.food:.0f}"
                      + (f"，被劫村庄{raided}" if raided else "")
                      + (f"，【正被{w.kingdoms[s.siege['kingdom']].name}围攻】" if s.siege else "") + "）")
        lines.append("你的封地：" + "；".join(fs))
    else:
        lines.append("你目前没有封地。")
    if h.caravans:
        lines.append(f"你拥有{len(h.caravans)}支商队。")
    rels = sorted(((v, o) for o, v in h.relations.items() if o in w.heroes and v), reverse=True)
    picked = rels[:3] + [r for r in rels[-3:] if r not in rels[:3]]
    if picked:
        lines.append("人际：" + "，".join(f"{w.heroes[o].name}({w.kingdoms[w.heroes[o].kingdom].name}){v:+d}"
                                        for v, o in picked))
    lines.append("近期记忆：\n" + ("\n".join(f"  - {m}" for m in h.memory[-8:]) or "  - （暂无）"))
    lines.append("天下大势：\n" + overview(w, h.kingdom))
    return "\n".join(lines)


def overview(w: World, me: str) -> str:
    out = []
    for k in w.kingdoms.values():
        if not k.alive:
            out.append(f"- {k.name}：已覆灭")
            continue
        wars = "、".join(f"{w.kingdoms[e].name}(交战{w.day - v['since']}天，战争分数{v['score']:+.0f})"
                        for e, v in k.wars.items()) or "无"
        forts = w.kingdom_settlements(k.id, ("town", "castle"))
        extra = ""
        if k.tributes:
            extra = "，向" + "、".join(f"{w.kingdoms[x].name}支付岁贡{t['amount']}金/日" for x, t in k.tributes.items())
        out.append(f"- {k.name}{'（本国）' if k.id == me else ''}：君主{w.heroes[k.ruler].name}，城池{len(forts)}座"
                   f"（占天下{fief_share(w, k.id):.0%}），实力{w.kingdom_strength(k.id):.0f}，交战：{wars}{extra}")
    open_ = [d for d in w.decisions.values() if not d.resolved and d.kingdom == me]
    if open_:
        from ..politics import decision_context
        out.append("本国朝议待决议题：" + "；".join(decision_context(w, d) for d in open_))
    return "\n".join(out)


def doctrine_text(h: Hero, use: str) -> str:
    rules = RULES.doctrine_for(h.kingdom, h.id, use)
    if not rules:
        return ""
    return "行事准则：\n" + "\n".join(f"- 【{r.get('topic', '')}】{r['text']}" for r in rules)


def options_txt(options: list[Option]) -> str:
    return "\n".join(f"{i}. {o.label}" for i, o in enumerate(options))


def decide_prompt(w: World, h: Hero, options: list[Option]) -> str:
    return (f"{describe_hero(w, h)}\n\n{doctrine_text(h, 'decide')}\n\n"
            f"你接下来要做什么？可选行动：\n{options_txt(options)}")


def propose_prompt(w: World, h: Hero, options: list[Option]) -> str:
    return (f"{describe_hero(w, h)}\n\n{doctrine_text(h, 'propose')}\n\n"
            f"本周朝议。你要在朝议上提出什么建言吗？（提案会消耗影响力）\n{options_txt(options)}")


def vote_prompt(w: World, h: Hero, context: str, options: list[Option], tally: dict | None) -> str:
    if tally is not None:
        t = "，".join(f"{o.label.split('（')[0]}：{tally.get(o.target, 0):.1f}票" for o in options)
        ask = (f"{context}\n朝议表态结果（按影响力加权）：{t}。\n你是君主，由你做最终裁决。"
               f"违背多数意见会损失影响力并让持异议的将军不满。")
    else:
        ask = f"{context}\n请表态："
    return f"{describe_hero(w, h)}\n\n{doctrine_text(h, 'vote')}\n\n{ask}\n{options_txt(options)}"


def build_prompt(method: str, w: World, *args) -> str:
    """Prompt for a brain call; must run on the simulation thread (it reads the world)."""
    if method == "decide":
        return decide_prompt(w, *args)
    if method == "propose":
        return propose_prompt(w, *args)
    if method == "vote":
        return vote_prompt(w, *args)
    raise ValueError(method)


def parse_decision(text: str, n_options: int) -> Decision | None:
    """Parse {"choice", "reason", "speech"} JSON; None if invalid."""
    text = (text or "").strip()
    if text.startswith("```"):
        text = text.strip("`").removeprefix("json").strip()
    try:
        data = json.loads(text)
        idx = int(data["choice"])
    except (ValueError, KeyError, TypeError):
        return None
    if not 0 <= idx < n_options:
        return None
    return Decision(idx, reason=str(data.get("reason", ""))[:80], speech=str(data.get("speech", ""))[:60])

