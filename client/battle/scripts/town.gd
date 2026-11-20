class_name TownLayout
extends RefCounted
## Walkable town / castle / village scenes (Warband's "take a walk around the streets"): a layout of
## solid blocks (houses, walls, stalls) generated from the place's seed, the named spots where people
## stand (the lord's hall, the market, the arena, the inn, the square, the prison, the gate) and the
## street points townsfolk stroll between. Blocks are folded into BattleField.height_at() as tall boxes,
## so the usual step-up rule keeps everyone out of the walls — no physics needed.
##
## Town (radius ~70): a square wall with a south gate, a grid of streets (16 m blocks), a plaza in the
## middle, the hall at the north end of the main street, an arena in the east. Castle: a smaller wall, a
## keep and a yard. Village: a dozen houses scattered round a well, fields beyond, no wall.

const CELL := 16.0              # town block pitch (a 4 m street between blocks)
const GRID := 8.0               # lookup grid for the height query

var kind := "town"
var radius := 72.0
var blocks: Array = []          # [x0, z0, x1, z1, h, look]
var anchors := {}               # where -> Vector3 (on the street, in front of the building)
var spawn := Vector3.ZERO
var spawn_yaw := 0.0
var gate := Vector3.ZERO
var paths: Array = []           # street points for strollers
var _grid := {}
var props: Array = []           # [kind, pos, ...] decorations (no collision)
# interiors (the lord's hall, the tavern): a walled room with a ceiling, entered from the street
var room := false
var rect := Rect2()             # the room's floor (x, z)
var ceiling := 0.0
var slots := {}                 # where -> [Vector3]: fixed places for people (the lord on the dais…)
var lights: Array = []          # Vector3: braziers / lamps
var exit := Vector3.ZERO        # the door (inside)
var enter := {}                 # street: room -> door point outside


func generate(k: String, seed_value: int, walls: int) -> void:
	kind = k
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	match kind:
		"castle":
			_castle(rng, walls)
		"village":
			_village(rng)
		"hall_room":
			_hall_room(rng)
		"inn_room":
			_inn_room(rng)
		_:
			_town(rng, walls)
	for i in blocks.size():
		var b: Array = blocks[i]
		for gx in range(floori(b[0] / GRID), floori(b[2] / GRID) + 1):
			for gz in range(floori(b[1] / GRID), floori(b[3] / GRID) + 1):
				var key := Vector2i(gx, gz)
				if not _grid.has(key):
					_grid[key] = []
				_grid[key].append(i)


func height(x: float, z: float) -> float:
	var lst = _grid.get(Vector2i(floori(x / GRID), floori(z / GRID)))
	if lst == null:
		return 0.0
	var h := 0.0
	for i in lst:
		var b: Array = blocks[i]
		if x >= b[0] and x <= b[2] and z >= b[1] and z <= b[3]:
			h = maxf(h, b[4])
	return h


func _box(x0: float, z0: float, x1: float, z1: float, h: float, look: String) -> void:
	blocks.append([minf(x0, x1), minf(z0, z1), maxf(x0, x1), maxf(z0, z1), h, look])


## A square wall of half-size `half` with a gate gap in the south side (+z), towers at the corners.
func _wall(half: float, h: float, thick: float, gate_w: float) -> void:
	_box(-half, -half - thick, half, -half, h, "wall")                       # north
	_box(-half - thick, -half - thick, -half, half + thick, h, "wall")       # west
	_box(half, -half - thick, half + thick, half + thick, h, "wall")         # east
	_box(-half - thick, half, -gate_w * 0.5, half + thick, h, "wall")        # south, left of the gate
	_box(gate_w * 0.5, half, half + thick, half + thick, h, "wall")
	for c in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		var p: Vector2 = c * (half + thick * 0.5)
		_box(p.x - 3.5, p.y - 3.5, p.x + 3.5, p.y + 3.5, h + 3.0, "tower")
	for sx in [-1.0, 1.0]:                                                    # gate towers
		var gx: float = sx * (gate_w * 0.5 + 3.0)
		_box(gx - 3.0, half - 1.0, gx + 3.0, half + thick + 2.0, h + 2.5, "tower")
	gate = Vector3(0, 0, half - 3.0)


