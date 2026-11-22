class_name Agent
extends Node3D
## One soldier (optionally on a horse). Controllers (BattleAI / player) write the intent_* fields;
## Battle calls step() every physics frame. Melee is directional like Warband:
##   up = overhead chop, right / left = side swings (named from the attacker's side), down = thrust.

enum { IDLE, READY, STRIKE, RECOVER, BLOCK, STUN, DOWN, DEAD, AIM, RELOAD, KICK }
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
var safe_pos := Vector3.ZERO          # last position known to be on legal ground (siege works)
var spawn_origin := Vector3.ZERO
var division := "inf"                # inf / arc / cav (order groups)
var rng_seed := 0

# stats & equipment
var max_hp := 100.0
var hp := 100.0
var armor := 0                       # body
var head_armor := 0
var look: Dictionary = {}            # {head, body}: gear tier shown on the model (the player's items)
var melee: Array = []
var melee_idx := 0
var ranged: Dictionary = {}
var ammo := 0
var shield: Dictionary = {}
var horse_kind := ""
var mounted := false
var horse_hp := 0.0
var horse_max_hp := 0.0
var horse_speed := 1.0               # the horse's speed factor (the player's own mount)
var horse_armor := -1.0              # < 0: by kind (rules [horse])
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
var jumping := false
var _jump_origin_y := 0.0
var _next_jump := 0.0

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
var rig_dt := 0.0                     # simulated time since the rig was last posed
var rig_done := false
var hoof_t := 0.0                      # time to the next hoof beat (sound)                 # a corpse that has finished falling: no more posing
var velocity := Vector3.ZERO
var radius := 0.32                   # footprint for pushing apart (soldiers don't use the physics engine)
var overlap_pos: Vector3            # working position during the overlap pass
var siege_level := 0                # sampled before the AI picks targets


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
	char_stats = lo.get("char", {})
	max_hp += float(char_stats.get("hp", 0.0))            # 铁骨
	hp = max_hp
	armor = int(lo.armor)
	head_armor = int(lo.head_armor)
	look = lo.get("look", {})
	horse_speed = float(lo.get("horse_speed", 1.0)) * float(lo.get("char", {}).get("horse", 1.0))   # 骑术
	horse_armor = float(lo.get("horse_armor", -1.0))
	melee = lo.melee
	ranged = lo.ranged
	ammo = int(ranged.get("ammo", 0))
	shield = lo.shield
	shield_max = float(shield.get("hp", 0.0))
	shield_hp = shield_max
	horse_kind = lo.horse
	if b.setup.get("dismounted", false):
		horse_kind = ""                 # hideout raids are fought on foot
	mounted = horse_kind != ""
	horse_max_hp = float(lo.get("horse_hp", r.num("horse", "hp", 110)))
	horse_hp = horse_max_hp if mounted else 0.0
	_check_mounted_kit()
	melee_idx = _first_usable(0)
	using_ranged = can_use_ranged()
	division = "cav" if mounted else ("arc" if is_archer() else "inf")
	_apply_shape()
	rig = AgentRig.new()
	add_child(rig)
	rig.build(self)


## A rider whose melee weapons are all foot-only (long axe…) still carries a sidearm.
func _check_mounted_kit() -> void:
	if not mounted:
		return
	for w in melee:
		if usable(w):
			return
	var k := rules.weapon("knife")
	if not k.is_empty():
		melee.append(k)


func _apply_shape() -> void:
	radius = rules.num("horse", "radius", 0.55) if mounted else rules.num("human", "radius", 0.32)
	if not mounted and not shield.is_empty():
		radius += 0.06 * float(shield.get("size", 0.55)) / 0.55     # a shield on the arm takes room


# ------------------------------------------------------------------ queries
func alive() -> bool:
	return state != DEAD


## Just died: the body is still toppling over (the battle keeps stepping it for the animation).
func falling() -> bool:
	return state == DEAD and visible and state_t < FALL_TIME + 0.3


func active() -> bool:
	return state != DEAD and not routed


func weapon() -> Dictionary:
	return melee[melee_idx] if melee_idx < melee.size() else {}


