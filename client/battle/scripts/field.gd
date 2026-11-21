class_name BattleField
extends Node3D
## The battlefield: a square heightmap (mesh + collision) coloured by the campaign terrain type,
## optional trees, sky and sun. Also answers height queries (arrows, camera, spawning).

const Art := preload("res://battle/scripts/art_mesh.gd")
const RES := 96                       # cells per side

const LOOKS := {
	# terrain: [low colour, high colour, hill amplitude (m), tree count]
	"plains": [Color("4f6b2c"), Color("72763f"), 4.0, 12],
	"meadow": [Color("4a6e2e"), Color("6a7d3e"), 3.0, 20],
	"steppe": [Color("7f7d44"), Color("9a8a55"), 2.5, 0],
	"hills": [Color("516631"), Color("7d7350"), 13.0, 25],
	"forest": [Color("3c5626"), Color("556436"), 6.0, 140],
	"taiga": [Color("566f45"), Color("8d9481"), 7.0, 110],
	"desert": [Color("c9a96a"), Color("dcc28a"), 5.0, 0],
	"dunes": [Color("cfa766"), Color("e2c48c"), 9.0, 0],
	"snow": [Color("d8dde0"), Color("f2f4f5"), 6.0, 15],
	"marsh": [Color("5d7a4a"), Color("6f8a5a"), 1.5, 25],
	"mountain": [Color("6f7a52"), Color("8e8a7a"), 18.0, 18],
}

var size := 300.0
var heights := PackedFloat32Array()
var trees: Array = []                 # [Vector3 pos, radius] for steering around them
var _tree_grid := {}                  # Vector2i cell (8 m) -> [tree]
var terrain := "plains"
static var _cloud_map: ImageTexture

# ---- siege works (setup["siege"]): a straight town wall across the field, scaling ladders leaning on its
# outer face, stone stairs down into the town. Everything is measured in "u" = depth towards the town
# (u = z * sd; the town lies at u > BACK). Heights are folded into height_at(), so soldiers stand on the
# wall walk, climb the ladders, and arrows stick in the wall face, with no extra physics.
var siege := {}                       # {} = open field; else {sd, h, ladders: [x], stairs: [x]}
const W_FRONT := 18.0                 # outer face of the wall
const W_BACK := 23.0                  # inner face (wall walk is 5 m wide)
const LADDER_LEN := 8.0               # horizontal run of a ladder (it ends on the wall walk)
const LADDER_HALF := 1.3              # half width
const STAIR_LEN := 9.0

# ---- a walkable town, castle or village (setup["town"]); see town.gd
var town := {}                        # {} = none; else {kind, radius, layout: TownLayout, roof: Color}


## Call before build(): lay out a town / castle / village from its seed.
func set_town(cfg: Dictionary) -> void:
	var lay := TownLayout.new()
	lay.generate(str(cfg.get("kind", "town")), int(cfg.get("seed", 1)), int(cfg.get("walls", 2)))
	town = {"kind": lay.kind, "radius": lay.radius, "layout": lay, "roof": Color(str(cfg.get("roof", "#3f444c")))}


func town_at(x: float, z: float) -> float:
	return town.layout.height(x, z)


func _build_town() -> void:
	town.layout.build_visuals(self, terrain_at, town.roof)
const STAIR_HALF := 1.6


## Call before build(): defender_side spawns behind the wall; walls = the town's wall level (1..5).
func set_siege(defender_side: int, walls: int, ladders: int) -> void:
	var n := clampi(ladders, 2, 6)
	var lx: Array = []
	for i in n:
		lx.append((i - (n - 1) * 0.5) * 22.0)
	siege = {"sd": 1.0 if defender_side == 0 else -1.0, "h": clampf(5.0 + 0.6 * walls, 5.0, 8.5),
		"ladders": lx, "stairs": [-55.0, -18.0, 18.0, 55.0]}


