class_name Agent
extends Node3D
## One soldier (optionally on a horse). Controllers (BattleAI / player) write the intent_* fields;
## Battle calls step() every physics frame. Melee is directional like Warband:
##   up = overhead chop, right / left = side swings (named from the attacker's side), down = thrust.

enum { IDLE, READY, STRIKE, RECOVER, BLOCK, STUN, DOWN, DEAD, AIM, RELOAD }
enum Dir { UP, RIGHT, LEFT, DOWN }
const DIR_NAMES := ["上劈", "右砍", "左砍", "直刺"]

const SHOULDER := Vector3(0.21, 1.42, 0.0)
const RIDER_LIFT := 0.68

var battle: Node                     # Battle
var rules: BattleRules
var side := 0
var troop: Dictionary = {}           # {id, name, culture, tier, cls}
var hero_name := ""
var is_player := false
var color := Color.WHITE
var division := "inf"                # inf / arc / cav (order groups)
var rng_seed := 0

# stats & equipment
var max_hp := 100.0
var hp := 100.0
var armor := 0
var melee: Array = []
var melee_idx := 0
var ranged: Dictionary = {}
var ammo := 0
var shield: Dictionary = {}
var horse_kind := ""
var mounted := false
var horse_hp := 0.0
var using_ranged := false
var crossbow_loaded := true

# state
var state := IDLE
var state_t := 0.0
var state_len := 0.0
var attack_dir := Dir.RIGHT
var block_dir := Dir.UP
var release_pending := false
var hit_done := false
var couched := false
var routed := false
var outcome := ""                    # "" / killed / wounded / routed
var last_attacker: Agent = null
var _prev_seg: Array = []
var _bump_cd := {}
var _couch_cd := {}
var heading := 0.0                   # yaw (radians); forward = -Z rotated by heading
var speed := 0.0                     # horse forward speed
var walk_phase := 0.0

# intents (set by the controller every frame)
var intent_move := Vector3.ZERO      # world-space horizontal, length 0..1
var intent_run := true
var intent_yaw := 0.0
var steer_direct := false            # player on horseback: A/D turn, W/S throttle
var intent_turn := 0.0
var intent_throttle := 0.0
var aim_point := Vector3.ZERO        # ranged target point (world)

# AI scratch
var ai: Dictionary = {}

var rig: AgentRig
var _rig_dt := 0.0
var velocity := Vector3.ZERO
var radius := 0.32                   # footprint for pushing apart (soldiers don't use the physics engine)


func setup(b: Node, r: BattleRules, tid: String, sd: int, col: Color, override: Dictionary = {}, hname: String = "") -> void:
	battle = b
	rules = r
	side = sd
	color = col
	hero_name = hname
	troop = r.troops.get(tid, {"id": tid, "name": tid, "culture": "", "tier": 1, "cls": "inf"}).duplicate()
	var lo := r.loadout(tid, override)
	var tier := int(troop.tier)
	max_hp = r.num("human", "hp_base", 70) + r.num("human", "hp_per_tier", 12) * tier
	if hname != "":
		max_hp += 30
	hp = max_hp
	armor = int(lo.armor)
	melee = lo.melee
	ranged = lo.ranged
	ammo = int(ranged.get("ammo", 0))
	shield = lo.shield
	horse_kind = lo.horse
	if b.setup.get("dismounted", false):
		horse_kind = ""                 # hideout raids are fought on foot
	mounted = horse_kind != ""
	horse_hp = r.num("horse", "hp", 110) if mounted else 0.0
	using_ranged = not ranged.is_empty()
	division = "cav" if mounted else ("arc" if not ranged.is_empty() else "inf")
	_apply_shape()
	rig = AgentRig.new()
	add_child(rig)
	rig.build(self)


func _apply_shape() -> void:
	radius = rules.num("horse", "radius", 0.55) if mounted else rules.num("human", "radius", 0.32)


