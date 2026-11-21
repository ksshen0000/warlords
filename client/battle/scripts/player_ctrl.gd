extends Node
## Player input + third-person camera, with Warband's controls:
##   mouse = look; the direction you move the mouse just before clicking picks the attack:
##     up = overhead, left / right = side swing, down = thrust
##   LMB hold = ready the attack (or draw the bow), release = strike / shoot
##   RMB hold = block (direction = mouse movement, like the attack; shields block every direction)
##   WASD move (on horseback: W/S speed up / slow down, A/D turn) · Shift walk · wheel switch weapon
##   1 infantry 2 archers 3 cavalry 0 everyone · F1 hold F2 follow F3 charge F4 stand ground F5 retreat
##   F6 advance F7 fall back F8 closer F9 spread · Backspace overview · Tab leave / let the troops finish · Esc release mouse

var battle: Battle
var cam: Camera3D
var yaw := 0.0
var pitch := -0.18
var dist := 3.6
var first_person := false
var hold_still := false       # a conversation in the town walk: no walking, no mouse look, free cursor
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
	auto_block = bool(b.diff.get("auto_block", false)) or bool(b.rules.sec("player").get("auto_block", false))
	if b.player:
		yaw = b.player.heading
	if DisplayServer.get_name() != "headless" and not b.auto:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_place_camera(0.0)


func _unhandled_input(e: InputEvent) -> void:
	if battle == null or hold_still:
		return
	if battle.phase_pending:
		if e is InputEventKey and e.pressed and not e.echo:
			if e.keycode in [KEY_ENTER, KEY_KP_ENTER]:
				_lmb = false
				_rmb = false
				battle.continue_phase()
				if battle.player and battle.player.is_player:
					yaw = battle.player.heading
					_place_camera(0.0)
			elif e.keycode == KEY_TAB:
				battle.request_retreat()
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
		if battle.peaceful:
			return
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
					battle.close()
				elif battle.player == null or not battle.player.alive():
					battle.auto_finish()
				else:
					battle.request_retreat()
			KEY_1: _select(["inf"], e.shift_pressed)
			KEY_2: _select(["arc"], e.shift_pressed)
			KEY_3: _select(["cav"], e.shift_pressed)
			KEY_0, KEY_QUOTELEFT: _select(["inf", "arc", "cav"] + _custom_groups())
			KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
				var g := "g%d" % (e.keycode - KEY_0)
				if e.ctrl_pressed:
					_assign(g)
				elif battle.orders[battle.player_side].has(g):
					_select([g], e.shift_pressed)
				else:
					battle.message("还没有第%d队：先选中兵种，按 Ctrl+%d 把你身边 25 米内的这些人编成第%d队" % [e.keycode - KEY_0, e.keycode - KEY_0, e.keycode - KEY_0], Color("e0b070"))
			KEY_M:
				if not battle.peaceful and not battle.over:
					var n: int = battle.order_mount(battle.player_side, selected, e.shift_pressed)
					battle.message(("上马！（%d 人去找马）" if e.shift_pressed else "下马步战！（%d 人）") % n if n > 0
						else ("没有可以上马的人" if e.shift_pressed else "选中的分队里没有骑马的人"), Color("cfd6dc"))
			KEY_H: _order("fire" if e.shift_pressed else "hold_fire")
			KEY_R:
				if _has_control():
					first_person = not first_person
					_place_camera(0.0)
			KEY_E:
				if _has_control():
					battle.player.start_kick()
			KEY_F:
				if _has_control() and battle.has_method("interact"):
					battle.interact(battle.player)       # dismount / mount a riderless horse / pick a weapon up
			KEY_SPACE:
				if _has_control():
					battle.player.start_jump()
			KEY_BACKSPACE:
				if battle.hud and battle.hud.has_method("toggle_map"):
					battle.hud.toggle_map()
			KEY_F1:
				if e.shift_pressed:
					_hold_at_aim()
				else:
					_order("hold")
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
					battle.close()


func _has_control() -> bool:
	return not battle.peaceful and not battle.over and battle.player != null and battle.player.is_player and battle.player.alive()


func _custom_groups() -> Array:
	return battle.orders[battle.player_side].keys().filter(func(k): return str(k).begins_with("g"))


## Ctrl+4..9: the selected soldiers within 25 m of you become a custom group.
func _assign(g: String) -> void:
	if battle.peaceful or battle.over:
		return
	var n: int = battle.assign_group(battle.player_side, selected, g, 25.0)
	if n == 0:
		battle.message("你身边 25 米内没有选中分队的人", Color("e0b070"))
		return
	selected = [g]
	battle.message("%d 人编为%s（按 %s 选中）" % [n, Battle.group_name(g), g.substr(1)], Color("cfd6dc"))


