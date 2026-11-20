class_name TownWalk
extends Battle
## Walking round a town, castle or village (Warband's "take a walk around the streets"). Built on the
## battle engine — the same soldiers, controls and camera — with the town's layout (town.gd) instead of
## an open field and nobody to fight. People stand where the town menu's business is done: the market
## clerk among the stalls, volunteers in the square, the arena master, the gaoler; the lord sits in his
## hall and the innkeeper and the ransom broker are in the tavern (rooms you walk into through their doors).
##
## Walk up to someone and press F. Conversations happen right there (the campaign's own menu panel, talking
## to the server directly): speak with the lord, ask for work, recruit, trade at the stall, sell prisoners.
## Only what needs the map (a bout in the arena, resting, leaving) ends the walk and hands over to it.
## Tab or the gate: back to the town menu.
##
## setup (from the server, warlords/walk.py):
##   {"town": {kind, seed, walls, roof}, "place", "subtitle", "night", "sides": [{hero, color}],
##    "crowd": {troop, n, color, guards, guard_n, guard_color},
##    "spots": [{action, label, enabled, hint, where, npc, role, troop, color, armed, hero?, choice?}],
##    "volunteers": [troop ids], "rumors": [str], "rooms": ["hall", "inn"],
##    "_server": URL (added by the client), "room": "hall" | "inn" (a room inside, added by walk.gd)}

const PlayerMenuScript := preload("res://scripts/player_menu.gd")
const ApiScript := preload("res://scripts/api.gd")
const TALK_RANGE := 2.7
## menu options carried out right here in the street (the rest go back to the map)
const IN_SCENE := ["talk", "quests", "recruit", "sell_prisoners", "deliver", "captive", "trade", "manage", "smith"]

var lay: TownLayout
var room := ""                    # "" = the streets; "hall" / "inn" = inside
var npcs: Array = []              # [{agent, spots: [spot], home, yaw, idle?, patron?}]
var strollers: Array = []         # [{agent, goal: Vector3, wait: float}]
var _near: Dictionary = {}        # what is in reach: an npc entry, {"gate"}, {"enter": room}, {"exit"}
var _ui: CanvasLayer
var _title: Label
var _prompt: RichTextLabel
var _say: Label
var _say_t := 0.0
var _rng := RandomNumberGenerator.new()
# conversations
var _api: Node = null
var _panel: PanelContainer
var _busy := false
var _session := ""                # "" / "menu" / "trade"
var _talk_to: Agent = null
# rooms
var _street: TownWalk = null      # set on a room: the streets to go back to
var _holder: Node = null          # the streets' parent while we are inside

const CHATTER := {
	"town": ["这几日米价又涨了，城外的路不太平。", "听说北边的关隘添了兵，怕是又要打仗。", "擂台那边今天热闹，有人押了十金。",
		"城里的豪族在招护院，管饭。", "守将大人治城还算宽厚，就是赋税重了些。", "渡口那边来了一船盐，掮客们都去抢了。"],
	"castle": ["这堡里吃的都是军粮，外人少来。", "夜里巡城要打起精神，上回有人摸到墙根下。", "守将练兵狠，弟兄们腿都跑细了。"],
	"village": ["今年的收成还凑合，就怕过兵。", "前些日子有匪寇在山那边晃，村里的后生都拿起了锄头。", "坞堡的主人说，再乱就把大家都收进堡里去。",
		"你们是官军？可别踩了田。"],
	"inn": ["再来一壶！今天不醉不归。", "这酒掺了水，喝着没劲。", "掌柜的，记账，下回一并还。", "外头又在征丁了，躲一躲是一躲。"],
	"hall": ["将军正在议事，说话小声些。", "府里的规矩大，莫要乱走。"],
}