# ------------------------------------------------------------------ queries
func alive() -> bool:
	return state != DEAD


func active() -> bool:
	return state != DEAD and not routed


func weapon() -> Dictionary:
	return melee[melee_idx] if melee_idx < melee.size() else {}


func reach() -> float:
	return float(weapon().get("reach", 1.4))


func forward() -> Vector3:
	return Vector3(-sin(heading), 0, -cos(heading))


func right() -> Vector3:
	return Vector3(cos(heading), 0, -sin(heading))


func chest() -> Vector3:
	return global_position + Vector3(0, 1.3 + (RIDER_LIFT if mounted else 0.0), 0)


func tier() -> int:
	return int(troop.get("tier", 1))


func can_thrust() -> bool:
	return float(weapon().get("thrust", 0)) > 0.0


func allowed_dirs() -> Array:
	var w := weapon()
	if w.get("thrust_only", false):
		return [Dir.DOWN, Dir.UP]
	if w.get("kind", "") == "lance":
		return [Dir.DOWN, Dir.RIGHT, Dir.LEFT] if not mounted else [Dir.RIGHT, Dir.LEFT, Dir.UP]
	return [Dir.UP, Dir.RIGHT, Dir.LEFT, Dir.DOWN] if can_thrust() else [Dir.UP, Dir.RIGHT, Dir.LEFT]


func ready_time() -> float:
	return rules.num("combat", "ready_time", 0.38) / float(weapon().get("speed", 1.0))


func strike_time() -> float:
	return rules.num("combat", "strike_time", 0.32) / float(weapon().get("speed", 1.0))


func attacking() -> bool:
	return state == READY or state == STRIKE


func blocking() -> bool:
	return state == BLOCK and state_t > 0.08


func busy() -> bool:
	return state in [STUN, DOWN, DEAD, RECOVER]


# ------------------------------------------------------------------ actions (controllers call these)
func start_attack(dir: int) -> void:
	if using_ranged or not (state == IDLE or state == BLOCK):
		return
	if not dir in allowed_dirs():
		dir = allowed_dirs()[0]
	attack_dir = dir
	ai["swing_id"] = int(ai.get("swing_id", 0)) + 1
	_set_state(READY, 0.0)
	release_pending = false
	hit_done = false
	_prev_seg = []


func release_attack() -> void:
	if state != READY:
		return
	battle.stat("swings")
	if state_t >= ready_time():
		_set_state(STRIKE, strike_time())
		_prev_seg = []
	else:
		release_pending = true


func start_block(dir: int) -> void:
	if using_ranged and shield.is_empty():
		return
	if state == IDLE or state == READY or (state == BLOCK and dir != block_dir):
		if state != BLOCK:
			_set_state(BLOCK, 0.0)
		block_dir = dir


func stop_block() -> void:
	if state == BLOCK:
		_set_state(IDLE, 0.0)


func begin_aim() -> void:
	if not using_ranged or ammo <= 0 or not (state == IDLE or state == BLOCK):
		return
	if ranged.kind == "crossbow" and not crossbow_loaded:
		return
	_set_state(AIM, 0.0)


func draw_progress() -> float:
	if state != AIM:
		return 0.0
	var draw: float = 0.35 if ranged.get("kind", "") == "crossbow" else float(ranged.get("draw", 0.9))
	return clampf(state_t / draw, 0.0, 1.0)


func spread() -> float:
	## current aiming spread in degrees
	var R := "ranged"
	var draw: float = 0.35 if ranged.get("kind", "") == "crossbow" else float(ranged.get("draw", 0.9))
	var aimed := clampf((state_t - draw) / rules.num(R, "aim_time", 1.1), 0.0, 1.0)
	var s := lerpf(rules.num(R, "draw_spread", 6.0), rules.num(R, "min_spread", 0.6), aimed)
	var v := Vector2(velocity.x, velocity.z).length()
	s += clampf(v / 4.0, 0.0, 1.0) * rules.num(R, "move_spread", 3.0)
	if mounted:
		s += rules.num(R, "horse_spread", 2.5) * clampf(v / 8.0, 0.3, 1.0)
	return s


