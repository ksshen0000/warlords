extends RefCounted
## Equipment is cached by its visible shape and rendered as one surface per held item.
const Art := preload("res://battle/scripts/art_mesh.gd")
const WOOD := Color("705032")
const LEATHER := Color("423025")
const BRONZE := Color("b19358")
const STEEL := Color("a5afb3")
const EDGE := Color("d8dee0")
static var _meshes := {}


static func melee(w: Dictionary, length: float) -> ArrayMesh:
	var id: String = w.get("id", "")
	var kind: String = w.get("kind", "one_hand")
	var blunt: bool = w.get("dtype", "") == "blunt"
	var key := [id, kind, length, blunt]
	if _meshes.has(key):
		return _meshes[key]
	var st := Art.begin()
	match kind:
		"polearm", "lance":
			Art.box(st, Vector3(0.044, 0.044, length + 0.5), Vector3(0, 0, -length * 0.5 + 0.25), WOOD)
			Art.box(st, Vector3(0.053, 0.053, 0.13), Vector3(0, 0, -length + 0.075), LEATHER)
			Art.box(st, Vector3(0.052, 0.052, 0.10), Vector3(0, 0, 0.45), BRONZE)
			_blade(st, -length + 0.04, -length - 0.21, 0.035, 0.013)
			if id == "ji":
				_axe_edge(st, length, 0.23)
		"two_hand":
			Art.box(st, Vector3(0.051, 0.051, length + 0.3), Vector3(0, 0, -length * 0.5 + 0.15), WOOD)
			Art.box(st, Vector3(0.060, 0.060, 0.27), Vector3(0, 0, 0.04), LEATHER)
			_axe_edge(st, length, 0.31)
		_:
			if blunt:
				Art.box(st, Vector3(0.052, 0.052, length + 0.08), Vector3(0, 0, -length * 0.5 + 0.04), WOOD)
				Art.box(st, Vector3(0.061, 0.061, 0.15), Vector3.ZERO, LEATHER)
				if id == "mace":
					for i in 4:
						Art.box(st, Vector3(0.14, 0.038, 0.155), Vector3(0, 0, -length + 0.055),
							STEEL.darkened(0.15), Basis(Vector3.FORWARD, PI * i * 0.25))
				else:
					Art.box(st, Vector3(0.105, 0.105, 0.20), Vector3(0, 0, -length + 0.075), WOOD.darkened(0.1))
					Art.box(st, Vector3(0.11, 0.11, 0.025), Vector3(0, 0, -length + 0.055), BRONZE.darkened(0.2))
			else:
				Art.box(st, Vector3(0.049, 0.049, 0.16), Vector3.ZERO, LEATHER)
				Art.box(st, Vector3(0.056, 0.045, 0.034), Vector3(0, 0, 0.08), BRONZE)
				Art.box(st, Vector3(0.12, 0.036, 0.032), Vector3(0, 0, -0.09), BRONZE)
				_blade(st, -0.10, -length, 0.029 if id == "knife" else 0.033, 0.009)
	return _save(st, key)


static func _blade(st: SurfaceTool, start: float, end: float, width: float, ridge: float) -> void:
	var tip := Vector3(0, 0, end)
	var shoulder := lerpf(start, end, 0.73)
	var offsets := [Vector3(0, ridge, 0), Vector3(width, 0, 0), Vector3(0, -ridge, 0), Vector3(-width, 0, 0)]
	for i in 4:
		var a: Vector3 = offsets[i]
		var b: Vector3 = offsets[(i + 1) % 4]
		var c := a * 0.82 + Vector3(0, 0, shoulder)
		var d := b * 0.82 + Vector3(0, 0, shoulder)
		var tint := STEEL if i % 2 == 0 else EDGE
		Art.quad(st, b + Vector3(0, 0, start), a + Vector3(0, 0, start), c, d, tint)
		Art.triangle(st, d, c, tip, EDGE)


static func _axe_edge(st: SurfaceTool, length: float, height: float) -> void:
	var edge_start := Vector3(0, height, -length - 0.035)
	var edge_end := Vector3(0, height * 0.91, -length + 0.23)
	for side in [-1.0, 1.0]:
		var a := Vector3(side * 0.025, 0, -length + 0.015)
		var b := Vector3(side * 0.025, 0, -length + 0.12)
		var c := edge_end + Vector3(side * 0.012, -0.038, -0.014)
		var d := edge_start + Vector3(side * 0.012, -0.039, 0.019)
		if side < 0:
			Art.quad(st, a, d, c, b, STEEL)
			Art.quad(st, d, edge_start, edge_end, c, EDGE)
		else:
			Art.quad(st, a, b, c, d, STEEL)
			Art.quad(st, d, c, edge_end, edge_start, EDGE)