func _ready() -> void:
	peaceful = true
	if embedded:
		_apply_room(preset_setup)
	_rng.seed = int(preset_setup.get("seed", 7)) + room.hash() % 1000
	super()
	if hud:
		hud.visible = false
	if room != "":
		_dim_for_indoors()
		ctrl.dist = 2.6
	_build_ui()
	var url := str(setup.get("_server", ""))
	if url != "":
		_api = ApiScript.new()
		_api.base_url = url
		add_child(_api)
		_api.response.connect(_on_api)
		_api.failed.connect(func(_k, msg):
			_busy = false
			_toast("服务器：" + msg))
	if OS.get_cmdline_user_args().has("--topdown"):
		var cam := Camera3D.new()
		add_child(cam)
		cam.position = Vector3(0, 150, 60) if room == "" else Vector3(0, 30, 16)
		cam.look_at(Vector3(0, 0, 0))
		cam.current = true
		set_meta("topdown", cam)


func _parse_args() -> void:
	super()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--room="):                     # standalone: start inside the hall / the tavern
			setup["room"] = a.substr(7)
	_apply_room(setup)


func _apply_room(st: Dictionary) -> void:
	room = str(st.get("room", ""))
	if room != "" and st.has("town"):
		var t: Dictionary = st.town.duplicate()
		t["base"] = str(t.get("base", t.get("kind", "town")))
		t["kind"] = room + "_room"
		st["town"] = t


## Indoors: no sun or fog, a warm dim ambient (the lamps do the rest).
func _dim_for_indoors() -> void:
	for c in field.get_children():
		if c is DirectionalLight3D:
			c.light_energy = 0.0
			c.shadow_enabled = false
		elif c is WorldEnvironment:
			var e: Environment = c.environment
			e.fog_enabled = false
			e.ambient_light_color = Color("7a6650")
			e.ambient_light_energy = 0.55
			e.background_mode = Environment.BG_COLOR
			e.background_color = Color("120d09")


