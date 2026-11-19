class_name BattleAI
extends RefCounted
## Troop AI in the spirit of Warband: pick a target (respecting the division's order), close in,
## swing in a random allowed direction, and try to block incoming attacks after a reaction delay.
## Archers keep their distance and shoot (leading the target, compensating for drop); cavalry
## charges through (couched lance or a side swing), rides on, and wheels around.


static func update(a: Agent, b, dt: float) -> void:
	if not a.alive():
		return
	if b.time >= float(a.ai.get("next", 0.0)):
		a.ai["next"] = b.time + b.rules.num("ai", "think", 0.2) * randf_range(0.7, 1.3)
		_think(a, b)
	_act(a, b, dt)


# ------------------------------------------------------------------ decisions (a few times a second)
static func _think(a: Agent, b) -> void:
	if a.routed:
		a.ai["target"] = null
		return
	var order: Dictionary = b.order_of(a)
	var t: String = order.get("type", "charge")
	var cur = a.ai.get("target")
	if cur != null and (not is_instance_valid(cur) or not cur.alive()):
		cur = null
	var engage := 9999.0
	var anchor: Vector3 = a.global_position
	if t in ["hold", "stand", "follow"]:
		anchor = b.slot_of(a)
		engage = 7.0 if a.division == "inf" else (30.0 if a.division == "cav" else 0.0)
	elif t == "retreat":
		a.ai["target"] = null
		return
	var ranged_ok: bool = not a.ranged.is_empty() and a.ammo > 0
	var best = null
	var best_s := INF
	var crowd := int(b.rules.num("ai", "crowd", 3))
	for e in b.alive_by_side[1 - a.side]:          # enemies only (rebuilt every frame)
		if e.state == Agent.DOWN:
			continue
		var d: float = e.position.distance_to(a.position)
		var from_anchor: float = e.position.distance_to(anchor)
		var limit := engage
		if ranged_ok:
			limit = maxf(engage, b.rules.num("ai", "archer_range", 85))
		if from_anchor > limit and d > limit:
			continue
		var s := d + (6.0 if int(b.attackers_on.get(e.get_instance_id(), 0)) >= crowd and e != cur else 0.0)
		if ranged_ok and a.using_ranged and d > 12.0 and b.engaged_with_ally(e, a.side):
			s += 40.0          # don't shoot into a melee where our own men are fighting
		if e.routed:
			s += 25.0
		if e == cur:
			s -= 3.0          # stick with the current opponent
		if s < best_s:
			best_s = s
			best = e
	a.ai["target"] = best
	# weapon choice: bow at range, melee when the enemy is close
	if not a.ranged.is_empty():
		var d: float = INF if best == null else best.global_position.distance_to(a.global_position)
		var close: float = b.rules.num("ai", "archer_min_range", 9)
		if a.mounted:
			close = 6.0
		if a.ammo > 0 and d > close:
			if not a.using_ranged and a.state == Agent.IDLE:
				a.using_ranged = true
		elif a.using_ranged and a.state in [Agent.IDLE, Agent.RELOAD]:
			a.use_melee(0)
			a.state = Agent.IDLE


# ------------------------------------------------------------------ every frame
static func _act(a: Agent, b, dt: float) -> void:
	var tgt = a.ai.get("target")
	if tgt != null and (not is_instance_valid(tgt) or not tgt.alive()):
		tgt = null
		a.ai["target"] = null
	a.intent_run = true
	if a.routed or b.order_of(a).get("type", "") == "retreat":
		var edge: Vector3 = b.retreat_point(a)
		_steer(a, b, edge, 1.0)
		if a.state == Agent.BLOCK:
			a.stop_block()
		return
	_defend(a, b)
	if tgt == null:
		_idle_move(a, b)
		return
	if a.using_ranged and a.ammo > 0:
		_shoot(a, b, tgt, dt)
	elif a.mounted:
		_cavalry(a, b, tgt)
	else:
		_melee(a, b, tgt)


