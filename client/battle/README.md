# 野战（3D，仿骑砍战团）

独立场景（不依赖 `scripts/` 里的任何东西），既能单独运行，也已接入大地图的遭遇战和匪巢。

```bash
cd client
./battle.sh                          # battle/sample_setup.json：周（你）vs 燕（拓延骁）
./battle.sh --terrain=hills --night  # 换地形（plains/meadow/steppe/hills/forest/taiga/desert/dunes/snow/marsh/mountain）、夜战
./battle.sh --auto                   # AI 代你作战（观战）
./battle.sh --setup=my.json --out=result.json
battle/tests/run_battles.sh 6        # 回归：无画面并行跑 6 场，打印胜负/伤亡/战斗统计
```

## 操作（按战团）

| 键 | 作用 |
|---|---|
| 鼠标 | 转视角 |
| **移动鼠标的方向 + 按住左键** | 举起武器（可以一直蓄着），**松开**挥出。鼠标往上 = 劈砍，往左/右 = 横砍，往下 = 刺 |
| **右键（按住）** | 格挡。方向同样由鼠标移动决定：挡左边来的就往左。盾牌任何方向都能挡，还能挡箭 |
| 准星旁的小三角 | 当前出招方向（金色 = 已举起，外圈 = 蓄满）；格挡时变蓝 |
| 弓/弩 | 按住左键拉弓（准星圈越收越小 = 越准），松开放箭；移动、骑马会变不准。弩射完要上弦 |
| WASD | 走（Shift 慢走）。**骑马时**：W 催马、S 勒马、A/D 转向；马有惯性 |
| 滚轮 | 换武器（弓 → 主武器 → 副武器） |
| 1 / 2 / 3 / 0 | 选中步兵 / 射手 / 骑兵 / 全军 |
| F1–F9 | 原地驻守 · 跟我来 · 冲锋 · 就地站住 · 撤退 · 前进十步 · 后退十步 · 靠拢 · 散开 |
| Tab | 撤离战场（附近有敌人时不行）；你倒下后 = 让部下加速打完 |
| Esc | 释放鼠标 |

## 规则从哪来

全部在 `server/rules/battle.toml`（和大地图同一套「规则即文档」），客户端用一个小 TOML 解析器直接读：

- `[combat]` 出招/挥出/收势时间、磕碰（太近打不出伤害）、**速度加成**（骑兵冲锋、迎着敌人挥砍更疼）、格挡角度、硬直、击倒
- `[armor]` 砍/刺/钝三种伤害对护甲的减免
- `[weapons.*]` `[shields.*]` 刀、骨朵、长斧、长矛、戟、马槊（**端枪冲刺**：马速够快自动平端）、弓、强弓、骑弓、弩
- `[loadout.*]` 每个兵种的配装：默认表 + 文化覆盖（周：弩与戟；燕：甲骑具装；蜀：藤牌与连弩；柔：骑射手……），土匪、中立按兵种 id
- `[horse]` 马速、惯性、转向、冲撞（撞倒步兵、陷进人群会被拖慢）
- `[morale]` 伤亡过半后逐个溃逃，等级越高越坚定，主将在场更稳
- `[ai]` 反应时间、格挡概率（随等级）、围攻上限、射程、骑兵冲过后多远回马
- `[battle]` 同时在场人数（战团的 battle size），其余作为援军分波上场

兵种名、等级、类别来自 `server/rules/units.toml`，id 和大地图服务器完全一致（`zhou_inf3`、`yan_cav4`……）。

## 和大地图的接入（已接入）

像战团一样：在大地图上遭遇敌军时，菜单里有两个选择——

- **亲自率军冲锋 / 亲自上阵迎战（进入战场）**：切到 3D 战场，你和部下（以及附近赶来助战的友军）对阵敌军；
  打完点「返回大地图」，每个兵种的阵亡、重伤、溃逃都会写回大地图，俘虏、战利品、名望、擒获敌将照常结算。