func build(terrain_type: String, field_size: float, seed_value: int, night: bool) -> void:
	terrain = terrain_type if LOOKS.has(terrain_type) else "plains"
	size = field_size
	var look: Array = LOOKS[terrain]
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.012
	noise.fractal_octaves = 4
	heights.resize((RES + 1) * (RES + 1))
	var amp: float = look[2]
	for j in RES + 1:
		for i in RES + 1:
			var x := (float(i) / RES - 0.5) * size
			var z := (float(j) / RES - 0.5) * size
			var h := noise.get_noise_2d(x, z) * amp
			# the two armies' deployment lines are a little flatter
			var flat := clampf(1.0 - absf(absf(z) - 55.0) / 40.0, 0.0, 1.0) * 0.5
			if not town.is_empty():
				# a town or village sits on level ground; the hills rise beyond it
				var r := Vector2(x, z).length()
				flat = clampf((float(town.radius) + 25.0 - r) / 25.0, 0.0, 1.0)
				h *= 1.0 - flat
				flat = 0.0
			elif not siege.is_empty():
				# level ground before the wall and in the town (blend in from 40 m outside)
				var u := z * float(siege.sd)
				flat = maxf(flat, clampf((u + 40.0) / 30.0, 0.0, 1.0))
				h *= 1.0 - flat
				flat = 0.0
			heights[j * (RES + 1) + i] = h * (1.0 - flat)
	if DisplayServer.get_name() != "headless":
		_build_mesh(look, seed_value)
	_build_collision()
	if not siege.is_empty():
		_build_siege_works()
	if not town.is_empty():
		_build_town()
	_build_trees(int(look[3]) if siege.is_empty() and town.is_empty() else (6 if town.get("kind", "") == "village" else 0), seed_value)
	if DisplayServer.get_name() != "headless":
		_build_env(night, seed_value)


func height_at(x: float, z: float) -> float:
	var g := terrain_at(x, z)
	if siege.is_empty() and town.is_empty():
		return g
	return g + works_at(x, z)


## Siege works or a town: heights that block walking (see Agent kinematics).
func has_works() -> bool:
	return not siege.is_empty() or not town.is_empty()


## Height of the siege works above the ground at (x, z): wall walk, ladders, stairs.
func works_at(x: float, z: float) -> float:
	if not town.is_empty():
		return town_at(x, z)
	var u := z * float(siege.sd)
	var h: float = siege.h
	if u >= W_FRONT and u <= W_BACK:
		return h
	if u < W_FRONT and u > W_FRONT - LADDER_LEN:
		for lx in siege.ladders:
			if absf(x - lx) <= LADDER_HALF:
				return h * (u - (W_FRONT - LADDER_LEN)) / LADDER_LEN
	elif u > W_BACK and u < W_BACK + STAIR_LEN:
		for sx in siege.stairs:
			if absf(x - sx) <= STAIR_HALF:
				return h * (1.0 - (u - W_BACK) / STAIR_LEN)
	return 0.0


const MERLON_STEP := 2.0
const MERLON_W := 1.3
const MERLON_H := 1.15


func _merlon_at(x: float) -> bool:
	for lx in siege.ladders:
		if absf(x - lx) < LADDER_HALF + 0.6 + MERLON_W * 0.5:
			return false
	var k := (x - (-size * 0.5 + 1.0)) / MERLON_STEP
	return absf(k - roundf(k)) * MERLON_STEP < MERLON_W * 0.5


## Does the arrow path p0 -> p1 cross a merlon on the outer edge of the wall?
func merlon_hit(p0: Vector3, p1: Vector3) -> bool:
	var sd: float = siege.sd
	var plane := W_FRONT + 0.25
	var u0 := p0.z * sd
	var u1 := p1.z * sd
	if (u0 - plane) * (u1 - plane) > 0.0 or absf(u1 - u0) < 1e-5:
		return false
	var t := (plane - u0) / (u1 - u0)
	var c := p0.lerp(p1, t)
	var h: float = siege.h
	return c.y >= h and c.y <= h + MERLON_H and _merlon_at(c.x)


## On a scaling ladder (slow going, one man at a time)?
func on_ladder(p: Vector3) -> bool:
	if siege.is_empty():
		return false
	var u := p.z * float(siege.sd)
	return u < W_FRONT and u > W_FRONT - LADDER_LEN and works_at(p.x, p.z) > 0.05


