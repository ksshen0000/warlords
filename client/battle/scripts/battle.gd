class_name Battle
extends Node3D
## 3D field battle in the style of Mount & Blade: Warband.
## Standalone for now (battle.tscn / battle.sh). Input: a setup JSON (two sides' troop rosters,
## terrain, time of day); output: a result JSON with every side's killed / wounded / routed troops,
## so the campaign can apply the outcome once the two parts are integrated.
##
## Command line (after `--`): --setup=file.json  --out=result.json  --auto (AI plays your character)
##   --fast=N (simulate N× faster, for tests)  --terrain=hills  --night  --seed=N  --rules=dir

signal finished(result: Dictionary)
signal closed(result: Dictionary)      # embedded: the player left the result screen (back to the campaign map)

var preset_setup: Dictionary = {}      # embedded in the campaign: the setup comes from the server, not a file
var embedded := false

var rules := BattleRules.new()
var setup: Dictionary = {}
# Warband-style difficulty (setup["difficulty"], from the campaign's settings; --ai=0..2 etc. standalone)
var diff := {"player_damage": 1.0, "ally_damage": 1.0, "ai_level": 1, "combat_speed": 1.0,
	"auto_block": false, "auto_attack": false}
var field: BattleField
var agents: Array = []                 # every Agent ever spawned (dead ones stay as corpses)
var player: Agent = null
var player_side := 0
var time := 0.0
var over := false
var result: Dictionary = {}
var attackers_on := {}                 # target instance id -> number of agents targeting it
var orders: Array = [{}, {}]           # per side: division -> {type, pos, facing, spacing}
var reserves: Array = [[], []]         # per side: troop ids waiting to come in
var share: Array = [0, 0]              # per side: how many may be on the field at once
var heroes: Array = [{}, {}]
var side_names: Array = ["", ""]
var side_colors: Array = [Color("d65a4a"), Color("5b8def")]
var spawned_total: Array = [0, 0]
var initial_total: Array = [0, 0]
var routing_announced: Array = [false, false]
var auto := false
var out_path := ""
var hud: Node = null
var sfx: BattleSfx = null
var ctrl: Node = null

var _grid := {}
var _engaged_cache := {}               # enemy id -> melee proximity, shared by all archers this tick
var _center_cache := {}                # side -> enemy centroid for this tick
var frame := 0                         # physics frame counter (rig level of detail)
var _headless := false
var prof := {}
var stats := {}                        # combat counters (tuning): swings, hits, blocks, arrows, couches, bumps…


func stat(k: String, n := 1) -> void:
	stats[k] = int(stats.get(k, 0)) + n
const CELL := 4.0
var _slots := {}                       # agent instance id -> Vector3 (world)
var _slot_t := 0.0
var _morale_t := 0.0
var _cmd_t := 0.0
var _corpses: Array[Agent] = []        # recent bodies kept visible; outcomes remain on the agents
var phase := 1
var phase_pending := false
var _waves := [0, 0]
var arrows: Array = []
var _arrow_mesh: BoxMesh
var _capture_path := ""
var _capture_at := 0.0
var _arrow_mat: StandardMaterial3D
var siege_def := -1                    # siege assault: the side behind the wall (-1 = open field)
var peaceful := false                  # walking round a town (walk.gd): no attacking, no orders


func _ready() -> void:
	var font: Font = load("res://assets/fonts/DroidSansFallbackFull.ttf")
	var theme := Theme.new()
	theme.default_font = font
	ThemeDB.fallback_font = font
	get_tree().root.theme = theme
	_headless = DisplayServer.get_name() == "headless"
	if not rules.load_all():
		push_error("battle: rules not found in %s" % BattleRules.rules_dir())
		get_tree().quit(1)
		return
	if embedded:
		setup = preset_setup
		player_side = int(setup.get("player_side", 0))
		seed(int(setup.get("seed", 1)))
	else:
		_parse_args()
	diff.merge(setup.get("difficulty", {}), true)
	field = BattleField.new()
	add_child(field)
	if setup.has("siege"):
		var sg: Dictionary = setup.siege
		siege_def = int(sg.get("defender", 1))
		field.set_siege(siege_def, int(sg.get("walls", 2)), int(sg.get("ladders", 4)))
	elif setup.has("town"):
		field.set_town(setup.town)
	field.build(str(setup.get("terrain", "plains")), rules.num("battle", "field", 300), int(setup.get("seed", 1)),
		bool(setup.get("night", false)))
	if not _headless:
		sfx = BattleSfx.new()
		add_child(sfx)
		var vol := float(diff.get("sfx_volume", 0.8))
		sfx.volume_db = linear_to_db(maxf(vol, 0.001))
		sfx.visible = vol > 0.0
	_arrow_mesh = BoxMesh.new()
	_arrow_mesh.size = Vector3(0.025, 0.025, 0.8)
	_arrow_mat = StandardMaterial3D.new()
	_arrow_mat.albedo_color = Color("4a3a28")
	_deploy()
	if setup.get("arena", false) and not _headless:
		_build_arena_ring()
	ctrl = load("res://battle/scripts/player_ctrl.gd").new()
	ctrl.name = "PlayerCtrl"
	add_child(ctrl)
	ctrl.setup(self)
	if DisplayServer.get_name() != "headless":
		hud = load("res://battle/scripts/hud.gd").new()
		add_child(hud)
		hud.setup(self)
		if OS.get_cmdline_user_args().has("--overview"):
			hud.show_map = true                 # tests: screenshot with the battle overview open
	if setup.get("arena", false):
		message("比武开始！木兵器，打倒对手即胜 · Tab 认输", Color("f2c75c"))
	elif siege_def >= 0:
		var objective := "守住梯口，击退攻方" if player_side == siege_def else "登城击败守军"
		message("%s 架云梯靠上了城墙 · %s · Backspace 全图" % [field.siege.ladders.size(), objective], Color("f2c75c"))
	else:
		message("战斗开始！1 步兵 2 射手 3 骑兵 0 全军 · F1 驻守 F2 跟我来 F3 冲锋 · Backspace 全图 · Tab 撤离", Color("f2c75c"))


func _parse_args() -> void:
	var path := "res://battle/sample_setup.json"
	var fast := 1.0
	var over_terrain := ""
	var night := false
	var seed_over := -1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--setup="):
			path = a.substr(8)
		elif a.begins_with("--out="):
			out_path = a.substr(6)
		elif a == "--auto":
			auto = true
		elif a.begins_with("--fast="):
			fast = float(a.substr(7))
		elif a.begins_with("--terrain="):
			over_terrain = a.substr(10)
		elif a == "--night":
			night = true
		elif a.begins_with("--ai="):
			diff["ai_level"] = clampi(int(a.substr(5)), 0, 2)
		elif a.begins_with("--player-damage="):
			diff["player_damage"] = float(a.substr(16))
		elif a.begins_with("--combat-speed="):
			diff["combat_speed"] = float(a.substr(15))
		elif a.begins_with("--seed="):
			seed_over = int(a.substr(7))
		elif a.begins_with("--capture="):
			# --capture=path.png@12  : save a screenshot after 12 s of battle and quit (tests)
			var parts := a.substr(10).split("@")
			_capture_path = parts[0]
			_capture_at = float(parts[1]) if parts.size() > 1 else 5.0
	var f := FileAccess.open(path, FileAccess.READ)
	if f:
		setup = JSON.parse_string(f.get_as_text())
	if setup == null or setup.is_empty():
		push_error("battle: bad setup %s" % path)
		setup = {}
	if over_terrain != "":
		setup["terrain"] = over_terrain
	if night:
		setup["night"] = true
	if seed_over >= 0:
		setup["seed"] = seed_over
	if fast > 1.0:
		Engine.physics_ticks_per_second = int(60 * fast)
		Engine.max_physics_steps_per_frame = int(8 * fast)
		Engine.time_scale = fast
	player_side = int(setup.get("player_side", 0))
	seed(int(setup.get("seed", 1)))


