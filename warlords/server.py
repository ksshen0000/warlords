"""JSON-over-HTTP server so the Godot client can drive the simulation.

    python -m warlords.server --port 8765 [--brain rule|claude|openai|deepseek] [--seed 3]

Endpoints (all JSON):
    GET  /map                 static terrain (heights/biomes base64, rivers, roads) - fetch once per world
    GET  /state               dynamic world state
    GET  /events?since=N      events after index N
    POST /step   {"hours": 6} advance time; returns state + new events
    POST /reset  {"seed": 3, "brain": "rule"}   new world
    POST /reload              re-read rules/balance.toml and rules/doctrine.toml
"""
from __future__ import annotations

import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import rules
from .brains import BRAINS, make_brain
from .data import refresh_balance
from .scenario import default_world
from .sim import Simulation


class Game:
    def __init__(self, seed: int, brain: str, model: str | None, effort: str):
        self.lock = threading.Lock()
        self.model, self.effort, self.default_brain = model, effort, brain
        self.reset(seed, brain)

    def reset(self, seed: int, brain: str) -> None:
        # build the brain first so a missing API key leaves the current game intact
        b = make_brain(brain, seed, model=self.model if brain == self.default_brain else None, effort=self.effort)
        self.seed, self.brain_name = seed, brain
        self.world = default_world(seed)
        self.sim = Simulation(self.world, b)
        self._map_cache = None

    def map(self) -> dict:
        if self._map_cache is None:
            self._map_cache = json.dumps({"seed": self.seed, "map": self.world.map_dict()}).encode()
        return self._map_cache

    def snapshot(self) -> dict:
        return {"state": self.world.to_dict(), "events_total": len(self.world.events),
                "brain": self.brain_name, "seed": self.seed, "brains": BRAINS}


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
                if url.path == "/step":
                    hours = max(1, min(24 * 7, int(data.get("hours", 6))))
                    events = game.sim.step(hours)
                    snap = game.snapshot()
                    snap["events"] = events
                    return self._send(200, snap)
                if url.path == "/reset":
                    brain = data.get("brain", game.brain_name)
                    if brain not in BRAINS:
                        return self._send(400, {"error": f"unknown brain {brain}"})
                    try:
                        game.reset(int(data.get("seed", game.seed)), brain)
                    except Exception as e:  # e.g. missing API key / SDK
                        return self._send(500, {"error": str(e)})
                    return self._send(200, game.snapshot())
                if url.path == "/reload":
                    try:
                        rules.reload()
                        refresh_balance()
                    except Exception as e:  # malformed TOML
                        return self._send(500, {"error": f"规则文档有误：{e}"})
                    return self._send(200, {"ok": True})
            self._send(404, {"error": "not found"})

        def log_message(self, fmt, *args):
            pass

    return Handler


def main():
    ap = argparse.ArgumentParser(description="Warlords 模拟服务器（供 Godot 客户端连接）")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--seed", type=int, default=3)
    ap.add_argument("--brain", choices=BRAINS, default="rule")
    ap.add_argument("--model", default=None)
    ap.add_argument("--effort", default="low", choices=["low", "medium", "high"])
    args = ap.parse_args()
    game = Game(args.seed, args.brain, args.model, args.effort)
    srv = ThreadingHTTPServer((args.host, args.port), make_handler(game))
    print(f"Warlords 服务器已启动：http://{args.host}:{args.port}  （brain={args.brain}, seed={args.seed}）", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