## Can this item be used right now (some are foot-only: long axe, great shield, strong bow…)?
func usable(item: Dictionary) -> bool:
	return not (mounted and item.get("mount", true) == false)


func hands() -> int:
	if using_ranged:
		return int(ranged.get("hands", 2))
	return int(weapon().get("hands", 1))


## Shield on the left arm (blocks, catches arrows in front). Otherwise it is slung on the back:
## a bow, crossbow or two-handed weapon needs the left hand, and a great shield is no use on a horse.
func shield_up() -> bool:
	return not shield.is_empty() and hands() < 2 and usable(shield) and state != RELOAD


func shield_on_back() -> bool:
	return not shield.is_empty() and not shield_up()


## Spanning a crossbow needs a foot in the stirrup on the ground: not on horseback (Warband's heavy crossbow).
func can_reload() -> bool:
	return not (mounted and ranged.get("mount_reload", true) == false)


## The bow / crossbow can be taken up: has ammo, works from here, and a crossbow is spanned or can be.
func can_use_ranged() -> bool:
	if ranged.is_empty() or ammo <= 0 or not usable(ranged):
		return false
	return ranged.get("kind", "") != "crossbow" or crossbow_loaded or can_reload()


func _first_usable(from: int) -> int:
	for k in melee.size():
		var i := (from + k) % melee.size()
		if usable(melee[i]):
			return i
	return 0


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


## The character's skills and proficiencies (the player, companions; empty for ordinary troops).
var char_stats: Dictionary = {}
var shield_hp := 0.0                 # durability left (shields with no "hp" never break)
var shield_max := 0.0


## Blows and arrows the shield caught wear it down; at zero it splinters and is gone.
func damage_shield(amount: float) -> void:
	if shield.is_empty() or shield_max <= 0.0 or amount <= 0.0:
		return
	shield_hp -= amount
	if shield_hp > 0.0:
		return
	var nm := str(shield.get("name", "盾"))
	shield = {}
	shield_hp = 0.0
	if state == BLOCK:
		_set_state(IDLE, 0.0)
	if rig:
		rig.drop_shield()
	battle.sound("shield", chest(), 2.0, 0.7)
	battle.stat("shield_broken")
	if is_player:
		battle.message("你的%s被劈碎了！" % nm, Color("ff8f7a"))


## The order group: a custom group (g4..g9, set in battle with Ctrl+number) or the division. Orders and
## formation slots go by this; the fighting style (BattleAI) still goes by the division.
var group := ""
var axis_f := Vector3.FORWARD         # the horse's heading this tick (Battle._resolve_overlaps)


func order_key() -> String:
	return group if group != "" else division


## A bow or crossbow (javelins and throwing axes belong to the infantry: a few throws, then the blade).
func is_archer() -> bool:
	return ranged.get("kind", "") in ["bow", "crossbow"]


func is_thrower() -> bool:
	return ranged.get("kind", "") == "throw"


## How far away the AI starts loosing: a throwing weapon carries much less far than a bow.
func ranged_reach(default_range: float) -> float:
	return float(ranged.get("range", default_range))


## Which proficiency the weapon in hand uses ("" = none: fists).
func prof_kind() -> String:
	if using_ranged:
		if is_thrower():
			return ""
		return "crossbow" if ranged.get("kind", "") == "crossbow" else "bow"
	match str(weapon().get("kind", "")):
		"one_hand":
			return "one_hand"
		"two_hand":
			return "two_hand"
		"polearm", "lance":
			return "polearm"
	return ""


## Proficiency effect relative to 100 points: what = "prof_damage" | "prof_speed".
func prof_mult(what: String) -> float:
	if char_stats.is_empty():
		return 1.0
	var p := float(char_stats.get("prof", {}).get(prof_kind(), 100))
	return clampf(1.0 + (p - 100.0) / 100.0 * float(char_stats.get(what, 0.0)), 0.75, 1.5)


