extends SceneTree
## Headless geometry check of the melee swings (Agent.pose / weapon_segment, which the hit tests use):
## where does the blade pass for a rider swinging at a man on foot beside him, and for a man on foot
## looking down — with the swing level and pitched by Agent.tilt_at / the camera.
## Run: godot --headless --path . -s tests/swing_test.gd

func _initialize() -> void:
	call_deferred("run")


func _agent(rules: BattleRules, tid: String, mounted: bool) -> Agent:
	var a := Agent.new()
	a.rules = rules
	a.troop = rules.troops.get(tid, {"id": tid, "name": tid, "culture": "", "tier": 3, "cls": "cav"}).duplicate()
	var l := rules.loadout(tid, {})
	a.melee = l.melee
	a.ranged = l.ranged
	a.shield = l.shield
	a.horse_kind = l.horse if mounted else ""
	a.mounted = mounted
	a.using_ranged = false
	a.melee_idx = 0
	root.add_child(a)
	return a


## Closest approach (m) of the blade to the target's body axis (a vertical segment), and the blade's
## height there, over a whole strike.
func sweep(a: Agent, t: Agent, dir: int, tilt: float) -> Array:
	a.attack_dir = dir
	a.swing_tilt = tilt
	a.swing_yaw = a.yaw_at(t)
	a.state = Agent.STRIKE
	a.state_len = 1.0
	var lo := t.global_position + Vector3(0, 0.3 + (Agent.RIDER_LIFT if t.mounted else 0.0), 0)
	var hi := t.global_position + Vector3(0, 1.75 + (Agent.RIDER_LIFT if t.mounted else 0.0), 0)
	var best := INF
	var at_h := 0.0
	for i in 41:
		a.state_t = i / 40.0
		var seg: Array = a.weapon_segment()
		for k in 9:
			var p: Vector3 = (seg[0] as Vector3).lerp(seg[1], k / 8.0)
			var q := Geometry3D.get_closest_point_to_segment(p, lo, hi)
			var d := p.distance_to(q)
			if d < best:
				best = d
				at_h = p.y
	return [best, at_h]


func run() -> void:
	var rules := BattleRules.new()
	rules.load_all()
	var rider := _agent(rules, "zhou_cav3", true)
	var foot := _agent(rules, "zhou_inf3", false)
	var ok := true
	# a man on foot 1.3 m to the rider's right and a little ahead (passing him on the weapon side)
	rider.global_position = Vector3.ZERO
	rider.rotation.y = 0.0
	foot.global_position = rider.global_position + rider.right() * 1.3 + rider.forward() * 0.4
	var level: Array = sweep(rider, foot, Agent.Dir.RIGHT, 0.0)
	var aimed_tilt := rider.tilt_at(foot)
	var aimed: Array = sweep(rider, foot, Agent.Dir.RIGHT, aimed_tilt)
	print("骑兵右砍身旁步兵：水平 最近 %.2fm 高 %.2fm；俯 %.2f rad 最近 %.2fm 高 %.2fm" % [level[0], level[1], aimed_tilt, aimed[0], aimed[1]])
	ok = ok and aimed[0] < level[0] and aimed[0] < 0.35
	foot.global_position = rider.global_position - rider.right() * 1.3 + rider.forward() * 0.4
	aimed_tilt = rider.tilt_at(foot)
	var left: Array = sweep(rider, foot, Agent.Dir.LEFT, aimed_tilt)
	print("骑兵左砍身旁步兵：俯 %.2f rad 最近 %.2fm 高 %.2fm" % [aimed_tilt, left[0], left[1]])
	ok = ok and left[0] < 0.35
	# on foot: a low target (a man kneeling / knocked down ~0.6 m) straight ahead, looking down
	var a := _agent(rules, "zhou_inf3", false)
	a.global_position = Vector3(10, 0, 0)
	var low := _agent(rules, "zhou_inf3", false)
	low.global_position = a.global_position + a.forward() * 1.1
	for dir in [Agent.Dir.RIGHT, Agent.Dir.LEFT]:
		a.attack_dir = dir
		var lv: float = 9.0
		var dn: float = 9.0
		for tilt in [0.0, -0.8]:
			a.swing_tilt = tilt
			a.state = Agent.STRIKE
			a.state_len = 1.0
			var lowest := INF
			for i in 41:
				a.state_t = i / 40.0
				var seg: Array = a.weapon_segment()
				lowest = minf(lowest, (seg[1] as Vector3).y)
			if tilt == 0.0:
				lv = lowest
			else:
				dn = lowest
		print("步兵%s砍：水平时刀尖最低 %.2fm，往下看时最低 %.2fm" % ["右" if dir == Agent.Dir.RIGHT else "左", lv, dn])
		ok = ok and dn < lv - 0.4
	print("SWING_TEST_" + ("OK" if ok else "FAIL"))
	quit(0 if ok else 1)
