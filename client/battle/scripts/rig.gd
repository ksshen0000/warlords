class_name AgentRig
extends Node3D
## Procedural low-poly soldier (and horse) built from primitives. It only *shows* the pose that
## Agent.pose() computes — hand and weapon positions come from the same maths as the hit tests, so what
## you see is what hits. Everything else (elbows, knees, feet, the horse's legs, bobbing) is solved here:
##   - arms and legs are two bones each, bent with two-bone IK towards the hand / foot targets
##   - feet follow a gait: they swing along the direction of travel (sideways, backwards too) and lift
##   - the chest twists, leans and lunges with the swing; a soldier falls away from the blow that dropped him
## Procedural animation in the spirit of Veloren's code-driven skeletons (buildup / action / recover stages).

const UPPER_ARM := 0.31
const FOREARM := 0.31
const THIGH := 0.455
const SHIN := 0.455
const HORSE_UPPER := 0.5
const HORSE_LOWER := 0.47
const Art := preload("res://battle/scripts/art_mesh.gd")
const Equipment := preload("res://battle/scripts/equipment_art.gd")
const HorseSkin := preload("res://battle/scripts/horse_skin.gd")

var rider: Node3D
var horse: Node3D
var pelvis: Node3D                 # hips (moves with crouch / lunge / bob)
var spine: Node3D                  # chest, head (twists and leans)
var arm_r: Array[Node3D] = []      # [upper, fore]
var arm_l: Array[Node3D] = []
var weapon: Node3D
var ranged_node: Node3D
var shield_node: Node3D
var shield_on_arm := true          # false: slung on the back (bow / crossbow / two-handed weapon in hand)
var legs: Array = []               # per side: [thigh, shin]
var horse_legs: Array = []         # per leg: [hip, upper, lower]
var horse_neck: Node3D
var label: Label3D
static var _mats := {}             # shared materials for feet and fallback body parts
static var _boxes := {}
var weapon_len := 0.7
var grip2 := 0.0                   # two-handed weapons: where the left hand holds the shaft (m along the weapon; 0 = one hand)
var _flash_on: Array = []          # the meshes that flash red when hit (an overlay: the skin is shared)
static var _flash_mat: StandardMaterial3D
var _mounted := false
# gait references: full run / full gallop speed from the rules (so slowing the battle keeps the animation)
var _run_ref := 4.4
var _gallop_ref := 10.5
# smoothed values (idle / block / stun poses blend; attacks are shown exactly)
var _s := {}


func _mat(c: Color) -> StandardMaterial3D:
	if _mats.has(c):
		return _mats[c]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.85
	_mats[c] = m
	return m