func _town(rng: RandomNumberGenerator, walls: int) -> void:
	var half := 4.0 * CELL + 2.0                                              # 8 × 8 blocks inside
	radius = half + 6.0
	_wall(half, clampf(6.0 + 0.6 * walls, 6.0, 9.0), 3.0, 8.0)
	spawn = Vector3(0, 0, half - 10.0)
	# reserved: the plaza (4 central blocks), the hall (2 blocks north end), the arena (2×2 east)
	var reserved := {}
	for cx in [-1, 0]:
		for cz in [-1, 0]:
			reserved[Vector2i(cx, cz)] = "plaza"
	for cx in [-1, 0]:
		reserved[Vector2i(cx, -4)] = "hall"
	for cx in [2, 3]:
		for cz in [-3, -2]:
			reserved[Vector2i(cx, cz)] = "arena"
	reserved[Vector2i(-2, 0)] = "inn"
	reserved[Vector2i(1, 2)] = "prison"
	for cx in range(-4, 4):
		for cz in range(-4, 4):
			var key := Vector2i(cx, cz)
			var x0 := cx * CELL + 2.0
			var z0 := cz * CELL + 2.0
			var what: String = reserved.get(key, "")
			if what == "":
				if cz == 3 and cx in [-1, 0]:
					continue                                              # keep the gate square open
				# one to three houses per block, leaving lanes
				var n := rng.randi_range(1, 3)
				if n == 1:
					_box(x0 + rng.randf_range(0.5, 2.0), z0 + rng.randf_range(0.5, 2.0),
						x0 + CELL - 4.0 - rng.randf_range(0.5, 2.0), z0 + CELL - 4.0 - rng.randf_range(0.5, 2.0),
						rng.randf_range(3.6, 5.5), "house")
				else:
					var split := rng.randf_range(4.5, 7.5)
					_box(x0 + 0.5, z0 + 0.5, x0 + split - 0.6, z0 + CELL - 4.5, rng.randf_range(3.4, 5.0), "house")
					if n == 3:
						_box(x0 + split + 0.6, z0 + 0.5, x0 + CELL - 4.5, z0 + 5.6, rng.randf_range(3.4, 5.0), "house")
						_box(x0 + split + 0.6, z0 + 7.0, x0 + CELL - 4.5, z0 + CELL - 4.5, rng.randf_range(3.4, 5.0), "house")
					else:
						_box(x0 + split + 0.6, z0 + 0.5, x0 + CELL - 4.5, z0 + CELL - 4.5, rng.randf_range(3.4, 5.0), "house")
	# the hall: one big building across the two reserved blocks, its door on the main street
	_box(-14.0, -4 * CELL + 1.0, 14.0, -4 * CELL + 12.0, 7.5, "hall")
	anchors["hall"] = Vector3(0, 0, -4 * CELL + 15.0)
	props.append(["steps", Vector3(0, 0, -4 * CELL + 12.8), 8.0])
	# the inn and the prison
	_box(-2 * CELL + 1.0, 1.0, -CELL - 3.0, CELL - 3.0, 5.2, "inn")
	anchors["inn"] = Vector3(-CELL + 0.3, 0, 7.0)
	_box(CELL + 3.0, 2 * CELL + 1.0, 2 * CELL - 3.0, 3 * CELL - 3.0, 4.5, "prison")
	anchors["prison"] = Vector3(CELL + 0.3, 0, 2 * CELL + 7.0)
	# the arena: a ring of posts (only for show) in the open ground in the east
	var ac := Vector3(3 * CELL, 0, -2 * CELL)
	props.append(["arena", ac, 11.0])
	anchors["arena"] = ac + Vector3(-12.5, 0, 6.0)
	# the plaza: market stalls on the west side, the recruiting square on the east, a well in the middle
	for i in 4:
		var sz := -10.0 + i * 6.5
		_box(-13.5, sz - 1.4, -11.0, sz + 1.4, 1.05, "stall")
	anchors["market"] = Vector3(-8.5, 0, 0.5)
	anchors["square"] = Vector3(8.0, 0, 0.5)
	_box(-1.2, -1.2, 1.2, 1.2, 0.9, "well")
	anchors["gate"] = gate
	# strolling: the street crossings
	for cx in range(-4, 5):
		for cz in range(-4, 5):
			var p := Vector3(cx * CELL, 0, cz * CELL)
			if absf(p.x) < half - 2.0 and absf(p.z) < half - 2.0:
				paths.append(p)