func release_shot(extra_error: float = 0.0) -> void:
	if state != AIM:
		return
	if draw_progress() < 1.0:
		_set_state(IDLE, 0.0)
		return
	var from := global_position + Vector3(0, 1.5 + (RIDER_LIFT if mounted else 0.0), 0) + forward() * 0.4
	var dir := (aim_point - from).normalized()
	var spr := deg_to_rad(spread() + extra_error)
	var b := Basis.looking_at(dir, Vector3.UP)
	var ang := randf() * TAU
	var mag := randf() * spr
	dir = (b * Vector3(cos(ang) * sin(mag), sin(ang) * sin(mag), -cos(mag))).normalized()
	battle.spawn_arrow(self, from, dir * float(ranged.speed), float(ranged.damage))
	ammo -= 1
	if ranged.kind == "crossbow":
		crossbow_loaded = false
	_set_state(RECOVER, 0.35)


func switch_weapon() -> void:
	## mouse wheel: cycle bow/crossbow -> melee weapons
	if state in [READY, STRIKE, AIM, STUN, DOWN, DEAD]:
		return
	if using_ranged:
		using_ranged = false
		melee_idx = 0
	elif melee_idx + 1 < melee.size():
		melee_idx += 1
	elif not ranged.is_empty() and ammo > 0:
		using_ranged = true
	else:
		melee_idx = 0
	rig.set_weapon(weapon())
	_set_state(RECOVER, 0.3)


func use_melee(idx := -1) -> void:
	if using_ranged or (idx >= 0 and idx != melee_idx):
		using_ranged = false
		if idx >= 0:
			melee_idx = clampi(idx, 0, melee.size() - 1)
		rig.set_weapon(weapon())


func _set_state(s: int, length: float) -> void:
	state = s
	state_t = 0.0
	state_len = length


# ------------------------------------------------------------------ simulation
func step(dt: float) -> void:
	state_t += dt
	match state:
		READY:
			if release_pending and state_t >= ready_time():
				_set_state(STRIKE, strike_time())
				_prev_seg = []
		STRIKE:
			_check_strike()
			if state == STRIKE and state_t >= state_len:
				_set_state(RECOVER, rules.num("combat", "recover_time", 0.28))
		RECOVER, STUN:
			if state_t >= state_len:
				_set_state(IDLE, 0.0)
		DOWN:
			if state_t >= state_len:
				_set_state(IDLE, 0.0)
		RELOAD:
			if state_t >= float(ranged.get("draw", 2.5)):
				crossbow_loaded = true
				_set_state(IDLE, 0.0)
		IDLE:
			if using_ranged and ranged.get("kind", "") == "crossbow" and not crossbow_loaded and ammo > 0:
				_set_state(RELOAD, 0.0)
	if state == DEAD:
		return
	_move(dt)
	if mounted:
		_horse_contacts()
	# the rig is only for show (hits use pose() maths), so far-away soldiers animate at a lower rate
	_rig_dt += dt
	var every: int = battle.rig_interval(self)
	if every > 0 and (battle.frame + rng_seed) % every == 0:
		_update_rig(_rig_dt)
		_rig_dt = 0.0