# ------------------------------------------------------------------ deployment
func _deploy() -> void:
	var sides: Array = setup.get("sides", [])
	var totals := [0, 0]
	var tactics := [0, 0]
	for s in 2:
		var sd: Dictionary = sides[s] if s < sides.size() else {}
		side_names[s] = str(sd.get("name", "我军" if s == player_side else "敌军"))
		if sd.has("color"):
			side_colors[s] = Color(str(sd.color))
		heroes[s] = sd.get("hero", {})
		tactics[s] = int(sd.get("tactics", 0))
		var roster: Array = []
		var troops: Dictionary = sd.get("troops", {})
		for tid in troops:
			for k in int(troops[tid]):
				roster.append(tid)
		roster.shuffle()
		# better troops tend to be at the front of the queue (like a party's roster order)
		roster.sort_custom(func(x, y): return int(rules.troops.get(x, {}).get("tier", 1)) > int(rules.troops.get(y, {}).get("tier", 1)))
		reserves[s] = roster
		totals[s] = roster.size() + (1 if not heroes[s].is_empty() else 0) + heroes[s].get("companions", []).size()
		initial_total[s] = totals[s]
	var size := int(setup.get("battle_size", rules.num("battle", "size", BattleRules.DEFAULT_BATTLE_SIZE)))
	share = deployment_slots(totals, size, tactics)
	for s in 2:
		orders[s] = {}
		for div in ["inf", "arc", "cav"]:
			orders[s][div] = {"type": "charge", "pos": _spawn_center(s), "facing": _side_facing(s), "spacing": rules.num("ai", "spacing", 1.15)}
		if not heroes[s].is_empty():
			var h: Dictionary = heroes[s]
			var is_pl: bool = h.get("player", false)
			var origin := _spawn_center(s) + Vector3(0, 0, 6.0 * (1 if s == 0 else -1))
			if is_pl and s == siege_def:
				origin = field.wall_point(0.0, 0.5)
			var a := _spawn(s, str(h.get("troop", "")), origin,
				h.get("loadout", {}), str(h.get("name", "")), is_pl)
			if is_pl:
				player = a
			# your companions ride beside you (named heroes: knocked out, never killed)
			var comps: Array = h.get("companions", [])
			for i in comps.size():
				var c: Dictionary = comps[i]
				var side_off := Vector3(2.4 * (1 + i / 2) * (1 if i % 2 == 0 else -1), 0, 0)
				var ca := _spawn(s, str(c.get("troop", "")), origin + side_off, c.get("loadout", {}), str(c.get("name", "")), false)
				ca.set_meta("companion", str(c.get("companion", "")))
				companion_agents.append(ca)
		_spawn_wave(s, share[s] - (1 if not heroes[s].is_empty() else 0) - heroes[s].get("companions", []).size())
	if auto and player:
		player.is_player = false            # the AI plays your character (tests / spectating)
	_enemy_commander(true)
	if player and player_side == siege_def:
		_siege_commander(player_side, true)


## Split a single budget. Keep a small contingent on each side where possible,
## and give any unused slots to the other side. Size 2 supports the arena.
static func deployment_slots(totals: Array, requested: int, tactics := [0, 0]) -> Array:
	var total: int = totals[0] + totals[1]
	if total == 0:
		return [0, 0]
	var slots := mini(total, clampi(requested, 2, BattleRules.MAX_BATTLE_SIZE))
	var guaranteed := mini(15, slots / 2)
	var minimum := maxi(mini(totals[0], guaranteed), slots - int(totals[1]))
	var maximum := mini(int(totals[0]), slots - mini(totals[1], guaranteed))
	var first_weight: float = totals[0] * (1.0 + 0.1 * clampi(tactics[0], 0, 10))
	var second_weight: float = totals[1] * (1.0 + 0.1 * clampi(tactics[1], 0, 10))
	var first := clampi(roundi(slots * first_weight / (first_weight + second_weight)), minimum, maximum)
	return [first, slots - first]


## The arena: a ring of wooden posts with a rail (only for show).
func _build_arena_ring() -> void:
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color("6b4a2a")
	var n := 40
	for i in n:
		var ang := TAU * i / n
		var p := Vector3(cos(ang), 0, sin(ang)) * 17.5
		var post := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.14, 1.3, 0.14)
		post.mesh = bm
		post.material_override = wood
		post.position = field.ground(p) + Vector3(0, 0.65, 0)
		add_child(post)
		var nxt := Vector3(cos(TAU * (i + 1) / n), 0, sin(TAU * (i + 1) / n)) * 17.5
		var rail := MeshInstance3D.new()
		var rm := BoxMesh.new()
		rm.size = Vector3(0.08, 0.08, p.distance_to(nxt))
		rail.mesh = rm
		rail.material_override = wood
		add_child(rail)
		var mid := (p + nxt) * 0.5
		rail.position = field.ground(mid) + Vector3(0, 1.05, 0)
		rail.look_at(rail.position + (nxt - p), Vector3.UP)


func _side_facing(s: int) -> float:
	return 0.0 if s == 0 else PI


func _spawn_center(s: int) -> Vector3:
	if siege_def >= 0:
		return field.siege_point(0.0, 48.0) if s == siege_def else field.siege_point(0.0, -55.0)
	var z := float(setup.get("spawn_gap", rules.num("battle", "spawn_gap", 110))) * 0.5 * (1 if s == 0 else -1)
	return Vector3(0, 0, z)


func _spawn_wave(s: int, n: int) -> void:
	var take: Array = reserves[s].slice(0, maxi(0, n))
	reserves[s] = reserves[s].slice(take.size())
	# group by class so each division forms up together
	var groups := {"inf": [], "arc": [], "cav": []}
	var dismounted: bool = setup.get("dismounted", false)
	for tid in take:
		var lo := rules.loadout(tid)
		var g := "cav" if not dismounted and lo.horse != "" else ("arc" if not lo.ranged.is_empty() else "inf")
		groups[g].append(tid)
	var c := _spawn_center(s)
	var fwd := Vector3(0, 0, -1) if s == 0 else Vector3(0, 0, 1)
	var rightv := Vector3(1, 0, 0) if s == 0 else Vector3(-1, 0, 0)
	var place := {"inf": c, "arc": c - fwd * 9.0, "cav": c + rightv * 28.0 - fwd * 4.0}
	if s == siege_def:
		# the garrison's archers go straight up on the wall walk; everyone else musters in the town
		var lst: Array = groups.arc
		for k in lst.size():
			var x := (k - (lst.size() - 1) * 0.5) * 1.7
			_spawn(s, lst[k], field.wall_point(clampf(x, -field.size * 0.45, field.size * 0.45), randf_range(0.1, 0.5)))
		groups.arc = []
	for g in groups:
		var lst: Array = groups[g]
		var cols := maxi(4, int(ceil(sqrt(lst.size() * 3.0))))
		for k in lst.size():
			var col := k % cols
			var row := k / cols
			var sp := 2.2 if g == "cav" else 1.3
			var p: Vector3 = place[g] + rightv * (col - (cols - 1) * 0.5) * sp - fwd * row * sp * 1.3
			p += Vector3(randf_range(-0.3, 0.3), 0, randf_range(-0.3, 0.3))
			_spawn(s, lst[k], p)


func _spawn(s: int, tid: String, p: Vector3, override: Dictionary = {}, hname := "", is_pl := false) -> Agent:
	var a := Agent.new()
	a.is_player = is_pl
	add_child(a)
	a.rng_seed = agents.size()
	a.setup(self, rules, tid, s, side_colors[s], override, hname)
	a.global_position = field.ground(p) + Vector3(0, 0.05, 0)
	a.safe_pos = a.global_position
	a.spawn_origin = a.position
	a.heading = _side_facing(s)
	a.intent_yaw = a.heading
	a.rotation.y = a.heading
	agents.append(a)
	spawned_total[s] += 1
	return a


# ------------------------------------------------------------------ main loop
func _physics_process(dt: float) -> void:
	if over or phase_pending:
		return
	time += dt
	frame += 1
	_rebuild_grid()
	attackers_on.clear()
	for a in agents:
		var t = a.ai.get("target")
		if t != null and is_instance_valid(t):
			var k: int = t.get_instance_id()
			attackers_on[k] = int(attackers_on.get(k, 0)) + 1
	var t0 := Time.get_ticks_usec()
	for a in _tick_agents:
		if a == player and a.is_player:
			ctrl.drive(a, dt)
		elif not a.ai.has("lab"):            # tests/pose_lab.gd drives these by hand
			BattleAI.update(a, self, dt)
	var t1 := Time.get_ticks_usec()
	for a in agents:
		if a.alive() or a.falling():
			a.step(dt)
	var t15 := Time.get_ticks_usec()
	_resolve_overlaps()
	_update_loose_horses(dt)
	var t2 := Time.get_ticks_usec()
	prof["overlap"] = float(prof.get("overlap", 0.0)) + (t2 - t15)
	prof["ai"] = float(prof.get("ai", 0.0)) + (t1 - t0)
	prof["step"] = float(prof.get("step", 0.0)) + (t2 - t1)
	prof["n"] = int(prof.get("n", 0)) + 1
	for a in _tick_agents:
		if not a.alive():
			continue
		if a.routed and _at_edge(a):
			_retire_routed(a)
	_update_arrows(dt)
	_slot_t -= dt
	if _slot_t <= 0.0:
		_slot_t = 1.0
		_assign_slots()
	_cmd_t -= dt
	if _cmd_t <= 0.0:
		_cmd_t = 1.0
		_center_cache.clear()              # the commander sees positions after movement
		_enemy_commander(false)
		_reinforce()
	_morale_t -= dt
	if _morale_t <= 0.0:
		_morale_t = rules.num("morale", "rout_check", 1.5)
		_morale()
	_check_end()
	if _capture_path != "" and time >= _capture_at:
		var path := _capture_path
		_capture_path = ""
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(path)
		get_tree().quit()
	if int(prof.get("n", 0)) % 600 == 0 and OS.get_cmdline_user_args().has("--prof"):
		var n := float(prof.n)
		print("PROF ai %.2fms step %.2fms (overlap %.2f) per frame, alive %d, fps %d" % [prof.ai / n / 1000.0, prof.step / n / 1000.0, prof.get("overlap", 0.0) / n / 1000.0, agents.filter(func(x): return x.alive()).size(), Engine.get_frames_per_second()])