func _castle(rng: RandomNumberGenerator, walls: int) -> void:
	var half := 30.0
	radius = half + 6.0
	_wall(half, clampf(7.0 + 0.5 * walls, 7.0, 9.5), 3.0, 7.0)
	spawn = Vector3(0, 0, half - 9.0)
	_box(-12.0, -half + 1.0, 12.0, -half + 14.0, 10.0, "hall")                # the keep
	anchors["hall"] = Vector3(0, 0, -half + 17.0)
	_box(-half + 1.0, -8.0, -half + 11.0, 6.0, 4.5, "house")                 # barracks
	_box(half - 11.0, -8.0, half - 1.0, 2.0, 4.5, "prison")
	anchors["prison"] = Vector3(half - 13.5, 0, -3.0)
	_box(half - 11.0, 8.0, half - 1.0, 18.0, 4.0, "inn")
	anchors["inn"] = Vector3(half - 13.5, 0, 13.0)
	_box(-half + 1.0, 12.0, -half + 9.0, 20.0, 3.5, "house")
	anchors["market"] = Vector3(-8.0, 0, 6.0)
	anchors["square"] = Vector3(8.0, 0, 4.0)
	anchors["arena"] = Vector3(0, 0, 0)
	anchors["gate"] = gate
	for p in [Vector3(-10, 0, 10), Vector3(10, 0, 10), Vector3(0, 0, 0), Vector3(-12, 0, -8), Vector3(12, 0, -10), Vector3(0, 0, 20)]:
		paths.append(p)
	rng.randi()


func _village(rng: RandomNumberGenerator) -> void:
	radius = 55.0
	spawn = Vector3(0, 0, 46.0)
	gate = Vector3(0, 0, 54.0)
	anchors["gate"] = gate
	_box(-1.2, -1.2, 1.2, 1.2, 0.9, "well")
	anchors["square"] = Vector3(0, 0, 5.0)
	anchors["market"] = Vector3(-6.0, 0, 4.0)
	anchors["hall"] = Vector3(6.0, 0, 4.0)
	anchors["arena"] = Vector3(0, 0, 9.0)
	anchors["prison"] = Vector3(-4.0, 0, 9.0)
	var placed: Array = []
	var tries := 0
	while placed.size() < 16 and tries < 400:
		tries += 1
		var ang := rng.randf() * TAU
		var r := rng.randf_range(14.0, 46.0)
		var c := Vector2(cos(ang), sin(ang)) * r
		if c.y > 8.0 and absf(c.x) < 7.0:
			continue                                   # keep the road in from the south clear
		var ok := true
		for q in placed:
			if c.distance_to(q) < 13.0:
				ok = false
				break
		if not ok:
			continue
		placed.append(c)
		var w := rng.randf_range(5.0, 8.0)
		var d := rng.randf_range(4.0, 6.0)
		_box(c.x - w * 0.5, c.y - d * 0.5, c.x + w * 0.5, c.y + d * 0.5, rng.randf_range(3.0, 4.0), "cottage")
		paths.append(Vector3(c.x, 0, c.y) + Vector3(0, 0, d * 0.5 + 2.0))
	# the elder's house by the well, with the inn's job (resting) done there too
	_box(-16.0, -14.0, -6.0, -6.0, 4.2, "cottage")
	anchors["inn"] = Vector3(-11.0, 0, -3.5)
	for i in 6:
		var ang2 := float(i) / 6.0 * TAU + 0.3
		props.append(["field", Vector3(cos(ang2), 0, sin(ang2)) * 66.0, 15.0])
	paths.append(Vector3(0, 0, 8))
	paths.append(Vector3(0, 0, 40))


## Four walls round `r` (thickness 1) with a door gap in the south wall, and a ceiling (visual only).
func _room(r: Rect2, h: float, door_w: float) -> void:
	room = true
	rect = r
	ceiling = h
	var x0 := r.position.x
	var z0 := r.position.y
	var x1 := r.end.x
	var z1 := r.end.y
	_box(x0 - 1.0, z0 - 1.0, x1 + 1.0, z0, h, "iwall")
	_box(x0 - 1.0, z0, x0, z1 + 1.0, h, "iwall")
	_box(x1, z0, x1 + 1.0, z1 + 1.0, h, "iwall")
	_box(x0, z1, -door_w * 0.5, z1 + 1.0, h, "iwall")
	_box(door_w * 0.5, z1, x1, z1 + 1.0, h, "iwall")
	exit = Vector3(0, 0, z1 - 0.6)
	spawn = Vector3(0, 0, z1 - 2.2)
	gate = exit
	radius = maxf(r.size.x, r.size.y) * 0.5 + 4.0