# ------------------------------------------------------------------ people
func _deploy() -> void:
	lay = field.town.layout
	var sides: Array = setup.get("sides", [])
	var me: Dictionary = sides[0] if sides.size() > 0 else {}
	side_names[0] = str(me.get("name", "你"))
	if me.has("color"):
		side_colors[0] = Color(str(me.color))
	var h: Dictionary = me.get("hero", {"name": "你", "player": true, "troop": "zhou_inf3"})
	player = _spawn(0, str(h.get("troop", "zhou_inf3")), lay.spawn, h.get("loadout", {}), "", true)
	initial_total = [1, 1]
	var rooms: Array = setup.get("rooms", [])
	if room == "":
		for r in rooms:
			if lay.anchors.has(r):
				lay.enter[r] = lay.anchors[r]
	# business: one person per distinct npc name (several menu options can belong to the same person)
	var by_npc := {}
	var order: Array = []
	for sp in setup.get("spots", []):
		var where := str(sp.get("where", "square"))
		if room != "" and where != room:
			continue
		if room == "" and where in rooms:
			continue                              # inside the hall / the tavern
		var key := _key(sp)
		if not by_npc.has(key):
			by_npc[key] = []
			order.append(key)
		by_npc[key].append(sp)
	var used := {}
	for key in order:
		var lst: Array = by_npc[key]
		var sp: Dictionary = lst[0]
		var where := str(sp.get("where", "square"))
		var i: int = used.get(where, 0)
		used[where] = i + 1
		var pos := lay.spot(where, i)
		var role := str(sp.get("role", ""))
		var a := _spawn_npc(str(sp.get("troop", "villager")), pos, Color(str(sp.get("color", "#8a7a5a"))),
			"%s · %s" % [sp.get("npc", ""), role] if role != "" else str(sp.get("npc", "")),
			{"melee": ["sword"], "armor": 20} if sp.get("armed", false) else UNARMED)
		npcs.append({"agent": a, "spots": lst, "home": pos, "yaw": _face_room(pos) if room != "" else _face_street(pos), "key": key})
	var crowd: Dictionary = setup.get("crowd", {})
	var kcol := Color(str(crowd.get("guard_color", "#7a7a7a")))
	if room == "hall":
		for k in mini(maxi(int(crowd.get("guard_n", 2)), 2), lay.slots.guard.size()):
			var p: Vector3 = lay.slots.guard[k]
			var a := _spawn_npc(str(crowd.get("guards", "militia")), p, kcol, "", {})
			npcs.append({"agent": a, "spots": [], "home": p, "yaw": _face_room(p), "idle": true})
		return
	if room == "inn":
		var pats: Array = lay.slots.patron
		for k in mini(6, pats.size()):
			var p: Vector3 = pats[(k * 3) % pats.size()]
			var tint := Color(str(crowd.get("color", "#8a7a5a"))).lerp(Color(_rng.randf(), _rng.randf(), _rng.randf()), 0.4)
			var a := _spawn_npc(str(crowd.get("troop", "villager")), p, tint, "")
			var t: Vector3 = _nearest_table(p)
			npcs.append({"agent": a, "spots": [], "home": p, "yaw": atan2(-(t.x - p.x), -(t.z - p.z)), "idle": true, "patron": true})
		return
	# the streets: volunteers waiting in the square, townsfolk strolling, guards at the gate
	var vi := 0
	for tid in setup.get("volunteers", []):
		vi += 1
		var p := lay.spot("square", 6 + vi)
		var a := _spawn_npc(str(tid), p, Color(str(crowd.get("color", "#8a7a5a"))), "")
		npcs.append({"agent": a, "spots": [], "home": p, "yaw": _face_street(p), "idle": true, "volunteer": true})
	for k in int(crowd.get("n", 10)):
		if lay.paths.is_empty():
			break
		var p: Vector3 = lay.paths[_rng.randi() % lay.paths.size()] + Vector3(_rng.randf_range(-1.5, 1.5), 0, _rng.randf_range(-1.5, 1.5))
		var tint := Color(str(crowd.get("color", "#8a7a5a"))).lerp(Color(_rng.randf(), _rng.randf(), _rng.randf()), 0.35)
		var a := _spawn_npc(str(crowd.get("troop", "villager")), p, tint, "")
		strollers.append({"agent": a, "goal": p, "wait": _rng.randf_range(0.0, 4.0)})
	for k in int(crowd.get("guard_n", 0)):
		var gx := (-1.0 if k % 2 == 0 else 1.0) * (5.5 + (k / 2) * 1.4)
		var p := lay.gate + Vector3(gx, 0, 0.8)
		var a := _spawn_npc(str(crowd.get("guards", "militia")), p, kcol, "", {})
		npcs.append({"agent": a, "spots": [], "home": p, "yaw": 0.0, "idle": true})


func _nearest_table(p: Vector3) -> Vector3:
	var best := p + Vector3(0, 0, -1)
	var bd := INF
	for b in lay.blocks:
		if b[5] != "table":
			continue
		var c := Vector3((b[0] + b[2]) * 0.5, 0, (b[1] + b[3]) * 0.5)
		if c.distance_to(p) < bd:
			bd = c.distance_to(p)
			best = c
	return best


func _key(sp: Dictionary) -> String:
	return "%s|%s" % [sp.get("npc", ""), sp.get("where", "")]


## Townsfolk, shopkeepers, clerks: empty-handed (guards and lords get their arms).
const UNARMED := {"melee": ["fists"], "armor": 0}


func _spawn_npc(tid: String, p: Vector3, col: Color, label: String, override: Dictionary = UNARMED) -> Agent:
	var a := Agent.new()
	add_child(a)
	a.rng_seed = agents.size()
	a.setup(self, rules, tid, 0, col, override, label)
	a.global_position = field.ground(p) + Vector3(0, 0.05, 0)
	a.safe_pos = a.global_position
	a.heading = _face_street(p) if room == "" else _face_room(p)
	a.intent_yaw = a.heading
	a.rotation.y = a.heading
	a.ai["lab"] = true                 # no battle AI: walk.gd moves them
	if a.rig and a.rig.label:
		a.rig.label.no_depth_test = false      # names are hidden behind houses
		a.rig.label.visibility_range_end = 30.0
	agents.append(a)
	return a