var render_frame := 0


func _process(_delta: float) -> void:
	if _headless:
		return
	render_frame += 1
	_update_markers()
	var cam := get_viewport().get_camera_3d()
	var camera_pos := cam.global_position if cam else Vector3.ZERO
	var view_dir := -cam.global_basis.z if cam else Vector3.ZERO
	for a: Agent in agents:
		if a.rig_done or not a.visible:
			continue
		var world_pos := a.global_position
		var to := world_pos - camera_pos
		var d2 := to.length_squared() if cam else 0.0
		var every := 1 if d2 < 484.0 else (2 if d2 < 2500.0 else (4 if d2 < 10000.0 else 8))
		if d2 > 100.0 and to.dot(view_dir) < 0.0:
			every = 8                   # behind the camera
		if a.rig and a.rig.visible and (render_frame + a.rng_seed) % every == 0:
			a.update_rig()
		# hooves of horses close to the camera
		if sfx and a.mounted and a.speed > 2.5 and a.alive() and cam and d2 < 900.0:
			a.hoof_t -= _delta * a.speed * 0.45
			if a.hoof_t <= 0.0:
				a.hoof_t = 1.0
				sfx.play("hoof", world_pos, -10.0 + a.speed * 0.6)


static func _gkey(cx: int, cz: int) -> int:
	return (cx + 2048) * 4096 + (cz + 2048)          # int keys: no Vector2i allocation per lookup


var alive_by_side: Array = [[], []]      # rebuilt every frame with the grid
var _tick_agents: Array[Agent] = []      # alive at the start of the tick, in spawn order


func _rebuild_grid() -> void:
	_grid.clear()
	_engaged_cache.clear()
	_center_cache.clear()
	alive_by_side[0].clear()
	alive_by_side[1].clear()
	_tick_agents.clear()
	for a: Agent in agents:
		if not a.alive():
			continue
		_tick_agents.append(a)
		alive_by_side[a.side].append(a)
		var p := a.position
		if siege_def >= 0:
			a.siege_level = field.level(p)
		var k := _gkey(floori(p.x / CELL), floori(p.z / CELL))
		var cell = _grid.get(k)
		if cell == null:
			_grid[k] = [a]
		else:
			cell.append(a)


## Soldiers are not physics bodies: push overlapping pairs apart (a horse shoves a man more than
## the other way round), keep everyone out of tree trunks and inside the field.
func _resolve_overlaps() -> void:
	# uses the grid built at the start of this frame (nobody moves more than a fraction of a cell)
	var half := rules.num("battle", "field", 300) * 0.5 - 1.0
	var has_trees := not field.trees.is_empty()
	var works := field.has_works()
	for a in _tick_agents:
		a.overlap_pos = a.position
	for a in _tick_agents:
		if not a.alive():
			continue
		var pa := a.overlap_pos
		var radius := a.radius
		var cx := floori(pa.x / CELL)
		var cz := floori(pa.z / CELL)
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var cell = _grid.get(_gkey(cx + dx, cz + dz))
				if cell == null:
					continue
				for o: Agent in cell:
					if o.rng_seed <= a.rng_seed:
						continue
					var other_pos := o.overlap_pos
					var d := other_pos - pa
					d.y = 0.0
					var need := radius + o.radius
					var l2 := d.length_squared()
					if l2 >= need * need or l2 < 1e-8:
						continue
					var l := sqrt(l2)
					var push := d / l * (need - l)
					var wa: float = 0.15 if a.mounted and not o.mounted else (0.85 if o.mounted and not a.mounted else 0.5)
					pa -= push * wa
					o.overlap_pos = other_pos + push * (1.0 - wa)
		if has_trees:
			for t in field.trees_near(pa):
				var d: Vector3 = pa - t[0]
				d.y = 0.0
				var need := float(t[1]) * 0.6 + radius
				var l2 := d.length_squared()
				if l2 < need * need and l2 > 1e-8:
					pa += d.normalized() * (need - d.length())
					if a.mounted:
						a.speed *= 0.5
		pa.x = clampf(pa.x, -half, half)
		pa.z = clampf(pa.z, -half, half)
		if works:
			var hh := field.height_at(pa.x, pa.z)
			if hh - pa.y > Agent.MAX_STEP or (pa.y - hh > Agent.MAX_DROP and a != player):
				pa = a.safe_pos   # shoved against a wall face or over the edge: stays put
		a.safe_pos = pa
		a.overlap_pos = pa
	# Submit each final position once. Higher spawn indices cannot push earlier agents.
	for a in _tick_agents:
		if a.position != a.overlap_pos:
			a.position = a.overlap_pos


func agents_near(p: Vector3, r: float) -> Array:
	var out: Array = []
	var x0 := floori((p.x - r) / CELL)
	var x1 := floori((p.x + r) / CELL)
	var z0 := floori((p.z - r) / CELL)
	var z1 := floori((p.z + r) / CELL)
	for x in range(x0, x1 + 1):
		for z in range(z0, z1 + 1):
			var cell = _grid.get(_gkey(x, z))
			if cell != null:
				out.append_array(cell)
	return out


func separation(a: Agent) -> Vector3:
	# recomputed every 3rd frame per soldier (staggered); neighbours barely move in between
	if (frame + a.rng_seed) % 3 != 0 and a.ai.has("sep"):
		return a.ai["sep"]
	var push := _separation(a)
	a.ai["sep"] = push
	return push


func _separation(a: Agent) -> Vector3:
	var push := Vector3.ZERO
	for o in agents_near(a.global_position, 1.4):
		if o == a or o.state == Agent.DEAD:
			continue
		var d: Vector3 = a.global_position - o.global_position
		d.y = 0
		var l := d.length()
		if l < 1.2 and l > 0.001:
			push += d / l * (1.2 - l)
	return push


func tree_push(a: Agent) -> Vector3:
	var push := Vector3.ZERO
	var look := a.global_position + a.velocity * 0.6
	for t in field.trees_near(look):
		var d: Vector3 = look - t[0]
		d.y = 0
		var l := d.length()
		var r: float = t[1] + (1.6 if a.mounted else 0.9)
		if l < r and l > 0.001:
			push += d / l * (r - l) / r
	return push


func enemy_center(s: int) -> Vector3:
	if _center_cache.has(s):
		return _center_cache[s]
	var c := Vector3.ZERO
	var n := 0
	for a in agents:
		if a.side != s and a.active():
			c += a.global_position
			n += 1
	var center := c / n if n > 0 else _spawn_center(1 - s)
	_center_cache[s] = center
	return center


func retreat_point(a: Agent) -> Vector3:
	var half := rules.num("battle", "field", 300) * 0.5
	return Vector3(clampf(a.global_position.x, -half + 20, half - 20), 0, half if a.side == 0 else -half)


func _at_edge(a: Agent) -> bool:
	var half := rules.num("battle", "field", 300) * 0.5 - rules.num("battle", "edge_margin", 6)
	return absf(a.global_position.x) > half or absf(a.global_position.z) > half


# ------------------------------------------------------------------ orders & formations
func order_of(a: Agent) -> Dictionary:
	return orders[a.side].get(a.order_key(), {"type": "charge"})


func slot_of(a: Agent) -> Vector3:
	var p = _slots.get(a.get_instance_id())
	if p == null:
		return order_of(a).get("pos", a.global_position)
	return p


func division_agents(s: int, div: String) -> Array:
	return agents.filter(func(a): return a.side == s and a.order_key() == div and a.active() and a != player)


func centroid(lst: Array) -> Vector3:
	var c := Vector3.ZERO
	for a in lst:
		c += a.global_position
	return c / maxi(1, lst.size())


func _assign_slots() -> void:
	for s in 2:
		for div in orders[s]:
			var o: Dictionary = orders[s][div]
			if not o.type in ["hold", "stand", "follow"]:
				continue
			if o.type == "follow" and player and player.alive():
				o.pos = player.global_position - player.forward() * (8.0 if div != "cav" else 14.0)
				o.facing = player.heading
			var lst := division_agents(s, div)
			if lst.is_empty():
				continue
			if o.get("wall", false):
				_wall_slots(lst, div)
				continue
			var f := float(o.facing)
			var fwd := Vector3(-sin(f), 0, -cos(f))
			var rv := Vector3(cos(f), 0, -sin(f))
			var c: Vector3 = o.pos
			lst.sort_custom(func(x, y): return (x.global_position - c).dot(rv) < (y.global_position - c).dot(rv))
			var sp := float(o.get("spacing", 1.15)) * (2.0 if div == "cav" else 1.0)
			var cols := maxi(4, int(ceil(sqrt(lst.size() * 4.0))))
			for k in lst.size():
				var col := k % cols
				var row := k / cols
				var p: Vector3 = c + rv * (col - (mini(cols, lst.size()) - 1) * 0.5) * sp - fwd * row * sp * 1.25
				_slots[lst[k].get_instance_id()] = field.ground(p)