- **让部下进攻 / 迎战（自动结算）**：和以前一样由大地图直接结算。

攻打**匪巢**同样可以「亲自带精兵步战突入」：带上你最精锐的十几个人（`balance.toml [bandits] hideout_team`），全体下马。

你本人和有名有姓的将军在战场上只会被打昏，不会阵亡（同战团）。你亲自上阵时的装备取决于家世
（`world.toml [backgrounds.*] battle_loadout`：流民帅是长矛藤牌，高门子弟是马、刀、盾、弓）。

流程：服务器生成 setup（双方兵力按自动结算同样的规则召集，地形取所在格子，昼夜取当前时辰）→ 菜单类型 `battle`
→ 客户端把大地图藏起来、在同一个窗口里加载 `battle.gd`（`embedded = true`）→ 打完 `closed(result)` →
`POST /player/battle` → 服务器 `warfare.apply_battle_result`（或匪巢的 `apply_hideout_result`）。

单独运行（不连大地图）仍然可以：`./battle.sh`，读 `--setup=` 的 JSON。

### setup / result 格式

输入 `setup`：

```json
{"terrain": "hills", "seed": 7, "night": false, "player_side": 0, "dismounted": false,
 "sides": [
   {"name": "你的部队", "color": "#3f6fb0",
    "hero": {"name": "你", "player": true, "troop": "zhou_cav3", "loadout": {"melee": ["sword"], "shield": "round", "horse": "horse", "armor": 26}},
    "troops": {"zhou_inf2": 14, "zhou_arc2": 12}},
   {"name": "拓延骁的部曲", "color": "#4f7fd8", "hero": {"name": "拓延骁", "troop": "yan_cav4"},
    "troops": {"yan_cav3": 12, "yan_inf2": 12}}]}
```

输出：

```json
{"winner": 1, "how": "", "player_side": 0, "time": 96,
 "sides": [{"name": "...", "hero": "wounded",
            "troops": {"zhou_inf2": {"killed": 4, "wounded": 5, "routed": 0, "fine": 5}}}, ...],
 "stats": {"swings": 560, "blocked": 82, "arrows": 400, "couch": 30, ...}}
```

`how = "retreat"` 表示玩家撤离（敌军不追俘你，但你留在战场上的伤亡照算）。

## 实现

| 文件 | 内容 |
|---|---|
| `scripts/battle.gd` | 部署、援军、命令与阵型、士气溃逃、战斗结算（格挡判定、速度加成、护甲）、箭矢、结果 |
| `scripts/agent.gd` | 单个士兵：状态机（举起/挥出/收势/格挡/硬直/倒地）、方向姿态（和画面共用，所见即所击）、骑马惯性、端枪、冲撞 |
| `scripts/ai.gd` | 士兵 AI：选目标（围攻上限）、出招方向（避开身边友军）、反应式格挡、射手提前量与抛物线补偿、不往友军里射、骑兵冲阵回马、骑射绕圈 |
| `scripts/player_ctrl.gd` | 第三人称相机、按键、鼠标方向出招 |
| `scripts/field.gd` | 高度图地形（按大地图地形类型着色）、树、天空 |
| `scripts/rig.gd` | 程序生成的人和马（方块风格，占位美术） |
| `scripts/toml.gd` `scripts/rules.gd` | TOML 读取、兵种表与配装 |

士兵不用物理引擎（120 人的胶囊体互相碰撞太慢）：位置按速度积分、贴地，重叠时由网格推开。整场约 6 ms/帧（120 人）。

## 还没做

攻城战（城墙、云梯）、跳跃、踢击、第一人称、马匹单独存在（骑手落马后马跑开）、伤害部位动画、音效、正式美术、
战场概览（Backspace）、开局部署阶段、天气、远程武器的弹药补给、按兵种的「骑砍式」AI 编队细节（盾墙、楔形）。