## Stand facing the open street (away from the nearest wall of a building).
func _face_street(p: Vector3) -> float:
	var best := 0.0
	var room_free := -1.0
	for k in 8:
		var ang := TAU * k / 8.0
		var dir := Vector3(-sin(ang), 0, -cos(ang))
		var free := 0.0
		for step in range(1, 8):
			if lay.height(p.x + dir.x * step, p.z + dir.z * step) > 0.45:
				break
			free = step
		if free > room_free:
			room_free = free
			best = ang
	return best


## Indoors: face the door end of the room (people look at whoever comes in).
func _face_room(p: Vector3) -> float:
	var t := lay.exit - p
	return atan2(-t.x, -t.z)


# ------------------------------------------------------------------ the loop
func _physics_process(dt: float) -> void:
	if over:
		return
	for s in strollers:
		var a: Agent = s.agent
		var to: Vector3 = s.goal - a.global_position
		to.y = 0.0
		if to.length() < 1.2:
			a.intent_move = Vector3.ZERO
			s.wait = float(s.wait) - dt
			if float(s.wait) <= 0.0:
				s.goal = _next_goal(a.global_position)
				s.wait = _rng.randf_range(1.5, 6.0)
		else:
			var dir := to.normalized() + separation(a) * 0.6
			dir.y = 0.0
			a.intent_move = dir.normalized() * 0.45
			a.intent_run = false
			a.intent_yaw = atan2(-dir.x, -dir.z)
	for n in npcs:
		var a: Agent = n.agent
		a.intent_move = Vector3.ZERO
		var home: Vector3 = n.home
		var off: Vector3 = home - a.global_position
		off.y = 0.0
		if off.length() > 0.8:                  # pushed aside: step back to the post
			a.intent_move = off.normalized() * 0.4
			a.intent_run = false
		var d := player.global_position.distance_to(a.global_position) if player else 99.0
		if (not n.get("idle", false) and d < 6.0) or a == _talk_to:
			var t := player.global_position - a.global_position
			a.intent_yaw = atan2(-t.x, -t.z)          # look at the visitor
		else:
			a.intent_yaw = float(n.yaw)
	if _talk_to and is_instance_valid(_talk_to) and player:
		var t2 := _talk_to.global_position - player.global_position
		player.intent_yaw = atan2(-t2.x, -t2.z)       # and the visitor looks at whoever he talks to
	super(dt)
	_test_hook()
	if over or not is_inside_tree():
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--walk-then=") and _session == "menu" and not _busy and _panel.visible and not has_meta("then"):
			var parts := arg.substr(12).split("@")              # tests: then choose this option after N s
			if time > float(parts[1]) if parts.size() > 1 else 3.0:
				set_meta("then", true)
				var o = _panel.menu.get("options", []).filter(func(x): return x.id == parts[0])
				if not o.is_empty():
					var data := {}
					for k in ["topic", "target", "hero", "choice"]:
						if o[0].get(k) != null:
							data[k] = o[0][k]
					_act(parts[0], data)
	if _session == "trade" and _panel and not _panel.trading and not _busy:
		_session = "menu"
		_act("walk", {})                                # "返回" on the market screen: back to the street
	if _session == "":
		_update_near()
	else:
		_prompt.text = ""
	if _say_t > 0.0:
		_say_t -= dt
		if _say_t <= 0.0:
			_say.text = ""


