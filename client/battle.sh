#!/usr/bin/env bash
# 单独启动 3D 野战（仿骑砍战团）。和 2D 大地图暂时分离，开发完毕后整合。
#   ./battle.sh                                 用 battle/sample_setup.json（周 vs 燕）
#   ./battle.sh --setup=/path/setup.json        自定义双方兵力 / 地形
#   ./battle.sh --terrain=hills --night         换地形、夜战
#   ./battle.sh --auto                          AI 代你作战（观战）
#   GPU=igpu ./battle.sh                        用核显（默认有 NVIDIA 驱动就用独显）
set -euo pipefail
project_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
godot_bin="${GODOT_BIN:-godot}"
# 双显卡笔记本：有 NVIDIA 驱动就用独显（PRIME 渲染卸载）；GPU=igpu 则用核显
if [ "${GPU:-auto}" != "igpu" ] && [ -e /proc/driver/nvidia/version ]; then
  export __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only
fi
command -v "$godot_bin" >/dev/null 2>&1 || godot_bin=godot4
exec "$godot_bin" --path "$project_dir" res://battle/battle.tscn -- "$@"
