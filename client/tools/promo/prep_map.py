import json, sys, urllib.request
U = sys.argv[1]; days = int(sys.argv[2])
op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def req(path, body=None):
    r = urllib.request.Request(U + path, data=None if body is None else json.dumps(body).encode(),
                               headers={"Content-Type": "application/json"})
    return json.loads(op.open(r).read())
def menu():
    return req("/state")["player"].get("menu")
def clear():
    for _ in range(50):
        m = menu()
        if not m: return
        ids = [o for o in m["options"] if o["enabled"]]
        pref = {"create": None, "battle": "autoresolve", "assault_ready": "assault"}
        o = next((x for x in ids if x["id"] == pref.get(m["type"])), None) or ids[-1 if m["type"] not in ("create",) else 0]
        body = {"action": o["id"]}
        if "choice" in o: body["choice"] = o["choice"]
        req("/player/act", body)
clear()
for d in range(days):
    clear(); req("/step", {"hours": 24})
clear()
st = req("/state"); print("day", st["state"]["day"], "wars", {k: list(v["wars"]) for k, v in st["state"]["kingdoms"].items()})
