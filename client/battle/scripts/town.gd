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

const Art := preload("res://battle/scripts/art_mesh.gd")
const TIMBER := Color("584033")
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
# Surface textures (client/assets/textures, CC0 from ambientCG — see CREDITS.md): look -> [texture, metres
# per tile]. Mapped in world space (triplanar), so a brick is the same size on a hut and on the city wall;
# the LOOK colour tints it.
const TEX := {
	"house": ["plaster", 3.0], "inn": ["plaster", 3.0], "hall": ["plaster", 3.0], "prison": ["plaster", 3.0],
	"iwall": ["plaster", 3.0], "cottage": ["earth", 2.5],
	"wall": ["brick", 2.2], "tower": ["brick", 2.2], "well": ["brick", 1.6],
	"stall": ["planks", 1.6], "pillar": ["planks", 1.6], "dais": ["planks", 1.6], "seat": ["planks", 1.2],
}
static var _tex_cache := {}
static var _mat_cache := {}


## A textured material (cached): tex = folder in assets/textures, tint multiplies the colour map.
static func tex_mat(tex: String, tint: Color, tile: float, rough := 1.0, bump := 0.8) -> StandardMaterial3D:
	var key := "%s|%s|%.2f|%.2f|%.2f" % [tex, tint.to_html(), tile, rough, bump]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.roughness = rough
	var dir := "res://assets/textures/%s/" % tex
	var al = _tex(dir + "albedo.jpg")
	if al:
		m.albedo_texture = al
		var nm = _tex(dir + "normal.jpg")
		if nm:
			m.normal_enabled = true
			m.normal_texture = nm
			m.normal_scale = bump
		var rm = _tex(dir + "rough.jpg")
		if rm:
			m.roughness_texture = rm
			m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_triplanar_sharpness = 4.0
		m.uv1_scale = Vector3.ONE / tile
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_mat_cache[key] = m
	return m


static func _tex(path: String):
	if not _tex_cache.has(path):
		_tex_cache[path] = load(path) if ResourceLoader.exists(path) else null
	return _tex_cache[path]


## The roof tiles in a colour (the culture's roof colour; the texture itself is grey).
static func roof_mat(c: Color) -> StandardMaterial3D:
	return tex_mat("roof_tiles", c.lightened(0.12), 2.4, 0.85, 1.6)


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
}


func build_visuals(parent: Node3D, ground: Callable, culture_roof: Color) -> void:
	var mats := {}
	for k in LOOK:
		var col: Color = LOOK[k][0]
		if TEX.has(k):
			# the textures carry their own shade: lighten the flat colour so it tints rather than darkens
			var lift: float = {"plaster": 0.3, "brick": 0.12}.get(TEX[k][0], 0.25)
			mats[k] = tex_mat(TEX[k][0], col.lightened(lift), TEX[k][1], 1.0, 1.2 if TEX[k][0] == "brick" else 0.8)
		else:
			var m := StandardMaterial3D.new()
			m.albedo_color = col
			m.roughness = 0.95
			mats[k] = m
	var roof_mats := {}
	var facades := {}
	var furniture := Art.begin() if room else null
	for b in blocks:
		var look: String = b[5]
		var w: float = b[2] - b[0]
		var d: float = b[3] - b[1]
		var h: float = b[4]
		var c := Vector3((b[0] + b[2]) * 0.5, 0, (b[1] + b[3]) * 0.5)
		var g: float = ground.call(c.x, c.z)
		if room and look in ["table", "bench", "shelf", "counter"]:
			_furniture(furniture, Vector3(c.x, g, c.z), w, d, h, look)
			continue
		var body := MeshInstance3D.new()
		var bm := BoxMesh.new()
		var body_height := h - 0.23 if look == "well" else h
		bm.size = Vector3(w, body_height + 0.6, d)
		body.mesh = bm
		body.material_override = mats.get(look, mats.house)
		body.position = Vector3(c.x, g + (body_height + 0.6) * 0.5 - 0.6, c.z)
		parent.add_child(body)
		if look == "well":
			_well(parent, Vector3(c.x, g + body_height, c.z), w, d, mats.well)
		var roof_col = LOOK.get(look, LOOK.house)[1]
		if roof_col != null:
			var rc: Color = culture_roof if look in ["house", "hall", "inn"] else roof_col
			var key := rc.to_html()
			if not roof_mats.has(key):
				roof_mats[key] = roof_mat(rc)
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
			var cell := Vector2i(floori(c.x / 32.0), floori(c.z / 32.0))
			if not facades.has(cell):
				facades[cell] = Art.begin()
			_facade(facades[cell], Vector3(c.x, g, c.z), w, d, h, look, along_x, rc)
		if look in ["house", "cottage", "inn", "hall", "prison"]:
			_door(parent, b, g)
		if look == "wall":
			_merlons(parent, b, g, mats.wall)
	for st in facades.values():
		Art.add(parent, st.commit())
	if room:
		Art.add(parent, furniture.commit())
		_interior(parent, culture_roof)
	else:
		_props(parent, ground)


