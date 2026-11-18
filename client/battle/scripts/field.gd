class_name BattleField
extends Node3D
## The battlefield: a square heightmap (mesh + collision) coloured by the campaign terrain type,
## optional trees, sky and sun. Also answers height queries (arrows, camera, spawning).

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
			heights[j * (RES + 1) + i] = h * (1.0 - flat)
	_build_mesh(look)
	_build_collision()
	_build_trees(int(look[3]), seed_value)
	_build_env(night)


func height_at(x: float, z: float) -> float:
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


func ground(p: Vector3) -> Vector3:
	return Vector3(p.x, height_at(p.x, p.z), p.z)


func _build_mesh(look: Array) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lo: Color = look[0]
	var hi: Color = look[1]
	var amp: float = maxf(1.0, look[2])
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var w := RES + 1
	var cols := PackedColorArray()
	cols.resize(w * w)
	for k in w * w:
		var t := clampf(heights[k] / amp * 0.5 + 0.5, 0.0, 1.0)
		cols[k] = lo.lerp(hi, t).darkened(rng.randf_range(-0.04, 0.06))
	for j in RES:
		for i in RES:
			var idx := [j * w + i, j * w + i + 1, (j + 1) * w + i, (j + 1) * w + i + 1]
			var pts: Array[Vector3] = []
			for k in idx:
				var ii: int = k % w
				var jj: int = k / w
				pts.append(Vector3((float(ii) / RES - 0.5) * size, heights[k], (float(jj) / RES - 0.5) * size))
			for tri in [[0, 1, 2], [1, 3, 2]]:
				for t in tri:
					st.set_color(cols[idx[t]])
					st.add_vertex(pts[t])
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.95
	mi.material_override = mat
	add_child(mi)


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
	var trunk_mm := MultiMesh.new()
	trunk_mm.transform_format = MultiMesh.TRANSFORM_3D
	var crown_mm := MultiMesh.new()
	crown_mm.transform_format = MultiMesh.TRANSFORM_3D
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.18
	trunk.bottom_radius = 0.25
	trunk.height = 3.0
	var crown := CylinderMesh.new()
	crown.top_radius = 0.0
	crown.bottom_radius = 1.8
	crown.height = 5.0
	var conifer := terrain in ["taiga", "snow", "mountain"]
	if not conifer:
		var sm := SphereMesh.new()
		sm.radius = 2.0
		sm.height = 3.6
		crown_mm.mesh = sm
	else:
		crown_mm.mesh = crown
	trunk_mm.mesh = trunk
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
	trunk_mm.instance_count = placed.size()
	crown_mm.instance_count = placed.size()
	var body := StaticBody3D.new()
	body.collision_layer = 1
	add_child(body)
	for k in placed.size():
		var t := placed[k]
		var s := t.basis.get_scale().x
		trunk_mm.set_instance_transform(k, Transform3D(t.basis, t.origin + Vector3(0, 1.5 * s, 0)))
		crown_mm.set_instance_transform(k, Transform3D(t.basis, t.origin + Vector3(0, (5.0 if conifer else 4.4) * s, 0)))
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
	var tm := MultiMeshInstance3D.new()
	tm.multimesh = trunk_mm
	var tmat := StandardMaterial3D.new()
	tmat.albedo_color = Color("5a4330")
	tm.material_override = tmat
	add_child(tm)
	var cm := MultiMeshInstance3D.new()
	cm.multimesh = crown_mm
	var cmat := StandardMaterial3D.new()
	cmat.albedo_color = Color("3f6a2e") if terrain != "snow" else Color("4d6a52")
	cm.material_override = cmat
	add_child(cm)


func _build_env(night: bool) -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	if night:
		sm.sky_top_color = Color("0b1424")
		sm.sky_horizon_color = Color("27324a")
		sm.ground_horizon_color = Color("1c2230")
		sm.ground_bottom_color = Color("0a0d12")
	else:
		sm.sky_top_color = Color("4f7fb8")
		sm.sky_horizon_color = Color("b9c9d6")
		sm.ground_horizon_color = Color("8f9a8a")
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color("8796a8") if not night else Color("2a3550")
	e.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	e.ambient_light_energy = 0.45 if night else 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = 1.0
	e.fog_enabled = true
	e.fog_light_color = Color("aab8c4") if not night else Color("1a2232")
	e.fog_density = 0.004 if not night else 0.012
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 0.25 if night else 1.0
	sun.light_color = Color("9fb4ff") if night else Color("fff1d6")
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	add_child(sun)