## Siege defenders' posts: archers spread along the wall walk, infantry in knots at the ladder heads
## (the rest wait at the foot of the stairs in the town).
func _wall_slots(lst: Array, div: String) -> void:
	if div == "arc":
		lst.sort_custom(func(x, y): return x.global_position.x < y.global_position.x)
		for k in lst.size():
			var x := clampf((k - (lst.size() - 1) * 0.5) * 1.7, -field.size * 0.45, field.size * 0.45)
			_slots[lst[k].get_instance_id()] = field.wall_point(x, 0.15 + 0.3 * float(k % 2))
		return
	var ladders: Array = field.siege.ladders
	var per := 7                                        # men posted at each ladder head
	var posted := 0
	lst.sort_custom(func(x, y): return x.rng_seed < y.rng_seed)
	var count := {}
	for a in lst:
		# fill the ladder heads in turn, nearest first
		var best := INF
		var pick := INF
		for lx in ladders:
			if int(count.get(lx, 0)) >= per:
				continue
			var d := absf(a.global_position.x - float(lx))
			if d < best:
				best = d
				pick = lx
		if pick == INF:
			var sx: float = field._nearest(field.siege.stairs, a.global_position.x)
			_slots[a.get_instance_id()] = field.siege_point(sx + randf_range(-4, 4), BattleField.W_BACK + BattleField.STAIR_LEN + 4.0 + (posted % 3) * 1.5)
			posted += 1
			continue
		var k := int(count.get(pick, 0))
		count[pick] = k + 1
		var row := k / 4
		var col := k % 4
		_slots[a.get_instance_id()] = field.wall_point(float(pick) + (col - 1.5) * 1.2, 0.2 + 0.35 * row)


## Player's orders (Warband keys): groups = ["inf", "arc", "cav"] subset; kind = hold / follow / charge /
## stand / retreat / advance / fallback / closer / spread
## "步兵" / "射手" / "骑兵", or "第4队".."第9队" for the custom groups.
static func group_name(g: String) -> String:
	return {"inf": "步兵", "arc": "射手", "cav": "骑兵"}.get(g, "第%s队" % g.substr(1))


## Ctrl+4..9: the soldiers of the selected groups within `radius` of you become custom group g (Warband's
## group assignment, here by distance). The group starts with the order its first member had.
func assign_group(s: int, from_groups: Array, g: String, radius: float) -> int:
	if player == null:
		return 0
	var n := 0
	var first: Dictionary = {}
	for a in agents:
		if a.side != s or not a.active() or a == player or not (a.order_key() in from_groups):
			continue
		if a.global_position.distance_to(player.global_position) > radius:
			continue
		if first.is_empty():
			first = order_of(a).duplicate(true)
		a.group = g
		n += 1
	if n > 0:
		if not orders[s].has(g):
			orders[s][g] = first if not first.is_empty() else {"type": "follow", "pos": player.global_position,
				"facing": player.heading, "spacing": rules.num("ai", "spacing", 1.15)}
		for a in agents:
			if a.side == s and a.group == g:
				a.ai["next"] = 0.0
	return n


## M / Shift+M: the selected groups' horsemen get off and fight on foot (their horses wait beside them),
## or go back to their horses and mount.
func order_mount(s: int, groups: Array, mount: bool) -> int:
	var n := 0
	for a in agents:
		if a.side != s or not a.active() or a == player or not (a.order_key() in groups):
			continue
		if not mount and a.mounted:
			var rec: Dictionary = a.horse_record()
			spawn_loose_horse(a, rec, 0.0, a.right() * -1.3)
			loose_horses.back()["owner"] = a
			if a.group == "":
				a.group = "cav"              # still commanded with the cavalry
			a.dismount()
			a.set_meta("dismount_order", true)
			n += 1
		elif mount and not a.mounted and (a.has_meta("dismount_order") or a.has_meta("lost_horse")):
			if a.has_meta("dismount_order"):
				a.remove_meta("dismount_order")
			a.set_meta("lost_horse", true)          # BattleAI._grab runs to a horse (its own first)
			a.ai["next"] = 0.0
			n += 1
	return n


## The riderless horse this agent left when ordered off it (or -1).
func own_horse(a: Agent) -> int:
	for i in loose_horses.size():
		if loose_horses[i].get("owner") == a:
			return i
	return -1


func command(s: int, groups: Array, kind: String, destination: Variant = null) -> void:
	var who: Array[String] = []
	for g in groups:
		if not orders[s].has(g):
			continue
		who.append(group_name(g))
		var o: Dictionary = orders[s][g]
		if kind in ["hold_fire", "fire"]:
			o["hold_fire"] = kind == "hold_fire"
			for a: Agent in division_agents(s, g):
				a.ai["next"] = 0.0
			continue
		if kind not in ["closer", "spread"]:
			o.erase("wall")
		var lst := division_agents(s, g)
		match kind:
			"hold":
				o.type = "hold"
				o.pos = destination if destination is Vector3 else (player.global_position if player else centroid(lst))
				o.facing = player.heading if player else o.facing
			"follow":
				o.type = "follow"
			"charge":
				o.type = "charge"
			"stand":
				o.type = "stand"
				o.pos = centroid(lst)
				o.facing = player.heading if player else o.facing
			"retreat":
				o.type = "retreat"
			"advance", "fallback":
				if not o.type in ["hold", "stand"]:
					o.type = "hold"
					o.pos = centroid(lst)
					o.facing = player.heading if player else o.facing
				var f := float(o.facing)
				var st := rules.num("orders", "step", 10) * (1.0 if kind == "advance" else -1.0)
				o.pos = (o.pos as Vector3) + Vector3(-sin(f), 0, -cos(f)) * st
			"closer", "spread":
				o.spacing = clampf(float(o.get("spacing", 1.15)) + (-0.35 if kind == "closer" else 0.35),
					rules.num("orders", "spacing_min", 0.8), rules.num("orders", "spacing_max", 3.0))
	_slot_t = 0.0
	var txt := {"hold": "原地驻守！", "follow": "跟我来！", "charge": "冲锋！", "stand": "就地站住！", "retreat": "撤退！",
		"advance": "前进十步！", "fallback": "后退十步！", "closer": "靠拢！", "spread": "散开！",
		"hold_fire": "停止射击！", "fire": "自由射击！"}
	message("%s：%s" % ["、".join(who), txt.get(kind, kind)], Color("f2c75c"))


## The AI general of each side the player doesn't command (Warband-like: archers hold and shoot,
## infantry waits in front of them until the enemy closes, cavalry charges).
func _enemy_commander(first: bool) -> void:
	for s in 2:
		if s == player_side and player and not auto and player.alive():
			continue
		if s == player_side and first and not auto:
			continue
		var o: Dictionary = orders[s]
		var c := _spawn_center(s)
		var fwd := Vector3(0, 0, -1) if s == 0 else Vector3(0, 0, 1)
		if siege_def >= 0:
			_siege_commander(s, first)
			continue
		if first:
			o.arc.type = "hold"
			o.arc.pos = c + fwd * 4.0
			o.arc.facing = _side_facing(s)
			o.inf.type = "hold"
			o.inf.pos = c + fwd * 14.0
			o.inf.facing = _side_facing(s)
			o.cav.type = "charge"
			continue
		var inf := division_agents(s, "inf")
		var arc := division_agents(s, "arc")
		var foe := enemy_center(s)
		if o.inf.type == "hold":
			var near := INF if inf.is_empty() else centroid(inf).distance_to(foe)
			var my_arc_ammo := 0
			for a in arc:
				my_arc_ammo += a.ammo
			if near < 45.0 or time > 40.0 or (arc.size() > 0 and my_arc_ammo == 0):
				o.inf.type = "charge"
		if o.arc.type == "hold" and not arc.is_empty():
			var ac := centroid(arc)
			for e in agents_near(ac, 14.0):
				if e.side != s and e.active():
					o.arc.type = "charge"          # the enemy is on top of the archers: draw swords
					break
		if time > 120.0:
			o.arc.type = "charge"


## Siege: the garrison holds the wall to the last; the attackers' archers shoot from below while
## everyone else goes up the ladders.
func _siege_commander(s: int, first: bool) -> void:
	var o: Dictionary = orders[s]
	if s == siege_def:
		if first:
			for div in ["arc", "inf", "cav"]:
				o[div].type = "hold"
				o[div].wall = true
				o[div].pos = field.wall_point(0.0, 0.5)
				o[div].facing = _side_facing(s)
		return
	if first:
		o.arc.type = "hold"
		o.arc.pos = field.siege_point(0.0, BattleField.W_FRONT - 34.0)
		o.arc.facing = _side_facing(s)
		o.inf.type = "charge"
		o.cav.type = "charge"
		return
	var arc := division_agents(s, "arc")
	var ammo := 0
	for a in arc:
		ammo += a.ammo
	if o.arc.type == "hold" and (ammo == 0 or time > 150.0):
		o.arc.type = "charge"