func _box(parent: Node3D, sz: Vector3, pos: Vector3, c: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	if not _boxes.has(sz):
		var b := BoxMesh.new()
		b.size = sz
		_boxes[sz] = b
	mi.mesh = _boxes[sz]
	mi.position = pos
	mi.material_override = _mat(c)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(mi)
	return mi


## A skinned bone: a pivot with a pixel-skinned cuboid along its local -Z (AgentSkin part).
func _sbone(parent: Node3D, part: String, length: float, thick: float, m: Material) -> Node3D:
	var n := Node3D.new()
	parent.add_child(n)
	var mi := MeshInstance3D.new()
	mi.mesh = AgentSkin.mesh(part, Vector3(thick, length, thick), true)
	mi.material_override = m
	n.add_child(mi)
	return n


func _sbox(parent: Node3D, part: String, size: Vector3, pos: Vector3, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = AgentSkin.mesh(part, size)
	mi.material_override = m
	mi.position = pos
	parent.add_child(mi)
	return mi


func build(a) -> void:
	var tunic: Color = a.color
	var tier: int = int(a.troop.get("tier", 1))
	_mounted = a.mounted
	if a.rules and a.rules.movement:
		_run_ref = maxf(1.0, a.rules.movement.foot_run)
		_gallop_ref = maxf(2.0, a.rules.movement.horse_speed)
	rider = Node3D.new()
	add_child(rider)
	if _mounted:
		_build_horse(a)
		rider.position = Vector3(0, a.RIDER_LIFT, 0)
	# blocky, pixel-skinned body (AgentSkin): the skin shows rank and gear — the troop's tier, or the
	# tier of the player's own helmet / body armour — in the side's colour
	var body_t: int = int(a.look.get("body", tier))
	var head_t: int = int(a.look.get("head", tier))
	var cult: String = str(a.troop.get("culture", ""))
	var skin_m := AgentSkin.material({"coat": tunic.to_html(false), "culture": cult, "body": body_t, "head": head_t,
		"var": int(a.rng_seed) % 4})
	# legs: thigh + shin (+ foot)
	for side in [-1, 1]:
		var thigh := _sbone(rider, "thigh", THIGH, 0.16, skin_m)
		var shin := _sbone(rider, "shin", SHIN, 0.15, skin_m)
		var foot := _box(shin, Vector3(0.15, 0.08, 0.22), Vector3(0, 0, -SHIN), Color("2a221c"))
		foot.set_meta("foot", true)
		legs.append([thigh, shin, foot])
	# hips, chest, head
	pelvis = Node3D.new()
	rider.add_child(pelvis)
	_sbox(pelvis, "pelvis", Vector3(0.38, 0.18, 0.24), Vector3(0, 0.02, 0), skin_m)
	spine = Node3D.new()
	pelvis.add_child(spine)
	var torso := _sbox(spine, "torso", Vector3(0.44, 0.52, 0.26), Vector3(0, 0.3, 0), skin_m)
	_flash_on = [torso]
	if body_t >= 2:
		_sbox(spine, "armor", Vector3(0.48, 0.56, 0.3), Vector3(0, 0.3, 0), skin_m)     # the armour layer
	var head := _sbox(spine, "head", Vector3(0.3, 0.3, 0.3), Vector3(0, 0.73, 0), skin_m)
	_sbox(spine, "helm", Vector3(0.34, 0.34, 0.34), Vector3(0, 0.75, 0), skin_m)        # helmet / headgear layer
	_flash_on.append(head)
	# arms: upper + forearm (the hand is painted on its end)
	for arr in [arm_r, arm_l]:
		var up := _sbone(rider, "uarm", UPPER_ARM, 0.12, skin_m)
		var fo := _sbone(rider, "farm", FOREARM, 0.11, skin_m)
		arr.append(up)
		arr.append(fo)
	# shield on the left forearm
	if not a.shield.is_empty():
		shield_node = Node3D.new()
		arm_l[1].add_child(shield_node)
		shield_node.position = Vector3(0, 0, -FOREARM * 0.6)
		var r: float = float(a.shield.get("size", 0.55))
		shield_node.set_meta("r", r)
		Art.add(shield_node, Equipment.shield(a.shield.get("id", ""), r, tunic))
	# ranged weapon (bow / crossbow) carried in the left hand while shooting
	if not a.ranged.is_empty():
		ranged_node = Node3D.new()
		rider.add_child(ranged_node)
		Art.add(ranged_node, Equipment.ranged(a.ranged.kind, str(a.ranged.get("id", ""))))
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


## A riderless horse (Battle.loose_horses): just the horse, posed with pose_horse().
func build_horse_only(a) -> void:
	_mounted = true
	if a.rules and a.rules.movement:
		_gallop_ref = maxf(2.0, a.rules.movement.horse_speed)
	_build_horse(a)


func pose_horse(walk_phase: float, speed: float) -> void:
	if horse:
		_horse_gait(walk_phase, speed)


func _build_horse(a) -> void:
	horse = Node3D.new()
	add_child(horse)
	var barded: bool = a.horse_kind == "barded"
	var skin_m := HorseSkin.material(a.rng_seed % 5, a.color, barded)
	_horse_part(horse, "body", Vector3(0.5, 0.62, 1.7), Vector3(0, 1.25, 0), skin_m)
	# neck and head nod together around the withers
	horse_neck = Node3D.new()
	horse_neck.position = Vector3(0, 1.45, -0.65)
	horse.add_child(horse_neck)
	var neck := _horse_part(horse_neck, "neck", Vector3(0.3, 0.75, 0.32), Vector3(0, 0.2, -0.2), skin_m)
	neck.rotation.x = deg_to_rad(-35)
	var head := _horse_part(horse_neck, "head", Vector3(0.24, 0.26, 0.42), Vector3(0, 0.53, -0.53), skin_m)
	head.rotation.x = deg_to_rad(25)
	if barded:
		_horse_part(horse_neck, "armor", Vector3(0.34, 0.5, 0.36), Vector3(0, 0.2, -0.2), skin_m).rotation.x = deg_to_rad(-35)
	var tail := _horse_part(horse, "tail", Vector3(0.1, 0.55, 0.1), Vector3(0, 1.2, 0.95), skin_m)
	tail.rotation.x = deg_to_rad(25)
	_horse_part(horse, "saddle", Vector3(0.54, 0.11, 0.62), Vector3(0, 1.571, 0.05), skin_m)
	# legs: front left, front right, hind left, hind right — upper leg + cannon with a knee / hock
	for p in [Vector3(-0.17, 0.97, -0.65), Vector3(0.17, 0.97, -0.65), Vector3(-0.17, 0.97, 0.65), Vector3(0.17, 0.97, 0.65)]:
		var hip := Node3D.new()
		hip.position = p
		horse.add_child(hip)
		var upper := Node3D.new()
		hip.add_child(upper)
		_horse_part(upper, "upper", Vector3(0.14, HORSE_UPPER, 0.17), Vector3(0, -HORSE_UPPER * 0.5, 0), skin_m)
		var lower := Node3D.new()
		lower.position = Vector3(0, -HORSE_UPPER, 0)
		upper.add_child(lower)
		_horse_part(lower, "lower", Vector3(0.1, HORSE_LOWER, 0.11), Vector3(0, -HORSE_LOWER * 0.5, 0), skin_m)
		_box(lower, Vector3(0.13, 0.08, 0.15), Vector3(0, -HORSE_LOWER + 0.03, 0), Color("1e1a17"))   # hoof
		horse_legs.append([hip, upper, lower])


func _horse_part(parent: Node3D, part: String, size: Vector3, pos: Vector3, m: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = HorseSkin.mesh(part, size)
	node.material_override = m
	node.position = pos
	parent.add_child(node)
	return node


func set_weapon(w: Dictionary) -> void:
	for child in weapon.get_children():
		weapon.remove_child(child)
		child.queue_free()
	var kind: String = w.get("kind", "one_hand")
	var reach: float = float(w.get("reach", 1.4))
	weapon_len = maxf(0.35, reach - 0.75)
	grip2 = {"two_hand": -0.13, "polearm": 0.42}.get(kind, 0.0)
	# weapon model points along local -Z, grip at the origin
	if kind != "unarmed":
		Art.add(weapon, Equipment.melee(w, weapon_len))


# ------------------------------------------------------------------ maths
static func _look(n: Node3D, from: Vector3, to: Vector3, up_hint := Vector3.UP) -> void:
	var d := to - from
	if d.length_squared() < 0.000001:
		n.position = from
		return
	var up := up_hint if absf(d.normalized().dot(up_hint.normalized())) < 0.97 else Vector3.FORWARD
	n.transform = Transform3D(Basis.looking_at(d, up), from)


## Two-bone IK: where the middle joint (elbow / knee) goes so the chain reaches from `a` towards `t`,
## bending towards `pole`.
static func ik_joint(a: Vector3, t: Vector3, l1: float, l2: float, pole: Vector3) -> Vector3:
	var d := t - a
	var dist := clampf(d.length(), 0.02, l1 + l2 - 0.001)
	var dn := d.normalized() if d.length() > 0.0001 else Vector3.DOWN
	var x := (l1 * l1 - l2 * l2 + dist * dist) / (2.0 * dist)
	var h := sqrt(maxf(0.0, l1 * l1 - x * x))
	var p := pole - dn * pole.dot(dn)
	if p.length_squared() < 0.000001:
		p = dn.cross(Vector3.RIGHT if absf(dn.x) < 0.9 else Vector3.UP)
	return a + dn * x + p.normalized() * h


func _chain(bones: Array, a: Vector3, t: Vector3, l1: float, l2: float, pole: Vector3) -> Vector3:
	var j := ik_joint(a, t, l1, l2, pole)
	_look(bones[0], a, j, pole)
	var end := t if a.distance_to(t) <= l1 + l2 else j + (t - j).normalized() * l2
	_look(bones[1], j, end, pole)
	return end


func _blend(key: String, target, k: float):
	## exponential smoothing of a pose value (Vector3 or float); k = 1 snaps
	if not _s.has(key) or k >= 1.0:
		_s[key] = target
	elif target is Vector3:
		_s[key] = (_s[key] as Vector3).lerp(target, k)
	else:
		_s[key] = lerpf(_s[key], target, k)
	return _s[key]


# ------------------------------------------------------------------ pose
## Apply and smooth the fresh pose returned by Agent.pose().
func show_pose(a, ps: Dictionary, walk_phase: float, speed: float, dt: float) -> void:
	# attacks are shown exactly (they are what hits); idle / guard / stagger blend in smoothly
	var exact: bool = a.state in [Agent.READY, Agent.STRIKE, Agent.RECOVER, Agent.AIM]
	var k := 1.0 if exact else 1.0 - exp(-dt * 14.0)
	var arm: Vector3 = _blend("arm", (ps.arm as Vector3).normalized(), k)
	var wdir: Vector3 = _blend("w", (ps.weapon as Vector3).normalized(), k)
	var larm: Vector3 = _blend("larm", (ps.larm as Vector3).normalized(), k)
	for key in ["twist", "lean", "crouch", "step", "reach", "lreach"]:
		ps[key] = _blend(key, float(ps[key]), k)
	ps["off"] = _blend("off", ps.off, k)
	# gait: run lean and a bob of the hips, from the actual speed
	var run := clampf(speed / _run_ref, 0.0, 1.0)
	var bob := 0.0
	if not _mounted:
		ps["lean"] = float(ps.lean) + 0.14 * run * (0.0 if exact else 1.0)
		bob = -absf(sin(walk_phase)) * 0.045 * run
	else:
		var gallop := clampf(speed / (_gallop_ref * 0.76), 0.0, 1.0)
		ps["lean"] = float(ps.lean) + 0.12 * gallop
	var lift: float = a.RIDER_LIFT if _mounted else 0.0
	# chest
	pelvis.position = Vector3(0, a.PELVIS_Y - float(ps.crouch) + bob, -float(ps.step))
	spine.basis = Basis(Vector3.UP, float(ps.twist)) * Basis(Vector3.RIGHT, -float(ps.lean))
	var sh_r: Vector3 = a.shoulder_local(ps, 1.0) - Vector3(0, lift - bob, 0)
	var sh_l: Vector3 = a.shoulder_local(ps, -1.0) - Vector3(0, lift - bob, 0)
	# arms (IK towards the pose's hands)
	var hand_r := sh_r + arm * float(ps.reach)
	_chain(arm_r, sh_r, hand_r, UPPER_ARM, FOREARM, Vector3(0.6, -0.7, 0.4))
	var hand_l := sh_l + larm * float(ps.lreach)
	var shooting_now: bool = ps.get("shooting", false)
	if shield_node and a.state not in [Agent.DOWN, Agent.DEAD]:
		_place_shield(a.shield_up())
	if grip2 != 0.0 and (shield_node == null or not shield_on_arm) and not shooting_now and a.state not in [Agent.DOWN, Agent.DEAD] \
			and hand_r.distance_to(sh_l) < UPPER_ARM + FOREARM + 0.25:
		hand_l = hand_r + wdir * grip2            # both hands on the haft
	_chain(arm_l, sh_l, hand_l, UPPER_ARM, FOREARM, Vector3(-0.6, -0.7, 0.4))
	_look(weapon, hand_r, hand_r + wdir)
	var holding_ranged: bool = shooting_now or (a.using_ranged and a.state not in [Agent.DOWN, Agent.DEAD])
	weapon.visible = not holding_ranged
	if ranged_node:
		ranged_node.visible = holding_ranged
		if holding_ranged and a.is_thrower():
			_look(ranged_node, hand_r, hand_r + wdir)      # javelin / throwing axe: in the right hand
		elif holding_ranged:
			_look(ranged_node, hand_l, hand_l + larm)
	_legs(a, ps, walk_phase, speed, bob)
	if horse:
		_horse_gait(walk_phase, speed)


## The shield splintered (Agent.damage_shield): gone from the arm and the back.
func drop_shield() -> void:
	if shield_node:
		shield_node.queue_free()
		shield_node = null


## Shield on the left forearm, or slung across the back (still catches arrows from behind).
func _place_shield(on_arm: bool) -> void:
	if on_arm == shield_on_arm:
		return
	shield_on_arm = on_arm
	shield_node.get_parent().remove_child(shield_node)
	if on_arm:
		arm_l[1].add_child(shield_node)
		shield_node.transform = Transform3D(Basis(), Vector3(0, 0, -FOREARM * 0.6))
	else:
		spine.add_child(shield_node)
		# a big shield is drawn smaller on the back so it doesn't hide the man (the hit test doesn't use the mesh)
		var r: float = float(shield_node.get_meta("r", 0.55))
		shield_node.transform = Transform3D(Basis(Vector3.FORWARD, 0.25).scaled(Vector3.ONE * minf(1.0, 0.4 / r)), Vector3(0, 0.3, 0.2))


func _legs(a, ps: Dictionary, walk_phase: float, speed: float, bob: float) -> void:
	var hip_y: float = a.PELVIS_Y - float(ps.crouch) + bob - 0.035
	var hip_z: float = -float(ps.step)
	if _mounted:
		# astride the horse: thighs out and forward, feet in the stirrups
		for k in 2:
			var s := -1.0 if k == 0 else 1.0
			var hip := Vector3(0.11 * s, hip_y, hip_z)
			_chain(legs[k], hip, Vector3(0.34 * s, hip_y - 0.62, -0.12), THIGH, SHIN, Vector3(0.3 * s, 0, -1))
		return
	# direction of travel in the soldier's own frame: legs step that way (sideways, backwards too)
	var lv: Vector3 = (get_parent() as Node3D).global_transform.basis.inverse() * (get_parent().velocity as Vector3)
	lv.y = 0
	var move := lv.normalized() if lv.length() > 0.15 else Vector3.ZERO
	var amp := clampf(speed * 0.12, 0.0, 0.42)
	var lift_amp := clampf(speed * 0.05, 0.0, 0.17)
	# fighting stance when standing still with something to do: left foot forward, right back
	var stance := 0.0 if speed > 0.4 else (1.0 if a.state != Agent.IDLE or float(ps.crouch) > 0.02 else 0.35)
	for k in 2:
		var s := -1.0 if k == 0 else 1.0
		var ph := walk_phase + PI * k
		var hip := Vector3(0.1 * s, hip_y, hip_z * 0.6)
		var base := Vector3(0.13 * s, 0.0, (-0.17 if k == 0 else 0.16) * stance)
		var foot := base + move * amp * sin(ph)
		foot.y = lift_amp * maxf(0.0, cos(ph))
		if a.jumping:
			foot += Vector3(0, 0.18, -0.13 if k == 0 else 0.12)
		elif k == 0 and a.state == Agent.KICK:
			var kick: float = clampf(a.state_t / maxf(a.state_len, 0.01), 0.0, 1.0)
			foot = Vector3(-0.12, 0.22 + 0.36 * kick, -0.12 - 0.58 * kick)
		_chain(legs[k], hip, foot, THIGH, SHIN, Vector3(0.15 * s, 0, -1))
		# keep the foot flat, toes forward, whatever the shin is doing
		var foot_mesh: Node3D = legs[k][2]
		if foot_mesh.is_inside_tree():
			foot_mesh.global_basis = global_basis
			foot_mesh.position = Vector3(0, 0, -SHIN)


func _horse_gait(walk_phase: float, speed: float) -> void:
	var hamp := clampf(speed / (_gallop_ref * 0.57), 0.0, 1.0)
	# trot: diagonal pairs together; gallop: a rolling four-beat with the fore pair leading
	var gallop := speed > _gallop_ref * 0.57
	var offs: Array = [0.0, 0.35, PI, PI + 0.35] if gallop else [0.0, PI, PI, 0.0]
	var ph := walk_phase * (0.7 if gallop else 1.0)
	var swing := 0.55 * hamp if gallop else 0.4 * hamp
	for k in horse_legs.size():
		var l: Array = horse_legs[k]
		var t: float = ph + offs[k]
		(l[1] as Node3D).rotation.x = sin(t) * swing
		var fold := maxf(0.0, sin(t + 1.3)) * (1.1 if gallop else 0.8) * hamp
		(l[2] as Node3D).rotation.x = -fold if k < 2 else fold       # knees fold back, hocks forward
	var rock := sin(ph * (1.0 if gallop else 2.0))
	horse.position.y = (0.08 if gallop else 0.04) * absf(rock) * hamp
	horse.rotation.x = (0.05 * rock if gallop else 0.0) * hamp
	horse_neck.rotation.x = (0.12 * sin(ph + 0.6) if gallop else 0.04 * sin(ph * 2.0)) * hamp
	rider.position.y = 0.68 + horse.position.y * 0.8


## Toppling over: `amount` 0..1 (upright .. flat), in direction `dir` (own frame). Pivots at the feet.
func show_fall(amount: float, dir: Vector3) -> void:
	if amount <= 0.001:
		if basis != Basis.IDENTITY:
			basis = Basis.IDENTITY
			position = Vector3.ZERO
		return
	var d := dir
	if horse:
		d = Vector3(signf(dir.x) if absf(dir.x) > 0.05 else 1.0, 0, 0)    # a horse goes down on its side
	d.y = 0
	d = d.normalized() if d.length() > 0.01 else Vector3(0, 0, 1)
	var axis := Vector3.UP.cross(d).normalized()
	basis = Basis(axis, deg_to_rad(84.0) * amount)
	position = Vector3(0, 0.1 * amount, 0)


func flash(c: Color) -> void:
	if _flash_mat == null:
		_flash_mat = StandardMaterial3D.new()
		_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_flash_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_flash_mat.albedo_color = Color(c.r, c.g, c.b, 0.55)
	for mi in _flash_on:
		if is_instance_valid(mi):
			mi.material_overlay = _flash_mat
	get_tree().create_timer(0.12).timeout.connect(func():
		if is_instance_valid(self):
			for mi in _flash_on:
				if is_instance_valid(mi):
					mi.material_overlay = null)
