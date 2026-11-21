class_name AgentSkin
extends RefCounted
## Blocky soldiers with pixel skins: every body part is a cuboid whose six faces are cut from one
## 64×64 skin image ("box UV": each part unfolded as a cross — top / bottom above, then the four sides),
## and an outer layer a little bigger than the head and the chest carries helmet and armour (transparent
## where there is none). The skins are painted here at runtime from the soldier's culture, rank, gear and
## coat colour — no image files — and cached, so a battle of 300 men shares a few dozen textures.
##
## Layout (pixels): [u, v, w, h, d] — w across, h along the part (up the body / down the limb), d deep.

const PARTS := {
	"head": [0, 0, 8, 8, 8],
	"helm": [32, 0, 8, 8, 8],          # outer layer over the head
	"torso": [0, 16, 8, 12, 4],
	"armor": [24, 16, 8, 12, 4],       # outer layer over the chest
	"pelvis": [0, 32, 8, 3, 4],
	"uarm": [24, 32, 3, 8, 3],
	"farm": [36, 32, 3, 8, 3],
	"thigh": [48, 32, 4, 8, 4],
	"shin": [0, 44, 4, 8, 4],
}
const SIZE := 64

static var _tex := {}
static var _mats := {}
static var _meshes := {}


## The face rectangles of a part, in pixels: {top, bottom, left, front, right, back} -> Rect2i.
static func faces(part: String) -> Dictionary:
	return box_faces(PARTS[part])


static func box_faces(p: Array) -> Dictionary:
	var u: int = p[0]
	var v: int = p[1]
	var w: int = p[2]
	var h: int = p[3]
	var d: int = p[4]
	return {
		"top": Rect2i(u + d, v, w, d), "bottom": Rect2i(u + d + w, v, w, d),
		"right": Rect2i(u, v + d, d, h), "front": Rect2i(u + d, v + d, w, h),
		"left": Rect2i(u + d + w, v + d, d, h), "back": Rect2i(u + 2 * d + w, v + d, w, h),
	}


