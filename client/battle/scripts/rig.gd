class_name AgentRig
extends Node3D
## Procedural low-poly soldier (and horse) built from primitives. It only *shows* the pose that
## Agent.pose() computes — the same pose is used for hit detection, so what you see is what hits.

const SKIN := Color("d8b48c")
const TROUSERS := Color("3b3530")

var rider: Node3D
var horse: Node3D
var arm_r: Node3D
var arm_l: Node3D
var weapon: Node3D
var ranged_node: Node3D
var shield_node: Node3D
var legs: Array[Node3D] = []
var horse_legs: Array[Node3D] = []
var label: Label3D
var _mats := {}
var weapon_len := 0.7
var _body_mat: StandardMaterial3D


func mat(c: Color, metal := false) -> StandardMaterial3D:
	var key := c.to_html() + str(metal)
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.45 if metal else 0.85
	m.metallic = 0.5 if metal else 0.0
	_mats[key] = m
	return m


func _box(parent: Node3D, sz: Vector3, pos: Vector3, c: Color, metal := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = sz
	mi.mesh = b
	mi.position = pos
	mi.material_override = mat(c, metal)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(mi)
	return mi


func _cyl(parent: Node3D, r_top: float, r_bot: float, h: float, pos: Vector3, c: Color, metal := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = r_top
	m.bottom_radius = r_bot
	m.height = h
	m.radial_segments = 8
	m.rings = 1
	mi.mesh = m
	mi.position = pos
	mi.material_override = mat(c, metal)
	parent.add_child(mi)
	return mi


func build(a) -> void:
	var tunic: Color = a.color
	var tier: int = int(a.troop.get("tier", 1))
	var mounted: bool = a.mounted
	rider = Node3D.new()
	add_child(rider)
	if mounted:
		_build_horse(a)
		rider.position = Vector3(0, a.RIDER_LIFT, 0)
	# legs
	for side in [-1, 1]:
		var hip := Node3D.new()
		hip.position = Vector3(0.1 * side, 0.9, 0)
		rider.add_child(hip)
		_box(hip, Vector3(0.15, 0.88, 0.17), Vector3(0, -0.44, 0), TROUSERS)
		_box(hip, Vector3(0.16, 0.12, 0.26), Vector3(0, -0.86, -0.05), Color("2a221c"))
		legs.append(hip)
		if mounted:
			hip.rotation = Vector3(deg_to_rad(-70), 0, deg_to_rad(-25 * side))
	# torso, armour, head, helmet
	_body_mat = mat(tunic)
	var torso := _box(rider, Vector3(0.44, 0.6, 0.26), Vector3(0, 1.2, 0), tunic)
	torso.material_override = _body_mat
	if tier >= 3:
		_box(rider, Vector3(0.47, 0.4, 0.29), Vector3(0, 1.27, 0), Color("6f6f6a").lerp(tunic, 0.2), true)
	if tier >= 4:
		_box(rider, Vector3(0.62, 0.1, 0.32), Vector3(0, 1.48, 0), Color("8a8a84"), true)
	var head := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.13
	sm.height = 0.27
	sm.radial_segments = 10
	sm.rings = 6
	head.mesh = sm
	head.position = Vector3(0, 1.64, 0)
	head.material_override = mat(SKIN)
	rider.add_child(head)
	if tier >= 2:
		_cyl(rider, 0.06 if tier >= 3 else 0.12, 0.145, 0.16 if tier >= 3 else 0.08, Vector3(0, 1.74, 0), Color("6d6d68"), true)
	elif a.troop.get("culture", "") in ["bandit", "neutral"]:
		_cyl(rider, 0.13, 0.14, 0.06, Vector3(0, 1.72, 0), Color("7a3a2a"))
	else:
		_cyl(rider, 0.08, 0.13, 0.08, Vector3(0, 1.72, 0), tunic.darkened(0.3))   # cloth cap
	# arms
	arm_r = Node3D.new()
	arm_r.position = a.SHOULDER
	rider.add_child(arm_r)
	_box(arm_r, Vector3(0.11, 0.11, 0.58), Vector3(0, 0, -0.29), tunic.darkened(0.1))
	_box(arm_r, Vector3(0.1, 0.1, 0.1), Vector3(0, 0, -0.6), SKIN)
	arm_l = Node3D.new()
	arm_l.position = Vector3(-a.SHOULDER.x, a.SHOULDER.y, a.SHOULDER.z)
	rider.add_child(arm_l)
	_box(arm_l, Vector3(0.11, 0.11, 0.58), Vector3(0, 0, -0.29), tunic.darkened(0.1))
	_box(arm_l, Vector3(0.1, 0.1, 0.1), Vector3(0, 0, -0.6), SKIN)
	# shield on the left arm
	if not a.shield.is_empty():
		shield_node = Node3D.new()
		arm_l.add_child(shield_node)
		shield_node.position = Vector3(0, 0, -0.5)
		var r: float = float(a.shield.get("size", 0.55))
		var disc := _cyl(shield_node, r, r, 0.05, Vector3.ZERO,
			Color("b08a4a") if a.shield.get("id", "") == "rattan" else tunic.darkened(0.25))
		disc.rotation = Vector3(deg_to_rad(90), 0, 0)
		_cyl(shield_node, 0.08, 0.08, 0.07, Vector3(0, 0, -0.03), Color("8a8a84"), true).rotation = Vector3(deg_to_rad(90), 0, 0)
	# ranged weapon (bow / crossbow) carried in the left hand while shooting
	if not a.ranged.is_empty():
		ranged_node = Node3D.new()
		rider.add_child(ranged_node)
		if a.ranged.kind == "crossbow":
			_box(ranged_node, Vector3(0.07, 0.07, 0.7), Vector3(0, 0, -0.2), Color("6b4a2a"))
			_box(ranged_node, Vector3(0.75, 0.04, 0.05), Vector3(0, 0, -0.5), Color("4a3a2a"))
		else:
			for k in 5:
				var t := (k - 2) / 2.0
				var seg := _box(ranged_node, Vector3(0.035, 0.32, 0.035), Vector3(0, t * 0.3, -0.06 * (1.0 - t * t)), Color("5b3a1e"))
				seg.rotation.x = -t * 0.45
		ranged_node.visible = false
	weapon = Node3D.new()
	rider.add_child(weapon)
	set_weapon(a.weapon())
	if a.hero_name != "" and a.battle.player != a:
		label = Label3D.new()
		label.text = a.hero_name
		label.font_size = 48
		label.pixel_size = 0.006
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.position = Vector3(0, 2.2, 0)
		label.outline_size = 8
		label.modulate = Color("f2c75c")
		label.no_depth_test = true
		rider.add_child(label)


func _build_horse(a) -> void:
	horse = Node3D.new()
	add_child(horse)
	var barded: bool = a.horse_kind == "barded"
	var coat: Color = [Color("6b4a2e"), Color("3d2c22"), Color("8c6a48"), Color("2b2622"), Color("b9b1a2")][a.rng_seed % 5]
	var body_c: Color = a.color.darkened(0.15) if barded else coat
	_box(horse, Vector3(0.5, 0.62, 1.7), Vector3(0, 1.25, 0), body_c, barded)
	var neck := _box(horse, Vector3(0.3, 0.75, 0.32), Vector3(0, 1.65, -0.85), coat)
	neck.rotation.x = deg_to_rad(-35)
	var head := _box(horse, Vector3(0.24, 0.26, 0.6), Vector3(0, 1.98, -1.18), coat)
	head.rotation.x = deg_to_rad(25)
	if barded:
		_box(horse, Vector3(0.34, 0.5, 0.36), Vector3(0, 1.65, -0.85), body_c, true).rotation.x = deg_to_rad(-35)
	var tail := _box(horse, Vector3(0.1, 0.55, 0.1), Vector3(0, 1.2, 0.95), Color("1e1a17"))
	tail.rotation.x = deg_to_rad(25)
	_box(horse, Vector3(0.52, 0.06, 0.6), Vector3(0, 1.58, 0.05), Color("5a2e22"))   # saddle cloth
	for p in [Vector3(-0.17, 0.95, -0.65), Vector3(0.17, 0.95, -0.65), Vector3(-0.17, 0.95, 0.65), Vector3(0.17, 0.95, 0.65)]:
		var hip := Node3D.new()
		hip.position = p
		horse.add_child(hip)
		_box(hip, Vector3(0.13, 0.95, 0.15), Vector3(0, -0.47, 0), coat)
		horse_legs.append(hip)


func set_weapon(w: Dictionary) -> void:
	for c in weapon.get_children():
		c.queue_free()
	var kind: String = w.get("kind", "one_hand")
	var reach: float = float(w.get("reach", 1.4))
	weapon_len = maxf(0.35, reach - 0.75)
	var wid: String = w.get("id", "")
	var L := weapon_len
	# weapon model points along local -Z, grip at the origin
	match kind:
		"polearm", "lance":
			_box(weapon, Vector3(0.045, 0.045, L + 0.5), Vector3(0, 0, -L * 0.5 + 0.25), Color("6b4a2a"))
			if wid == "ji":
				_box(weapon, Vector3(0.03, 0.22, 0.28), Vector3(0, 0.08, -L + 0.12), Color("b8bcc0"), true)
			_box(weapon, Vector3(0.06, 0.03, 0.3), Vector3(0, 0, -L - 0.08), Color("c8ccd0"), true)
		"two_hand":
			_box(weapon, Vector3(0.05, 0.05, L + 0.3), Vector3(0, 0, -L * 0.5 + 0.15), Color("6b4a2a"))
			_box(weapon, Vector3(0.04, 0.32, 0.26), Vector3(0, 0.12, -L + 0.1), Color("b8bcc0"), true)
		_:
			if w.get("dtype", "") == "blunt":
				_box(weapon, Vector3(0.05, 0.05, L), Vector3(0, 0, -L * 0.5), Color("6b4a2a"))
				_box(weapon, Vector3(0.13, 0.13, 0.18), Vector3(0, 0, -L + 0.06), Color("8a8a84") if wid == "mace" else Color("5a3e24"), wid == "mace")
			else:
				_box(weapon, Vector3(0.05, 0.05, 0.16), Vector3(0, 0, 0.0), Color("3a2a1e"))
				_box(weapon, Vector3(0.16, 0.04, 0.04), Vector3(0, 0, -0.09), Color("8a7a50"), true)
				_box(weapon, Vector3(0.045, 0.012, L - 0.1), Vector3(0, 0, -L * 0.5 - 0.05), Color("d0d4d8"), true)


func _aim(n: Node3D, dir: Vector3) -> void:
	if dir.length_squared() < 0.0001:
		return
	var up := Vector3.UP if absf(dir.normalized().y) < 0.95 else Vector3.FORWARD
	n.basis = Basis.looking_at(dir, up)


## Apply a pose from Agent.pose(): {arm, weapon, off, larm, shooting}
func show_pose(a, pose: Dictionary, walk_phase: float, speed: float, dt: float) -> void:
	arm_r.position = a.SHOULDER + pose.off
	_aim(arm_r, pose.arm)
	var hand: Vector3 = arm_r.position + (pose.arm as Vector3).normalized() * 0.6
	weapon.position = hand
	_aim(weapon, pose.weapon)
	weapon.visible = not pose.get("shooting", false)
	_aim(arm_l, pose.larm)
	if ranged_node:
		ranged_node.visible = pose.get("shooting", false)
		if ranged_node.visible:
			ranged_node.position = arm_l.position + (pose.larm as Vector3).normalized() * 0.62
			_aim(ranged_node, pose.larm)
	# legs / horse legs
	var amp := clampf(speed / 4.0, 0.0, 1.0) * 0.6
	if horse:
		var hamp := clampf(speed / 6.0, 0.0, 1.0) * 0.7
		for k in horse_legs.size():
			horse_legs[k].rotation.x = sin(walk_phase * (0.7 if speed > 6.0 else 1.0) + [0.0, PI, PI * 0.5, PI * 1.5][k]) * hamp
		horse.position.y = absf(sin(walk_phase)) * 0.06 * hamp
		rider.position.y = a.RIDER_LIFT + horse.position.y
	else:
		for k in legs.size():
			legs[k].rotation.x = sin(walk_phase + PI * k) * amp


func flash(c: Color) -> void:
	_body_mat.emission_enabled = true
	_body_mat.emission = c
	_body_mat.emission_energy_multiplier = 0.7
	get_tree().create_timer(0.12).timeout.connect(func():
		if is_instance_valid(self):
			_body_mat.emission_enabled = false)