static func _idle_move(a: Agent, b) -> void:
	var order: Dictionary = b.order_of(a)
	if a.state == Agent.READY:
		a.release_attack()
	if order.get("type", "charge") in ["hold", "stand", "follow"]:
		var slot: Vector3 = b.slot_of(a)
		var d := Vector2(slot.x - a.global_position.x, slot.z - a.global_position.z).length()
		if d > 0.8:
			a.intent_run = d > 6.0
			_steer(a, b, slot, 1.0 if d > 3.0 else 0.6)
		else:
			a.intent_move = Vector3.ZERO
			a.speed = move_toward(a.speed, 0.0, 0.2)
			a.intent_yaw = float(order.get("facing", a.heading))
	else:
		# charge with nobody in reach: advance towards the enemy army
		var c: Vector3 = b.enemy_center(a.side)
		_steer(a, b, c, 1.0)


static func _steer(a: Agent, b, dest: Vector3, mag: float) -> void:
	var d := dest - a.global_position
	d.y = 0
	if d.length() < 0.05:
		a.intent_move = Vector3.ZERO
		return
	var dir := d.normalized()
	if not a.mounted:
		dir = (dir + b.separation(a) * 0.9 + b.tree_push(a) * 1.5).normalized()
	else:
		dir = (dir + b.tree_push(a) * 2.0).normalized()
	a.intent_move = dir * mag
	if not a.mounted:
		a.intent_yaw = atan2(-dir.x, -dir.z)


static func _face(a: Agent, p: Vector3) -> void:
	var d := p - a.global_position
	a.intent_yaw = atan2(-d.x, -d.z)


# ------------------------------------------------------------------ melee on foot
static func _melee(a: Agent, b, tgt: Agent) -> void:
	var d := Vector2(tgt.global_position.x - a.global_position.x, tgt.global_position.z - a.global_position.z).length()
	var r := a.reach() + (0.25 if not tgt.mounted else 0.6)
	if d > r * 0.85:
		_steer(a, b, tgt.global_position, 1.0)
		a.intent_run = d > 4.0
	elif d < r * 0.45 and a.weapon().get("kind", "") == "polearm":
		a.intent_move = (a.global_position - tgt.global_position).normalized() * 0.6   # keep the spear's distance
	else:
		a.intent_move = b.separation(a) * 0.5
	_face(a, tgt.global_position)
	if a.state == Agent.BLOCK:
		return
	var now: float = b.time
	var blocked_by = _ally_ahead(a, b, d)
	if blocked_by != null:
		# a comrade is between me and the enemy: step around him instead of hitting him in the back
		var sidestep: Vector3 = a.right() * (1.0 if (blocked_by.global_position - a.global_position).dot(a.right()) < 0 else -1.0)
		a.intent_move = (sidestep + (tgt.global_position - a.global_position).normalized() * 0.3).normalized() * 0.8
		if a.state == Agent.READY:
			return
	if a.state == Agent.IDLE and now > float(a.ai.get("cd", 0.0)) and d < r * 1.35 and blocked_by == null:
		var dirs: Array = a.allowed_dirs().duplicate()
		# a side swing would sweep through the comrade standing on that side: chop or thrust instead
		for o in b.agents_near(a.global_position, 2.0):
			if o == a or o.side != a.side or not o.alive():
				continue
			var off: Vector3 = o.global_position - a.global_position
			if off.length() > 1.9 or off.dot(a.forward()) < -0.3:
				continue
			var sidev := off.dot(a.right())
			if sidev > 0.3:
				dirs.erase(Agent.Dir.RIGHT)
			elif sidev < -0.3:
				dirs.erase(Agent.Dir.LEFT)
		if dirs.is_empty():
			dirs = [Agent.Dir.DOWN] if a.can_thrust() else [Agent.Dir.UP]
		var dir: int = dirs[randi() % dirs.size()]
		# a little cunning: don't attack straight into a raised guard
		if tgt.state == Agent.BLOCK and tgt.shield.is_empty() and dirs.size() > 1 and dir == tgt.block_dir:
			dir = dirs[(dirs.find(dir) + 1) % dirs.size()]
		a.start_attack(dir)
		a.ai["hold"] = randf_range(0.0, 0.25)
	elif a.state == Agent.READY and a.state_t >= a.ready_time() + float(a.ai.get("hold", 0.0)) and d <= r:
		a.release_attack()
		a.ai["cd"] = now + b.rules.num("ai", "attack_cooldown", 0.35) + randf_range(0.0, 0.5)