func _furniture(st: SurfaceTool, c: Vector3, w: float, d: float, h: float, look: String) -> void:
	var wood := Color("6a4a31")
	var dark := wood.darkened(0.24)
	var top := c + Vector3.UP * (h - 0.065)
	Art.box(st, Vector3(w, 0.13, d), top, wood.lightened(0.06))
	match look:
		"shelf":
			for x in [-w * 0.5 + 0.075, w * 0.5 - 0.075]:
				Art.box(st, Vector3(0.15, h, d), c + Vector3(x, h * 0.5, 0), dark)
			for i in 3:
				var y := 0.14 + i * 0.68
				Art.box(st, Vector3(w - 0.28, 0.095, d), c + Vector3.UP * y, wood)
				for j in 8:
					var x := ((j + 0.5) / 8.0 - 0.5) * (w - 0.26)
					var height := 0.19 + 0.065 * ((j + i * 2) % 4)
					var clay: Color = [Color("82654a"), Color("776654"), Color("95794e")][(j + i) % 3]
					Art.box(st, Vector3(0.22, height, 0.24), c + Vector3(x, y + 0.048 + height * 0.5, 0.05), clay)
		"counter":
			Art.box(st, Vector3(w - 0.15, h - 0.13, d - 0.12), c + Vector3.UP * ((h - 0.13) * 0.5), dark)
			for i in 5:
				var x := (i - 2) * w * 0.187
				Art.box(st, Vector3(w * 0.17, h - 0.36, 0.038), c + Vector3(x, (h - 0.04) * 0.5, d * 0.5 - 0.052), wood)
		_:
			var count := maxi(2, ceili(maxf(w, d) / 3.2))
			var span := maxf(w, d) - 0.34
			var wide := w >= d
			var sides := [0.0] if look == "bench" else [-1.0, 1.0]
			for i in count:
				var length := (float(i) / (count - 1) - 0.5) * span
				for side in sides:
					var cross: float = side * (minf(w, d) * 0.5 - 0.12)
					var p := Vector3(length, (h - 0.13) * 0.5, cross) if wide else Vector3(cross, (h - 0.13) * 0.5, length)
					Art.box(st, Vector3(0.13, h - 0.13, 0.13), c + p, dark)
			var apron := Vector3(w - 0.30, 0.10, maxf(0.10, d - 0.26))
			Art.box(st, apron, top - Vector3.UP * 0.101, dark)


func _facade(st: SurfaceTool, c: Vector3, w: float, d: float, h: float,
		look: String, along_x: bool, color: Color) -> void:
	var tower := look == "tower"
	var plinth := Color("797269") if tower else Color("756453")
	# The recessed base and the roof fascia give the same block three distinct levels.
	Art.box(st, Vector3(w + 0.08, 0.48, d + 0.08), c + Vector3.UP * 0.24, plinth)
	Art.box(st, Vector3(w + 0.82, 0.17, d + 0.82), c + Vector3.UP * (h - 0.06), TIMBER)
	var ridge_height := minf(w, d) * (0.6 if tower else 0.32)
	var ridge := Vector3(w + 0.97, 0.12, 0.18) if along_x else Vector3(0.18, 0.12, d + 0.97)
	Art.box(st, ridge, c + Vector3.UP * (h + ridge_height - 0.03), color.darkened(0.24))
	if not tower:
		for x in [-w * 0.5 + 0.13, w * 0.5 - 0.13]:
			for z in [-d * 0.5 + 0.13, d * 0.5 - 0.13]:
				Art.box(st, Vector3(0.32, h - 0.48, 0.32), c + Vector3(x, (h + 0.48) * 0.5, z), TIMBER)
	# Keep the windows high enough to clear the usable doors.
	for side in 4:
		var basis := Basis(Vector3.UP, side * PI * 0.5)
		var width := w if side % 2 == 0 else d
		var depth := d if side % 2 == 0 else w
		var count := clampi(floori(width / 3.6), 1, 6)
		var window_width := 0.32 if tower else (0.67 if look == "cottage" else 0.95)
		var window_y := h - (1.1 if tower else 0.67)
		for i in count:
			var x := ((i + 0.5) / count - 0.5) * width
			var p := c + basis * Vector3(x, window_y, depth * 0.5)
			Art.box(st, Vector3(window_width + 0.20, 0.80, 0.13), p, TIMBER, basis)
			Art.box(st, Vector3(window_width, 0.61, 0.085), p + basis * Vector3(0, 0, 0.032), Color("282925"), basis)
			if not tower:
				Art.box(st, Vector3(0.072, 0.62, 0.10), p + basis * Vector3(0, 0, 0.050), TIMBER, basis)
				Art.box(st, Vector3(window_width + 0.30, 0.10, 0.23), p + basis * Vector3(0, -0.35, 0.047), plinth, basis)