## Damage multiplier of this attacker's current weapon (强击 / 强弓 and proficiency).
func damage_mult() -> float:
	if char_stats.is_empty():
		return 1.0
	var skill := float(char_stats.get("melee", 1.0))
	if using_ranged:
		skill = float(char_stats.get("bow", 1.0)) if ranged.get("kind", "") != "crossbow" else 1.0
	return skill * prof_mult("prof_damage")


func ready_time() -> float:
	return rules.num("combat", "ready_time", 0.38) / float(weapon().get("speed", 1.0)) / float(battle.diff.combat_speed) / prof_mult("prof_speed")


func strike_time() -> float:
	return rules.num("combat", "strike_time", 0.32) / float(weapon().get("speed", 1.0)) / float(battle.diff.combat_speed) / prof_mult("prof_speed")


func _whoosh() -> void:
	# heavier weapons swing lower and slower
	battle.sound("whoosh", chest(), -6.0, clampf(float(weapon().get("speed", 1.0)), 0.7, 1.3))


func recover_time() -> float:
	return rules.num("combat", "recover_time", 0.28) / float(battle.diff.combat_speed)


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
		_whoosh()
	else:
		release_pending = true


func start_block(dir: int) -> void:
	if using_ranged:
		return                  # bow / crossbow in hand: no guard
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
		if is_player and not can_reload():
			battle.message("马上无法给弩上弦", Color("e0b070"))
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
		s += rules.num(R, "horse_spread", 2.5) * clampf(v / 8.0, 0.3, 1.0) * float(char_stats.get("mounted_spread", 1.0))
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
	battle.spawn_arrow(self, from, dir * float(ranged.speed), float(ranged.damage) * damage_mult())
	battle.sound("crossbow" if ranged.kind == "crossbow" else "twang", from, -3.0)
	ammo -= 1
	if ranged.kind == "crossbow":
		crossbow_loaded = false
	_set_state(RECOVER, 0.35)


func switch_weapon() -> void:
	## mouse wheel: cycle bow/crossbow -> melee weapons
	if state in [READY, STRIKE, AIM, STUN, DOWN, DEAD, KICK]:
		return
	var nxt := -1                      # next usable melee weapon after the current one
	if not using_ranged:
		for i in range(melee_idx + 1, melee.size()):
			if usable(melee[i]):
				nxt = i
				break
	if using_ranged:
		using_ranged = false
		melee_idx = _first_usable(0)
	elif nxt >= 0:
		melee_idx = nxt
	elif can_use_ranged():
		using_ranged = true
	else:
		if is_player and not ranged.is_empty() and ammo > 0 and not can_use_ranged():
			battle.message("马上用不了" + str(ranged.get("name", "")) if not usable(ranged) else "马上无法给弩上弦", Color("e0b070"))
		melee_idx = _first_usable(0)
	rig.set_weapon(weapon())
	_set_state(RECOVER, 0.3)


func use_melee(idx := -1) -> void:
	if using_ranged or (idx >= 0 and idx != melee_idx):
		using_ranged = false
		if idx >= 0:
			melee_idx = _first_usable(clampi(idx, 0, melee.size() - 1))
		rig.set_weapon(weapon())


func _set_state(s: int, length: float) -> void:
	state = s
	state_t = 0.0
	state_len = length


func start_kick() -> void:
	if state == IDLE and not mounted and not jumping:
		_set_state(KICK, rules.num("combat", "kick_windup", 0.16))


func start_jump() -> void:
	if not alive() or state in [DOWN, STUN, KICK, RELOAD] or jumping or battle.time < _next_jump:
		return
	if mounted and speed < rules.num("horse", "jump_min_speed", 4.0):
		return
	jumping = true
	couched = false
	_jump_origin_y = position.y
	velocity.y = rules.num("horse" if mounted else "human", "jump_speed", 4.2)
	_next_jump = battle.time + rules.num("human", "jump_cooldown", 0.85)


func regroup(facing: float) -> void:
	position = spawn_origin
	safe_pos = position
	heading = facing
	rotation.y = facing
	intent_yaw = facing
	intent_move = Vector3.ZERO
	velocity = Vector3.ZERO
	speed = 0.0
	couched = false
	jumping = false
	_next_jump = 0.0
	release_pending = false
	_prev_seg.clear()
	ai.clear()
	_set_state(IDLE, 0.0)