## Which level a point is on: 0 = outside the wall, 1 = up on the wall (or the upper half of a ladder or
## stair), 2 = inside the town. Without siege works everything is 0.
func level(p: Vector3) -> int:
	if siege.is_empty():
		return 0
	var u := p.z * float(siege.sd)
	if u < W_FRONT:
		if u > W_FRONT - LADDER_LEN * 0.5:
			for lx: float in siege.ladders:
				if absf(p.x - lx) <= LADDER_HALF:
					return 1
		return 0
	if u <= W_BACK:
		return 1
	if u < W_BACK + STAIR_LEN * 0.5:
		for sx: float in siege.stairs:
			if absf(p.x - sx) <= STAIR_HALF:
				return 1
	return 2


func _wpt(x: float, u: float) -> Vector3:
	var z := u * float(siege.sd)
	return Vector3(x, height_at(x, z), z)


func _nearest(xs: Array, x: float) -> float:
	var best: float = xs[0]
	for v in xs:
		if absf(v - x) < absf(best - x):
			best = v
	return best


## Where to walk next on the way from `from` to `to` (siege works: up and down the ladders and stairs,
## never off the side of one). Same point back when the way is open.
func waypoint(from: Vector3, to: Vector3) -> Vector3:
	if siege.is_empty():
		return to
	var lf := level(from)
	var lt := level(to)
	var u := from.z * float(siege.sd)
	var w := works_at(from.x, from.z)
	# on a ladder or a stair: keep straight along it to the end that leads the right way
	if u < W_FRONT and w > 0.05:
		var lx := _nearest(siege.ladders, from.x)
		return _wpt(lx, W_FRONT + 1.2) if lt != 0 else _wpt(lx, W_FRONT - LADDER_LEN - 1.5)
	if u > W_BACK and w > 0.05:
		var sx := _nearest(siege.stairs, from.x)
		return _wpt(sx, W_BACK - 1.2) if lt != 2 else _wpt(sx, W_BACK + STAIR_LEN + 1.5)
	if lf == lt:
		return to
	if lf == 0:
		var lx := _nearest(siege.ladders, lerpf(from.x, to.x, 0.3))
		if absf(from.x - lx) < LADDER_HALF * 0.6 and u > W_FRONT - LADDER_LEN - 3.0:
			return _wpt(lx, W_FRONT + 1.2)
		return _wpt(lx, W_FRONT - LADDER_LEN - 1.5)
	if lf == 2:
		var sx := _nearest(siege.stairs, lerpf(from.x, to.x, 0.3))
		if absf(from.x - sx) < STAIR_HALF * 0.6 and u < W_BACK + STAIR_LEN + 3.0:
			return _wpt(sx, W_BACK - 1.2)
		return _wpt(sx, W_BACK + STAIR_LEN + 1.5)
	# up on the wall walk: along it to the top of a ladder (going out) or a stair (going in)
	if lt == 0:
		var lx := _nearest(siege.ladders, from.x)
		if absf(from.x - lx) < LADDER_HALF * 0.6:
			return _wpt(lx, W_FRONT - LADDER_LEN - 1.5)
		return _wpt(lx, W_FRONT + 0.8)
	var sx := _nearest(siege.stairs, from.x)
	if absf(from.x - sx) < STAIR_HALF * 0.6:
		return _wpt(sx, W_BACK + STAIR_LEN + 1.5)
	return _wpt(sx, W_BACK - 0.8)


## A point on the wall walk (for the defenders' posts): x along the wall, d = 0 outer edge .. 1 inner edge.
func wall_point(x: float, d: float) -> Vector3:
	return _wpt(x, lerpf(W_FRONT + 0.7, W_BACK - 0.7, d))


## A point in the town / outside at depth u (negative = outside).
func siege_point(x: float, u: float) -> Vector3:
	return _wpt(x, u)