## The lord's hall: a long room, pillars down both sides, a raised dais with the high seat at the far end.
func _hall_room(rng: RandomNumberGenerator) -> void:
	_room(Rect2(-10, -16, 20, 28), 6.5, 3.2)
	_box(-6.0, -16.0, 6.0, -11.0, 0.4, "dais")
	_box(-1.1, -16.0, 1.1, -15.0, 1.5, "seat")
	for z in [-7.0, -1.0, 5.0]:
		for x in [-6.5, 6.5]:
			_box(x - 0.45, z - 0.45, x + 0.45, z + 0.45, 6.5, "pillar")
	_box(-9.6, -8.0, -8.4, 4.0, 0.75, "table")
	_box(8.4, -8.0, 9.6, 4.0, 0.75, "table")
	slots["hall"] = [Vector3(0, 0, -12.6), Vector3(-3.6, 0, -9.6), Vector3(3.6, 0, -9.6), Vector3(-4.6, 0, -4.0),
		Vector3(4.6, 0, -4.0), Vector3(-4.6, 0, 2.0), Vector3(4.6, 0, 2.0)]
	slots["guard"] = [Vector3(-4.2, 0, 10.6), Vector3(4.2, 0, 10.6), Vector3(-7.5, 0, -13.5), Vector3(7.5, 0, -13.5)]
	for z in [-7.0, -1.0, 5.0]:
		lights.append(Vector3(-5.2, 2.6, z))
		lights.append(Vector3(5.2, 2.6, z))
	lights.append(Vector3(0, 3.2, -12.0))
	props.append(["banner", Vector3(0, 0, -15.9), 3.0])
	rng.randi()


## The tavern: a counter along the back, tables with benches, the innkeeper behind the counter.
func _inn_room(rng: RandomNumberGenerator) -> void:
	_room(Rect2(-9, -10, 18, 18), 4.6, 2.8)
	_box(-8.0, -7.3, -1.0, -6.3, 1.1, "counter")
	_box(-8.8, -10.0, -1.0, -9.4, 2.4, "shelf")
	var tables := [Vector2(4.0, -5.0), Vector2(5.5, 1.5), Vector2(-5.0, 1.0), Vector2(-0.5, -2.0)]
	var pat: Array = []
	for t in tables:
		_box(t.x - 0.9, t.y - 0.55, t.x + 0.9, t.y + 0.55, 0.8, "table")
		_box(t.x - 0.9, t.y - 1.25, t.x + 0.9, t.y - 0.95, 0.5, "bench")
		_box(t.x - 0.9, t.y + 0.95, t.x + 0.9, t.y + 1.25, 0.5, "bench")
		pat.append(Vector3(t.x + 1.5, 0, t.y))
		pat.append(Vector3(t.x - 1.5, 0, t.y + 0.2))
	slots["inn"] = [Vector3(-4.5, 0, -8.6), Vector3(7.6, 0, -8.2), Vector3(-7.6, 0, 5.5)]
	slots["patron"] = pat
	lights.append(Vector3(-4.5, 3.4, -6.0))
	lights.append(Vector3(4.0, 3.4, -2.0))
	lights.append(Vector3(-3.0, 3.4, 4.0))
	rng.randi()


## Free street spots around an anchor for several people (in a small fan facing the street).
func spot(where: String, i: int) -> Vector3:
	if slots.has(where):
		var lst: Array = slots[where]
		if i < lst.size():
			return lst[i]
		var b: Vector3 = lst[-1]
		return b + Vector3(1.4 * (i - lst.size() + 1), 0, 0.8)
	var a: Vector3 = anchors.get(where, anchors.get("square", Vector3.ZERO))
	if i == 0:
		return a
	var ring := 1 + (i - 1) / 6
	var ang := float((i - 1) % 6) / 6.0 * TAU
	return a + Vector3(cos(ang), 0, sin(ang)) * 1.6 * ring