func _reinforce() -> void:
	var wave_limit := int(rules.num("battle", "reinforcement_waves", 2))
	for s in 2:
		if reserves[s].is_empty() or _waves[s] >= wave_limit:
			continue
		var on := 0
		for a in agents:
			if a.side == s and a.alive():     # routed troops still occupy a slot until they exit
				on += 1
		if on > 0 and on < share[s] * rules.num("battle", "reinforce_at", 0.35):
			_waves[s] += 1
			_spawn_wave(s, share[s] - on)
			message("%s的援军赶到了" % side_names[s], Color("8fd3a0") if s == player_side else Color("ff8f8f"))


func _morale() -> void:
	if setup.get("arena", false):
		return                      # a bout in the arena: nobody runs
	var M := "morale"
	for s in 2:
		if s == siege_def:
			continue                # a garrison has nowhere to run: it holds the wall to the last
		var lost := 0
		for a in agents:
			if a.side == s and (not a.alive() or a.routed):
				lost += 1
		var ratio := float(lost) / maxf(1.0, initial_total[s])
		var start := rules.num(M, "start_rout", 0.45)
		if ratio <= start:
			continue
		var leader_up := false
		for a in agents:
			if a.side == s and a.active() and (a == player or a.hero_name != ""):
				leader_up = true
		for a in agents:
			if a.side != s or not a.active() or a == player:
				continue
			var p: float = rules.num(M, "rout_chance", 0.06) * (1.0 + 3.0 * (ratio - start) / (1.0 - start)) \
				- rules.num(M, "tier_courage", 0.012) * a.tier()
			if leader_up:
				p *= rules.num(M, "leader_bonus", 0.5)
			if randf() < p:
				a.routed = true
				a.ai["target"] = null
				if not routing_announced[s]:
					routing_announced[s] = true
					message("%s开始溃逃！" % side_names[s], Color("8fd3a0") if s != player_side else Color("ff8f8f"))


func _check_end() -> void:
	var remaining := [0, 0]
	for a: Agent in agents:
		if a.active():
			remaining[a.side] += 1
	for s in 2:
		if remaining[s] == 0 and reserves[s].is_empty():
			end_battle(1 - s, "")
			return
	if remaining[0] > 0 and remaining[1] > 0:
		return
	phase_pending = true
	if _headless or auto or not player or not player.alive():
		continue_phase()


func _retire_routed(a: Agent) -> void:
	a.outcome = "routed"
	a.state = Agent.DEAD
	a.hide()
	a.rig.queue_free()
	a.rig = null


func continue_phase() -> void:
	if not phase_pending or over:
		return
	phase_pending = false
	phase += 1
	_waves = [0, 0]
	var remaining := [0, 0]
	for a: Agent in agents:
		if not a.alive():
			continue
		if a.routed:
			_retire_routed(a)
			continue
		remaining[a.side] += 1
		a.regroup(_side_facing(a.side))
	for ar in arrows:
		if ar.node:
			ar.node.queue_free()
	arrows.clear()
	attackers_on.clear()
	for s in 2:
		for div in orders[s]:
			var order: Dictionary = orders[s][div]
			order.type = "charge"
			order.pos = _spawn_center(s)
			order.facing = _side_facing(s)
		_spawn_wave(s, share[s] - remaining[s])
	_enemy_commander(true)
	if player and player_side == siege_def and player.alive():
		_siege_commander(player_side, true)
	_rebuild_grid()
	_slot_t = 0.0
	_cmd_t = 1.0
	message("第 %d 阶段：双方重新列阵" % phase, Color("f2c75c"))


## Tab: leave the field. Allowed only if no enemy is close (like Warband).
func request_retreat() -> bool:
	if phase_pending:
		end_battle(1 - player_side, "retreat")
		return true
	if over:
		return false
	if player and player.alive() and not setup.get("arena", false):      # in the arena Tab = concede
		for a in agents_near(player.global_position, 40.0):
			if a.side != player_side and a.active():
				message("附近有敌人，无法撤离", Color("ff8f8f"))
				return false
	end_battle(1 - player_side, "retreat")
	return true


## After the player falls: let the troops fight it out quickly.
func auto_finish() -> void:
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 32
	Engine.time_scale = 4.0
	message("你倒下了，部下仍在作战……（加速中）", Color("ff8f8f"))


# ------------------------------------------------------------------ combat resolution
## Closest body part of any agent touched by the segment [p0, p1] (pad = extra radius).
## Returns [agent, point, part] or [] — part: "body" / "head" / "horse"
func segment_hit(att: Agent, p0: Vector3, p1: Vector3, pad: float, skip_side := -1) -> Array:
	var target: Agent = null
	var part := ""
	var best_t := INF
	var ray := p1 - p0
	var ray_sq := ray.length_squared()
	var mid := (p0 + p1) * 0.5
	var half_span := ray.abs() * 0.5
	var body_radius := (0.27 + pad) * (0.27 + pad)
	var head_radius := (0.14 + pad) * (0.14 + pad)
	var horse_radius := (0.36 + pad) * (0.36 + pad)
	for o: Agent in agents_near(mid, sqrt(ray_sq) * 0.5 + 2.5):
		if o == att or not o.alive() or o.state == Agent.DOWN or o.side == skip_side:
			continue
		var base: Vector3 = o.global_position
		# Reject grid neighbours whose body capsules cannot reach the segment.
		# A horse's horizontal envelope includes its 0.7 m axis and 0.36 m radius.
		var mounted: bool = o.mounted
		var horizontal := (1.06 if mounted else 0.27) + pad + 0.001
		var offset := base - mid
		if absf(offset.x) > half_span.x + horizontal or absf(offset.z) > half_span.z + horizontal:
			continue
		var low := (0.89 if mounted else 0.03) - pad - 0.001
		var high := (2.74 if mounted else 1.86) + pad + 0.001
		if offset.y + low > half_span.y or offset.y + high < -half_span.y:
			continue
		var body_start := base + Vector3.UP * (1.75 if mounted else 0.3)
		var body_end := base + Vector3.UP * (2.4 if mounted else 1.45)
		var t := _capsule_hit_t(p0, ray, ray_sq, body_start, body_end, body_radius)
		if t < best_t:
			best_t = t
			target = o
			part = "body"
		var head_start := base + Vector3.UP * (2.4 if mounted else 1.5)
		var head_end := base + Vector3.UP * (2.6 if mounted else 1.72)
		t = _capsule_hit_t(p0, ray, ray_sq, head_start, head_end, head_radius)
		if t < best_t:
			best_t = t
			target = o
			part = "head"
		if mounted:
			var back := base + Vector3(0, 1.25, 0)
			var axis := o.forward() * 0.7
			t = _capsule_hit_t(p0, ray, ray_sq, back + axis, back - axis, horse_radius)
			if t < best_t:
				best_t = t
				target = o
				part = "horse"
	return [target, p0 + ray * best_t, part] if target != null else []


## Parameter of closest approach if the path touches the capsule, INF on a miss.
static func _capsule_hit_t(p1: Vector3, d1: Vector3, a: float, p2: Vector3, q2: Vector3, radius_sq: float) -> float:
	var d2 := q2 - p2
	var r := p1 - p2
	var e := d2.dot(d2)
	var f := d2.dot(r)
	var s := 0.0
	var t := 0.0
	if a <= 1e-6 and e <= 1e-6:
		return 0.0 if r.length_squared() <= radius_sq else INF
	if a <= 1e-6:
		t = clampf(f / e, 0.0, 1.0)
	else:
		var c := d1.dot(r)
		if e <= 1e-6:
			s = clampf(-c / a, 0.0, 1.0)
		else:
			var b := d1.dot(d2)
			var den := a * e - b * b
			s = clampf((b * f - c * e) / den, 0.0, 1.0) if den > 1e-6 else 0.0
			t = (b * s + f) / e
			if t < 0.0:
				t = 0.0
				s = clampf(-c / a, 0.0, 1.0)
			elif t > 1.0:
				t = 1.0
				s = clampf((b - c) / a, 0.0, 1.0)
	var c1 := p1 + d1 * s
	var c2 := p2 + d2 * t
	return s if c1.distance_squared_to(c2) <= radius_sq else INF


func _armor(raw: float, armor: float, dtype: String) -> float:
	var A := "armor"
	var soak := rules.num(A, dtype + "_soak", 0.4)
	var red := minf(rules.num(A, "max_reduce", 0.85), armor * rules.num(A, dtype + "_reduce", 0.7) / 100.0)
	return maxf(0.0, raw - armor * soak) * (1.0 - red)


func _speed_bonus(att: Agent, tgt: Agent) -> float:
	var to := (tgt.global_position - att.global_position)
	to.y = 0
	to = to.normalized()
	var rel := att.velocity - tgt.velocity
	var along := maxf(0.0, rel.dot(to))
	if att.mounted:
		along = maxf(along, att.speed * 0.45)
	return clampf(along / rules.num("combat", "speed_bonus_ref", 6.0), -0.3, 1.0) * rules.num("combat", "speed_bonus_max", 1.2)


func _blocked(att: Agent, tgt: Agent) -> bool:
	if not tgt.blocking():
		return false
	var to_att := (att.global_position - tgt.global_position)
	to_att.y = 0
	var ang := rad_to_deg(tgt.forward().angle_to(to_att.normalized()))
	if tgt.shield_up():
		return ang <= rules.num("combat", "shield_angle", 100)
	return ang <= rules.num("combat", "block_angle", 75) and tgt.block_dir == att.attack_dir


