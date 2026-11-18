extends Node
## Player input + third-person camera, with Warband's controls:
##   mouse = look; the direction you move the mouse just before clicking picks the attack:
##     up = overhead, left / right = side swing, down = thrust
##   LMB hold = ready the attack (or draw the bow), release = strike / shoot
##   RMB hold = block (direction = mouse movement, like the attack; shields block every direction)
##   WASD move (on horseback: W/S speed up / slow down, A/D turn) · Shift walk · wheel switch weapon
##   1 infantry 2 archers 3 cavalry 0 everyone · F1 hold F2 follow F3 charge F4 stand ground F5 retreat
##   F6 advance F7 fall back F8 closer F9 spread · Tab leave / let the troops finish · Esc release mouse

var battle: Battle
var cam: Camera3D
var yaw := 0.0
var pitch := -0.18
var dist := 3.6
var mdir := Vector2.ZERO          # recent mouse motion (decays), picks attack / block direction
var last_dir := Agent.Dir.RIGHT
var selected: Array = ["inf", "arc", "cav"]
var sens := 0.0028
var auto_block := false
var _lmb := false
var _rmb := false
var _spectate: Agent = null
var _down_handled := false


func setup(b: Battle) -> void:
	battle = b
	cam = Camera3D.new()
	cam.fov = 70.0
	cam.far = 900.0
	b.add_child(cam)
	cam.current = true
	auto_block = bool(b.rules.sec("player").get("auto_block", false))
	if b.player:
		yaw = b.player.heading
	if DisplayServer.get_name() != "headless" and not b.auto:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_place_camera(0.0)


func _unhandled_input(e: InputEvent) -> void:
	if battle == null:
		return
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var r: Vector2 = e.relative
		yaw -= r.x * sens
		pitch = clampf(pitch - r.y * sens, -1.2, 0.9)
		mdir += r
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			if mb.pressed and not battle.over:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		var p := battle.player
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_lmb = mb.pressed
			if p and p.alive() and p.is_player:
				if mb.pressed:
					if p.using_ranged:
						p.begin_aim()
					else:
						last_dir = _attack_dir()
						p.start_attack(last_dir)
				else:
					if p.state == Agent.AIM:
						p.aim_point = _aim_point()
						p.release_shot()
					else:
						p.release_attack()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_rmb = mb.pressed
			if p and p.alive() and p.is_player:
				if mb.pressed:
					p.start_block(_block_dir(p))
				else:
					p.stop_block()
		elif mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			if p and p.alive() and p.is_player:
				p.switch_weapon()
	if e is InputEventKey and e.pressed and not e.echo:
		var k := (e as InputEventKey).keycode
		match k:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_TAB:
				if battle.over:
					get_tree().quit()
				elif battle.player == null or not battle.player.alive():
					battle.auto_finish()
				else:
					battle.request_retreat()
			KEY_1: _select(["inf"])
			KEY_2: _select(["arc"])
			KEY_3: _select(["cav"])
			KEY_0, KEY_QUOTELEFT: _select(["inf", "arc", "cav"])
			KEY_F1: _order("hold")
			KEY_F2: _order("follow")
			KEY_F3: _order("charge")
			KEY_F4: _order("stand")
			KEY_F5: _order("retreat")
			KEY_F6: _order("advance")
			KEY_F7: _order("fallback")
			KEY_F8: _order("closer")
			KEY_F9: _order("spread")
			KEY_ENTER, KEY_KP_ENTER:
				if battle.over:
					get_tree().quit()


func _select(groups: Array) -> void:
	selected = groups
	var names := {"inf": "步兵", "arc": "射手", "cav": "骑兵"}
	var t: Array[String] = []
	for g in groups:
		t.append(names[g])
	battle.message("选中：%s（F1 驻守 F2 跟我来 F3 冲锋 F4 站住 F5 撤退 F6 前进 F7 后退 F8 靠拢 F9 散开）" % "、".join(t), Color("cfd6dc"))


func _order(kind: String) -> void:
	if battle.over:
		return
	battle.command(battle.player_side, selected, kind)


## Warband: the mouse movement just before clicking chooses the swing.
func _attack_dir() -> int:
	if mdir.length() < 3.0:
		return last_dir
	if absf(mdir.x) > absf(mdir.y):
		return Agent.Dir.RIGHT if mdir.x > 0 else Agent.Dir.LEFT
	return Agent.Dir.UP if mdir.y < 0 else Agent.Dir.DOWN


