#!/usr/bin/env bash
# 录制并剪辑宣传片（带合成的背景音乐）。需要 Godot 4.7、Python 3 + Pillow、ffmpeg；配乐另需 numpy + scipy。
#   client/tools/promo/make_promo.sh [输出.mp4=~/Videos/liuminshuai_promo.mp4]
#   同时输出竖版（1080×1920，手机用）：<输出>_vertical.mp4，两版共用同一段配乐
# 流程：Movie Maker 逐帧录三段素材（大地图、野战、攻城）→ compose.py 按 cut.json 剪辑、加字幕和片头片尾 → mp4。
# 录制时会开一个 1920×1080 的 Godot 窗口，录完自动关闭。AI 战斗每次不完全一样，镜头不理想就重录或改 cut.json 的时间段。
set -euo pipefail
here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
client="$here/../.."
server="$client/../server"
out="${1:-$HOME/Videos/liuminshuai_promo.mp4}"
work="$(mktemp -d)"
port=8799
py=python3; [ -x "$server/.venv/bin/python" ] && py="$server/.venv/bin/python"

# 录制分辨率：临时的 override.cfg（结束时删掉，不影响平时游戏的窗口）
printf '[display]\nwindow/size/viewport_width=1920\nwindow/size/viewport_height=1080\n' > "$client/override.cfg"
srv=""
cleanup() { rm -f "$client/override.cfg"; [ -n "$srv" ] && kill "$srv" 2>/dev/null || true; }
trap cleanup EXIT

rec() {   # rec 名字 场景 参数…
  mkdir -p "$work/$1"
  godot --path "$client" --write-movie "$work/$1/f.png" --fixed-fps 30 "$2" -- "${@:3}" > "$work/$1.log" 2>&1
  echo "录好 $1：$(ls "$work/$1" | wc -l) 帧"
}

rec field res://tools/promo/promo_battle.tscn --setup=res://tools/promo/field.json --auto --promo=field
rec siege res://tools/promo/promo_battle.tscn --setup=res://tools/promo/siege.json --auto --promo=siege

# 大地图：起一个离线服务器，建好角色、推进 40 天，让队伍从洛阳出发去长安
(cd "$server" && exec "$py" -m warlords.server --port $port --seed 3 --tier 0) > "$work/srv.log" 2>&1 &
srv=$!
until curl -s --noproxy '*' -o /dev/null "http://127.0.0.1:$port/state"; do sleep 0.2; done
python3 "$here/prep_map.py" "http://127.0.0.1:$port" 40
post() { curl -s --noproxy '*' -X POST -H 'Content-Type: application/json' -d "$2" "http://127.0.0.1:$port$1" > /dev/null; }
post /player/move '{"kind":"place","id":"zhao1"}'
for _ in $(seq 6); do post /step '{"hours":24}'; done        # 走到洛阳
post /player/act '{"action":"leave"}'
post /player/move '{"kind":"place","id":"zhao2"}'          # 出发去长安
rec map res://tools/promo/promo_map.tscn --server=http://127.0.0.1:$port

python3 "$here/compose.py" "$here/cut.json" "$work" "$work/silent.mp4"
python3 "$here/compose.py" "$here/cut.json" "$work" "$work/silent_v.mp4" --vertical
out_v="${out%.mp4}_vertical.mp4"

# 背景音乐（music.py 现场合成，需要 numpy + scipy；MUSIC_PY 可指定装了它们的 python）
mpy="${MUSIC_PY:-python3}"
if "$mpy" -c "import numpy, scipy" 2>/dev/null; then
  len=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$work/silent.mp4")
  "$mpy" "$here/music.py" "$work/bgm_raw.wav" "$len" "$here/cut.json"
  ffmpeg -y -loglevel error -i "$work/bgm_raw.wav" -af "highpass=f=32,loudnorm=I=-16:TP=-1.5:LRA=11" -ar 44100 "$work/bgm.wav"
  for pair in "silent.mp4:$out" "silent_v.mp4:$out_v"; do
    ffmpeg -y -loglevel error -i "$work/${pair%%:*}" -i "$work/bgm.wav" -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k \
      -shortest -movflags +faststart "${pair#*:}"
  done
else
  echo "没有 numpy/scipy，输出无配乐版本（pip install numpy scipy 后可加配乐）"
  mv "$work/silent.mp4" "$out"
  mv "$work/silent_v.mp4" "$out_v"
fi
echo "横版：$out"
echo "竖版：$out_v"
rm -rf "$work"
