extends RefCounted
## Two shared meshes per tree type: a forked trunk and a canopy. Trees differ in
## rotation, proportions and colour, while the battlefield batches both meshes.

static var _models := {}
static var _tuft_mesh: ArrayMesh


static func build(placed: Array[Transform3D], conifer: bool, snowy: bool) -> Node3D:
	var model := _model(conifer)
	var root := Node3D.new()
	root.name = "Trees"
	for surface in 2:
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.mesh = model[surface]
		multimesh.instance_count = placed.size()
		for i in placed.size():
			var placement := placed[i]
			var scale := placement.basis.get_scale().x
			var width := 0.88 + 0.24 * fposmod(i * 0.381966, 1.0)
			var basis := Basis(Vector3.UP, i * 2.399963).scaled(Vector3(width, 1.0, width) * scale)
			multimesh.set_instance_transform(i, Transform3D(basis, placement.origin))
			var shade := 0.76 + fposmod(i * 0.618034, 1.0) * 0.24
			var tint := Color.WHITE * shade
			if surface == 1:
				var light := Color("819d76") if snowy else Color("b7c8a5")
				var dark := Color("566542") if conifer else Color("87966d")
				tint = dark.lerp(light, fposmod(i * 0.754878, 1.0)) * shade
			tint.a = 1.0
			multimesh.set_instance_color(i, tint)
		var node := MultiMeshInstance3D.new()
		node.multimesh = multimesh
		root.add_child(node)
	return root


static func understory(placed: Array[Transform3D]) -> MultiMeshInstance3D:
	if _tuft_mesh == null:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var material := StandardMaterial3D.new()
		material.vertex_color_use_as_albedo = true
		material.vertex_color_is_srgb = true
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.roughness = 1.0
		st.set_material(material)
		for i in 7:
			var turn := i * 2.399963
			var away := Vector3(cos(turn), 0.0, sin(turn))
			var across := Vector3(-away.z, 0.0, away.x) * 0.021
			var base := away * (0.014 * i)
			var middle := base + away * 0.075 + Vector3.UP * (0.12 + i * 0.008)
			var tip := middle + away * 0.075 + Vector3.UP * 0.09
			var points := [base - across, base + across, middle - across * 0.60, middle + across * 0.60, tip]
			for j in [0, 1, 2, 2, 1, 3, 2, 3, 4]:
				st.set_normal(Vector3.UP)
				st.set_color(Color("48552d") if j < 2 else Color("7c884e"))
				st.add_vertex(points[j])
		_tuft_mesh = st.commit()
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.mesh = _tuft_mesh
	batch.instance_count = placed.size()
	for i in placed.size():
		batch.set_instance_transform(i, placed[i])
	var node := MultiMeshInstance3D.new()
	node.name = "Understory"
	node.multimesh = batch
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


static func _model(conifer: bool) -> Array:
	if _models.has(conifer):
		return _models[conifer]
	var bark := StandardMaterial3D.new()
	bark.albedo_color = Color("b4a697")
	bark.albedo_texture = load("res://assets/textures/bark/albedo.jpg")
	bark.normal_enabled = true
	bark.normal_texture = load("res://assets/textures/bark/normal.jpg")
	bark.normal_scale = 0.65
	bark.vertex_color_use_as_albedo = true
	bark.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	bark.roughness = 0.94
	var leaves := StandardMaterial3D.new()
	leaves.vertex_color_use_as_albedo = true
	leaves.roughness = 0.94
	var species := "spruce" if conifer else "elm"
	leaves.albedo_texture = load("res://assets/textures/foliage/%s.png" % species)
	leaves.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	leaves.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	leaves.alpha_scissor_threshold = 0.43
	leaves.cull_mode = BaseMaterial3D.CULL_DISABLED
	var trunk := SurfaceTool.new()
	trunk.begin(Mesh.PRIMITIVE_TRIANGLES)
	trunk.set_material(bark)
	var canopy := SurfaceTool.new()
	canopy.begin(Mesh.PRIMITIVE_TRIANGLES)
	canopy.set_material(leaves)
	_tube(trunk, Vector3(0, -0.12, 0), Vector3(0.04, 1.5, 0.02), 0.29, 0.19, 9)
	_tube(trunk, Vector3(0.04, 1.5, 0.02), Vector3(-0.11, 3.0, 0.06), 0.19, 0.11, 9)
	_tube(trunk, Vector3(-0.11, 3.0, 0.06), Vector3(0.10, 5.3, -0.10), 0.11, 0.02, 8)
	for i in 4:
		var direction := Vector3(cos(i * 1.57 + 0.3), 0.0, sin(i * 1.57 + 0.3))
		_tube(trunk, Vector3.UP * 0.42, direction * 0.61 - Vector3.UP * 0.10, 0.135, 0.05, 5)
	if conifer:
		_fir(trunk, canopy)
	else:
		_broadleaf(trunk, canopy)
	trunk.generate_tangents()
	_models[conifer] = [trunk.commit(), canopy.commit()]
	return _models[conifer]


