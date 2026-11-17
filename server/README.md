# Warlords — AI 原生的领主沙盒（v2）

类骑砍的战略层模拟：连续的大陆地图、王国与领主、商队与村民、土匪与赏金猎人、佣兵团，
议会政治与外交。**规则写在文档里，领主由 LLM 扮演**；Godot 客户端见 `../client`。

## 运行

```bash
python3 -m warlords --days 120 --seed 3            # 命令行观看（规则 AI，零依赖）
python3 -m warlords.server --port 8765             # 给 Godot 客户端用的服务器

uv venv && uv pip install -e '.[llm]'              # LLM 依赖
OPENAI_API_KEY=...    .venv/bin/python -m warlords --brain openai   --days 30 --verbose
DEEPSEEK_API_KEY=...  .venv/bin/python -m warlords --brain deepseek --days 30 --verbose
ANTHROPIC_API_KEY=... .venv/bin/python -m warlords --brain claude   --days 30 --verbose
```

| AI | 默认模型 | 换模型 |
|---|---|---|
| `openai` | `gpt-5-mini`（reasoning_effort=low） | `--model` / `OPENAI_MODEL`；`OPENAI_REASONING_EFFORT` |
| `deepseek` | `deepseek-v4-flash` | `--model` / `DEEPSEEK_MODEL`；`DEEPSEEK_BASE_URL` |
| `claude` | `claude-opus-5-5`（effort=low） | `--model` |

LLM 出错（认证、限流、无法解析）时自动退回规则 AI，模拟不会中断。

## 规则即文档（`rules/`）

| 文件 | 内容 | 谁读它 |
|---|---|---|
| `balance.toml` | 所有数值：军饷、税收、攻城速度、城墙加成、民心、俘虏、议会成本、土匪刷新……以及规则 AI 的权重 | 引擎、规则 AI |
| `doctrine.toml` | 领主行事准则：均势、避免多线作战、僵持时议和、解围、攻城需兵力优势、劫掠的代价、分封公平……可按王国/领主分别设定 | LLM 领主（写进提示词） |
| `units.toml` | 地形、货物、文化与兵种树、土匪类型 | 引擎 |
| `world.toml` | 王国、领主人设与性格、初始关系、战争、封地、地名 | 引擎、LLM |

- 改 `balance.toml` / `doctrine.toml` 后，在 Godot 里点「重载规则」（或 `POST /reload`）立即生效，不用重开。
- 改 `units.toml` / `world.toml` 需要开新局。
- 准则是「倾向」：LLM 领主会结合性格、处境、记忆权衡；**合法性**（能做什么）始终由引擎保证——LLM 只能从选项列表里选编号。

## 世界

- **地图**：程序生成的大陆（海岸、山脉、丘陵、森林、雪原、针叶林、沙漠、沙丘、草原、沼泽、河流），
  道路按地形寻路修建、过河处是桥。部队在连续地图上行军，速度受地形、道路、渡河、规模、骑兵比例影响；
  每个地点预计算「流场」，上百支部队寻路也很快。时间精度 1 小时。
- **据点**：城镇（市场、繁荣、民心、粮仓、守军、民兵、城墙）、城堡、村庄（特产、劫掠）、匪巢。
- **部队**：领主（可组成军团）、商队（低买高卖、交关税）、村民（运货进城）、土匪（按地形分五类）、
  赏金猎人（剿匪、押俘虏领赏）、佣兵团（受雇于王国）。
- **战斗**：4 文化 × 9 兵种的兵种树；步克骑、射克步、骑克射；地形与文化加成；运气；阵亡/受伤；俘虏与战利品。
- **内政**：影响力；议会提案（宣战/议和）→ 领主投票（按影响力加权）→ 君主裁决（可违背多数，有代价）；
  新征服城池由议会分封；无封地、被冷落的领主会叛逃；民心低落的异族城池会起义回归故国。
- **外交**：战争分数、带岁贡的和约、停战期、赎回被俘领主、雇佣佣兵；一国独大时其他国家倾向联手（均势）。

## 代码结构

```
warlords/
  rules.py      读取 rules/*.toml（B = 数值，RULES = 全部，支持热重载）
  data.py       由文档生成兵种、货物、地形表
  terrain.py    大陆生成、河流、选址、道路、导航网格、流场（缓存于 ~/.cache/warlords）
  model.py      World / Kingdom / Hero / Party / Settlement / Army / Decision
  scenario.py   开局：封地、守军、市场、商队、土匪、猎人、佣兵
  movement.py   连续移动、追击、逃跑
  npc.py        每小时：中立势力 AI + 领主临场反应与命令执行（规则）
  battle.py     战斗结算；warfare.py：会战/援军/俘虏/攻城/劫掠/剿匪
  economy.py    生产、市场、商队贸易、税收军饷、招募升级
  politics.py   议会、军团、赎金、和约、叛逃、民心与起义、佣兵合同
  options.py    领主的合法战略选项（附带决策所需的情报）
  sim.py        主循环（每小时 / 每 6 小时战略决策 / 每日议会）
  brains/       rule.py 规则 AI；llm_common.py 提示词（含准则）；claude.py；openai_compat.py
  server.py     HTTP 服务：/map /state /step /reset /reload /events
```

## 路线图（AI 原生）

1. ✅ 规则即文档；LLM 领主为主（混合：战略/外交/投票用 LLM，临场反应用规则）
2. ⏳ 领主之间自由谈判与密谋（LLM 对话 → 结盟、背叛、交换条件）
3. ⏳ AI 生成内容：编年史与传闻、领主家族与生平、事件；AI 生成新世界（world.toml）
4. ⏳ 自然语言交互：玩家与领主对话、谈判、下令

（v1 的点线图版本不在本仓库中。）