func _move(dt: float) -> void:
	var H := "human"
	var down := state == DOWN
	if mounted:
		var top := rules.num("horse", "speed", 10.5)
		var tgt_speed := 0.0
		var turn_rate := rules.num("horse", "turn", 2.2) * (1.35 - 0.6 * clampf(speed / top, 0.0, 1.0))
		if steer_direct:
			# player: W gallops, S reins in, neither = the horse slowly loses pace
			heading += -intent_turn * turn_rate * dt
			tgt_speed = top if intent_throttle > 0.0 else (0.0 if intent_throttle < 0.0 else maxf(0.0, speed - 2.0 * dt))
			if intent_throttle > 0.0 and not intent_run:
				tgt_speed = rules.num("horse", "canter", 5.0)
		else:
			var m := intent_move
			if m.length() > 0.05:
				var want := atan2(-m.x, -m.z)
				heading += clampf(wrapf(want - heading, -PI, PI), -turn_rate * dt, turn_rate * dt)
				tgt_speed = m.length() * (top if intent_run else rules.num("horse", "canter", 5.0))
				# slow down for sharp turns
				tgt_speed *= clampf(1.0 - absf(wrapf(want - heading, -PI, PI)) / PI, 0.35, 1.0)
		var acc := rules.num("horse", "accel", 4.5) * (1.8 if tgt_speed < speed else 1.0)
		if routed:
			tgt_speed = top
		speed = move_toward(speed, tgt_speed, acc * dt)
		var f := forward()
		velocity.x = f.x * speed
		velocity.z = f.z * speed
	else:
		var top := rules.num(H, "run", 4.4) - armor * rules.num(H, "armor_slow", 0.012)
		if not intent_run:
			top = rules.num(H, "walk", 1.6)
		var mult := 1.0
		if state == READY or state == STRIKE or state == AIM:
			mult = 0.65
		elif state == BLOCK:
			mult = 0.55
		elif state == STUN:
			mult = 0.25
		if down:
			mult = 0.0
		var m := intent_move.limit_length(1.0)
		if m.length() > 0.01 and m.normalized().dot(forward()) < -0.3:
			mult *= rules.num(H, "backward", 0.6)
		var want_v := m * top * mult
		var acc := rules.num(H, "accel", 14.0)
		velocity.x = move_toward(velocity.x, want_v.x, acc * dt)
		velocity.z = move_toward(velocity.z, want_v.z, acc * dt)
		if not down:
			if is_player:
				heading = intent_yaw
			else:
				heading += clampf(wrapf(intent_yaw - heading, -PI, PI), -rules.num(H, "turn", 7.0) * dt,
					rules.num(H, "turn", 7.0) * dt)
	# plain kinematics on the heightmap (Battle pushes overlapping soldiers / trees apart afterwards)
	var p := position
	p.x += velocity.x * dt
	p.z += velocity.z * dt
	p.y = battle.field.height_at(p.x, p.z)
	position = p
	velocity.y = 0.0
	rotation.y = heading


func _update_rig(dt: float) -> void:
	var v := Vector2(velocity.x, velocity.z).length()
	walk_phase += dt * (v * (1.7 if mounted else 3.2) + 0.0)
	rig.show_pose(self, pose(), walk_phase, v, dt)
	if state == DOWN:
		rig.rotation.x = lerpf(rig.rotation.x, deg_to_rad(-80), 0.3)
		rig.position.y = 0.15
	elif rig.rotation.x != 0.0:
		rig.rotation.x = lerpf(rig.rotation.x, 0.0, 0.25)
		rig.position.y = 0.0
		if absf(rig.rotation.x) < 0.01:
			rig.rotation.x = 0.0


# ------------------------------------------------------------------ pose (shared by visuals and hits)
static func _sl(a: Vector3, b: Vector3, t: float) -> Vector3:
	return a.normalized().slerp(b.normalized(), clampf(t, 0.0, 1.0))


static func _arc(keys: Array, t: float) -> Vector3:
	## piecewise slerp through keyframe directions, t in 0..1
	var n := keys.size() - 1
	var f := clampf(t, 0.0, 1.0) * n
	var i := mini(int(f), n - 1)
	return _sl(keys[i], keys[i + 1], f - i)