func _select(groups: Array, add := false) -> void:
	if battle.peaceful:
		return
	if not add:
		selected = []
	for g in groups:
		if g not in selected:
			selected.append(g)
	var t: Array[String] = []
	for g in selected:
		t.append(Battle.group_name(g))
	battle.message("选中：%s（F1 驻守 F2 跟我来 F3 冲锋 F4 站住 F5 撤退 F6 前进 F7 后退 F8 靠拢 F9 散开 · H 停射只用近战 · M 下马 Shift+M 上马 · Ctrl+4~9 编队）" % "、".join(t), Color("cfd6dc"))


func _order(kind: String) -> void:
	if battle.over or battle.peaceful:
		return
	battle.command(battle.player_side, selected, kind)


func _hold_at_aim() -> void:
	if not _has_control():
		return
	var from := cam.global_position
	var dir := -cam.global_basis.z
	var edge := battle.field.size * 0.5 - 1.0
	for step in 250:
		var p := from + dir * float(step + 1)
		if absf(p.x) > edge or absf(p.z) > edge:
			break
		var ground := battle.field.height_at(p.x, p.z)
		if p.y <= ground:
			p.y = ground
			battle.command(battle.player_side, selected, "hold", p)
			return
	battle.message("把准星对准战场地面，再指定驻守点", Color("e0b070"))


## Warband: the mouse movement just before clicking chooses the swing.
func _attack_dir() -> int:
	if battle.diff.get("auto_attack", false) and battle.player:
		return _auto_attack_dir(battle.player)
	if mdir.length() < 3.0:
		return last_dir
	if absf(mdir.x) > absf(mdir.y):
		return Agent.Dir.RIGHT if mdir.x > 0 else Agent.Dir.LEFT
	return Agent.Dir.UP if mdir.y < 0 else Agent.Dir.DOWN


## Difficulty "automatic attack direction": strike where the enemy in front isn't guarding.
func _auto_attack_dir(p: Agent) -> int:
	var dirs: Array = p.allowed_dirs()
	var best: Agent = null
	var bd := 4.0
	for e in battle.agents_near(p.global_position, 4.0):
		if e.side == p.side or not e.alive():
			continue
		var to: Vector3 = e.global_position - p.global_position
		var d := to.length()
		if d < bd and to.normalized().dot(p.forward()) > 0.3:
			bd = d
			best = e
	if best and best.state == Agent.BLOCK and not best.shield_up() and dirs.size() > 1:
		dirs = dirs.filter(func(x): return x != best.block_dir)
	if best and best.shield_up() and Agent.Dir.UP in dirs:
		return Agent.Dir.UP                    # overhead over the shield rim
	return dirs[randi() % dirs.size()]


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
	var start := 0.1 if first_person else 2.0
	for k in 250:
		var q := from + dir * (start + k)
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
	if hold_still:
		p.intent_move = Vector3.ZERO
		return
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
	var eyes := first_person and p == focus and p.is_player and p.alive() and not battle.over
	if p and p.rig:
		p.rig.visible = not eyes
	if focus != p or not p.is_player:
		# spectating / AI-controlled: swing the camera round behind the soldier we follow
		yaw = lerp_angle(yaw, focus.heading, clampf(dt * 1.5, 0.0, 1.0))
	var d := dist + (1.6 if focus.mounted else 0.0)
	var pivot := focus.global_position + Vector3(0, 1.6 + (Agent.RIDER_LIFT if focus.mounted else 0.0), 0)
	var look := Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
	var side := Vector3(cos(yaw), 0, -sin(yaw)) * 0.45
	var want := pivot - look * d + side
	if eyes:
		want = pivot + Vector3(0, 0.04, 0)
	var g := battle.field.height_at(want.x, want.z) + 0.4
	if want.y < g:
		want.y = g
	cam.global_position = want if eyes or dt == 0.0 else cam.global_position.lerp(want, clampf(dt * 18.0, 0.0, 1.0))
	cam.look_at(cam.global_position + look, Vector3.UP)
	if shake > 0.001:
		# a jolt when you are hit (decays fast)
		cam.global_position += Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * shake * 0.08
		cam.rotate_object_local(Vector3.FORWARD, randf_range(-1, 1) * shake * 0.03)
		shake = maxf(0.0, shake - dt * 3.5)
	if battle.has_method("adjust_camera"):
		battle.adjust_camera(cam, dt)          # the town walk: keep the camera inside rooms, frame a conversation


var shake := 0.0


func jolt(amount: float) -> void:
	shake = clampf(maxf(shake, amount), 0.0, 1.0)