func terrain_at(x: float, z: float) -> float:
	var fx := clampf((x / size + 0.5) * RES, 0.0, RES - 0.001)
	var fz := clampf((z / size + 0.5) * RES, 0.0, RES - 0.001)
	var i := int(fx)
	var j := int(fz)
	var tx := fx - i
	var tz := fz - j
	var w := RES + 1
	var h00 := heights[j * w + i]
	var h10 := heights[j * w + i + 1]
	var h01 := heights[(j + 1) * w + i]
	var h11 := heights[(j + 1) * w + i + 1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


## trees within ~8 m of p
func trees_near(p: Vector3) -> Array:
	if _tree_grid.is_empty():
		return []
	var out: Array = []
	var k := Vector2i(floori(p.x / 8.0), floori(p.z / 8.0))
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var c = _tree_grid.get(k + Vector2i(dx, dz))
			if c != null:
				out.append_array(c)
	return out


func _build_siege_works() -> void:
	var sd: float = siege.sd
	var h: float = siege.h
	# grey brick (CC0 textures, see client/assets/textures/CREDITS.md)
	var stone := TownLayout.tex_mat("brick", Color("8a8478"), 2.2, 1.0, 1.2)
	var stone_dark := TownLayout.tex_mat("brick", Color("6e695f"), 2.2, 1.0, 1.2)
	var wood := TownLayout.tex_mat("planks", Color("8a6a48"), 1.2)
	# the wall: one long block (sunk a little into the ground)
	var wall := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(size, h + 2.0, W_BACK - W_FRONT)
	wall.mesh = bm
	wall.material_override = stone
	wall.position = Vector3(0, (h + 2.0) * 0.5 - 2.0, (W_FRONT + W_BACK) * 0.5 * sd)
	add_child(wall)
	# battlements on the outer edge (gaps where the ladders come over)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var merlon := BoxMesh.new()
	merlon.size = Vector3(MERLON_W, MERLON_H, 0.5)
	mm.mesh = merlon
	var xs: Array[float] = []
	var x := -size * 0.5 + 1.0
	while x < size * 0.5 - 1.0:
		if _merlon_at(x):
			xs.append(x)
		x += MERLON_STEP
	mm.instance_count = xs.size()
	for i in xs.size():
		mm.set_instance_transform(i, Transform3D(Basis(), Vector3(xs[i], h + MERLON_H * 0.5, (W_FRONT + 0.25) * sd)))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = stone_dark
	add_child(mmi)
	# Stone trim is inset into the face so the ladder rungs still clear it.
	var trim := BoxMesh.new()
	trim.size = Vector3(size, 0.38, 0.23)
	Art.add(self, trim, Vector3(0, h - 0.55, (W_FRONT + 0.032) * sd)).material_override = stone_dark
	Art.add(self, trim, Vector3(0, 0.58, (W_FRONT + 0.032) * sd)).material_override = stone_dark
	var tower_roof := PrismMesh.new()
	tower_roof.size = Vector3(8.5, 3.5, 8.5)
	var tower_tiles := TownLayout.roof_mat(Color("4e535a"))
	# Roofed watchtowers frame the approach on both sides.
	for tx in [-110.0, -75.0, 75.0, 110.0]:
		var t := MeshInstance3D.new()
		var tb := BoxMesh.new()
		tb.size = Vector3(7.0, h + 6.0, 7.0)
		t.mesh = tb
		t.material_override = stone_dark
		t.position = Vector3(tx, (h + 6.0) * 0.5 - 2.0, (W_FRONT - 2.5) * sd)
		add_child(t)
		var roof_center := Vector3(tx, h + 4.0 + tower_roof.size.y * 0.5, t.position.z)
		Art.add(self, tower_roof, roof_center).material_override = tower_tiles
		var details := Art.begin()
		var beams := Color("584740")
		Art.box(details, Vector3(8.35, 0.24, 8.35), Vector3(tx, h + 3.91, t.position.z), beams)
		Art.box(details, Vector3(0.17, 0.16, 8.67), roof_center + Vector3(0, 1.71, 0), beams)
		var face_z := t.position.z - sd * 3.5
		for off in [-2.2, 2.2]:
			Art.box(details, Vector3(0.60, 1.28, 0.19), Vector3(tx + off, h + 2.30, face_z), beams)
			Art.box(details, Vector3(0.33, 1.05, 0.16), Vector3(tx + off, h + 2.30, face_z - sd * 0.054), Color("282b2c"))
		var cloth := Color("815045") if absf(tx) < 100.0 else Color("566976")
		var p := Vector3(tx, h + 1.39, face_z - sd * 0.13)
		Art.box(details, Vector3(1.03, 2.32, 0.069), p, cloth)
		Art.box(details, Vector3(1.44, 0.09, 0.11), p + Vector3.UP * 1.15, beams)
		Art.box(details, Vector3(0.72, 0.072, 0.081), p - Vector3.UP * 0.90, Color("b99d6b"))
		Art.add(self, details.commit())
	# scaling ladders: two rails and rungs from the foot to the top of the wall
	var rlen := sqrt(LADDER_LEN * LADDER_LEN + h * h)
	for lx in siege.ladders:
		var foot := Vector3(lx, 0.0, (W_FRONT - LADDER_LEN) * sd)
		var top := Vector3(lx, h, W_FRONT * sd)
		var mid := (foot + top) * 0.5
		var lb := Basis.looking_at((top - foot).normalized(), Vector3.UP)
		for side in [-1.0, 1.0]:
			var rail := MeshInstance3D.new()
			var rm := BoxMesh.new()
			rm.size = Vector3(0.12, 0.12, rlen + 0.8)
			rail.mesh = rm
			rail.material_override = wood
			rail.transform = Transform3D(lb, mid + Vector3(side * LADDER_HALF, 0.1, 0))
			add_child(rail)
		var rungs := MultiMesh.new()
		rungs.transform_format = MultiMesh.TRANSFORM_3D
		var rb := BoxMesh.new()
		rb.size = Vector3(LADDER_HALF * 2.0, 0.08, 0.12)
		rungs.mesh = rb
		var nr := int(rlen / 0.45)
		rungs.instance_count = nr
		for k in nr:
			rungs.set_instance_transform(k, Transform3D(lb, foot.lerp(top, (k + 0.5) / nr) + Vector3(0, 0.1, 0)))
		var ri := MultiMeshInstance3D.new()
		ri.multimesh = rungs
		ri.material_override = wood
		add_child(ri)
	# stairs down into the town: a sloping stone ramp with steps
	var slen := sqrt(STAIR_LEN * STAIR_LEN + h * h)
	for sx in siege.stairs:
		var top := Vector3(sx, h, W_BACK * sd)
		var foot := Vector3(sx, 0.0, (W_BACK + STAIR_LEN) * sd)
		var st := MeshInstance3D.new()
		var sb := BoxMesh.new()
		sb.size = Vector3(STAIR_HALF * 2.0, 0.6, slen)
		st.mesh = sb
		st.material_override = stone
		st.transform = Transform3D(Basis.looking_at((foot - top).normalized(), Vector3.UP), (top + foot) * 0.5 - Vector3(0, 0.3, 0))
		add_child(st)
	# a few houses in the town behind (for show)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var roofs := [TownLayout.roof_mat(Color("4a4f58")), TownLayout.roof_mat(Color("615845")),
		TownLayout.roof_mat(Color("71524b"))]
	var plaster := TownLayout.tex_mat("plaster", Color("e0d6c2"), 3.0)
	for k in 26:
		var hx := rng.randf_range(-size * 0.45, size * 0.45)
		var hu := rng.randf_range(W_BACK + STAIR_LEN + 42.0, size * 0.48)
		var hw := rng.randf_range(6.0, 11.0)
		var hd := rng.randf_range(5.0, 8.0)
		var hh := rng.randf_range(3.0, 4.5)
		var base := Vector3(hx, terrain_at(hx, hu * sd), hu * sd)
		var body := MeshInstance3D.new()
		var hb := BoxMesh.new()
		hb.size = Vector3(hw, hh, hd)
		body.mesh = hb
		body.material_override = plaster
		body.position = base + Vector3(0, hh * 0.5, 0)
		add_child(body)
		var r := MeshInstance3D.new()
		var pm := PrismMesh.new()
		pm.size = Vector3(hw + 1.0, 1.8, hd + 1.0)
		r.mesh = pm
		r.material_override = roofs[k % roofs.size()]
		r.position = base + Vector3(0, hh + 0.9, 0)
		add_child(r)