# ------------------------------------------------------------------ visuals
const LOOK := {
	# look: [wall colour, roof colour or null]
	"house": [Color("8f846f"), Color("3f444c")],
	"cottage": [Color("8e8064"), Color("7a6a48")],
	"inn": [Color("9a8264"), Color("5a3a2a")],
	"prison": [Color("8a8478"), Color("3c3a38")],
	"hall": [Color("9c8f76"), Color("2f3540")],
	"wall": [Color("8c8473"), null],
	"tower": [Color("7d7666"), Color("3a3f48")],
	"stall": [Color("7a5a36"), null],
	"well": [Color("7d786c"), null],
	"iwall": [Color("8a7a62"), null],
	"pillar": [Color("6a2f24"), null],
	"dais": [Color("5a4634"), null],
	"seat": [Color("4a2a1c"), null],
	"table": [Color("5c4128"), null],
	"bench": [Color("4f3820"), null],
	"counter": [Color("5a3d22"), null],
	"shelf": [Color("4a3220"), null],
}


func build_visuals(parent: Node3D, ground: Callable, culture_roof: Color) -> void:
	var mats := {}
	for k in LOOK:
		var m := StandardMaterial3D.new()
		m.albedo_color = LOOK[k][0]
		m.roughness = 0.95
		mats[k] = m
	var roof_mats := {}
	for b in blocks:
		var look: String = b[5]
		var w: float = b[2] - b[0]
		var d: float = b[3] - b[1]
		var h: float = b[4]
		var c := Vector3((b[0] + b[2]) * 0.5, 0, (b[1] + b[3]) * 0.5)
		var g: float = ground.call(c.x, c.z)
		var body := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(w, h + 0.6, d)
		body.mesh = bm
		body.material_override = mats.get(look, mats.house)
		body.position = Vector3(c.x, g + (h + 0.6) * 0.5 - 0.6, c.z)
		parent.add_child(body)
		var roof_col = LOOK.get(look, LOOK.house)[1]
		if roof_col != null:
			var rc: Color = culture_roof if look in ["house", "hall", "inn"] else roof_col
			var key := rc.to_html()
			if not roof_mats.has(key):
				var rm := StandardMaterial3D.new()
				rm.albedo_color = rc
				rm.roughness = 0.8
				roof_mats[key] = rm
			var roof := MeshInstance3D.new()
			var pm := PrismMesh.new()
			var along_x := w >= d
			var rh := minf(w, d) * (0.32 if look != "tower" else 0.6)
			pm.size = Vector3((d if along_x else w) + 0.9, rh, (w if along_x else d) + 0.9)
			roof.mesh = pm
			roof.material_override = roof_mats[key]
			roof.position = Vector3(c.x, g + h + rh * 0.5, c.z)
			if along_x:
				roof.rotation.y = PI * 0.5
			parent.add_child(roof)
		if look in ["house", "cottage", "inn", "hall", "prison"]:
			_door(parent, b, g)
		if look == "wall":
			_merlons(parent, b, g, mats.wall)
	if room:
		_interior(parent)
	else:
		_props(parent, ground)


func _door(parent: Node3D, b: Array, g: float) -> void:
	var big: bool = b[5] in ["hall", "inn"]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color("2a2017")
	var cx: float = (b[0] + b[2]) * 0.5
	var cz: float = (b[1] + b[3]) * 0.5
	# a building someone stands in front of (the hall, the inn, the prison) has its door facing that spot
	var faces: Array = []                   # [position, along_x]
	for k in ["hall", "inn", "prison"]:
		if not anchors.has(k):
			continue
		var a: Vector3 = anchors[k]
		var dx := maxf(maxf(b[0] - a.x, a.x - b[2]), 0.0)
		var dz := maxf(maxf(b[1] - a.z, a.z - b[3]), 0.0)
		if Vector2(dx, dz).length() < 5.0:
			if dx > dz:
				faces.append([Vector3(b[2] + 0.05 if a.x > b[2] else b[0] - 0.05, 0, clampf(a.z, b[1] + 1.5, b[3] - 1.5)), false])
			else:
				faces.append([Vector3(clampf(a.x, b[0] + 1.5, b[2] - 1.5), 0, b[3] + 0.05 if a.z > b[3] else b[1] - 0.05), true])
	if faces.is_empty():
		faces = [[Vector3(cx, 0, b[3] + 0.05), true], [Vector3(cx, 0, b[1] - 0.05), true]]
	for f in faces:
		var door := MeshInstance3D.new()
		var dm := BoxMesh.new()
		var w := 2.4 if big else 1.3
		var h := 2.6 if big else 2.1
		dm.size = Vector3(w, h, 0.12) if f[1] else Vector3(0.12, h, w)
		door.mesh = dm
		door.material_override = m
		door.position = f[0] + Vector3(0, g + h * 0.5, 0)
		parent.add_child(door)


