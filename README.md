# Warlords · 战旗领主

一个 **AI 原生**的类骑马与砍杀战略沙盒：程序生成的大陆上，王国、领主、商队、村民、土匪、
赏金猎人和佣兵团各自行动；领主由 LLM（OpenAI / DeepSeek / Claude）或规则 AI 扮演，
在议会里提案、投票、宣战议和、分封、叛逃。游戏规则、数值平衡和领主的行事准则都写在结构化文档里。

![大地图](client/docs/screens/v2_overview.png)

## 快速开始

需要 Python 3.11+ 和 Godot 4.7。

```bash
cd client && ./play.sh                       # 自动启动模拟服务器（规则 AI）并打开 Godot 客户端
```

用 LLM 扮演领主：

```bash
cd server && uv venv && uv pip install -e '.[llm]'
cd ../client
OPENAI_API_KEY=...   BRAIN=openai   ./play.sh
DEEPSEEK_API_KEY=... BRAIN=deepseek ./play.sh
```

只看命令行模拟：`cd server && python3 -m warlords --days 120 --seed 3`

## 目录

| 目录 | 内容 |
|---|---|
| [`server/`](server/README.md) | Python 模拟服务器：地图生成、行军、战斗、经济、政治、AI 大脑、HTTP 接口 |
| [`server/rules/`](server/rules) | 规则即文档：`balance.toml` 数值、`doctrine.toml` 领主准则、`units.toml` 兵种货物地形、`world.toml` 王国与领主 |
| [`client/`](client/README.md) | Godot 4 客户端：着色器渲染的大地图、详情/诸国/议会面板、编年史与战报 |

改 `server/rules/balance.toml` 或 `doctrine.toml` 后，在客户端点「重载规则」即可生效，无需重开。

## 路线图

1. ✅ 规则即文档；LLM 领主为主（战略、外交、投票用 LLM，行军中的临场反应用规则）
2. ⏳ 领主之间自由谈判与密谋
3. ⏳ AI 生成内容：编年史、传闻、领主生平、新世界
4. ⏳ 自然语言交互：玩家与领主对话、谈判