func ground(p: Vector3) -> Vector3:
	return Vector3(p.x, height_at(p.x, p.z), p.z)


## The heightmap keeps its original topology for collisions. The visible mesh shares vertices
## and uses smooth normals, plus world-scale UVs for soil, grass, sand and snow.
func _build_mesh(look: Array, seed_value: int) -> void:
	var width := RES + 1
	var count := width * width
	var cell := size / RES
	var points := PackedVector3Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var uvs := PackedVector2Array()
	var masks := PackedColorArray()
	var indices := PackedInt32Array()
	points.resize(count)
	normals.resize(count)
	tangents.resize(count * 4)
	uvs.resize(count)
	masks.resize(count)
	indices.resize(RES * RES * 6)
	var patches := FastNoiseLite.new()
	patches.seed = 97
	patches.frequency = 0.063
	patches.fractal_octaves = 2
	var cover_amount: float = {"meadow": 0.79, "plains": 0.64, "steppe": 0.36, "hills": 0.61,
		"forest": 0.52, "taiga": 0.48, "marsh": 0.63, "mountain": 0.38}.get(terrain, 0.0)
	for j in width:
		var z := j * cell - size * 0.5
		for i in width:
			var x := i * cell - size * 0.5
			var k := j * width + i
			var dx := heights[j * width + mini(i + 1, RES)] - heights[j * width + maxi(i - 1, 0)]
			var dz := heights[mini(j + 1, RES) * width + i] - heights[maxi(j - 1, 0) * width + i]
			var tangent := Vector3(cell * 2.0, dx, 0.0).normalized()
			points[k] = Vector3(x, heights[k], z)
			normals[k] = Vector3(-dx, cell * 2.0, -dz).normalized()
			tangents[k * 4] = tangent.x
			tangents[k * 4 + 1] = tangent.y
			tangents[k * 4 + 2] = tangent.z
			tangents[k * 4 + 3] = -1.0
			uvs[k] = Vector2(x, z)
			var patch := patches.get_noise_2d(x, z)
			var grass := clampf(cover_amount + patch * 1.18 - (1.0 - normals[k].y) * 1.8, 0.0, 1.0)
			masks[k] = Color(grass, clampf(0.55 + patch * 0.6, 0.0, 1.0), 0.0)
			if i < RES and j < RES:
				var f := (j * RES + i) * 6
				indices[f] = k
				indices[f + 1] = k + 1
				indices[f + 2] = k + width
				indices[f + 3] = k + 1
				indices[f + 4] = k + width + 1
				indices[f + 5] = k + width
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = masks
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var material := _ground_material(look, cover_amount > 0.0)
	mi.material_override = material
	add_child(mi)
	_build_horizon(material, patches, cover_amount, maxf(17.0, float(look[2]) * 2.8), seed_value)