static func shield(id: String, radius: float, coat: Color) -> ArrayMesh:
	var rattan := id == "rattan"
	var face := Color("b69455") if rattan else coat.darkened(0.20).lerp(WOOD, 0.2)
	var key := ["shield", id, radius, face]
	if _meshes.has(key):
		return _meshes[key]
	var st := Art.begin()
	var rings := [Vector2(0.0, -0.100), Vector2(0.105 / radius, -0.081)]
	if rattan:
		rings.append_array([Vector2(0.30, -0.070), Vector2(0.49, -0.057), Vector2(0.68, -0.050), Vector2(0.82, -0.043)])
	rings.append_array([Vector2(0.93, -0.038), Vector2(1, -0.025), Vector2(1, 0.025)])
	var n := 12
	for i in n:
		var a := Vector3(cos(TAU * i / n) * radius, sin(TAU * i / n) * radius, 0)
		var b := Vector3(cos(TAU * (i + 1) / n) * radius, sin(TAU * (i + 1) / n) * radius, 0)
		for j in rings.size() - 1:
			var inner: Vector2 = rings[j]
			var outer: Vector2 = rings[j + 1]
			var p := a * inner.x + Vector3(0, 0, inner.y)
			var q := a * outer.x + Vector3(0, 0, outer.y)
			var r := b * outer.x + Vector3(0, 0, outer.y)
			var s := b * inner.x + Vector3(0, 0, inner.y)
			var tint := face.darkened(0.11 * ((i + j) % 3) / 2.0)
			if j == 0:
				Art.triangle(st, p, q, r, BRONZE if rattan else STEEL)
			else:
				if j >= rings.size() - 3:
					tint = LEATHER.darkened(0.1) if j == rings.size() - 2 else BRONZE
				Art.quad(st, p, q, r, s, tint)
		Art.triangle(st, Vector3(0, 0, 0.025), b + Vector3(0, 0, 0.025), a + Vector3(0, 0, 0.025), WOOD)
		if i % 2 == 0:
			Art.box(st, Vector3(0.031, 0.031, 0.013), a * 0.9 + Vector3(0, 0, -0.047), BRONZE.lightened(0.15))
	for x in [-0.12, 0.12]:
		Art.box(st, Vector3(0.055, radius * 0.85, 0.025), Vector3(x, 0, 0.038), LEATHER)
	return _save(st, key)


static func ranged(kind: String, id: String = "") -> ArrayMesh:
	var key := ["ranged", kind, id if kind == "throw" else ""]
	if _meshes.has(key):
		return _meshes[key]
	var st := Art.begin()
	if kind == "throw":
		# held in the right hand like a melee weapon, pointing along local -Z
		if id == "throwing_axe":
			Art.box(st, Vector3(0.035, 0.035, 0.42), Vector3(0, 0, -0.16), WOOD)
			Art.box(st, Vector3(0.02, 0.16, 0.1), Vector3(0, 0.06, -0.34), STEEL)
		else:
			Art.box(st, Vector3(0.03, 0.03, 1.5), Vector3(0, 0, -0.35), WOOD)
			Art.box(st, Vector3(0.045, 0.02, 0.16), Vector3(0, 0, -1.15), STEEL)
		return _save(st, key)
	var points := [Vector3(0, -0.68, 0.07), Vector3(0, -0.48, -0.03), Vector3(0, -0.23, -0.1),
		Vector3(0, 0, -0.08), Vector3(0, 0.23, -0.10), Vector3(0, 0.48, -0.03), Vector3(0, 0.68, 0.07)]
	if kind == "crossbow":
		Art.box(st, Vector3(0.069, 0.069, 0.70), Vector3(0, 0, -0.2), WOOD)
		Art.box(st, Vector3(0.041, 0.014, 0.41), Vector3(0, 0.037, -0.33), STEEL.darkened(0.21))
		for i in points.size():
			var p: Vector3 = points[i]
			points[i] = Vector3(p.y * 0.55, 0, -0.47 + p.z * 0.8)
	else:
		Art.box(st, Vector3(0.052, 0.15, 0.052), Vector3(0, 0, -0.08), LEATHER)
	for i in points.size() - 1:
		_segment(st, points[i], points[i + 1], 0.024 if i in [0, 5] else 0.037, WOOD.lightened(0.12))
	_segment(st, points.front(), points.back(), 0.009, Color("c3b79c"))
	return _save(st, key)


static func _segment(st: SurfaceTool, a: Vector3, b: Vector3, width: float, tint: Color) -> void:
	var up := Vector3.RIGHT if absf((b - a).normalized().y) > 0.95 else Vector3.UP
	Art.box(st, Vector3(width, width, a.distance_to(b) + width * 0.25), (a + b) * 0.5,
		tint, Basis.looking_at(b - a, up))


static func _save(st: SurfaceTool, key: Array) -> ArrayMesh:
	st.index()
	var mesh := st.commit()
	_meshes[key] = mesh
	return mesh