## Tests: --walk-do=ACTION acts as if F was pressed at the person offering it; --walk-room=hall walks in.
func _test_hook() -> void:
	if time < 1.5 or _session != "" or _busy or has_meta("did"):
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--walk-room=") and room == "" and _street == null:
			set_meta("did", true)
			_enter_room(arg.substr(12))
			return
		if arg.begins_with("--walk-do="):
			var want := arg.substr(10)
			for n in npcs:
				for sp in n.spots:
					if sp.action == want:
						set_meta("did", true)
						player.global_position = field.ground(n.agent.global_position + n.agent.forward() * 1.8)
						_talk_to = n.agent
						_choose(sp)
						return
			if want == "_exit" and room != "":
				set_meta("did", true)
				_finish({"action": "_exit"})
				return
			if room == "" and not " ".join(OS.get_cmdline_user_args()).contains("--walk-room="):
				set_meta("did", true)
				_finish({"action": want})
			return


func _next_goal(from: Vector3) -> Vector3:
	# a nearby street corner (not the one we stand on)
	var cands: Array = []
	for p in lay.paths:
		var d: float = p.distance_to(Vector3(from.x, 0, from.z))
		if d > 4.0 and d < 26.0:
			cands.append(p)
	if cands.is_empty():
		cands = lay.paths
	return cands[_rng.randi() % cands.size()] + Vector3(_rng.randf_range(-1.2, 1.2), 0, _rng.randf_range(-1.2, 1.2))


# nothing to fight
func _check_end() -> void:
	pass


func _enemy_commander(_first: bool) -> void:
	pass


func _reinforce() -> void:
	pass


func _morale() -> void:
	pass


func _assign_slots() -> void:
	pass


func request_retreat() -> bool:
	if _session != "":
		return false
	_finish({"action": "back"})
	return true


## Camera: indoors it stays inside the walls and under the beams; in a conversation it frames the two faces.
func adjust_camera(cam: Camera3D, dt: float) -> void:
	if _talk_to and is_instance_valid(_talk_to) and player and ctrl.hold_still:
		var p := player.global_position
		var n := _talk_to.global_position
		var d := n - p
		d.y = 0.0
		d = d.normalized() if d.length() > 0.01 else Vector3(0, 0, -1)
		var side := Vector3(d.z, 0, -d.x)
		var want := p - d * 0.9 + side * 1.7 + Vector3(0, 1.9, 0)
		if not has_meta("talk_cam"):
			set_meta("talk_cam", cam.global_position)
		var tc: Vector3 = get_meta("talk_cam")
		tc = tc.lerp(want, 1.0 - exp(-4.0 * dt))       # our own smoothed position (the controller resets the camera)
		set_meta("talk_cam", tc)
		cam.global_position = tc
		cam.look_at(p.lerp(n, 0.62) + Vector3(0, 1.45, 0) - side * 0.35, Vector3.UP)
	elif has_meta("talk_cam"):
		remove_meta("talk_cam")
	if lay and lay.room:
		var c := cam.global_position
		c.x = clampf(c.x, lay.rect.position.x + 0.35, lay.rect.end.x - 0.35)
		c.z = clampf(c.z, lay.rect.position.y + 0.35, lay.rect.end.y - 0.35)
		c.y = clampf(c.y, 0.6, lay.ceiling - 0.6)
		if not c.is_equal_approx(cam.global_position):
			var fwd := -cam.global_basis.z
			cam.global_position = c
			cam.look_at(c + fwd, Vector3.UP)


# ------------------------------------------------------------------ what is in reach
func _update_near() -> void:
	_near = {}
	if player == null:
		return
	var pp := player.global_position
	var best := TALK_RANGE + (0.6 if room != "" else 0.0)
	for n in npcs:
		var d: float = pp.distance_to(n.agent.global_position)
		if d < best:
			best = d
			_near = n
	if _near.is_empty():
		for s in strollers:
			var d: float = pp.distance_to(s.agent.global_position)
			if d < best:
				best = d
				_near = {"chatter": true, "agent": s.agent}
	if _near.is_empty():
		for r in lay.enter:
			var e: Vector3 = lay.enter[r]
			if Vector2(pp.x - e.x, pp.z - e.z).length() < 2.6:
				_near = {"enter": r}
		if room != "" and Vector2(pp.x - lay.exit.x, pp.z - lay.exit.z).length() < 2.2:
			_near = {"exit": true}
		elif room == "" and Vector2(pp.x - lay.gate.x, pp.z - lay.gate.z).length() < 4.0:
			_near = {"gate": true}
	_show_prompt()