func _merlons(parent: Node3D, b: Array, g: float, mat: Material) -> void:
	var w: float = b[2] - b[0]
	var d: float = b[3] - b[1]
	var along_x := w > d
	var n := int((w if along_x else d) / 2.0)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var bm := BoxMesh.new()
	bm.size = Vector3(1.2, 1.1, 0.8) if along_x else Vector3(0.8, 1.1, 1.2)
	mm.mesh = bm
	mm.instance_count = n
	for i in n:
		var t := (i + 0.5) / n
		var p := Vector3(lerpf(b[0], b[2], t) if along_x else (b[0] + b[2]) * 0.5, g + b[4] + 0.55,
			(b[1] + b[3]) * 0.5 if along_x else lerpf(b[1], b[3], t))
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, p))
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = mat
	parent.add_child(mi)


func _props(parent: Node3D, ground: Callable) -> void:
	# beaten earth inside the walls (a village: round the well and along the road in)
	var dirt := StandardMaterial3D.new()
	dirt.albedo_color = Color("6a5c46")
	dirt.roughness = 1.0
	var pads: Array = [[Vector3.ZERO, radius * 2.0 - 8.0, radius * 2.0 - 8.0]] if kind != "village" \
		else [[Vector3.ZERO, 22.0, 22.0], [Vector3(0, 0, 32), 6.0, 44.0]]
	for pd in pads:
		var pl := MeshInstance3D.new()
		var plm := PlaneMesh.new()
		plm.size = Vector2(pd[1], pd[2])
		pl.mesh = plm
		pl.material_override = dirt
		var pc: Vector3 = pd[0]
		pl.position = Vector3(pc.x, ground.call(pc.x, pc.z) + 0.03, pc.z)
		parent.add_child(pl)
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color("6b4a2a")
	var cloth := StandardMaterial3D.new()
	cloth.albedo_color = Color("b0503a")
	cloth.cull_mode = BaseMaterial3D.CULL_DISABLED
	# awnings over the market stalls
	for b in blocks:
		if b[5] == "stall":
			var aw := MeshInstance3D.new()
			var am := BoxMesh.new()
			am.size = Vector3(3.4, 0.08, 3.2)
			aw.mesh = am
			aw.material_override = cloth
			var c := Vector3((b[0] + b[2]) * 0.5 + 0.6, 0, (b[1] + b[3]) * 0.5)
			aw.position = Vector3(c.x, ground.call(c.x, c.z) + 2.3, c.z)
			aw.rotation.z = -0.25
			parent.add_child(aw)
	for pr in props:
		var kind_p: String = pr[0]
		var pos: Vector3 = pr[1]
		match kind_p:
			"arena":
				var r: float = pr[2]
				for i in 36:
					var ang := TAU * i / 36.0
					var p := pos + Vector3(cos(ang), 0, sin(ang)) * r
					var post := MeshInstance3D.new()
					var bm := BoxMesh.new()
					bm.size = Vector3(0.16, 1.4, 0.16)
					post.mesh = bm
					post.material_override = wood
					post.position = Vector3(p.x, ground.call(p.x, p.z) + 0.7, p.z)
					parent.add_child(post)
				var sand := MeshInstance3D.new()
				var cm := CylinderMesh.new()
				cm.top_radius = r
				cm.bottom_radius = r
				cm.height = 0.06
				sand.mesh = cm
				var sm := StandardMaterial3D.new()
				sm.albedo_color = Color("b9a57c")
				sand.material_override = sm
				sand.position = Vector3(pos.x, ground.call(pos.x, pos.z) + 0.03, pos.z)
				parent.add_child(sand)
			"steps":
				var st := MeshInstance3D.new()
				var bm2 := BoxMesh.new()
				bm2.size = Vector3(pr[2], 0.3, 1.6)
				st.mesh = bm2
				var stone := StandardMaterial3D.new()
				stone.albedo_color = Color("8c8473")
				st.material_override = stone
				st.position = Vector3(pos.x, ground.call(pos.x, pos.z) + 0.15, pos.z)
				parent.add_child(st)
			"field":
				var f := MeshInstance3D.new()
				var pm := PlaneMesh.new()
				pm.size = Vector2(pr[2] * 1.6, pr[2])
				f.mesh = pm
				var fm := StandardMaterial3D.new()
				fm.albedo_color = Color("8a8a3a") if int(pos.x) % 2 == 0 else Color("6a7a32")
				f.material_override = fm
				f.position = Vector3(pos.x, ground.call(pos.x, pos.z) + 0.05, pos.z)
				f.rotation.y = atan2(pos.x, pos.z)
				parent.add_child(f)