## Continue the terrain beyond the four gameplay edges, joining the exact
## heightmap samples. Only the original square has collision.
func _build_horizon(material: ShaderMaterial, patches: FastNoiseLite, cover_amount: float,
		relief: float, seed_value: int) -> void:
	var hills := FastNoiseLite.new()
	hills.seed = seed_value + 2147
	hills.frequency = 0.0055
	hills.fractal_octaves = 3
	var edge := PackedVector2Array()
	var edge_heights := PackedFloat32Array()
	var width := RES + 1
	for side in 4:
		for i in RES:
			var t := float(i) / RES - 0.5
			match side:
				0:
					edge.append(Vector2(t, -0.5))
					edge_heights.append(heights[i])
				1:
					edge.append(Vector2(0.5, t))
					edge_heights.append(heights[i * width + RES])
				2:
					edge.append(Vector2(-t, 0.5))
					edge_heights.append(heights[RES * width + RES - i])
				3:
					edge.append(Vector2(-0.5, -t))
					edge_heights.append(heights[(RES - i) * width])
	var rings := [1.0, 1.16, 1.44, 1.87, 2.47, 3.3, 4.6]
	var points := PackedVector3Array()
	var tint := PackedColorArray()
	for radial: float in rings:
		var merge := smoothstep(1.0, 2.0, radial)
		var haze := smoothstep(1.0, 1.76, radial)
		for i in edge.size():
			var p := edge[i] * (size * radial)
			var ridge := hills.get_noise_2d(p.x, p.y) * relief + relief * 0.43
			points.append(Vector3(p.x, lerpf(edge_heights[i], ridge, merge), p.y))
			var patch := patches.get_noise_2d(p.x, p.y)
			tint.append(Color(clampf(cover_amount + patch * 1.18, 0.0, 1.0),
				clampf(0.55 + patch * 0.6, 0.0, 1.0), haze))
	var mesh := SurfaceTool.new()
	mesh.begin(Mesh.PRIMITIVE_TRIANGLES)
	for ring in rings.size() - 1:
		for i in edge.size():
			var a := ring * edge.size() + i
			var b := ring * edge.size() + ((i + 1) % edge.size())
			var c := a + edge.size()
			var d := b + edge.size()
			for k in [a, c, b, b, c, d]:
				mesh.set_uv(Vector2(points[k].x, points[k].z))
				mesh.set_color(tint[k])
				mesh.add_vertex(points[k])
	mesh.index()
	mesh.generate_normals()
	mesh.generate_tangents()
	var backdrop := MeshInstance3D.new()
	backdrop.name = "DistantGround"
	backdrop.mesh = mesh.commit()
	backdrop.material_override = material
	backdrop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(backdrop)


