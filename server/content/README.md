# 内容（content/）

发行版的游戏**不连 LLM**：领主决策用规则 AI，台词、差事文本、剧情事件都从这里的数据文件读取，完全离线。
LLM 只在开发时用来**写和打磨**这些内容（`server/tools/author.py`），审阅后才进入这个目录。
直连 LLM 的档位（`rules/ai.toml` 的 1–4 档）仍然保留，作为可选项；默认是 0 档。

| 文件 | 内容 | 谁读 |
|---|---|---|
| `dialogue_*.toml` | 与将军、君主交谈的台词（按话题分文件） | `warlords/dialogue.py`、`warlords/content.py` |
| `spec/dialogue.toml` | 台词需求表：每个话题在什么情形下需要什么台词、各国口吻 | `tools/author.py` |
| `drafts/` | LLM 写的草稿和审稿记录（`*.review.md`），审阅后用 `accept` 并入 | 人 |

## 台词格式

```toml
[[line]]
topic = "news"                    # 话题
culture = "zhao"                  # 可选：只有这一国的人说（不写 = 通用）
when = ["at_war", "!winning"]     # 可选：全部条件成立才可能被选中
priority = 1                      # 可选：情形重叠时优先
text = "吃了点亏罢了，{enemy}的账，某记着。"
```

选择规则：在条件都成立的台词里，取最具体的一组（先比 `priority`，再比条件个数，再比是否分国家），
从中按（将军、话题、日期）固定的种子挑一句，所以同一天重复问不会变来变去。说话人是君主时，
只要有君主专用台词（条件里有 `ruler`），就只从君主台词里挑。

条件里能用的事实见 `warlords/dialogue.py` 的 `facts()`：好感 `rel`、玩家身份 `status`（free/merc/vassal）、
`ruler`、`same_realm`、`player_enemy`、`met`、`renown`、性格 `honor/greed/aggression/caution`、门第 `pedigree`、
`at_war`、`winning`、`besieging`、`in_army`、`army_leader`、`ruler_rel`（与君主的关系）……

占位符：`{name}` 说话人自己、`{kingdom}` 说话人的国家、`{ruler}` `{ruler_title}` 他的君主、`{culture}`、
`{here}` 说话人此刻所在的地方，以及话题专用的 `{enemy}` `{siege}` `{fief}` `{target}` `{place}`。

## 写台词的流程

```bash
cd server
.venv/bin/python -m tools.author gen --topic news            # LLM 按需求表写草稿 → content/drafts/
.venv/bin/python -m tools.author review dialogue_news         # LLM 当编辑逐句审：保留 / 改写 / 删除（记录在 .review.md）
#   然后人工过目草稿：删掉不好的、改措辞
.venv/bin/python -m tools.author check                       # 占位符、长度、禁用词（真实朝代、民族、人物，现代用语）
.venv/bin/python -m tools.author accept dialogue_news         # 并入 content/
.venv/bin/python -m tools.author stats                       # 每一格（话题 × 情形 × 口吻）有多少句
```

要加新情形：在 `spec/dialogue.toml` 加一格（`topic`、`when`、`brief`），`gen --topic X --cond Y` 只写新的格子。
要加新话题：`warlords/dialogue.py` 的 `QUESTIONS` 和 `topics()`、`say()`，再在需求表里写它的格子。

编辑时发现的常见问题（已写进写作和审稿的提示）：许诺游戏里没有的事（「随我出征」「价钱好说」）、
编造和玩家的往事、占位符含义用错（`{name}` 是说话人自己）、君主的自称（皇帝「朕」，王与公「孤/本王」，可汗「我」）。