func _well(parent: Node3D, rim: Vector3, w: float, d: float, stone: Material) -> void:
	var side := BoxMesh.new()
	side.size = Vector3(0.28, 0.23, d)
	var end := BoxMesh.new()
	end.size = Vector3(w - 0.56, 0.23, 0.28)
	for sign in [-1.0, 1.0]:
		Art.add(parent, side, rim + Vector3(sign * (w - 0.28) * 0.5, 0.115, 0)).material_override = stone
		Art.add(parent, end, rim + Vector3(0, 0.115, sign * (d - 0.28) * 0.5)).material_override = stone
	var water := PlaneMesh.new()
	water.size = Vector2(w - 0.54, d - 0.54)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("384d45")
	material.roughness = 0.32
	var surface := Art.add(parent, water, rim + Vector3.UP * 0.018)
	surface.material_override = material
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _door(parent: Node3D, b: Array, g: float) -> void:
	var big: bool = b[5] in ["hall", "inn"]
	var m := tex_mat("planks", Color("5a4430"), 1.0)
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
	# The village path blends directly into the terrain material.
	if kind != "village":
		var pad := PlaneMesh.new()
		pad.size = Vector2.ONE * (radius * 2.0 - 8.0)
		var street := Art.add(parent, pad, Vector3.UP * (ground.call(0.0, 0.0) + 0.03))
		street.material_override = tex_mat("earth", Color("8e8a78"), 5.1, 1.0, 0.56)
		street.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color("6b4a2a")
	if kind in ["town", "castle"]:
		_paving(parent, ground)
	var canopies := Art.begin()
	var stall := 0
	for b in blocks:
		if b[5] != "stall":
			continue
		var c := Vector3((b[0] + b[2]) * 0.5, 0, (b[1] + b[3]) * 0.5)
		c.y = ground.call(c.x, c.z)
		var cloth: Color = [Color("a8573b"), Color("597779"), Color("a37e40"), Color("8b4d49")][stall % 4]
		_canopy(canopies, c, cloth)
		stall += 1
	if stall > 0:
		Art.add(parent, canopies.commit())
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
				_field_rows(parent, pos, pr[2], ground)


func _field_rows(parent: Node3D, p: Vector3, depth: float, ground: Callable) -> void:
	var basis := Basis(Vector3.UP, atan2(p.x, p.z))
	var st := Art.begin()
	var loam := Color("746548")
	var crop := Color("8b9049") if p.x > 0.0 else Color("7d8744")
	for i in 15:
		var x := (i - 7) * depth * 0.10
		for j in 8:
			var z0 := (float(j) / 8.0 - 0.5) * depth
			var z1 := z0 + depth / 8.0
			var half := depth * 0.05
			var a := _furrow_point(p, basis, Vector3(x - half, 0.026, z0), ground)
			var b := _furrow_point(p, basis, Vector3(x - half, 0.026, z1), ground)
			var c := _furrow_point(p, basis, Vector3(x, 0.19, z1), ground)
			var d := _furrow_point(p, basis, Vector3(x, 0.19, z0), ground)
			var e := _furrow_point(p, basis, Vector3(x + half, 0.026, z1), ground)
			var f := _furrow_point(p, basis, Vector3(x + half, 0.026, z0), ground)
			Art.quad(st, b, a, d, c, loam.lerp(crop, 0.38 + 0.16 * ((i + j) % 3)))
			Art.quad(st, c, d, f, e, crop.darkened(0.14 + 0.04 * ((i + j) % 3)))
	var rows := Art.add(parent, st.commit())
	rows.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _furrow_point(p: Vector3, basis: Basis, offset: Vector3, ground: Callable) -> Vector3:
	var pos := p + basis * offset
	pos.y += ground.call(pos.x, pos.z)
	return pos