## Blocking: guard the side you move the mouse to. A swing from the enemy's right comes in on
## your left, so "mouse left" guards against Dir.RIGHT.
func _block_dir(p: Agent) -> int:
	if auto_block:
		var best: Agent = null
		var bd := INF
		for e in battle.agents_near(p.global_position, 4.0):
			if e.side != p.side and e.attacking() and e.global_position.distance_to(p.global_position) < bd:
				bd = e.global_position.distance_to(p.global_position)
				best = e
		if best:
			return best.attack_dir
	if mdir.length() < 3.0:
		return Agent.Dir.UP
	if absf(mdir.x) > absf(mdir.y):
		return Agent.Dir.RIGHT if mdir.x < 0 else Agent.Dir.LEFT
	return Agent.Dir.UP if mdir.y < 0 else Agent.Dir.DOWN


func current_dir() -> int:
	return _attack_dir()


func _aim_point() -> Vector3:
	var from := cam.global_position
	var dir := -cam.global_basis.z
	# the point under the crosshair: march along the view ray until it meets the ground or a soldier
	var p := from + dir * 250.0
	for k in 250:
		var q := from + dir * float(k + 2)
		if q.y < battle.field.height_at(q.x, q.z):
			p = q
			break
		var hit: Array = battle.segment_hit(battle.player, q, q + dir, 0.15)
		if not hit.is_empty():
			p = hit[1]
			break
	return p


## called by Battle every physics frame while the player is alive and in control
func drive(p: Agent, dt: float) -> void:
	mdir = mdir * pow(0.0005, dt)
	var mv := Vector3.ZERO
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var rgt := Vector3(cos(yaw), 0, -sin(yaw))
	if Input.is_key_pressed(KEY_W):
		mv += fwd
	if Input.is_key_pressed(KEY_S):
		mv -= fwd
	if Input.is_key_pressed(KEY_D):
		mv += rgt
	if Input.is_key_pressed(KEY_A):
		mv -= rgt
	p.intent_run = not Input.is_key_pressed(KEY_SHIFT)
	if p.mounted:
		p.steer_direct = true
		p.intent_throttle = (1.0 if Input.is_key_pressed(KEY_W) else 0.0) - (1.0 if Input.is_key_pressed(KEY_S) else 0.0)
		p.intent_turn = (1.0 if Input.is_key_pressed(KEY_D) else 0.0) - (1.0 if Input.is_key_pressed(KEY_A) else 0.0)
	else:
		p.steer_direct = false
		p.intent_move = mv.normalized() if mv.length() > 0 else Vector3.ZERO
		p.intent_yaw = yaw
	if p.state == Agent.AIM or (p.using_ranged and _lmb):
		p.aim_point = _aim_point()
	if _rmb and p.state == Agent.BLOCK and mdir.length() > 6.0:
		p.block_dir = _block_dir(p)


func _process(dt: float) -> void:
	if battle == null:
		return
	_place_camera(dt)


func _place_camera(dt: float) -> void:
	var p := battle.player
	var focus: Agent = p
	if p == null or not p.alive() or not p.is_player:
		if _spectate == null or not _spectate.alive():
			_spectate = null
			for a in battle.agents:
				if a.side == battle.player_side and a.active():
					_spectate = a
					break
			if _spectate == null:
				for a in battle.agents:
					if a.active():
						_spectate = a
						break
		focus = _spectate if _spectate else p
		if p and not p.alive() and not _down_handled:
			_down_handled = true
	if focus == null:
		return
	if focus != p or not p.is_player:
		# spectating / AI-controlled: swing the camera round behind the soldier we follow
		yaw = lerp_angle(yaw, focus.heading, clampf(dt * 1.5, 0.0, 1.0))
	var d := dist + (1.6 if focus.mounted else 0.0)
	var pivot := focus.global_position + Vector3(0, 1.6 + (Agent.RIDER_LIFT if focus.mounted else 0.0), 0)
	var look := Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
	var side := Vector3(cos(yaw), 0, -sin(yaw)) * 0.45
	var want := pivot - look * d + side
	var g := battle.field.height_at(want.x, want.z) + 0.4
	if want.y < g:
		want.y = g
	cam.global_position = want if dt == 0.0 else cam.global_position.lerp(want, clampf(dt * 18.0, 0.0, 1.0))
	cam.look_at(cam.global_position + look, Vector3.UP)