const REST := Vector3(0.25, 0.15, -0.95)
const READY_POSE := [Vector3(0.15, 0.9, 0.45), Vector3(0.95, 0.35, 0.25), Vector3(-0.8, 0.45, 0.2), Vector3(0.2, 0.05, -1.0)]
const STRIKE_PATH := [
	[Vector3(0.15, 0.9, 0.45), Vector3(0.05, 0.6, -0.8), Vector3(0.05, -0.75, -0.65)],          # overhead
	[Vector3(0.95, 0.35, 0.25), Vector3(0.0, 0.15, -1.0), Vector3(-0.85, -0.15, -0.5)],        # right swing
	[Vector3(-0.8, 0.45, 0.2), Vector3(0.0, 0.15, -1.0), Vector3(0.85, -0.15, -0.45)],         # left swing
	[Vector3(0.12, 0.05, -1.0), Vector3(0.08, 0.04, -1.0), Vector3(0.05, 0.03, -1.0)],         # thrust
]


func pose() -> Dictionary:
	var arm := REST
	var off := Vector3.ZERO
	var wdir := Vector3.ZERO
	var larm := Vector3(-0.15, 0.1, -1.0)
	var shooting := false
	var lift := Vector3(0, RIDER_LIFT if mounted else 0.0, 0)
	var long_weapon: bool = weapon().get("kind", "") in ["polearm", "lance"]
	match state:
		READY:
			var p := clampf(state_t / ready_time(), 0.0, 1.0)
			arm = _sl(REST, READY_POSE[attack_dir], p)
			if attack_dir == Dir.DOWN:
				off = Vector3(0, 0, 0.35 * p)
		STRIKE:
			var p := clampf(state_t / state_len, 0.0, 1.0)
			arm = _arc(STRIKE_PATH[attack_dir], p)
			if attack_dir == Dir.DOWN:
				off = Vector3(0, 0, lerpf(0.35, -0.45, p))
		RECOVER:
			arm = REST
		BLOCK:
			arm = Vector3(0.1, 0.45, -0.9)
			match block_dir:
				Dir.UP: wdir = Vector3(-1.0, 0.25, -0.1)
				Dir.RIGHT: wdir = Vector3(0.35, 1.0, -0.25)       # guarding against a swing from the enemy's right = my left
				Dir.LEFT: wdir = Vector3(-0.35, 1.0, -0.25)
				Dir.DOWN: wdir = Vector3(0.0, -0.9, -0.5)
			if not shield.is_empty():
				larm = Vector3(-0.05, 0.25, -1.0)
		AIM, RELOAD:
			shooting = true
			var d := (aim_point - chest()).normalized() if state == AIM else forward()
			var loc := (global_transform.basis.inverse() * d).normalized()
			larm = loc
			arm = (loc + Vector3(0.0, 0.0, 0.9) * draw_progress()).normalized() if ranged.get("kind", "") == "bow" else loc
		DOWN, STUN:
			arm = Vector3(0.4, -0.6, -0.5)
	if couched:
		arm = Vector3(0.18, -0.12, -1.0)
	if long_weapon and state in [IDLE, RECOVER, BLOCK] and not couched:
		arm = Vector3(0.2, -0.1, -1.0)
		wdir = Vector3(0.0, 0.25, -1.0) if state != BLOCK else wdir
	if not shield.is_empty() and state != BLOCK and not shooting:
		larm = Vector3(-0.45, 0.0, -0.85)
	if wdir == Vector3.ZERO:
		wdir = arm
	return {"arm": arm, "weapon": wdir, "off": off, "larm": larm, "shooting": shooting}


## Weapon blade as [hand, tip] in world space (for hit tests)
func weapon_segment() -> Array:
	var ps := pose()
	var lift := Vector3(0, RIDER_LIFT if mounted else 0.0, 0)
	var sh: Vector3 = SHOULDER + lift + ps.off
	var hand: Vector3 = sh + (ps.arm as Vector3).normalized() * 0.6
	var L := maxf(0.35, reach() - 0.75)
	var tip: Vector3 = hand + (ps.weapon as Vector3).normalized() * L
	var gb := global_transform
	return [gb * hand, gb * tip]


