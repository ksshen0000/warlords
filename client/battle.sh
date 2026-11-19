#!/usr/bin/env bash
# 单独启动 3D 野战（仿骑砍战团）。和 2D 大地图暂时分离，开发完毕后整合。
#   ./battle.sh                                 用 battle/sample_setup.json（周 vs 燕）
#   ./battle.sh --setup=/path/setup.json        自定义双方兵力 / 地形
#   ./battle.sh --terrain=hills --night         换地形、夜战
#   ./battle.sh --auto                          AI 代你作战（观战）
set -euo pipefail
project_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
godot_bin="${GODOT_BIN:-godot}"
command -v "$godot_bin" >/dev/null 2>&1 || godot_bin=godot4
exec "$godot_bin" --path "$project_dir" res://battle/battle.tscn -- "$@"