func _room_name(r: String) -> String:
	if r == "hall":
		var base := str(setup.get("town", {}).get("base", setup.get("town", {}).get("kind", "town")))
		return "主堡" if base == "castle" else "府衙"
	return "酒肆"


func _show_prompt() -> void:
	if _near.is_empty():
		_prompt.text = ""
		return
	var key := "[color=#f2c75c]F[/color]  "
	if _near.has("enter"):
		_prompt.text = "[center]%s进入%s[/center]" % [key, _room_name(_near.enter)]
		return
	if _near.has("exit"):
		_prompt.text = "[center]%s出门[/center]" % key
		return
	if _near.get("gate", false):
		_prompt.text = "[center]%s%s[/center]" % [key, "出村" if lay.kind == "village" else "出城"]
		return
	if _near.get("chatter", false) or _near.spots.is_empty():
		_prompt.text = "[center]%s搭话[/center]" % key
		return
	var lines: Array[String] = []
	var spots: Array = _near.spots
	for i in spots.size():
		var sp: Dictionary = spots[i]
		var k := "F" if spots.size() == 1 else str(i + 1)
		if sp.get("enabled", true):
			lines.append("[color=#f2c75c]%s[/color]  %s" % [k, sp.label])
		else:
			lines.append("[color=#8c8478]%s  %s（%s）[/color]" % [k, sp.label, sp.get("hint", "做不到")])
	_prompt.text = "[center]%s[/center]" % "\n".join(lines)


func _unhandled_input(e: InputEvent) -> void:
	if over or not (e is InputEventKey) or not e.pressed or e.echo:
		return
	var k := (e as InputEventKey).keycode
	if _session != "":
		if k == KEY_ESCAPE and not _busy:
			if _session == "trade":
				_panel.trading = false
			elif _panel.menu.get("options", []).any(func(o): return o.id == "back"):
				_act("back", {})
		return
	if _near.is_empty() or _busy:
		return
	if k == KEY_F or k == KEY_E:
		if _near.has("enter"):
			_enter_room(_near.enter)
		elif _near.has("exit"):
			_finish({"action": "_exit"})
		elif _near.get("gate", false):
			_finish({"action": "leave"})
		elif _near.get("chatter", false) or _near.spots.is_empty():
			_chatter(_near)
		elif _near.spots.size() == 1:
			_talk_to = _near.agent
			_choose(_near.spots[0])
	elif k >= KEY_1 and k <= KEY_9 and _near.has("spots"):
		var i := k - KEY_1
		if i < _near.spots.size():
			_talk_to = _near.agent
			_choose(_near.spots[i])


func _chatter(n: Dictionary) -> void:
	var lines: Array = []
	if n.get("patron", false) or room == "inn":
		lines = setup.get("rumors", []).duplicate()
		lines.append_array(CHATTER.inn)
	elif room == "hall":
		lines = CHATTER.hall
	else:
		lines = CHATTER.get(lay.kind, CHATTER.town).duplicate()
		var rum: Array = setup.get("rumors", [])
		if not rum.is_empty() and _rng.randf() < 0.4:
			lines = rum
	_toast("「%s」" % lines[_rng.randi() % lines.size()], 5.0)


func _choose(sp: Dictionary) -> void:
	if not sp.get("enabled", true):
		_toast(str(sp.get("hint", "做不到")))
		_talk_to = null
		return
	var data := {}
	for key in ["hero", "choice"]:
		if sp.has(key):
			data[key] = sp[key]
	if _api and sp.action in IN_SCENE:
		_session = "trade" if sp.action == "trade" else "menu"
		_act(sp.action, data)
		return
	_talk_to = null
	var r := {"action": sp.action}
	r.merge(data)
	_finish(r)