func _ground_material(look: Array, blend_cover: bool) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://battle/scripts/ground.gdshader")
	var soil_texture := "earth"
	var soil_tint := Color("867054")
	var far_tint := Color("75867c")
	if terrain in ["desert", "dunes"]:
		soil_texture = "sand"
		soil_tint = look[0].lerp(look[1], 0.40)
		far_tint = Color("ac9270")
	elif terrain == "snow":
		soil_texture = "snow"
		soil_tint = Color("aabecb")
		far_tint = Color("9fb5c6")
		m.set_shader_parameter("exposure", 0.39)
	elif terrain in ["forest", "marsh", "taiga"]:
		soil_tint = Color("705f46")
	var dir := "res://assets/textures/%s/" % soil_texture
	m.set_shader_parameter("soil", load(dir + "albedo.jpg"))
	m.set_shader_parameter("relief", load(dir + "normal.jpg"))
	m.set_shader_parameter("cover", load("res://assets/textures/turf/albedo.jpg"))
	m.set_shader_parameter("cover_relief", load("res://assets/textures/turf/normal.jpg"))
	m.set_shader_parameter("soil_tint", soil_tint)
	m.set_shader_parameter("cover_tint", look[0].lerp(look[1], 0.5).lightened(0.09))
	m.set_shader_parameter("far_tint", far_tint)
	m.set_shader_parameter("blend_cover", blend_cover)
	m.set_shader_parameter("village", town.get("kind", "") == "village")
	return m


func _build_collision() -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var hm := HeightMapShape3D.new()
	hm.map_width = RES + 1
	hm.map_depth = RES + 1
	hm.map_data = heights
	cs.shape = hm
	var cell := size / RES
	cs.scale = Vector3(cell, 1.0, cell)
	body.add_child(cs)
	add_child(body)