func _paving(parent: Node3D, ground: Callable) -> void:
	var stone := tex_mat("brick", Color("999180"), 3.0, 1.0, 0.74)
	var parts := [Rect2(-2.3, -50.0, 4.6, 36.0), Rect2(-15.0, -14.0, 30.0, 28.0),
		Rect2(-2.3, 14.0, 4.6, 53.0)] if kind == "town" else [Rect2(-3.0, -16.0, 6.0, 48.0)]
	for r in parts:
		var plane := PlaneMesh.new()
		plane.size = r.size
		var c: Vector2 = r.get_center()
		var paving := Art.add(parent, plane, Vector3(c.x, ground.call(c.x, c.y) + 0.047, c.y))
		paving.material_override = stone
		paving.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _canopy(st: SurfaceTool, base: Vector3, cloth: Color) -> void:
	var tilt := Basis(Vector3.FORWARD, 0.25)
	var c := base + Vector3(0.43, 2.33, 0)
	for j in 7:
		var z := (j - 3) * 0.45
		var col := cloth if j % 2 == 0 else Color("cebb94")
		Art.box(st, Vector3(3.45, 0.06, 0.45), c + Vector3(0, 0, z), col, tilt)
		Art.box(st, Vector3(0.055, 0.22, 0.44), c + tilt * Vector3(1.70, -0.11, z), col)
	for z in [-1.32, 1.32]:
		Art.box(st, Vector3(0.09, 2.64, 0.09), base + Vector3(-1.08, 1.34, z), TIMBER)
		Art.box(st, Vector3(0.09, 2.05, 0.09), base + Vector3(1.89, 1.04, z), TIMBER)
		Art.box(st, Vector3(3.55, 0.075, 0.075), c + tilt * Vector3(0, -0.085, z), TIMBER, tilt)


func _interior(parent: Node3D, culture_roof: Color) -> void:
	var floor_m := tex_mat("planks", Color("8a7058"), 1.8)
	if kind == "hall_room":
		floor_m = tex_mat("brick", Color("b8b2a6"), 1.9, 1.0, 0.8).duplicate() as StandardMaterial3D
		floor_m.roughness_texture = null
	var fl := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = rect.size + Vector2(2, 2)
	fl.mesh = pm
	fl.material_override = floor_m
	fl.position = Vector3(rect.get_center().x, 0.02, rect.get_center().y)
	parent.add_child(fl)
	var ceil_m := tex_mat("planks", Color("6a5038"), 1.8).duplicate() as StandardMaterial3D
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
	var furnishings := Art.begin()
	# Warm lanterns with iron cages, around the existing light sources.
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
		var iron := Color("423c34")
		if kind == "hall_room" and absf(lp.x) > 1.0:
			var side := signf(lp.x)
			Art.box(furnishings, Vector3(1.0, 0.078, 0.086), lp + Vector3(side * 0.49, 0.22, 0), iron)
		else:
			var length: float = ceiling - lp.y - 0.22
			Art.box(furnishings, Vector3(0.040, length, 0.04), lp + Vector3.UP * (0.22 + length * 0.5), iron)
		for y in [-0.20, 0.20]:
			Art.box(furnishings, Vector3(0.36, 0.056, 0.36), lp + Vector3.UP * y, iron)
		for x in [-0.148, 0.148]:
			for z_offset in [-0.148, 0.148]:
				Art.box(furnishings, Vector3(0.041, 0.44, 0.041), lp + Vector3(x, 0, z_offset), iron)
	for pr in props:
		if pr[0] == "banner":
			var h: float = pr[2]
			var p := Vector3(pr[1].x, 2.1 + h * 0.5, pr[1].z + 0.11)
			var cloth := culture_roof.lerp(Color("823e32"), 0.50)
			var gold := Color("c39c58")
			Art.box(furnishings, Vector3(2.20, h, 0.052), p, cloth)
			Art.box(furnishings, Vector3(2.58, 0.11, 0.11), p + Vector3.UP * (h * 0.5), TIMBER)
			for x in [-0.91, 0.91]:
				Art.box(furnishings, Vector3(0.073, h, 0.055), p + Vector3(x, 0, 0.025), gold)
			Art.box(furnishings, Vector3(0.72, 0.72, 0.048), p + Vector3(0, 0.15, 0.035), gold,
				Basis(Vector3.FORWARD, PI * 0.25))
			Art.box(furnishings, Vector3(0.51, 0.51, 0.032), p + Vector3(0, 0.15, 0.054), cloth,
				Basis(Vector3.FORWARD, PI * 0.25))
	if kind == "hall_room":
		var rug := Color("73453b")
		var border := Color("8d7045")
		Art.box(furnishings, Vector3(2.9, 0.018, 18.0), Vector3(0, 0.044, -1.0), rug)
		for x in [-1.35, 1.35]:
			Art.box(furnishings, Vector3(0.12, 0.015, 17.7), Vector3(x, 0.05, -1.0), border)
		for z_offset in [-9.8, 7.8]:
			Art.box(furnishings, Vector3(2.8, 0.015, 0.12), Vector3(0, 0.05, z_offset), border)
		for z_offset in [-8.4, -4.7, -1.0, 2.7, 6.4]:
			Art.box(furnishings, Vector3(0.49, 0.015, 0.49), Vector3(0, 0.051, z_offset), border,
				Basis(Vector3.UP, PI * 0.25))
	Art.add(parent, furnishings.commit())
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
