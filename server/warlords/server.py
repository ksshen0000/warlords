"""JSON-over-HTTP server so the Godot client can drive the simulation.

    python -m warlords.server --port 8765 [--tier 3] [--seed 3]

Endpoints (all JSON):
    GET  /map                   static terrain (fetch once per world)
    GET  /state                 dynamic world state + player view + AI status
    GET  /events?since=N        events after index N
    POST /step    {"hours": 1}  advance time (refused while a player menu is open)
    POST /player/move  {"kind": "point", "pos": [x, y]} | {"kind": "place"|"party", "id": ...}
    POST /player/act   {"action": "...", ...}     choose a menu option
    POST /player/talk  {"hero": id, "text": "..."} speak to a lord (LLM reply)
    POST /reset   {"seed": 3, "tier": 3}        new world
    POST /config  {"tier": 2}                   change how much the AI is involved
    POST /reload                                re-read rules/balance.toml, doctrine.toml, ai.toml
"""
from __future__ import annotations

import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import player, rules
from .ai import AIRouter
from .brains import make_llm
from .data import refresh_balance
from .rules import RULES
from .scenario import default_world
from .sim import Simulation


class Game:
    def __init__(self, seed: int, tier: int, provider: str | None, model: str | None):
        self.lock = threading.Lock()
        self.provider = provider or RULES.llm_setting("provider", "deepseek")
        self.model = model
        self.llm, self.llm_error = None, ""
        try:
            self.llm = make_llm(self.provider, model)
        except Exception as e:      # no key / SDK missing: run with the rule AI only
            self.llm_error = str(e)
            print(f"[ai] LLM 不可用，只使用规则 AI：{e}", flush=True)
        self.reset(seed, tier)

    def reset(self, seed: int, tier: int) -> None:
        old = getattr(self, "ai", None)
        if old:
            old.shutdown()
        self.seed = seed
        self.world = default_world(seed)
        self.ai = AIRouter(self.world, tier, self.llm, wait=False)
        self.sim = Simulation(self.world, self.ai)
        self._map_cache = None

    def map(self) -> bytes:
        if self._map_cache is None:
            self._map_cache = json.dumps({"seed": self.seed, "map": self.world.map_dict()}).encode()
        return self._map_cache

    def snapshot(self) -> dict:
        ai = self.ai.describe()
        ai["error"] = self.llm_error
        return {"state": self.world.to_dict(), "player": player.view(self.world), "ai": ai,
                "events_total": len(self.world.events), "seed": self.seed}


def make_handler(game: Game):
    class Handler(BaseHTTPRequestHandler):
        def _send_raw(self, code: int, body: bytes) -> None:
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        def _send(self, code: int, payload: dict) -> None:
            self._send_raw(code, json.dumps(payload, ensure_ascii=False).encode("utf-8"))

        def _body(self) -> dict:
            n = int(self.headers.get("Content-Length") or 0)
            if not n:
                return {}
            try:
                return json.loads(self.rfile.read(n) or b"{}")
            except json.JSONDecodeError:
                return {}

        def do_GET(self):
            url = urlparse(self.path)
            with game.lock:
                if url.path == "/map":
                    return self._send_raw(200, game.map())
                if url.path == "/state":
                    return self._send(200, game.snapshot())
                if url.path == "/events":
                    since = int(parse_qs(url.query).get("since", ["0"])[0])
                    ev = game.world.events
                    return self._send(200, {"events": ev[since:], "events_total": len(ev)})
            self._send(404, {"error": "not found"})

        def do_POST(self):
            url = urlparse(self.path)
            data = self._body()
            with game.lock:
                w = game.world
                start = len(w.events)
                result = None
                if url.path == "/step":
                    game.sim.step(max(1, min(24 * 7, int(data.get("hours", 1)))))
                elif url.path == "/player/move":
                    result = player.move(w, data)
                elif url.path == "/player/act":
                    result = player.act(w, str(data.get("action", "")), data)
                elif url.path == "/player/talk":
                    result = player.talk(w, game.ai, str(data.get("hero", "")), str(data.get("text", "")))
                elif url.path == "/reset":
                    try:
                        game.reset(int(data.get("seed", game.seed)), int(data.get("tier", game.ai.tier)))
                    except Exception as e:
                        return self._send(500, {"error": str(e)})
                    return self._send(200, game.snapshot())
                elif url.path == "/config":
                    game.ai.set_tier(int(data.get("tier", game.ai.tier)))
                elif url.path == "/reload":
                    try:
                        rules.reload()
                        refresh_balance()
                        game.ai.set_tier(game.ai.tier)
                    except Exception as e:  # malformed TOML
                        return self._send(500, {"error": f"规则文档有误：{e}"})
                else:
                    return self._send(404, {"error": "not found"})
                game.ai.poll()
                snap = game.snapshot()
                snap["events"] = w.events[start:]
                if result is not None:
                    snap["result"] = result
                return self._send(200, snap)

        def log_message(self, fmt, *args):
            pass

    return Handler


def main():
    ap = argparse.ArgumentParser(description="Warlords 模拟服务器（供 Godot 客户端连接）")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--seed", type=int, default=3)
    ap.add_argument("--tier", type=int, default=None, help="AI 档位（见 rules/ai.toml），默认取文档中的 default_tier")
    ap.add_argument("--provider", default=None, help="deepseek / openai / claude（默认取 ai.toml / local.toml）")
    ap.add_argument("--model", default=None)
    args = ap.parse_args()
    tier = args.tier if args.tier is not None else int(RULES.ai.get("default_tier", 0))
    game = Game(args.seed, tier, args.provider, args.model)
    srv = ThreadingHTTPServer((args.host, args.port), make_handler(game))
    llm = f"{game.llm.label} {game.llm.model}" if game.llm else "无（规则 AI）"
    print(f"Warlords 服务器已启动：http://{args.host}:{args.port}  （AI 档位 {game.ai.tier}「{game.ai.tier_name}」，"
          f"LLM：{llm}，seed={args.seed}）", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        game.ai.shutdown()


if __name__ == "__main__":
    main()
