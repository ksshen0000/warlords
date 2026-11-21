extends RefCounted
## One opaque surface for small pieces that share a transform or belong to one static prop.
static var _material: StandardMaterial3D
static var _unit_cube: Array


static func begin() -> SurfaceTool:
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.vertex_color_use_as_albedo = true
		_material.vertex_color_is_srgb = true
		_material.roughness = 0.82
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_material)
	return st


static func box(st: SurfaceTool, size: Vector3, pos: Vector3, tint: Color, basis := Basis.IDENTITY) -> void:
	if _unit_cube.is_empty():
		_unit_cube = BoxMesh.new().get_mesh_arrays()
	var vertices: PackedVector3Array = _unit_cube[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = _unit_cube[Mesh.ARRAY_NORMAL]
	st.set_color(tint)
	for i in _unit_cube[Mesh.ARRAY_INDEX]:
		st.set_normal(basis * normals[i])
		st.add_vertex(pos + basis * (vertices[i] * size))


static func triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, tint: Color) -> void:
	st.set_color(tint)
	st.set_normal((c - a).cross(b - a).normalized())
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)


static func quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, tint: Color) -> void:
	triangle(st, a, b, c, tint)
	triangle(st, a, c, d, tint)


static func add(parent: Node3D, mesh: Mesh, pos := Vector3.ZERO) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = pos
	parent.add_child(instance)
	return instance