func melee_hit(att: Agent, tgt: Agent, point: Vector3, part: String, thrust: bool, early: bool, _motion: Vector3) -> void:
	var C := "combat"
	var w := att.weapon()
	stat("melee_contact")
	if tgt.side == att.side and not att.is_player:
		# an AI soldier's swing that catches a comrade just glances off (Warband: "hit a teammate")
		stat("ally_bounce")
		att.state = Agent.STUN
		att.state_t = 0.0
		att.state_len = 0.2
		return
	if part != "horse" and _blocked(att, tgt):
		stat("blocked")
		att.state = Agent.STUN
		att.state_t = 0.0
		att.state_len = rules.num(C, "block_stun", 0.4)
		_effect(point, Color("ffd27a"), 6)
		sound("shield" if tgt.shield_up() else "clash", point)
		if tgt.shield_up():
			var key := "shield_thrust" if thrust else ("shield_axe" if str(w.get("kind", "")) == "two_hand"
				else ("shield_blunt" if str(w.get("dtype", "")) == "blunt" else "shield_cut"))
			tgt.damage_shield(float(w.get("thrust" if thrust else "damage", 20)) * att.damage_mult() * rules.num(C, key, 1.0))
		if att == player or tgt == player:
			message("格挡！" if tgt == player else "被挡住了", Color("cfd6dc"))
		return
	var raw := float(w.get("thrust" if thrust else "damage", 20))
	var dtype: String = "pierce" if thrust else str(w.get("dtype", "cut"))
	if early:
		raw *= rules.num(C, "early_damage", 0.35)
	raw *= (1.0 + _speed_bonus(att, tgt)) * (1.0 + 0.06 * att.tier()) * randf_range(0.85, 1.15)
	raw *= att.damage_mult()
	_count_hit(att, att.prof_kind())
	_apply(att, tgt, raw, dtype, part, point, early)


func couch_hit(att: Agent, tgt: Agent, point: Vector3, part: String) -> void:
	var w := att.weapon()
	var raw := float(w.get("couch", 60)) * (1.0 + _speed_bonus(att, tgt)) * randf_range(0.9, 1.1)
	stat("couch")
	if att == player:
		message("端枪冲刺！", Color("f2c75c"))
	_apply(att, tgt, raw, "pierce", part, point, false)


func bump(att: Agent, tgt: Agent) -> void:
	var H := "horse"
	var raw := rules.num(H, "bump_damage", 6) * att.speed / rules.num(H, "bump_speed", 5.5)
	stat("bump")
	att.speed *= rules.num(H, "bump_slow", 0.45)
	_apply(att, tgt, raw, "blunt", "body", tgt.chest(), false, randf() < rules.num(H, "bump_knock", 0.45))


func kick(att: Agent) -> void:
	var reach := rules.num("combat", "kick_reach", 1.15)
	var from := att.global_position + Vector3.UP * 0.72
	var hit := segment_hit(att, from, from + att.forward() * reach, 0.12)
	if hit.is_empty():
		return
	var target: Agent = hit[0]
	if target.side == att.side or target.mounted:
		return
	target.take_hit(rules.num("combat", "kick_damage", 3.0) * damage_scale(target), att, false, true)
	if target.alive():
		target._set_state(Agent.STUN, rules.num("combat", "kick_stun", 0.48))
	else:
		_feed(att, target)
	sound("thud", hit[1])
	stat("kicks")


func _apply(att: Agent, tgt: Agent, raw: float, dtype: String, part: String, point: Vector3, early: bool, force_knock := false) -> void:
	var C := "combat"
	if tgt.side == att.side:
		raw *= rules.num(C, "friendly_fire", 0.5)
	if part == "horse":
		var harm := rules.num("horse", "barded_armor", 28) if tgt.horse_kind == "barded" else 6.0
		if tgt.horse_armor >= 0.0:
			harm = tgt.horse_armor                  # the player's own horse (rules/items.toml)
		var hd := _armor(raw, harm, dtype) * damage_scale(tgt)
		tgt.hit_horse(hd, att)
		_effect(point, Color("8a1a14"), 5)
		return
	if part == "head":
		raw *= 1.25
	if siege_def >= 0 and not att.using_ranged and att.global_position.y > tgt.global_position.y + 0.6:
		raw *= 1.0 + rules.num("siege", "height_edge", 0.25)    # striking down from the wall
	var dmg := _armor(raw, tgt.head_armor if part == "head" else tgt.armor, dtype) * damage_scale(tgt)
	if not att.using_ranged:
		sound("thud" if dtype == "blunt" else "hit", point, clampf(-8.0 + dmg * 0.25, -8.0, 3.0))
	stat("dmg_" + att.division, int(dmg))
	if tgt.side == att.side:
		stat("friendly_hits")
		stat("ff_" + ("ranged" if att.using_ranged else "melee"))
	var knock := force_knock or dmg >= rules.num(C, "knockdown_damage", 34) or (dtype == "blunt" and dmg >= rules.num(C, "knockdown_damage", 34) * 0.7)
	var was_alive := tgt.alive()
	tgt.take_hit(dmg, att, knock, dtype == "blunt")
	_effect(point, Color("a01a12"), 4 + int(dmg / 8))
	if att == player:
		hud_hit(int(dmg), early)
	if was_alive and not tgt.alive():
		_feed(att, tgt)
	elif tgt == player and hud and hud.has_method("hurt"):
		hud.hurt(int(dmg))
	if tgt == player and ctrl and ctrl.has_method("jolt"):
		ctrl.jolt(clampf(0.3 + dmg / 40.0, 0.3, 1.0))


## Difficulty: damage taken by the player (and his horse) / by his troops and allies.
## Falling off the wall or a ladder (drop in metres).
func fall_damage(a: Agent, drop: float) -> void:
	var dmg := (drop - 2.5) * 9.0 * damage_scale(a)
	if dmg > 1.0:
		sound("thud", a.global_position, -4.0)
		a.take_hit(dmg, null, true, true)


func damage_scale(tgt: Agent) -> float:
	if tgt == player and tgt.is_player:
		return float(diff.player_damage)
	if tgt.side == player_side and player != null:
		return float(diff.ally_damage)
	return 1.0


## Difficulty: combat AI level 0 (poor) .. 2 (good), as an offset into battle.toml [difficulty] lists.
func ai_skill(key: String) -> float:
	var arr = rules.sec("difficulty").get(key, [0.0, 0.0, 0.0])
	return float(arr[clampi(int(diff.ai_level), 0, arr.size() - 1)])


func sound(kind: String, pos: Vector3, vol := 0.0, pitch := 1.0) -> void:
	if sfx:
		sfx.play(kind, pos, vol, pitch)


func _feed(att: Agent, tgt: Agent) -> void:
	var verb := "击倒了" if tgt.outcome == "wounded" else "杀死了"
	var a_name: String = "你" if att == player else (att.hero_name if att.hero_name != "" else att.troop.name)
	var t_name: String = "你" if tgt == player else (tgt.hero_name if tgt.hero_name != "" else tgt.troop.name)
	var col := Color("8fd3a0") if att.side == player_side else Color("ff8f8f")
	if att.side == tgt.side:
		col = Color("e0a030")
		verb = "误伤了"
	if hud and hud.has_method("feed"):
		hud.feed("%s %s %s" % [a_name, verb, t_name], col)


func hud_hit(dmg: int, early: bool) -> void:
	if hud and hud.has_method("hit_marker"):
		hud.hit_marker(dmg, early)


func on_agent_down(a: Agent) -> void:
	if not _headless:
		_corpses.append(a)
		var limit := maxi(0, int(rules.num("battle", "corpse_limit", 30)))
		if _corpses.size() > limit:
			var oldest: Agent = _corpses.pop_front()
			oldest.hide()
			oldest.rig.queue_free()
			oldest.rig = null
	if siege_def >= 0:
		var by: Agent = a.last_attacker
		stat("down_s%d_lv%d_by_%s" % [a.side, field.level(a.global_position), "fall" if by == null else ("arrow" if by.using_ranged else "melee")])
	if a == player:
		message("你被打倒了！按 Tab 让部下继续作战", Color("ff6b5b"))
		if auto:
			return
	if a.hero_name != "" and a != player:
		message("%s倒下了！" % a.hero_name, Color("f2c75c"))


func on_horse_killed(a: Agent, by: Agent) -> void:
	if a == player:
		message("你的马被杀死了！", Color("ff8f8f"))
	elif by == player:
		message("你杀死了对方的马", Color("cfd6dc"))


func _effect(p: Vector3, c: Color, n: int) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var parts := CPUParticles3D.new()
	parts.one_shot = true
	parts.emitting = false
	parts.amount = clampi(n, 2, 24)
	parts.lifetime = 0.5
	parts.explosiveness = 1.0
	parts.direction = Vector3.UP
	parts.spread = 70.0
	parts.initial_velocity_min = 1.5
	parts.initial_velocity_max = 3.5
	parts.gravity = Vector3(0, -9.8, 0)
	var m := SphereMesh.new()
	m.radius = 0.035
	m.height = 0.07
	m.radial_segments = 4
	m.rings = 2
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.material = mat
	parts.mesh = m
	add_child(parts)
	parts.global_position = p
	parts.emitting = true
	get_tree().create_timer(1.0).timeout.connect(parts.queue_free)