# ------------------------------------------------------------------ simulation
func step(dt: float) -> void:
	state_t += dt
	match state:
		READY:
			if release_pending and state_t >= ready_time():
				_set_state(STRIKE, strike_time())
				_prev_seg = []
				_whoosh()
		STRIKE:
			_check_strike()
			if state == STRIKE and state_t >= state_len:
				_set_state(RECOVER, recover_time())
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
		KICK:
			if state_t >= state_len:
				battle.kick(self)
				_set_state(RECOVER, rules.num("combat", "kick_recovery", 0.36))
		IDLE:
			if using_ranged and ranged.get("kind", "") == "crossbow" and not crossbow_loaded and ammo > 0 and can_reload():
				_set_state(RELOAD, 0.0)
	if state == DEAD:
		rig_dt += dt                            # Battle keeps posing the body while it topples over
		return
	_move(dt)
	if mounted and not jumping:
		_horse_contacts()
	# the rig is only for show (hits use pose() maths): Battle poses it once per *rendered* frame
	# (fewer for far-away soldiers), so a slow frame never makes the simulation fall behind
	rig_dt += dt


func _move(dt: float) -> void:
	var tuning := rules.movement
	var down := state == DOWN
	if mounted:
		var top := tuning.horse_speed * horse_speed
		var tgt_speed := 0.0
		var turn_rate := tuning.horse_turn * (1.35 - 0.6 * clampf(speed / top, 0.0, 1.0))
		if steer_direct:
			# player: W gallops, S reins in, neither = the horse slowly loses pace
			heading += -intent_turn * turn_rate * dt
			tgt_speed = top if intent_throttle > 0.0 else (0.0 if intent_throttle < 0.0 else maxf(0.0, speed - 2.0 * dt))
			if intent_throttle > 0.0 and not intent_run:
				tgt_speed = tuning.canter
		else:
			var m := intent_move
			var run_strength := m.length()
			if run_strength > 0.05:
				var want := atan2(-m.x, -m.z)
				heading += clampf(wrapf(want - heading, -PI, PI), -turn_rate * dt, turn_rate * dt)
				tgt_speed = run_strength * (top if intent_run else tuning.canter)
				# slow down for sharp turns
				tgt_speed *= clampf(1.0 - absf(wrapf(want - heading, -PI, PI)) / PI, 0.35, 1.0)
		var acc := tuning.horse_accel * (1.8 if tgt_speed < speed else 1.0)
		if routed:
			tgt_speed = top
		speed = move_toward(speed, tgt_speed, acc * dt)
		var f := forward()
		velocity.x = f.x * speed
		velocity.z = f.z * speed
	else:
		var top := tuning.foot_run - armor * tuning.armor_slow if intent_run else tuning.foot_walk
		top *= float(char_stats.get("foot", 1.0))             # 跑动
		var mult := 1.0
		if state == READY or state == STRIKE or state == AIM:
			mult = 0.65
		elif state == BLOCK:
			mult = 0.55
		elif state == STUN:
			mult = 0.25
		if down or state == KICK:
			mult = 0.0
		if battle.siege_def >= 0 and battle.field.on_ladder(position):
			mult *= tuning.ladder_speed     # hand over hand up a scaling ladder
		var m := intent_move.limit_length(1.0)
		if m.length() > 0.01 and m.normalized().dot(forward()) < -0.3:
			mult *= tuning.backward
		var want_v := m * top * mult
		var acc := tuning.foot_accel
		velocity.x = move_toward(velocity.x, want_v.x, acc * dt)
		velocity.z = move_toward(velocity.z, want_v.z, acc * dt)
		if not down:
			if is_player:
				heading = intent_yaw
			else:
				heading += clampf(wrapf(intent_yaw - heading, -PI, PI), -tuning.foot_turn * dt, tuning.foot_turn * dt)
	# plain kinematics on the heightmap (Battle pushes overlapping soldiers / trees apart afterwards)
	var p := position
	var f: BattleField = battle.field
	var nx := p.x + velocity.x * dt
	var nz := p.z + velocity.z * dt
	var ground := f.height_at(nx, nz)
	if jumping:
		velocity.y -= rules.num("human", "jump_gravity", 13.0) * dt
		p.y += velocity.y * dt
	if not f.has_works():
		p.x = nx
		p.z = nz
	else:
		# siege works: no walking up a wall face (slide along it instead); stepping off an edge drops you
		var y0 := f.height_at(p.x, p.z)
		var step_ceiling := maxf(y0, p.y) if jumping else y0
		var max_drop := INF if is_player else MAX_DROP    # only you may jump off on purpose
		if ground - step_ceiling <= MAX_STEP and y0 - ground <= max_drop:
			p.x = nx
			p.z = nz
		else:
			ground = f.height_at(nx, p.z)
			if ground - step_ceiling <= MAX_STEP and y0 - ground <= max_drop:
				p.x = nx
				velocity.z = 0.0
			else:
				ground = f.height_at(p.x, nz)
				if ground - step_ceiling <= MAX_STEP and y0 - ground <= max_drop:
					p.z = nz
					velocity.x = 0.0
				else:
					ground = y0
					velocity.x = 0.0
					velocity.z = 0.0
		var drop := y0 - ground
		if not jumping and drop > 2.5 and alive():
			battle.fall_damage(self, drop)
	if jumping and p.y <= ground:
		jumping = false
		var drop := _jump_origin_y - ground
		if drop > 2.5 and alive():
			battle.fall_damage(self, drop)
	if not jumping:
		p.y = ground
		velocity.y = 0.0
	position = p
	safe_pos = p
	rotation.y = heading