static func _ally_ahead(a: Agent, b, tgt_dist: float):
	for o in b.agents_near(a.global_position, minf(tgt_dist, 3.0)):
		if o == a or o.side != a.side or not o.alive() or o.state == Agent.DOWN:
			continue
		var off: Vector3 = o.global_position - a.global_position
		off.y = 0.0
		var l := off.length()
		if l < tgt_dist - 0.2 and l < a.reach() + 0.3 and off.normalized().dot(a.forward()) > 0.75:
			return o
	return null


## Raise the guard against an incoming attack (after a reaction delay; better troops block more).
static func _defend(a: Agent, b) -> void:
	if a.using_ranged and a.shield.is_empty():
		return
	if a.state == Agent.STRIKE or a.busy() and a.state != Agent.RECOVER:
		return
	# scan for attackers every 3rd frame (staggered); in between keep the current guard
	if (b.frame + a.rng_seed) % 3 != 0:
		var keep = a.ai.get("threat")
		if keep == null or not is_instance_valid(keep) or not keep.attacking():
			if a.state == Agent.BLOCK and keep != null:
				a.stop_block()
			return
	var threat: Agent = null
	var td := INF
	for e in b.agents_near(a.global_position, 3.6):
		if e.side == a.side or not e.attacking() or e.state == Agent.DEAD:
			continue
		var d: float = e.global_position.distance_to(a.global_position)
		if d > e.reach() + 1.0 or d >= td:
			continue
		var to_me: Vector3 = (a.global_position - e.global_position).normalized()
		if to_me.dot(e.forward()) < 0.5:
			continue
		threat = e
		td = d
	a.ai["threat"] = threat
	if threat == null:
		if a.state == Agent.BLOCK:
			a.stop_block()
		a.ai.erase("block_key")
		return
	var key := "%d_%d" % [threat.get_instance_id(), int(threat.ai.get("swing_id", 0))]
	if a.ai.get("block_key", "") != key:
		a.ai["block_key"] = key
		var p: float = b.rules.num("ai", "block_base", 0.35) + b.rules.num("ai", "block_per_tier", 0.12) * a.tier()
		if not a.shield.is_empty():
			p += 0.25
		if a.is_player:
			p = 0.0
		a.ai["block_ok"] = randf() < p
		a.ai["block_at"] = b.time + maxf(0.05, b.rules.num("ai", "reaction", 0.22) + b.rules.num("ai", "reaction_per_tier", -0.03) * a.tier())
		a.ai["block_wrong"] = randi() % 4
	if not bool(a.ai.get("block_ok", false)) or b.time < float(a.ai.get("block_at", 0.0)):
		return
	if a.state == Agent.READY and a.state_t > a.ready_time():
		return              # committed: trade blows
	_face(a, threat.global_position)
	var dir: int = threat.attack_dir
	a.start_block(dir)