# ------------------------------------------------------------------ arrows
## Is enemy e in hand-to-hand fighting with soldiers of `my_side`?
func engaged_with_ally(e: Agent, my_side: int) -> bool:
	# There are exactly two sides; the enemy id also identifies the querying side.
	var key := e.get_instance_id()
	if _engaged_cache.has(key):
		return _engaged_cache[key]
	for o in agents_near(e.global_position, 2.2):
		if o.side == my_side and o.alive() and not o.using_ranged:
			if o.global_position.distance_squared_to(e.global_position) < 2.2 * 2.2:
				_engaged_cache[key] = true
				return true
	_engaged_cache[key] = false
	return false


## Is a comrade standing in the line of fire (first 80 % of the way)? AI archers hold their shot.
func ally_in_line(a: Agent, to: Vector3) -> bool:
	var from := a.chest()
	var d := to - from
	var L := d.length()
	if L < 0.1:
		return false
	var dir := d / L
	var s := 3.0
	while s < L * 0.8:
		var q := from + dir * s
		for o in agents_near(q, 1.2):
			if o != a and o.side == a.side and o.alive() and not o.mounted:
				var off: Vector3 = o.chest() - q
				off.y *= 0.5
				# the arc rises over close comrades at long range
				if off.length() < 1.5 and (s < 30.0 or L < 45.0):
					return true
		s += 2.5
	return false


# ------------------------------------------------------------------ riderless horses (Warband)
## {pos, heading, speed, phase, rec (Agent.horse_record), node, rig}: a horse whose rider fell runs on,
## slows and stands; you can walk up and mount it (F). Scenery otherwise: they don't block anyone.
var loose_horses: Array = []
const LOOSE_HORSE_LIMIT := 40


func spawn_loose_horse(a: Agent, rec: Dictionary, run_speed: float, offset := Vector3.ZERO) -> void:
	var h := {"pos": a.global_position + offset, "heading": a.heading + randf_range(-0.7, 0.7),
		"speed": run_speed, "phase": 0.0, "rec": rec, "node": null, "rig": null}
	if DisplayServer.get_name() != "headless":
		var node := Node3D.new()
		add_child(node)
		node.global_position = h.pos
		node.rotation.y = h.heading
		var rig := AgentRig.new()
		node.add_child(rig)
		rig.build_horse_only(a)
		h.node = node
		h.rig = rig
	loose_horses.append(h)
	if loose_horses.size() > LOOSE_HORSE_LIMIT:
		var old: Dictionary = loose_horses.pop_front()
		if old.node:
			old.node.queue_free()


func _update_loose_horses(dt: float) -> void:
	var half := field.size * 0.48
	for h in loose_horses:
		if h.speed > 0.0:
			h.speed = maxf(0.0, h.speed - 1.6 * dt)
			var f := Vector3(-sin(h.heading), 0, -cos(h.heading))
			var p: Vector3 = h.pos + f * h.speed * dt
			p.x = clampf(p.x, -half, half)
			p.z = clampf(p.z, -half, half)
			p.y = field.height_at(p.x, p.z)
			h.pos = p
			h.phase += dt * h.speed * 1.7
		# a horse takes up room: nobody walks through it
		for a in agents_near(h.pos, 1.3):
			if not a.alive() or a.mounted:
				continue
			var off: Vector3 = a.global_position - (h.pos as Vector3)
			off.y = 0.0
			var dist := off.length()
			var need: float = 0.75 + a.radius
			if dist < need and dist > 0.001:
				a.global_position += off / dist * (need - dist)
		if h.node:
			h.node.global_position = h.pos
			h.node.rotation.y = h.heading
			h.rig.pose_horse(h.phase, h.speed)


func _nearest_loose_horse(p: Agent, within: float) -> int:
	var best := -1
	var bd := within
	for i in loose_horses.size():
		var d: float = (loose_horses[i].pos as Vector3).distance_to(p.global_position)
		if d < bd and float(loose_horses[i].speed) < 3.5:
			bd = d
			best = i
	return best


## F: dismount, mount a riderless horse nearby, or pick a weapon up off the ground.
func interact(p: Agent) -> void:
	if p == null or not p.alive() or p.busy() or p.attacking():
		return
	if p.mounted:
		if p.speed > 3.0:
			message("马跑得太快，先勒马（S）再下马", Color("e0b070"))
			return
		spawn_loose_horse(p, p.horse_record(), 0.0, p.right() * -1.4)
		p.dismount()
		message("你下了马", Color("cfd6dc"))
		return
	var i := _nearest_loose_horse(p, 3.0)
	if i >= 0:
		mount_agent(p, i)
		return
	pick_up(p)


## Put an agent on the riderless horse loose_horses[i] (you with F, a horseman who lost his own: BattleAI).
func mount_agent(p: Agent, i: int) -> void:
	var h: Dictionary = loose_horses[i]
	loose_horses.remove_at(i)
	if h.node:
		h.node.queue_free()
	p.global_position = Vector3(h.pos.x, p.global_position.y, h.pos.z)
	p.heading = h.heading
	p.mount(h.rec)
	if p.has_meta("lost_horse"):
		p.remove_meta("lost_horse")
	if p == player:
		message("你骑上了%s" % _horse_name(h.rec), Color("cfd6dc"))
	else:
		stat("remount")


## How good a melee weapon is (for an AI deciding to pick one up).
static func weapon_value(w: Dictionary) -> float:
	if w.is_empty() or str(w.get("kind", "")) == "unarmed":
		return 0.0
	return maxf(float(w.get("damage", 0)), float(w.get("thrust", 0))) * float(w.get("speed", 1.0)) * (0.8 + 0.2 * float(w.get("reach", 1.2)))


func _horse_name(rec: Dictionary) -> String:
	return "具装甲马" if str(rec.get("kind", "")) == "barded" else "战马"


# ------------------------------------------------------------------ weapons on the ground
## {pos, weapon (dict as in a loadout), node}: what the fallen dropped. F swaps it with the weapon in hand.
var drops: Array = []
const DROP_LIMIT := 60


func drop_weapon(w: Dictionary, at: Vector3) -> void:
	if w.is_empty() or str(w.get("kind", "")) == "unarmed":
		return
	var pos := Vector3(at.x + randf_range(-0.6, 0.6), 0.0, at.z + randf_range(-0.6, 0.6))
	pos.y = field.height_at(pos.x, pos.z) + 0.04
	var d := {"pos": pos, "weapon": w, "node": null}
	if DisplayServer.get_name() != "headless":
		var mi := Node3D.new()
		add_child(mi)
		AgentRig.Art.add(mi, AgentRig.Equipment.melee(w, maxf(0.35, float(w.get("reach", 1.4)) - 0.75)))
		mi.global_position = pos
		mi.rotation = Vector3(0, randf() * TAU, PI * 0.5)        # lying on its side
		d.node = mi
	drops.append(d)
	if drops.size() > DROP_LIMIT:
		var old: Dictionary = drops.pop_front()
		if old.node:
			old.node.queue_free()


func _nearest_drop(p: Agent, within: float) -> int:
	var best := -1
	var bd := within
	for i in drops.size():
		var d: float = (drops[i].pos as Vector3).distance_to(p.global_position)
		if d < bd:
			bd = d
			best = i
	return best


func pick_up(p: Agent) -> void:
	var i := _nearest_drop(p, 2.2)
	if i < 0:
		return
	var d: Dictionary = drops[i]
	drops.remove_at(i)
	if d.node:
		d.node.queue_free()
	var w: Dictionary = d.weapon
	if not p.usable(w):
		if p == player:
			message("%s马上用不了" % str(w.get("name", "")), Color("e0b070"))
		drops.insert(i, d)
		return
	var old: Dictionary = p.weapon() if not p.melee.is_empty() else {}
	if p.melee.is_empty():
		p.melee.append(w)
		p.melee_idx = 0
	else:
		p.melee[p.melee_idx] = w
	p.using_ranged = false
	p.rig.set_weapon(p.weapon())
	drop_weapon(old, p.global_position)
	if p == player:
		message("你拾起了%s" % str(w.get("name", "兵器")), Color("cfd6dc"))
	else:
		stat("pickup")


## What F would do right now (the HUD shows it).
func interact_hint(p: Agent) -> String:
	if p == null or not p.alive():
		return ""
	if p.mounted:
		return ""
	var i := _nearest_loose_horse(p, 3.0)
	if i >= 0:
		return "F 上马（%s）" % _horse_name(loose_horses[i].rec)
	var w := _nearest_drop(p, 2.2)
	if w >= 0:
		return "F 拾起%s" % str(drops[w].weapon.get("name", "兵器"))
	return ""