func update_rig() -> void:
	if rig == null or rig_done:
		return
	_update_rig(rig_dt)
	rig_dt = 0.0
	if state == DEAD and state_t > FALL_TIME + 0.35:
		rig_done = true


func _update_rig(dt: float) -> void:
	var v := Vector2(velocity.x, velocity.z).length()
	walk_phase += dt * (v * (1.7 if mounted else 3.2) + 0.0)
	rig.show_pose(self, pose(), walk_phase, v, dt)
	rig.show_fall(_fall_amount(), fall_dir)


## How far the body has toppled (0 = upright, 1 = flat on the ground): knocked down, getting up, dying.
func _fall_amount() -> float:
	if state == DEAD:
		var t := clampf(state_t / FALL_TIME, 0.0, 1.0)
		return t * t + 0.06 * sin(clampf((state_t - FALL_TIME) / 0.25, 0.0, 1.0) * PI)   # gravity, then a small bounce
	if state == DOWN:
		var t := clampf(state_t / FALL_TIME, 0.0, 1.0)
		var up := clampf((state_len - state_t) / 0.55, 0.0, 1.0)                          # get up at the end
		return minf(t * t, up * up * (3.0 - 2.0 * up))
	return 0.0


# ------------------------------------------------------------------ pose (shared by visuals and hits)
static func _sl(a: Vector3, b: Vector3, t: float) -> Vector3:
	return a.normalized().slerp(b.normalized(), clampf(t, 0.0, 1.0))


static func _arc(keys: Array, t: float) -> Vector3:
	## piecewise slerp through keyframe directions, t in 0..1
	var n := keys.size() - 1
	var f := clampf(t, 0.0, 1.0) * n
	var i := mini(int(f), n - 1)
	return _sl(keys[i], keys[i + 1], f - i)


