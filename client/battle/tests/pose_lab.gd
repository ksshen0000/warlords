extends Node
## Animation check: a row of soldiers each doing one move in a loop, in front of a fixed camera.
##   godot --path . res://battle/tests/pose_lab.tscn -- --shots=/tmp/lab@0.3,0.6,0.9   (screenshots, then quit)
##   godot --path . res://battle/tests/pose_lab.tscn                                     (watch)
## Row (left to right): idle sword+shield · walk · run · right swing · overhead · thrust (spear) ·
##                      block · two-hand left swing · archer · knocked down · death · rider galloping

var battle
var cam: Camera3D
var lab: Array = []          # [agent, action]
var t := 0.0
var shots: Array = []
var shot_dir := ""
var focus := Vector2i(0, 11)    # --cam=3,6 : frame soldiers 3..6
const PERIOD := 2.4

const ROW := [
	["idle", {"melee": ["sword"], "shield": "round", "armor": 20}],
	["walk", {"melee": ["sword"], "armor": 10}],
	["run", {"melee": ["mace"], "shield": "rattan", "armor": 5}],
	["swing_r", {"melee": ["sword"], "armor": 20}],
	["swing_up", {"melee": ["sword"], "shield": "round", "armor": 20}],
	["thrust", {"melee": ["spear"], "armor": 10}],
	["block", {"melee": ["sword"], "armor": 20}],
	["swing_l", {"melee": ["axe"], "armor": 30}],
	["shoot", {"melee": ["knife"], "ranged": "bow", "armor": 5}],
	["down", {"melee": ["club"], "armor": 5}],
	["die", {"melee": ["sword"], "armor": 5}],
	["ride", {"melee": ["sword"], "shield": "round", "horse": "horse", "armor": 20}],
]


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			var parts := a.substr(8).split("@")
			shot_dir = parts[0]
			for x in parts[1].split(","):
				shots.append(float(x))
		elif a.begins_with("--cam="):
			var p := a.substr(6).split(",")
			focus = Vector2i(int(p[0]), int(p[1]))
	battle = load("res://battle/scripts/battle.gd").new()
	battle.embedded = true
	battle.preset_setup = {"terrain": "plains", "seed": 3, "battle_size": 40, "player_side": 0,
		"sides": [{"name": "甲", "troops": {"zhou_t1": 2}}, {"name": "乙", "troops": {"yan_t1": 2}}]}
	get_tree().root.add_child.call_deferred(battle)
	await get_tree().create_timer(0.3).timeout
	# park the deployed armies far away and frozen
	for a in battle.agents:
		a.ai["lab"] = "park"
		a.global_position = Vector3(0, 0, -120 if a.side == 0 else 120)
		a.visible = false
	var x0 := -float(ROW.size() - 1) * 0.5 * 1.9
	for i in ROW.size():
		var r: Array = ROW[i]
		var ag = battle._spawn(0, "zhou_inf2", Vector3(x0 + i * 1.9, 0, 0), r[1])
		ag.ai["lab"] = r[0]
		ag.heading = PI * 0.82            # three-quarter view towards the camera
		ag.intent_yaw = ag.heading
		lab.append([ag, r[0]])
	cam = Camera3D.new()
	cam.fov = 50
	battle.add_child(cam)
	var cx := x0 + (focus.x + focus.y) * 0.5 * 1.9
	var span := (focus.y - focus.x + 1) * 1.9
	cam.global_position = Vector3(cx, 1.9, span * 0.95 + 2.0)
	cam.look_at(Vector3(cx, 1.0, 0))
	cam.current = true
	set_physics_process(true)


func _physics_process(dt: float) -> void:
	if lab.is_empty():
		return
	t += dt
	var ph := fmod(t, PERIOD)
	for e in lab:
		var a: Agent = e[0]
		var act: String = e[1]
		a.intent_move = Vector3.ZERO
		a.intent_run = true
		match act:
			"walk", "run":
				# back and forth on the spot
				var dir := Vector3(0, 0, 1) if fmod(t, 4.0) < 2.0 else Vector3(0, 0, -1)
				a.intent_move = dir
				a.intent_run = act == "run"
			"ride":
				a.intent_move = Vector3(1, 0, 0) if fmod(t, 6.0) < 3.0 else Vector3(-1, 0, 0)
			"swing_r", "swing_up", "thrust", "swing_l":
				var d: int = {"swing_r": Agent.Dir.RIGHT, "swing_up": Agent.Dir.UP, "thrust": Agent.Dir.DOWN, "swing_l": Agent.Dir.LEFT}[act]
				if a.state == Agent.IDLE and ph < 0.1:
					a.start_attack(d)
				elif a.state == Agent.READY and ph > 0.7:
					a.release_attack()
			"block":
				if a.state == Agent.IDLE:
					a.start_block([Agent.Dir.UP, Agent.Dir.RIGHT, Agent.Dir.LEFT][int(t / PERIOD) % 3])
			"shoot":
				a.use_melee(-1) if false else null
				if not a.using_ranged:
					a.switch_weapon()
				a.aim_point = a.global_position + Vector3(0, 1.4, 30).rotated(Vector3.UP, a.heading + PI)
				if a.state == Agent.IDLE:
					a.begin_aim()
				elif a.state == Agent.AIM and ph > 2.0:
					a.release_shot()
			"down":
				if a.state == Agent.IDLE and ph < 0.1:
					a.fall_dir = Vector3(0, 0, 1)
					a._set_state(Agent.DOWN, 1.8)
			"die":
				if a.state != Agent.DEAD and t > 0.6:
					a.fall_dir = Vector3(0.3, 0, 1).normalized()
					a.die(false)
		# keep them in place (the walkers drift back and forth)
		if act in ["walk", "run"]:
			a.global_position.z = clampf(a.global_position.z, -3.0, 3.0)
		if act == "ride":
			a.global_position.x = clampf(a.global_position.x, 8.0, 30.0)
	if not shots.is_empty() and t >= float(shots[0]):
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s_%04.1f.png" % [shot_dir, t])
		shots.pop_front()
		if shots.is_empty():
			get_tree().quit()