# ------------------------------------------------------------------ cavalry
static func _cavalry(a: Agent, b, tgt: Agent) -> void:
	var to := tgt.global_position - a.global_position
	to.y = 0
	var d := to.length()
	var f := a.forward()
	var behind := to.normalized().dot(f) < -0.1
	var pass_dist: float = b.rules.num("ai", "cav_pass", 14)
	var lance: bool = a.weapon().get("kind", "") == "lance"
	if behind and d < pass_dist and a.speed > 3.0:
		# rode through: keep going, then wheel around
		a.intent_move = f
		if a.state == Agent.READY:
			a.release_attack()
		return
	if lance and a.weapon().get("couch", 0) > 0:
		# point the couched lance at the target (lead it a little)
		var lead: Vector3 = tgt.global_position + tgt.velocity * clampf(d / maxf(a.speed, 3.0), 0.0, 1.0)
		_steer(a, b, lead, 1.0)
		if d < 3.0 and a.speed < 4.0 and a.state == Agent.IDLE:
			a.start_attack(Agent.Dir.RIGHT if to.dot(a.right()) > 0 else Agent.Dir.LEFT)
		elif a.state == Agent.READY and a.state_t >= a.ready_time():
			a.release_attack()
		return
	# sword cavalry: pass the target on the weapon side and swing
	var side_off := a.right() * (1.3 if to.dot(a.right()) >= 0 else -1.3)
	_steer(a, b, tgt.global_position - side_off * 0.0 + side_off, 1.0)
	if a.state == Agent.IDLE and d < 9.0 and not behind:
		a.start_attack(Agent.Dir.RIGHT if to.dot(a.right()) > 0 else Agent.Dir.LEFT)
	elif a.state == Agent.READY and a.state_t >= a.ready_time() and d < a.reach() + a.speed * 0.12 + 0.4:
		a.release_attack()


# ------------------------------------------------------------------ archers
static func _shoot(a: Agent, b, tgt: Agent, dt: float) -> void:
	var d := a.global_position.distance_to(tgt.global_position)
	var rng: float = b.rules.num("ai", "archer_range", 85)
	var order: Dictionary = b.order_of(a)
	if a.mounted:
		# horse archers keep a band of distance and ride around
		var to := (tgt.global_position - a.global_position)
		to.y = 0
		var perp := Vector3(-to.z, 0, to.x).normalized()
		if d < 18.0:
			a.intent_move = (-to.normalized() + perp * 0.6).normalized()
		elif d > 40.0:
			a.intent_move = (to.normalized() + perp * 0.3).normalized()
		else:
			a.intent_move = perp * 0.7
	elif d > rng and order.get("type", "charge") == "charge":
		_steer(a, b, tgt.global_position, 1.0)
	elif order.get("type", "charge") in ["hold", "stand", "follow"]:
		var slot: Vector3 = b.slot_of(a)
		var sd := Vector2(slot.x - a.global_position.x, slot.z - a.global_position.z).length()
		a.intent_move = (slot - a.global_position).normalized() * 0.8 if sd > 1.5 else Vector3.ZERO
		a.intent_move.y = 0
	else:
		a.intent_move = b.separation(a) * 0.4
	if d > rng * 1.15:
		if a.state == Agent.AIM:
			a.state = Agent.IDLE
		return
	_face(a, tgt.global_position)
	var spd: float = float(a.ranged.get("speed", 55))
	var t := d / spd
	var p: Vector3 = tgt.chest() + tgt.velocity * t
	p.y += 0.5 * b.rules.num("ranged", "gravity", 9.8) * t * t
	a.aim_point = p
	if a.state == Agent.IDLE:
		a.begin_aim()
		a.ai["aim_extra"] = randf_range(0.6, 1.3)
	elif a.state == Agent.AIM and a.draw_progress() >= 1.0:
		var draw: float = 0.35 if a.ranged.kind == "crossbow" else float(a.ranged.get("draw", 0.9))
		if a.state_t >= draw + float(a.ai.get("aim_extra", 0.3)):
			if b.ally_in_line(a, p):
				a.ai["aim_extra"] = float(a.ai.get("aim_extra", 0.3)) + 0.4   # wait for a clear shot
				return
			var err: float = maxf(0.2, b.rules.num("ranged", "ai_aim_error", 1.4) - 0.25 * a.tier())
			a.release_shot(err)