# ------------------------------------------------------------------ hits
func _check_strike() -> void:
	var p := state_t / maxf(0.001, state_len)
	var seg := weapon_segment()
	if hit_done or p > rules.num("combat", "active_to", 0.95):
		_prev_seg = seg
		return
	var segs := [seg]
	if not _prev_seg.is_empty():
		segs.append([(_prev_seg[0] + seg[0]) * 0.5, (_prev_seg[1] + seg[1]) * 0.5])
		segs.append(_prev_seg)
	var motion: Vector3 = (seg[1] - _prev_seg[1]) if not _prev_seg.is_empty() else forward()
	_prev_seg = seg
	for s in segs:
		var hit: Array = battle.segment_hit(self, s[0], s[1], 0.08)
		if not hit.is_empty():
			hit_done = true
			var early := p < rules.num("combat", "active_from", 0.22)
			battle.melee_hit(self, hit[0], hit[1], hit[2], attack_dir == Dir.DOWN, early, motion.normalized())
			return


func _horse_contacts() -> void:
	var t := Time.get_ticks_msec() / 1000.0
	# couched lance: automatic when galloping with a lance and not attacking
	var w := weapon()
	couched = not using_ranged and w.get("kind", "") == "lance" and speed > float(w.get("couch_speed", 7.5)) \
		and state == IDLE
	if couched:
		var seg := weapon_segment()
		var hit: Array = battle.segment_hit(self, seg[0], seg[1], 0.1)
		if not hit.is_empty() and t > float(_couch_cd.get(hit[0].get_instance_id(), 0.0)) and hit[0].side != side:
			_couch_cd[hit[0].get_instance_id()] = t + 1.5
			battle.couch_hit(self, hit[0], hit[1], hit[2])
	if speed < rules.num("horse", "bump_speed", 5.5):
		return
	for o in battle.agents_near(global_position, 1.8):
		if o == self or not o.alive() or o.mounted or o.state == DOWN or o.side == side:
			continue
		var d: Vector3 = o.global_position - global_position
		d.y = 0
		if d.length() < 1.3 and d.normalized().dot(forward()) > 0.4 and t > float(_bump_cd.get(o.get_instance_id(), 0.0)):
			_bump_cd[o.get_instance_id()] = t + 1.2
			battle.bump(self, o)


func take_hit(dmg: float, from: Agent, knock: bool, blunt: bool) -> void:
	if state == DEAD:
		return
	last_attacker = from
	hp -= dmg
	rig.flash(Color(1, 0.2, 0.15))
	if hp <= 0.0:
		die(blunt)
		return
	if knock and not mounted:
		_set_state(DOWN, rules.num("combat", "knockdown_time", 1.6))
	elif state != BLOCK or dmg > 0:
		_set_state(STUN, rules.num("combat", "hit_stun", 0.45))


func hit_horse(dmg: float, from: Agent) -> void:
	horse_hp -= dmg
	rig.flash(Color(1, 0.3, 0.2))
	if horse_hp <= 0.0 and mounted:
		battle.on_horse_killed(self, from)
		dismount()
		take_hit(10.0, from, true, true)


func dismount() -> void:
	mounted = false
	couched = false
	speed = 0.0
	division = "arc" if not ranged.is_empty() else "inf"
	_apply_shape()
	rig.queue_free()
	rig = AgentRig.new()
	add_child(rig)
	rig.build(self)


func die(blunt: bool) -> void:
	# like Warband: you and the named generals are only ever knocked out, never killed
	var wounded: bool = blunt or is_player or hero_name != "" or battle.player == self \
		or randf() < rules.num("combat", "wounded_chance", 0.4)
	outcome = "wounded" if wounded else "killed"
	_set_state(DEAD, 0.0)
	velocity = Vector3.ZERO
	rig.rotation.x = deg_to_rad(-88)
	rig.position.y = 0.12 + (0.5 if mounted else 0.0)
	if rig.label:
		rig.label.visible = false
	battle.on_agent_down(self)