func _interior(parent: Node3D) -> void:
	var floor_m := StandardMaterial3D.new()
	floor_m.albedo_color = Color("4a3a2a") if ceiling < 5.0 else Color("6a6458")
	var fl := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = rect.size + Vector2(2, 2)
	fl.mesh = pm
	fl.material_override = floor_m
	fl.position = Vector3(rect.get_center().x, 0.02, rect.get_center().y)
	parent.add_child(fl)
	var ceil_m := StandardMaterial3D.new()
	ceil_m.albedo_color = Color("3a2a1e")
	ceil_m.cull_mode = BaseMaterial3D.CULL_DISABLED
	var ce := MeshInstance3D.new()
	var cm := PlaneMesh.new()
	cm.size = rect.size + Vector2(2.2, 2.2)
	ce.mesh = cm
	ce.material_override = ceil_m
	ce.position = Vector3(rect.get_center().x, ceiling, rect.get_center().y)
	ce.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(ce)
	# beams under the ceiling
	var beam_m := StandardMaterial3D.new()
	beam_m.albedo_color = Color("2e2016")
	var z := rect.position.y + 2.0
	while z < rect.end.y:
		var bmi := MeshInstance3D.new()
		var bb := BoxMesh.new()
		bb.size = Vector3(rect.size.x + 2.0, 0.35, 0.35)
		bmi.mesh = bb
		bmi.material_override = beam_m
		bmi.position = Vector3(rect.get_center().x, ceiling - 0.2, z)
		parent.add_child(bmi)
		z += 4.0
	# lamps: a warm glow on a small bright box
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color("ffcf7a")
	glow.emission_enabled = true
	glow.emission = Color("ffb04a")
	glow.emission_energy_multiplier = 2.0
	for lp in lights:
		var l := OmniLight3D.new()
		l.position = lp
		l.light_color = Color("ffc985")
		l.light_energy = 1.6
		l.omni_range = 11.0
		l.shadow_enabled = false
		parent.add_child(l)
		var lm := MeshInstance3D.new()
		var lb := BoxMesh.new()
		lb.size = Vector3(0.28, 0.36, 0.28)
		lm.mesh = lb
		lm.material_override = glow
		lm.position = lp
		parent.add_child(lm)
	for pr in props:
		if pr[0] == "banner":
			var bn := MeshInstance3D.new()
			var bq := BoxMesh.new()
			bq.size = Vector3(2.2, pr[2], 0.06)
			bn.mesh = bq
			var bm := StandardMaterial3D.new()
			bm.albedo_color = Color("7a2a20")
			bn.material_override = bm
			bn.position = Vector3(pr[1].x, 2.6 + pr[2] * 0.5 - 0.5, pr[1].z)
			parent.add_child(bn)
	# the doorway: daylight (or night) beyond
	var door_m := StandardMaterial3D.new()
	door_m.albedo_color = Color("d8c9a8")
	door_m.emission_enabled = true
	door_m.emission = Color("c8b89a")
	door_m.emission_energy_multiplier = 0.6
	var dq := MeshInstance3D.new()
	var dbm := BoxMesh.new()
	dbm.size = Vector3(3.0, 2.8, 0.05)
	dq.mesh = dbm
	dq.material_override = door_m
	dq.position = Vector3(0, 1.4, rect.end.y + 1.05)
	parent.add_child(dq)