# ------------------------------------------------------------------ conversations (straight to the server)
func _act(action: String, data: Dictionary) -> void:
	_busy = true
	_api.act(action, data)


func _on_api(_kind: String, data: Dictionary) -> void:
	_busy = false
	var res: Dictionary = data.get("result", {}) if typeof(data.get("result")) == TYPE_DICTIONARY else {}
	var msg := str(res.get("message", ""))
	var m = data.get("player", {}).get("menu")
	if m == null:
		_handoff()
		return
	var t := str(m.get("type", ""))
	match t:
		"walk":
			_refresh(m.get("setup", {}))
			_end_talk()
			if msg != "":
				_toast(msg, 4.0)
		"settlement":
			if _session == "trade":
				_panel.trade_next = true
				_open_panel(m)
				if msg != "":
					_toast(msg)
			else:
				if msg != "":
					_toast(msg, 4.0)
				_act("walk", {})                     # done: back into the street
		"talk", "quest", "notice", "captive", "fief", "request_fief", "equip", "smith":
			_open_panel(m)
			if msg != "":
				_toast(msg, 4.0)
		_:
			_handoff()                               # a bout in the arena, an event…: the map takes over


func _open_panel(m: Dictionary) -> void:
	if _talk_to and is_instance_valid(_talk_to) and _talk_to.rig and _talk_to.rig.label:
		_talk_to.rig.label.visible = false            # the name is in the panel's title
	_panel.open(m)
	_panel.visible = true
	ctrl.hold_still = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _end_talk() -> void:
	if _panel:
		_panel.close()
	if _talk_to and is_instance_valid(_talk_to) and _talk_to.rig and _talk_to.rig.label:
		_talk_to.rig.label.visible = true
	ctrl.hold_still = false
	_session = ""
	_talk_to = null


## New spots after something changed (recruited, a quest taken…): give each person their current options;
## volunteers who joined leave the square.
func _refresh(st: Dictionary) -> void:
	if st.is_empty():
		return
	setup["spots"] = st.get("spots", [])
	setup["volunteers"] = st.get("volunteers", [])
	setup["rumors"] = st.get("rumors", setup.get("rumors", []))
	var by_key := {}
	for sp in setup.spots:
		if not by_key.has(_key(sp)):
			by_key[_key(sp)] = []
		by_key[_key(sp)].append(sp)
	for n in npcs:
		if n.has("key"):
			n.spots = by_key.get(n.key, [])
	var keep := int(setup.volunteers.size())
	for n in npcs.duplicate():
		if n.get("volunteer", false):
			if keep > 0:
				keep -= 1
			else:
				npcs.erase(n)
				agents.erase(n.agent)
				n.agent.queue_free()
	if _street:
		_street._refresh(st)


func _handoff() -> void:
	_end_talk()
	_finish({"action": "_handoff"})


func _toast(text: String, secs := 3.0) -> void:
	_say.text = text
	_say_t = secs


# ------------------------------------------------------------------ rooms
func _enter_room(r: String) -> void:
	var rn: TownWalk = (load("res://battle/scripts/walk.gd") as Script).new()
	var st: Dictionary = setup.duplicate(true)
	st["room"] = r
	rn.preset_setup = st
	rn.embedded = true
	rn._street = self
	if _capture_path != "":                            # tests: the screenshot is taken in the room
		rn._capture_path = _capture_path
		rn._capture_at = maxf(_capture_at - time, 1.0)
		_capture_path = ""
	_holder = get_parent()
	_near = {}
	_swap.call_deferred(rn)


func _swap(rn: Node) -> void:
	_holder.remove_child(self)
	_holder.add_child(rn)