# ------------------------------------------------------------------ friendly markers (hold Alt)
const GROUP_COLORS := {"inf": Color("efe6d2"), "arc": Color("8fd36a"), "cav": Color("6fa8ff"), "g4": Color("f2c75c"),
	"g5": Color("ff9f5a"), "g6": Color("d58cff"), "g7": Color("5ad8d0"), "g8": Color("ff6b8a"), "g9": Color("b8b8b8")}
var _markers_on := false
var _markers_test := OS.get_cmdline_user_args().has("--markers")     # tests / screenshots: always shown


## Warband's troop banners: while Alt is held, a small marker in the group's colour over every soldier on your side.
func _update_markers() -> void:
	var want := (Input.is_key_pressed(KEY_ALT) or _markers_test) and not peaceful and not over
	if not want and not _markers_on:
		return
	_markers_on = want
	for a in agents:
		if a.side != player_side or a == player:
			continue
		var m: Label3D = a.get_meta("marker") if a.has_meta("marker") else null
		if not want or not a.active():
			if m:
				m.visible = false
			continue
		if m == null:
			m = Label3D.new()
			m.text = "▼"
			m.font_size = 40
			m.pixel_size = 0.0007
			m.fixed_size = true                       # the same small size near and far
			m.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			m.no_depth_test = true
			m.outline_size = 10
			a.add_child(m)
			a.set_meta("marker", m)
		m.position = Vector3(0, 3.1 if a.mounted else 2.35, 0)
		m.modulate = GROUP_COLORS.get(a.order_key(), Color.WHITE)
		m.visible = true


## Your hits on enemies by weapon kind: the server turns them into weapon proficiency.
var player_hits := {}
var companion_agents: Array = []


func _companion_outcomes() -> Dictionary:
	var out := {}
	for a in companion_agents:
		if is_instance_valid(a):
			out[str(a.get_meta("companion"))] = a.outcome if a.outcome != "" else "fine"
	return out


func _count_hit(att: Agent, kind: String) -> void:
	if att != null and att == player and kind != "":
		player_hits[kind] = int(player_hits.get(kind, 0)) + 1


func spawn_arrow(owner: Agent, from: Vector3, vel: Vector3, dmg: float) -> void:
	var node: MeshInstance3D = null
	if DisplayServer.get_name() != "headless":
		node = MeshInstance3D.new()
		node.mesh = _arrow_mesh
		node.material_override = _arrow_mat
		if is_instance_valid(owner) and owner.is_thrower():
			# a javelin is a long shaft; a throwing axe a short, thick one
			node.scale = Vector3(1.6, 1.6, 2.4) if owner.ranged.get("id", "") == "javelin" else Vector3(3.0, 3.0, 0.75)
		add_child(node)
	stat("arrows")
	arrows.append({"origin": from, "pos": from, "vel": vel, "owner": owner, "dmg": dmg, "life": rules.num("ranged", "arrow_life", 6.0),
		"node": node, "stuck": false})
	if arrows.size() > 500:
		var old: Dictionary = arrows.pop_front()
		if old.node:
			old.node.queue_free()


func _update_arrows(dt: float) -> void:
	var g := rules.num("ranged", "gravity", 9.8)
	var keep: Array = []
	for ar in arrows:
		ar.life -= dt
		if ar.life <= 0.0:
			if ar.node:
				ar.node.queue_free()
			continue
		if ar.stuck:
			keep.append(ar)
			continue
		var p0: Vector3 = ar.pos
		var v: Vector3 = ar.vel
		v.y -= g * dt
		var p1 := p0 + v * dt
		ar.vel = v
		var owner = ar.owner
		# arrows clear the shooter's own front ranks (archers loose over their comrades' heads)
		var skip: int = owner.side if is_instance_valid(owner) and p0.distance_to(ar.origin) < 9.0 else -1
		var hit: Array = segment_hit(owner if is_instance_valid(owner) else null, p0, p1, 0.02, skip)
		if not hit.is_empty():
			var tgt: Agent = hit[0]
			ar.stuck = true
			ar.life = 4.0
			ar.pos = hit[1]
			stat("arrow_hits")
			if _shield_stops(tgt, v, hit[2]):
				stat("arrow_shield")
				tgt.damage_shield(float(ar.dmg) * rules.num("combat", "shield_arrow", 0.5))
				_effect(hit[1], Color("c8a060"), 3)
				sound("shield", hit[1], -6.0, 1.3)
			elif is_instance_valid(owner):
				var spd := v.length() / rules.num("ranged", "speed_damage_ref", 50.0)
				var raw: float = ar.dmg * clampf(spd, 0.5, 1.4) * randf_range(0.85, 1.15)
				_apply(owner, tgt, raw, "pierce", hit[2], hit[1], false)
				if not owner.is_thrower():
					_count_hit(owner, "crossbow" if owner.ranged.get("kind", "") == "crossbow" else "bow")
				sound("arrow_hit", hit[1], -2.0)
			_place_arrow(ar)
			keep.append(ar)
			continue
		if siege_def >= 0 and p0.distance_to(ar.origin) > 2.5 and field.merlon_hit(p0, p1):
			ar.stuck = true
			ar.life = 6.0
			ar.pos = p0.lerp(p1, 0.5)
			stat("arrow_merlon")
			_place_arrow(ar)
			keep.append(ar)
			continue
		var gh := field.height_at(p1.x, p1.z)
		if p1.y <= gh:
			ar.stuck = true
			ar.pos = Vector3(p1.x, gh + 0.2, p1.z)
			ar.life = 8.0
			_place_arrow(ar)
			keep.append(ar)
			continue
		if absf(p1.x) > 400 or absf(p1.z) > 400:
			if ar.node:
				ar.node.queue_free()
			continue
		ar.pos = p1
		_place_arrow(ar)
		keep.append(ar)
	arrows = keep


func _place_arrow(ar: Dictionary) -> void:
	if ar.node == null:
		return
	var v: Vector3 = ar.vel
	ar.node.global_position = ar.pos
	if v.length_squared() > 0.01:
		var up := Vector3.UP if absf(v.normalized().y) < 0.98 else Vector3.FORWARD
		ar.node.global_basis = Basis.looking_at(v.normalized(), up)


func _shield_stops(tgt: Agent, v: Vector3, part: String) -> bool:
	if tgt.shield.is_empty() or part == "horse":
		return false
	var from := -v
	from.y = 0
	var ang := rad_to_deg(tgt.forward().angle_to(from.normalized()))
	if tgt.shield_on_back():
		# slung on the back: covers the back against arrows from behind (not the head)
		return part == "body" and ang >= 180.0 - rules.num("combat", "back_shield_angle", 55) \
			and randf() < rules.num("combat", "back_shield_chance", 0.6) + float(tgt.char_stats.get("shield", 0.0))
	if tgt.attacking() or tgt.state == Agent.AIM:
		return false
	if ang > rules.num("combat", "shield_angle", 100):
		return false
	# a raised shield always stops it; otherwise the shield on the arm catches about half
	return tgt.blocking() or randf() < 0.55 + float(tgt.char_stats.get("shield", 0.0))     # 盾术


# ------------------------------------------------------------------ results
func end_battle(winner: int, how: String) -> void:
	if over:
		return
	over = true
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	var sides: Array = []
	for s in 2:
		var tally := {}
		for a in agents:
			if a.side != s or a.hero_name != "" or a == player:
				continue
			var tid: String = a.troop.id
			if not tally.has(tid):
				tally[tid] = {"killed": 0, "wounded": 0, "routed": 0, "fine": 0}
			var k: String = a.outcome if a.outcome != "" else ("routed" if a.routed else "fine")
			tally[tid][k] = int(tally[tid][k]) + 1
		for tid in reserves[s]:
			if not tally.has(tid):
				tally[tid] = {"killed": 0, "wounded": 0, "routed": 0, "fine": 0}
			tally[tid].fine = int(tally[tid].fine) + 1
		var hero_state := ""
		for a in agents:
			if a.side == s and (a.hero_name != "" or a == player) and not a.has_meta("companion"):
				hero_state = a.outcome if a.outcome != "" else "fine"
		sides.append({"name": side_names[s], "troops": tally, "hero": hero_state})
	result = {"winner": winner, "how": how, "player_side": player_side, "time": round(time), "sides": sides, "stats": stats,
		"player_hits": player_hits, "companions": _companion_outcomes()}
	var txt := JSON.stringify(result)
	print("BATTLE_RESULT " + txt)
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f:
			f.store_string(txt)
	finished.emit(result)
	if hud and hud.has_method("show_result"):
		hud.show_result(result)
	if embedded:
		if auto or hud == null:
			get_tree().create_timer(1.5, true, false, true).timeout.connect(close)
	elif auto or hud == null:
		get_tree().create_timer(0.5).timeout.connect(func(): get_tree().quit())


## Leave the field: standalone -> quit; embedded -> hand the result back to the campaign map.
func close() -> void:
	if not over:
		return
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if not embedded:
		get_tree().quit()
		return
	closed.emit(result)
	queue_free()


func message(text: String, c: Color = Color.WHITE) -> void:
	if hud and hud.has_method("message"):
		hud.message(text, c)
	elif DisplayServer.get_name() == "headless" and OS.is_debug_build():
		print("[battle %.0fs] %s" % [time, text])