static func _smooth(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func _ease_out(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	return 1.0 - (1.0 - t) * (1.0 - t)


# Arm directions are in the soldier's own frame (-Z forward, +X right), from the shoulder.
const MAX_STEP := 0.45          # highest step a man can take (siege works: no climbing a wall face)
const MAX_DROP := 1.2           # AI soldiers don't step off the wall walk or a ladder
const REST := Vector3(0.3, -0.55, -0.75)            # weapon hand low and forward, elbow bent
const READY_POSE := [Vector3(0.15, 0.9, 0.45), Vector3(0.95, 0.35, 0.25), Vector3(-0.8, 0.45, 0.2), Vector3(0.2, 0.05, -1.0)]
const STRIKE_PATH := [
	[Vector3(0.15, 0.9, 0.45), Vector3(0.05, 0.6, -0.8), Vector3(0.05, -0.75, -0.65)],          # overhead
	[Vector3(0.95, 0.35, 0.25), Vector3(0.0, 0.15, -1.0), Vector3(-0.85, -0.15, -0.5)],        # right swing
	[Vector3(-0.8, 0.45, 0.2), Vector3(0.0, 0.15, -1.0), Vector3(0.85, -0.15, -0.45)],         # left swing
	[Vector3(0.12, 0.05, -1.0), Vector3(0.08, 0.04, -1.0), Vector3(0.05, 0.03, -1.0)],         # thrust
]
# The body behind each swing: [twist wound up, twist at the end, lean wound up, lean at the end, step at the end].
# twist > 0 turns the chest to the left (yaw), lean > 0 bends forward, step = how far the hips come forward (m).
const SWING_BODY := [
	[0.15, -0.1, -0.2, 0.35, 0.12],     # overhead: rear back, then chop down leaning in
	[-0.7, 0.5, 0.02, 0.12, 0.1],       # right swing: wound up to the right, unwinds through to the left
	[0.6, -0.45, 0.02, 0.12, 0.1],      # left swing
	[-0.45, 0.2, -0.06, 0.25, 0.32],    # thrust: shoulder back, then a lunge
]
const PELVIS_Y := 0.92
const FALL_TIME := 0.6            # the topple when knocked out (was 0.42: too quick to follow)
var fall_dir := Vector3(0, 0, 1)        # direction the body topples (own frame), set when hit


func pose() -> Dictionary:
	var arm := REST
	var off := Vector3.ZERO
	var wdir := Vector3.ZERO
	var larm := Vector3(-0.25, -0.5, -0.8)
	var shooting := false
	var twist := 0.0
	var lean := 0.0
	var crouch := 0.0
	var step := 0.0
	var reach := 0.48
	var lreach := 0.5
	var long_weapon: bool = weapon().get("kind", "") in ["polearm", "lance"]
	var body: Array = SWING_BODY[attack_dir]
	match state:
		READY:
			var p := _ease_out(state_t / ready_time())
			arm = _sl(REST, READY_POSE[attack_dir], p)
			twist = body[0] * p
			lean = body[2] * p
			reach = lerpf(0.48, 0.56, p)
			crouch = 0.05 * p
			if attack_dir == Dir.DOWN:
				off = Vector3(0, 0, 0.35 * p)
				reach = lerpf(0.48, 0.42, p)
		STRIKE:
			var raw := clampf(state_t / state_len, 0.0, 1.0)
			var p := _smooth(raw)
			arm = _arc(STRIKE_PATH[attack_dir], p)
			twist = lerpf(body[0], body[1], p)
			lean = lerpf(body[2], body[3], p)
			step = body[4] * p
			crouch = 0.05 + 0.04 * p
			reach = 0.6
			if attack_dir == Dir.DOWN:
				off = Vector3(0, 0, lerpf(0.35, -0.45, p))
				reach = lerpf(0.42, 0.6, p)
		RECOVER:
			var q := _smooth(state_t / maxf(0.01, state_len))
			arm = _sl(STRIKE_PATH[attack_dir][-1], REST, q)
			twist = body[1] * (1.0 - q)
			lean = body[3] * (1.0 - q)
			step = body[4] * (1.0 - q)
			crouch = 0.09 * (1.0 - q)
			reach = lerpf(0.6, 0.48, q)
			if attack_dir == Dir.DOWN:
				off = Vector3(0, 0, -0.45 * (1.0 - q))
		BLOCK:
			arm = Vector3(0.1, 0.45, -0.9)
			reach = 0.44
			crouch = 0.06
			match block_dir:
				Dir.UP:
					wdir = Vector3(-1.0, 0.25, -0.1)
					lean = -0.06
				Dir.RIGHT:
					wdir = Vector3(0.35, 1.0, -0.25)       # guarding against a swing from the enemy's right = my left
					twist = 0.25
				Dir.LEFT:
					wdir = Vector3(-0.35, 1.0, -0.25)
					twist = -0.25
				Dir.DOWN:
					wdir = Vector3(0.0, -0.9, -0.5)
					lean = 0.1
			if shield_up():
				larm = Vector3(-0.05, 0.25, -1.0)
				lreach = 0.42
		AIM, RELOAD:
			shooting = true
			var d := (aim_point - chest()).normalized() if state == AIM else forward()
			var loc := (global_transform.basis.inverse() * d).normalized()
			larm = loc
			lreach = 0.6
			twist = -0.35 * draw_progress()           # an archer turns his shoulder into the draw
			if is_thrower():
				# the throw: the right arm cocks back overhead, the shield stays up on the left
				shooting = false
				arm = Vector3(0.25, 0.25 + 0.45 * draw_progress(), 0.15 + 0.6 * draw_progress()).normalized()
				reach = 0.5
				larm = Vector3(-0.05, 0.25, -1.0) if shield_up() else Vector3(-0.3, -0.1, -0.8)
				lreach = 0.42
				twist = 0.3 * draw_progress()
			elif ranged.get("kind", "") == "bow":
				arm = (loc + Vector3(0.0, 0.0, 0.9) * draw_progress()).normalized()
				reach = lerpf(0.5, 0.3, draw_progress())
			else:
				arm = loc
				reach = 0.45
		STUN:
			# staggered by the blow: rock away from where it came from
			var k := 1.0 - clampf(state_t / maxf(0.01, state_len), 0.0, 1.0)
			arm = Vector3(0.45, -0.45, -0.5)
			lean = -0.3 * fall_dir.z * k
			twist = 0.35 * fall_dir.x * k
			crouch = 0.06
		DOWN:
			arm = Vector3(0.6, -0.4, 0.2)
			larm = Vector3(-0.6, -0.4, 0.2)
		DEAD:
			arm = Vector3(0.75, 0.1, 0.4)
			larm = Vector3(-0.75, 0.15, 0.3)
			reach = 0.6
			lreach = 0.6
	if couched:
		arm = Vector3(0.18, -0.12, -1.0)
		reach = 0.55
		lean = 0.15
	if long_weapon and state in [IDLE, RECOVER, BLOCK] and not couched:
		arm = Vector3(0.2, -0.1, -1.0)
		wdir = Vector3(0.0, 0.25, -1.0) if state != BLOCK else wdir
		larm = Vector3(-0.05, -0.15, -1.0)      # both hands on the shaft
		lreach = 0.55
	if shield_up() and state != BLOCK and not shooting and state not in [DOWN, DEAD]:
		# shield carried at the side, ready to come up
		larm = Vector3(-0.5, -0.45, -0.6) if state in [IDLE, RECOVER] else Vector3(-0.45, 0.0, -0.85)
		lreach = 0.45
	if wdir == Vector3.ZERO:
		wdir = arm if state != IDLE or long_weapon else Vector3(0.1, 0.55, -0.85)   # idle: blade up and forward
	if weapon().get("kind", "") == "unarmed" and state in [IDLE, RECOVER] and not shooting:
		arm = Vector3(0.18, -1.0, 0.05)          # empty-handed townsfolk: arms hang at the sides
		larm = Vector3(-0.18, -1.0, 0.05)
		wdir = arm
		reach = 0.55
		lreach = 0.55
	if mounted:
		crouch = 0.0
		step = 0.0
	return {"arm": arm, "weapon": wdir, "off": off, "larm": larm, "shooting": shooting, "twist": twist,
		"lean": lean, "crouch": crouch, "step": step, "reach": reach, "lreach": lreach}


## Where a shoulder is (own frame) for a pose: the chest twists, leans and lunges with the swing.
## side = 1 right, -1 left. Used by both the rig and the hit tests.
func shoulder_local(ps: Dictionary, side_sign := 1.0) -> Vector3:
	var pel := Vector3(0, PELVIS_Y - float(ps.crouch) + (RIDER_LIFT if mounted else 0.0), -float(ps.step))
	var bas := Basis(Vector3.UP, float(ps.twist)) * Basis(Vector3.RIGHT, -float(ps.lean))
	var sh := pel + bas * Vector3(SHOULDER.x * side_sign, SHOULDER.y - PELVIS_Y, 0)
	return sh + (ps.off as Vector3) if side_sign > 0 else sh


## Weapon blade as [hand, tip] in world space (for hit tests)
func weapon_segment() -> Array:
	var ps := pose()
	var hand: Vector3 = shoulder_local(ps) + (ps.arm as Vector3).normalized() * float(ps.reach)
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
	var t: float = battle.time
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
	# whoever is in front of the horse's chest (the overlap pass keeps men just clear of its head)
	var f := forward()
	var rt := right()
	for o in battle.agents_near(global_position, 2.4):
		if o == self or not o.alive() or o.mounted or o.state == DOWN or o.side == side:
			continue
		var d: Vector3 = o.global_position - global_position
		d.y = 0
		var along := d.dot(f)
		if along > 0.3 and along < 1.95 and absf(d.dot(rt)) < 0.75 and t > float(_bump_cd.get(o.get_instance_id(), 0.0)):
			_bump_cd[o.get_instance_id()] = t + 1.2
			battle.bump(self, o)


func take_hit(dmg: float, from: Agent, knock: bool, blunt: bool) -> void:
	if state == DEAD:
		return
	last_attacker = from
	if from != null and from != self:
		# fall away from the blow (own frame); a little sideways so bodies don't all lie the same way
		var away := global_transform.basis.inverse() * (global_position - from.global_position)
		away.y = 0
		fall_dir = (away.normalized() if away.length() > 0.01 else Vector3(0, 0, 1)).rotated(Vector3.UP, randf_range(-0.5, 0.5))
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
		set_meta("lost_horse", true)        # a horseman on foot looks for another mount (BattleAI)
		dismount()
		take_hit(10.0, from, true, true)


## Get on a riderless horse (Battle.interact): its breed, wounds and barding come with it.
func mount(h: Dictionary) -> void:
	mounted = true
	horse_kind = str(h.get("kind", "horse"))
	horse_hp = float(h.get("hp", 110.0))
	horse_max_hp = float(h.get("max_hp", horse_hp))
	horse_speed = float(h.get("speed_mult", 1.0)) * float(char_stats.get("horse", 1.0))
	horse_armor = float(h.get("armor", -1.0))
	speed = 0.0
	division = "cav"
	_check_mounted_kit()
	if not usable(weapon()):
		melee_idx = _first_usable(0)
	if using_ranged and not can_use_ranged():
		using_ranged = false
	_apply_shape()
	rig.queue_free()
	rig = AgentRig.new()
	add_child(rig)
	rig.build(self)


## The horse this agent rides, as a record a riderless horse keeps.
func horse_record() -> Dictionary:
	var base_mult := horse_speed / maxf(0.01, float(char_stats.get("horse", 1.0)))
	return {"kind": horse_kind, "hp": horse_hp, "max_hp": horse_max_hp, "speed_mult": base_mult,
		"armor": horse_armor, "color": color, "seed": rng_seed}


func dismount() -> void:
	mounted = false
	couched = false
	speed = 0.0
	division = "arc" if is_archer() else "inf"
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
	if battle.has_method("drop_weapon") and not melee.is_empty():
		battle.drop_weapon(weapon(), global_position)        # left on the field for anyone to pick up
	if mounted and horse_hp > 0.0 and battle.has_method("spawn_loose_horse"):
		# the rider falls; the horse runs on without him (Warband's riderless horses)
		battle.spawn_loose_horse(self, horse_record(), speed)
		dismount()
	if jumping:
		jumping = false
		position.y = battle.field.height_at(position.x, position.z)
	_set_state(DEAD, 0.0)
	velocity = Vector3.ZERO
	if rig.label:
		rig.label.visible = false
	battle.on_agent_down(self)