## A cuboid mesh of `size` (x across, y up, z deep; the front faces -Z) with its faces mapped to a part.
## limb = true: the part's length runs down -Z instead (the rig's bones point along -Z from the joint).
static func mesh(part: String, size: Vector3, limb := false) -> ArrayMesh:
	var key := "%s|%s|%s" % [part, size, limb]
	if _meshes.has(key):
		return _meshes[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# A limb is modelled upright, then laid along -Z with its top at the joint.
	var basis := Basis(Vector3.RIGHT, -PI * 0.5) if limb else Basis()
	var shift := Vector3(0, 0, -size.y * 0.5) if limb else Vector3.ZERO
	append_box(st, faces(part), size, SIZE, Transform3D(basis, shift))
	var m := st.commit()
	_meshes[key] = m
	return m


## Append an atlas-mapped box to the same surface as other parts on the same joint.
static func append_box(st: SurfaceTool, faces_uv: Dictionary, size: Vector3, atlas: float,
		transform: Transform3D = Transform3D.IDENTITY) -> void:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	# each face: 4 corners (top-left, top-right, bottom-right, bottom-left as seen from outside) + normal
	var quads := {
		"front": [Vector3(-hx, hy, -hz), Vector3(hx, hy, -hz), Vector3(hx, -hy, -hz), Vector3(-hx, -hy, -hz), Vector3(0, 0, -1)],
		"back": [Vector3(hx, hy, hz), Vector3(-hx, hy, hz), Vector3(-hx, -hy, hz), Vector3(hx, -hy, hz), Vector3(0, 0, 1)],
		"right": [Vector3(-hx, hy, hz), Vector3(-hx, hy, -hz), Vector3(-hx, -hy, -hz), Vector3(-hx, -hy, hz), Vector3(-1, 0, 0)],
		"left": [Vector3(hx, hy, -hz), Vector3(hx, hy, hz), Vector3(hx, -hy, hz), Vector3(hx, -hy, -hz), Vector3(1, 0, 0)],
		"top": [Vector3(-hx, hy, hz), Vector3(hx, hy, hz), Vector3(hx, hy, -hz), Vector3(-hx, hy, -hz), Vector3(0, 1, 0)],
		"bottom": [Vector3(-hx, -hy, -hz), Vector3(hx, -hy, -hz), Vector3(hx, -hy, hz), Vector3(-hx, -hy, hz), Vector3(0, -1, 0)],
	}
	for name in quads:
		var q: Array = quads[name]
		var r: Rect2i = faces_uv[name]
		var uv0 := Vector2(r.position) / atlas
		var uv1 := Vector2(r.end) / atlas
		var uvs := [uv0, Vector2(uv1.x, uv0.y), uv1, Vector2(uv0.x, uv1.y)]
		var n: Vector3 = transform.basis * (q[4] as Vector3)
		for i in [0, 2, 1, 0, 3, 2]:          # Godot culls by winding: this order faces outwards
			st.set_normal(n)
			st.set_uv(uvs[i])
			st.add_vertex(transform * (q[i] as Vector3))


## Material for a soldier's look (cached by everything that changes the picture).
static func material(look: Dictionary) -> StandardMaterial3D:
	var key := JSON.stringify(look)
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_texture = ImageTexture.create_from_image(paint(look))
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.5
	m.roughness = 0.9
	_mats[key] = m
	return m


# ------------------------------------------------------------------ painting
## look: {coat (html colour), culture, body (armour tier 0-4), head (helmet tier 0-4), var (0-3), civ (bool)}
static func paint(look: Dictionary) -> Image:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var coat := Color(str(look.get("coat", "#7a6a50")))
	var culture := str(look.get("culture", ""))
	var body := int(look.get("body", 1))
	var head := int(look.get("head", 1))
	var vr := int(look.get("var", 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(look))
	var skin: Color = [Color("e0b994"), Color("d2a77c"), Color("c08e64"), Color("e8c4a0")][vr % 4]
	var hair: Color = [Color("1b1714"), Color("2a201a"), Color("15120f"), Color("3a2c22")][(vr + 1) % 4]
	var trousers := Color("3b3530") if body >= 2 else Color("6a5e4c")
	var steppe: bool = culture in ["rou", "yan"]

	# ---- head: skin, hair (topknot for the Han, braids / shaved crown for the steppe), a face
	var hf := faces("head")
	for k in hf:
		_fill(img, hf[k], skin)
	_fill(img, hf.top, hair)
	_fill(img, hf.back, hair, 0, 0, 8, 6)
	for side in ["left", "right"]:
		_fill(img, hf[side], hair, 0, 0, 8, 3)
		_fill(img, hf[side], hair, 6 if side == "right" else 0, 3, 2, 2)    # hair at the back of the temples
	_fill(img, hf.front, hair, 0, 0, 8, 2)                                  # hairline
	var fr: Rect2i = hf.front
	_px(img, fr, 2, 4, Color("1a1410"))          # eyes
	_px(img, fr, 5, 4, Color("1a1410"))
	_px(img, fr, 1, 3, hair.lightened(0.1))
	_px(img, fr, 2, 3, hair.lightened(0.1))      # brows
	_px(img, fr, 5, 3, hair.lightened(0.1))
	_px(img, fr, 6, 3, hair.lightened(0.1))
	_px(img, fr, 4, 5, skin.darkened(0.15))      # nose
	_fill(img, fr, skin.darkened(0.35), 3, 6, 2, 1)   # mouth
	if vr >= 2 or body >= 3:
		_fill(img, fr, hair, 2, 6, 1, 2)          # moustache / beard for older men
		_fill(img, fr, hair, 5, 6, 1, 2)
		_fill(img, fr, hair, 3, 7, 2, 1)
	if steppe:
		_fill(img, hf.back, hair, 3, 6, 2, 2)     # braid

	# ---- helmet / headgear (outer layer)
	var hl := faces("helm")
	var iron := Color("7c7f82")
	if head >= 2:
		var hc := iron if head >= 3 else iron.darkened(0.15)
		_fill(img, hl.top, hc)
		for side in ["left", "right", "back"]:
			_fill(img, hl[side], hc, 0, 0, 8, 3 if head == 2 else 6)       # 顿项: the neck guard hangs down
		_fill(img, hl.front, hc, 0, 0, 8, 2)
		_fill(img, hl.front, hc.lightened(0.2), 0, 2, 8, 1)               # brow band
		if head >= 3:
			_fill(img, hl.front, hc, 0, 3, 1, 4)                          # cheek guards
			_fill(img, hl.front, hc, 7, 3, 1, 4)
		if head >= 4:
			_fill(img, hl.top, Color("b8a050"), 3, 3, 2, 2)                # gilt finial
			_fill(img, hl.front, Color("b8a050"), 3, 1, 2, 1)
		for side in ["left", "right", "back"]:
			for x in range(0, 8, 2):
				_px(img, hl[side], x, 1, hc.darkened(0.25))                 # rivets
	elif culture == "bandit":
		_fill(img, hl.front, Color("8a2a20"), 0, 1, 8, 1)                  # a red headband
		for side in ["left", "right", "back"]:
			_fill(img, hl[side], Color("8a2a20"), 0, 1, 8, 1)
	elif steppe:
		var fur := Color("5a4632")
		_fill(img, hl.top, fur)
		for side in ["left", "right", "back", "front"]:
			_fill(img, hl[side], fur, 0, 0, 8, 2)
	else:
		var cap := coat.darkened(0.45)                                     # 帻 / cloth cap with a topknot
		_fill(img, hl.top, cap, 2, 2, 4, 4)
		for side in ["left", "right", "back", "front"]:
			_fill(img, hl[side], cap, 0, 0, 8, 1)

	# ---- torso: a cross-collared robe (交领), a belt
	var tf := faces("torso")
	for k in tf:
		_cloth(img, tf[k], coat, vr)
	_fill(img, tf.top, coat.darkened(0.1))
	var tr: Rect2i = tf.front
	for y in 7:
		# the collar crosses from the right shoulder down to the left side of the waist
		_px(img, tr, clampi(1 + y, 0, 7), y, coat.lightened(0.35))
		_px(img, tr, clampi(2 + y, 0, 7), y, coat.darkened(0.25))
	_px(img, tr, 3, 0, skin)
	_px(img, tr, 4, 0, skin)
	var belt := Color("2e241c") if not steppe else Color("5a3a22")
	for k in ["front", "back", "left", "right"]:
		_fill(img, tf[k], belt, 0, 8, tf[k].size.x, 1)
		_fill(img, tf[k], coat.darkened(0.14), 0, 9, tf[k].size.x, 1)
		_fill(img, tf[k], coat.lightened(0.12), 0, 11, tf[k].size.x, 1)      # stitched robe hem
	_px(img, tr, 3, 8, Color("b8a050"))                                    # buckle
	# pelvis: the robe's skirt
	var pf := faces("pelvis")
	for k in pf:
		_cloth(img, pf[k], coat.darkened(0.15), vr + 2)

	# ---- armour (outer layer over the chest)
	var af := faces("armor")
	if body >= 2:
		var lam := Color("6e6658") if body == 2 else Color("767a7e")
		if body == 2:
			lam = Color("6a4a2e")                                           # leather cuirass
		for k in ["front", "back", "left", "right"]:
			var r: Rect2i = af[k]
			_fill(img, af[k], lam, 0, 1, r.size.x, 8 if body >= 3 else 7)
			if body >= 3:
				for y in range(2, 9, 2):
					_fill(img, af[k], lam.darkened(0.3), 0, y, r.size.x, 1)    # rows of lamellae (札甲)
					for x in range((y / 2) % 2, r.size.x, 2):
						_px(img, af[k], x, y - 1, lam.lightened(0.24))
						_px(img, af[k], x, y, Color("716351"))
				_fill(img, af[k], lam.darkened(0.15), 0, 9, r.size.x, 2)        # the armoured skirt
			else:
				_fill(img, af[k], lam.darkened(0.25), 0, 4, r.size.x, 1)
		_fill(img, af.top, lam, 0, 0, 8, 4)
		_fill(img, af.front, lam.darkened(0.35), 0, 1, 8, 1)                    # shoulder straps (裲裆)
		if body >= 4:
			for c in [Vector2i(2, 4), Vector2i(5, 4)]:                         # 明光铠: the bright round chest plates
				_fill(img, af.front, Color("d8dce0"), c.x - 1, c.y - 1, 2, 2)
				_px(img, af.front, c.x - 1, c.y - 1, Color("ffffff"))
			_fill(img, af.front, Color("b8a050"), 3, 8, 2, 1)

	# ---- arms: sleeves, the hand at the end (and shoulder plates over armour)
	for part in ["uarm", "farm"]:
		var ff := faces(part)
		for k in ff:
			_cloth(img, ff[k], coat.darkened(0.08), vr)
		if part == "farm":
			for k in ["front", "back", "left", "right"]:
				_fill(img, ff[k], skin, 0, 6, 3, 2)
				_fill(img, ff[k], coat.lightened(0.25), 0, 5, 3, 1)               # cuff
			_fill(img, ff.bottom, skin)
			if body >= 3:
				for k in ["front", "back", "left", "right"]:
					_fill(img, ff[k], Color("6e6a62"), 0, 1, 3, 3)                # bracers
		elif body >= 3:
			for k in ["front", "back", "left", "right"]:
				_fill(img, ff[k], Color("767a7e"), 0, 0, 3, 4)                    # shoulder guard (披膊)
				_fill(img, ff[k], Color("50545a"), 0, 2, 3, 1)
			_fill(img, ff.top, Color("767a7e"))

	# ---- legs: trousers, puttees (绑腿) for the foot soldier, boots
	var boot := Color("2a221c")
	for part in ["thigh", "shin"]:
		var ff := faces(part)
		for k in ff:
			_cloth(img, ff[k], trousers, vr)
		if part == "shin":
			for k in ["front", "back", "left", "right"]:
				if body <= 2 and not steppe:
					for y in range(0, 5, 2):
						_fill(img, ff[k], trousers.lightened(0.25), 0, y, 4, 1)
				_fill(img, ff[k], boot, 0, 5, 4, 3)
			_fill(img, ff.bottom, boot)
	return img


## Weave and larger folds are painted once into the existing cached atlas.
static func _cloth(img: Image, r: Rect2i, base: Color, variation: int) -> void:
	for y in r.size.y:
		for x in r.size.x:
			var fold := (x + int(y / 5) + variation) % 5
			var c := base.darkened(0.13) if fold == 0 else (base.lightened(0.09) if fold == 1 else base)
			if (x * 3 + y * 7 + variation) % 6 == 0:
				c = c.lightened(0.07)
			img.set_pixelv(r.position + Vector2i(x, y), c)


static func _fill(img: Image, r: Rect2i, c: Color, x := 0, y := 0, w := -1, h := -1) -> void:
	if w < 0:
		w = r.size.x
	if h < 0:
		h = r.size.y
	w = mini(w, r.size.x - x)
	h = mini(h, r.size.y - y)
	if w <= 0 or h <= 0:
		return
	img.fill_rect(Rect2i(r.position.x + x, r.position.y + y, w, h), c)


static func _px(img: Image, r: Rect2i, x: int, y: int, c: Color) -> void:
	if x >= 0 and y >= 0 and x < r.size.x and y < r.size.y:
		img.set_pixel(r.position.x + x, r.position.y + y, c)