func _build_trees(n: int, seed_value: int) -> void:
	if n <= 0:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 99
	var placed: Array[Transform3D] = []
	var tries := 0
	while placed.size() < n and tries < n * 20:
		tries += 1
		var x := rng.randf_range(-size * 0.47, size * 0.47)
		var z := rng.randf_range(-size * 0.47, size * 0.47)
		# keep the deployment lines open
		if absf(absf(z) - 55.0) < 14.0 and absf(x) < 45.0:
			continue
		var s := rng.randf_range(0.8, 1.3)
		placed.append(Transform3D(Basis().scaled(Vector3(s, s, s)), Vector3(x, height_at(x, z), z)))
	var body := StaticBody3D.new()
	body.collision_layer = 1
	add_child(body)
	for t in placed:
		var s := t.basis.get_scale().x
		var cs := CollisionShape3D.new()
		var cyl := CylinderShape3D.new()
		cyl.radius = 0.35 * s
		cyl.height = 4.0
		cs.shape = cyl
		cs.position = t.origin + Vector3(0, 2.0, 0)
		body.add_child(cs)
		var tr := [t.origin, 0.6 * s]
		trees.append(tr)
		var ck := Vector2i(floori(t.origin.x / 8.0), floori(t.origin.z / 8.0))
		if not _tree_grid.has(ck):
			_tree_grid[ck] = []
		_tree_grid[ck].append(tr)
	if DisplayServer.get_name() != "headless" and not placed.is_empty():
		var conifer := terrain in ["taiga", "snow", "mountain"]
		var art := preload("res://battle/scripts/tree_art.gd")
		add_child(art.build(placed, conifer, terrain == "snow"))
		if terrain != "snow":
			var tufts: Array[Transform3D] = []
			var decor := RandomNumberGenerator.new()
			decor.seed = seed_value + 884
			for t in placed:
				for i in 19:
					var angle := decor.randf_range(0.0, TAU)
					var origin := t.origin + Vector3(cos(angle), 0, sin(angle)) * decor.randf_range(1.4, 6.0)
					var scale := decor.randf_range(0.62, 1.36)
					tufts.append(Transform3D(Basis(Vector3.UP, angle).scaled(Vector3.ONE * scale), ground(origin)))
			add_child(art.understory(tufts))


func _build_env(night: bool, seed_value: int) -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ShaderMaterial.new()
	sm.shader = preload("res://battle/scripts/field_sky.gdshader")
	if _cloud_map == null:
		var noise := FastNoiseLite.new()
		noise.frequency = 0.031
		noise.fractal_octaves = 4
		var cloud_image := noise.get_seamless_image(256, 256)
		cloud_image.generate_mipmaps()
		_cloud_map = ImageTexture.create_from_image(cloud_image)
	sm.set_shader_parameter("cloud_map", _cloud_map)
	sm.set_shader_parameter("cloud_shift", Vector2(fposmod(seed_value * 0.031, 1.0), fposmod(seed_value * 0.047, 1.0)))
	sm.set_shader_parameter("night", night)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sm.set_shader_parameter("light_dir", sun.transform.basis.z)
	if night:
		sm.set_shader_parameter("zenith", Color("0a152d"))
		sm.set_shader_parameter("horizon", Color("2e4262"))
		sm.set_shader_parameter("lower_air", Color("131b29"))
		sm.set_shader_parameter("cloud_top", Color("46516b"))
		sm.set_shader_parameter("cloud_base", Color("1e283c"))
		sm.set_shader_parameter("cloud_threshold", 0.56)
	else:
		var dry := terrain in ["desert", "dunes", "steppe"]
		sm.set_shader_parameter("zenith", Color("3873ae"))
		sm.set_shader_parameter("horizon", Color("d3d2be") if dry else Color("aec5d4"))
		sm.set_shader_parameter("lower_air", Color("c2c7c4"))
		sm.set_shader_parameter("cloud_top", Color("e7e8e0"))
		sm.set_shader_parameter("cloud_base", Color("9baab6"))
		sm.set_shader_parameter("cloud_threshold", 0.62 if dry else (0.42 if terrain in ["snow", "marsh"] else 0.48))
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color("8796a8") if not night else Color("2a3550")
	e.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	e.ambient_light_energy = 0.45 if night else 0.52
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = 1.0
	e.fog_enabled = true
	e.fog_light_color = Color("aab8c4") if not night else Color("1a2232")
	e.fog_density = 0.0032 if not night else 0.012
	e.fog_sky_affect = 0.16 if not night else 0.31
	env.environment = e
	add_child(env)
	sun.light_energy = 0.25 if night else 0.91
	sun.light_color = Color("9fb4ff") if night else Color("fff1d6")
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	add_child(sun)