static func _tube(st: SurfaceTool, a: Vector3, b: Vector3, r0: float, r1: float, sides: int) -> void:
	var delta := b - a
	var axis := delta.normalized()
	var u := axis.cross(Vector3.FORWARD).normalized()
	if u.length_squared() < 0.1:
		u = axis.cross(Vector3.RIGHT).normalized()
	var v := axis.cross(u)
	var length := delta.length()
	for i in sides:
		# Clockwise triangles on the outside of a tapered tube.
		for k in [Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 0),
				Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
			var fraction := float(i + k.x) / sides
			var theta := TAU * fraction
			var radial := u * cos(theta) + v * sin(theta)
			st.set_normal(radial)
			st.set_uv(Vector2(fraction, (a.y + length * k.y) / 1.7))
			st.add_vertex((a if k.y == 0 else b) + radial * (r0 if k.y == 0 else r1))


static func _broadleaf(trunk: SurfaceTool, canopy: SurfaceTool) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 227
	for i in 13:
		var height := float(i) / 12.0
		var turn := i * 2.399963
		var ray := Vector3(cos(turn), 0.0, sin(turn))
		var base := Vector3(-0.03, lerpf(1.75, 4.40, height), 0.02)
		var span := lerpf(1.9, 0.3, height) * rng.randf_range(0.86, 1.16)
		var elbow := base + ray * span * 0.50 + Vector3.UP * 0.45
		var tip := base + ray * span + Vector3.UP * rng.randf_range(0.82, 1.48)
		_tube(trunk, base, elbow, lerpf(0.092, 0.038, height), 0.035, 6)
		_tube(trunk, elbow, tip, 0.035, 0.009, 5)
		for j in 3:
			var yaw := turn + j * PI / 3.0
			var right := Vector3(cos(yaw), 0.0, sin(yaw))
			var up := Vector3.UP.rotated(right, rng.randf_range(-0.68, 0.68))
			var center := tip + Vector3.UP * 0.20 + right * rng.randf_range(-0.20, 0.20)
			_spray(canopy, center, right, up, rng.randf_range(0.77, 1.27), rng.randf_range(0.79, 1.15))


static func _spray(st: SurfaceTool, center: Vector3, right: Vector3, up: Vector3, w: float, h: float) -> void:
	var corners := [center - right * w + up * h, center + right * w + up * h,
		center - right * w - up * h, center + right * w - up * h]
	var uvs := [Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN, Vector2.ONE]
	var normal := (right.cross(up) * 0.46 + Vector3.UP * 0.82).normalized()
	for i in [0, 1, 2, 2, 1, 3]:
		st.set_normal(normal)
		st.set_uv(uvs[i])
		st.add_vertex(corners[i])


static func _fir(trunk: SurfaceTool, canopy: SurfaceTool) -> void:
	# Whorls of drooping branches, narrower and denser near the leader.
	for tier in 8:
		var h := 1.35 + float(tier) * 0.57
		var spread := lerpf(2.2, 0.38, float(tier) / 7.0)
		var count := 9 if tier < 5 else 6
		for i in count:
			var theta := float(i) * TAU / count + tier * 0.83
			var ray := Vector3(cos(theta), 0.0, sin(theta))
			var side := Vector3(-ray.z, 0.0, ray.x)
			var span := spread * (0.82 + 0.26 * fposmod(i * 0.618 + tier * 0.41, 1.0))
			var base := Vector3(0, h + 0.12 * sin(i * 2.9), 0)
			var tip_dir := (ray - Vector3.UP * 0.23).normalized()
			if i % 2 == 0 and tier < 6:
				_tube(trunk, base, base + tip_dir * span * 0.85, 0.062, 0.009, 5)
			var fan := (side * 0.86 + Vector3.UP * (0.45 if i % 2 == 0 else -0.45)).normalized()
			_spray(canopy, base + tip_dir * (span * 0.47), -tip_dir, fan, span * 0.54, 0.26 + span * 0.24)
	for i in 3:
		var direction := Vector3(cos(i * PI / 3.0), 0.0, sin(i * PI / 3.0))
		_spray(canopy, Vector3(0.07, 5.65, -0.08), Vector3.DOWN, direction, 0.61, 0.27)
