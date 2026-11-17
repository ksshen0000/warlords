#!/usr/bin/env bash
# 启动 Python 模拟服务器（如未运行）+ Godot 客户端；退出游戏时自动关闭本脚本启动的服务器。
#   ./play.sh                    规则 AI
#   BRAIN=claude ./play.sh       Claude 领主（需要 ANTHROPIC_API_KEY）
set -euo pipefail
project_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
sim_dir="${WARLORDS_DIR:-$HOME/Projects/warlords}"
port="${PORT:-8765}"
brain="${BRAIN:-rule}"
godot_bin="${GODOT_BIN:-godot}"
command -v "$godot_bin" >/dev/null 2>&1 || godot_bin=godot4

py="python3"
[ -x "$sim_dir/.venv/bin/python" ] && py="$sim_dir/.venv/bin/python"

server_pid=""
if ! curl -s -o /dev/null "http://127.0.0.1:$port/state"; then
  echo "启动模拟服务器（brain=$brain, port=$port）…"
  (cd "$sim_dir" && exec "$py" -m warlords.server --port "$port" --brain "$brain") &
  server_pid=$!
  trap '[ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null' EXIT
  for _ in $(seq 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/state" && break
    sleep 0.1
  done
fi
"$godot_bin" --path "$project_dir" "$@" -- --server="http://127.0.0.1:$port"
