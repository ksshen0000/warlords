extends RefCounted
## Pixel atlas for the horse and its tack. Side colours and coats are cached
## across riders. Ears, muzzle and mane share their joint's existing draw call.

const SIZE := 128
const COATS := [Color("8e603a"), Color("58392d"), Color("a9845f"), Color("352d28"), Color("b9b2a5")]
const PARTS := {
	"body": [0, 0, 12, 14, 26], "neck": [78, 0, 10, 21, 10],
	"head": [0, 41, 10, 10, 23], "upper": [67, 42, 6, 16, 6], "lower": [93, 42, 6, 17, 6],
	"tail": [73, 67, 6, 18, 6], "mane": [101, 66, 3, 18, 7], "saddle": [0, 76, 14, 5, 20],
	"armor": [0, 103, 12, 14, 7], "muzzle": [42, 104, 8, 7, 8], "ear": [80, 99, 4, 8, 4],
}
const LEATHER := Color("38271e")
const BRASS := Color("c6a263")

static var _materials := {}
static var _meshes := {}


static func mesh(part: String, size: Vector3) -> ArrayMesh:
	var key := [part, size]
	if _meshes.has(key):
		return _meshes[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	AgentSkin.append_box(st, AgentSkin.box_faces(PARTS[part]), size, SIZE)
	if part == "head":
		_box_at(st, "muzzle", Vector3(0.202, 0.172, 0.25), Vector3(0, -0.035, -0.18))
		for side in [-1, 1]:
			_box_at(st, "ear", Vector3(0.057, 0.16, 0.064),
				Vector3(0.081 * side, 0.186, 0.137), Basis(Vector3.BACK, -0.20 * side))
	elif part == "neck":
		_box_at(st, "mane", Vector3(0.125, 0.687, 0.104), Vector3(0, 0.045, 0.188))
	var result := st.commit()
	_meshes[key] = result
	return result


static func _box_at(st: SurfaceTool, part: String, size: Vector3, pos: Vector3, basis := Basis.IDENTITY) -> void:
	AgentSkin.append_box(st, AgentSkin.box_faces(PARTS[part]), size, SIZE, Transform3D(basis, pos))


static func material(index: int, team: Color, armored: bool) -> StandardMaterial3D:
	var key := [index, team.to_html(false), armored]
	if _materials.has(key):
		return _materials[key]
	var img := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGB8)
	var coat: Color = COATS[index]
	var mane := coat.darkened(0.64).lerp(Color("29201b"), 0.42)
	var cloth := team.darkened(0.30).lerp(Color("7d4735"), 0.24)
	for part in PARTS:
		var faces := AgentSkin.box_faces(PARTS[part])
		for side in faces:
			var r: Rect2i = faces[side]
			for y in r.size.y:
				for x in r.size.x:
					img.set_pixelv(r.position + Vector2i(x, y),
						_pixel(part, side, Vector2i(x, y), r.size, coat, mane, cloth, index, armored))
	img.generate_mipmaps()
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(img)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC
	mat.roughness = 0.87
	_materials[key] = mat
	return mat


static func _pixel(part: String, side: String, p: Vector2i, size: Vector2i, coat: Color, mane: Color,
		cloth: Color, index: int, armored: bool) -> Color:
	var f := float(p.y) / maxf(1.0, size.y - 1)
	var flank := side in ["right", "left"]
	var ripple := float((p.x * 23 + p.y * 13 + p.x * p.y + index * 11) % 17) / 17.0
	var horse_color := coat.lerp(mane, 0.06 + 0.30 * f * f).lightened(ripple * 0.095)
	if side == "top":
		horse_color = horse_color.lightened(0.10)
	elif side == "bottom":
		horse_color = horse_color.darkened(0.27)
	match part:
		"body":
			if flank and p.x >= 11 and p.x <= 15 and not armored:
				return LEATHER.lightened(ripple * 0.11) if p.x != 11 else LEATHER.darkened(0.20)
			if armored and (flank or side == "front"):
				return _scale(p, size, cloth, ripple)
			if index == 4 and ripple > 0.69:
				horse_color = horse_color.darkened(0.12)
		"neck":
			if flank and (p.x == (1 if side == "left" else size.x - 2)):
				horse_color = horse_color.lerp(mane, 0.35)
		"head":
			if flank:
				var from_nose := p.x if side == "left" else size.x - 1 - p.x
				if from_nose == size.x - 6 and p.y in [2, 3]:
					return Color("1d1a18") if p.y == 3 else Color("a08b72")
				if from_nose == 4 or from_nose == size.x - 3 or (p.y == 5 and from_nose > 3):
					return BRASS if p.y == 5 and from_nose == 4 else LEATHER
			if side == "top" and absf(p.x - (size.x - 1) * 0.5) <= (1.6 if index in [0, 4] else 0.5):
				return coat.lightened(0.63)
		"muzzle":
			var from_nose := p.x if side == "left" else size.x - 1 - p.x
			if flank and from_nose == 3:
				return LEATHER
			if side == "front" and p.y == 3 and p.x in [1, size.x - 2]:
				return mane.darkened(0.42)
			return coat.lerp(mane, 0.58).lightened(ripple * 0.09)
		"ear":
			if p.y < 2 or (side == "front" and p.x in [1, 2] and p.y < 6):
				return mane
		"tail", "mane":
			return mane.lightened(0.035 + float((p.x * 7) % 5) * 0.03 + ripple * 0.06)
		"lower":
			return horse_color.lerp(mane, smoothstep(0.0, 0.72, f) * 0.75)
		"saddle":
			if (side == "top" and (p.x in [1, size.x - 2] or p.y in [2, size.y - 3])) or (flank and p.y == 1):
				return cloth.lerp(BRASS, 0.67).lightened(ripple * 0.13)
			return cloth.lightened(ripple * 0.17)
		"armor":
			return _scale(p, size, cloth, ripple)
	return horse_color


static func _scale(p: Vector2i, size: Vector2i, cloth: Color, shade: float) -> Color:
	if p.y in [0, size.y - 1]:
		return cloth.lerp(BRASS, 0.41)
	if p.x in [0, size.x - 1]:
		return LEATHER
	if p.y % 3 == 2:
		return Color("363c3c").lerp(cloth, 0.25)
	if (p.x + p.y / 3) % 4 == 0 and p.y % 3 == 0:
		return Color("b2a497")
	return Color("636e6d").lerp(cloth, 0.20).lightened(shade * 0.24)
