#!/usr/bin/env bash
# 启动 Python 模拟服务器（如未运行）+ Godot 客户端；退出游戏时自动关闭本脚本启动的服务器。
#   ./play.sh                       AI 档位取 server/rules/ai.toml 的 default_tier；LLM 取 ai.toml / server/local.toml
#   TIER=0 ./play.sh                只用规则 AI（不调用 LLM）
#   TIER=2 PROVIDER=openai ./play.sh
#   SEED=7 ./play.sh                换一张地图
set -euo pipefail
project_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
sim_dir="${WARLORDS_DIR:-$project_dir/../server}"
port="${PORT:-8765}"
godot_bin="${GODOT_BIN:-godot}"
command -v "$godot_bin" >/dev/null 2>&1 || godot_bin=godot4

py="python3"
[ -x "$sim_dir/.venv/bin/python" ] && py="$sim_dir/.venv/bin/python"

args=(--port "$port" --seed "${SEED:-3}")
[ -n "${TIER:-}" ] && args+=(--tier "$TIER")
[ -n "${PROVIDER:-}" ] && args+=(--provider "$PROVIDER")
[ -n "${MODEL:-}" ] && args+=(--model "$MODEL")

server_pid=""
if ! curl -s --noproxy "*" -o /dev/null "http://127.0.0.1:$port/state"; then
  echo "启动模拟服务器（port=$port）…"
  (cd "$sim_dir" && exec "$py" -m warlords.server "${args[@]}") &
  server_pid=$!
  trap '[ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null' EXIT
  for _ in $(seq 100); do
    curl -s --noproxy "*" -o /dev/null "http://127.0.0.1:$port/state" && break
    sleep 0.1
  done
fi
"$godot_bin" --path "$project_dir" "$@" -- --server="http://127.0.0.1:$port"