## Back out of a room onto the street, at its door.
func _back_from_room(rn: TownWalk) -> void:
	var holder := rn.get_parent()
	holder.remove_child(rn)
	holder.add_child(self)
	ctrl.cam.current = true
	if rn._capture_path != "":
		_capture_path = rn._capture_path
		_capture_at = time + maxf(rn._capture_at - rn.time, 0.5)
	var door: Vector3 = lay.enter.get(rn.room, lay.spawn)
	var away := _face_street(door)
	player.global_position = field.ground(door + Vector3(-sin(away), 0, -cos(away)) * 1.5)
	player.safe_pos = player.global_position
	player.heading = away
	player.intent_yaw = away
	ctrl.yaw = away
	_near = {}


func _finish(r: Dictionary) -> void:
	if over:
		return
	if _street != null:
		# a room: go back out; anything but the door is passed on to the street (and from there to the map)
		over = true
		_end_talk()
		var st := _street
		st._back_from_room(self)
		if r.get("action", "") != "_exit":
			st._finish(r)
		queue_free()
		return
	over = true
	result = r.duplicate()
	result["walk"] = true
	print("WALK_RESULT " + JSON.stringify(result))
	finished.emit(result)
	close()


# ------------------------------------------------------------------ overlay
func _build_ui() -> void:
	_ui = CanvasLayer.new()
	add_child(_ui)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(root)
	_title = Label.new()
	_title.text = str(setup.get("place", "")) + ("" if room == "" else " · " + _room_name(room))
	_title.add_theme_font_size_override("font_size", 30)
	_title.add_theme_color_override("font_color", Color("f2c75c"))
	_title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_title.add_theme_constant_override("outline_size", 6)
	_title.position = Vector2(24, 16)
	root.add_child(_title)
	var sub := Label.new()
	sub.text = str(setup.get("subtitle", ""))
	sub.add_theme_font_size_override("font_size", 16)
	sub.add_theme_color_override("font_color", Color("efe6d2"))
	sub.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	sub.add_theme_constant_override("outline_size", 4)
	sub.position = Vector2(26, 58)
	root.add_child(sub)
	var keys := Label.new()
	keys.text = "WASD 走动 · Shift 慢走 · 鼠标 看 · F 交谈 / 办事 / 进门 · Esc 结束交谈 · Tab 回到菜单"
	keys.add_theme_font_size_override("font_size", 14)
	keys.add_theme_color_override("font_color", Color("cfd6dc"))
	keys.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	keys.add_theme_constant_override("outline_size", 4)
	keys.anchor_top = 1.0
	keys.anchor_bottom = 1.0
	keys.offset_top = -36
	keys.offset_left = 24
	root.add_child(keys)
	_prompt = RichTextLabel.new()
	_prompt.bbcode_enabled = true
	_prompt.fit_content = true
	_prompt.scroll_active = false
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt.add_theme_font_size_override("normal_font_size", 20)
	_prompt.add_theme_color_override("default_color", Color("efe6d2"))
	_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_prompt.add_theme_constant_override("outline_size", 6)
	_prompt.anchor_left = 0.2
	_prompt.anchor_right = 0.8
	_prompt.anchor_top = 0.66
	_prompt.anchor_bottom = 0.95
	root.add_child(_prompt)
	_say = Label.new()
	_say.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_say.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_say.add_theme_font_size_override("font_size", 20)
	_say.add_theme_color_override("font_color", Color("efe6d2"))
	_say.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_say.add_theme_constant_override("outline_size", 6)
	_say.anchor_left = 0.15
	_say.anchor_right = 0.85
	_say.anchor_top = 0.56
	root.add_child(_say)
	# the conversation panel: the campaign's own menu window, on the right so both faces stay in view
	_panel = PlayerMenuScript.new()
	_panel.visible = false
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.08
	_panel.offset_left = -600
	_panel.offset_right = -24
	_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN      # the equipment screen is wider: grow leftwards
	root.add_child(_panel)
	_panel.action.connect(func(id, data):
		if _busy or _api == null:
			return
		_act(id, data))
	_panel.say.connect(func(hero, text):
		if _api and not _busy:
			_busy = true
			_api.talk(hero, text))
