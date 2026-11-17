extends Control
## Campaign map: shader terrain + overlay (rivers, roads, settlements, parties, effects).
## Camera: wheel = zoom at cursor, right/middle drag = pan, WASD/arrows = pan.

signal selection_changed(kind: String, id: String)

const TerrainShader := preload("res://scripts/terrain.gdshader")
const CREAM := Color("efe6d2")
const MUTED := Color("aab4ae")
const GOLD := Color("f2c75c")
const RED := Color("e5534b")
const OUTLINE := Color(0.05, 0.06, 0.07, 0.9)
const RIVER := Color(0.25, 0.48, 0.62)
const ROAD := Color(0.47, 0.36, 0.22, 0.85)
const TRACK := Color(0.47, 0.38, 0.26, 0.5)
const BANDIT_COL := Color("3b2626")
const HUNTER_COL := Color("d9b44a")
const MERC_COL := Color("9b6bd6")
const SIEGE_DAYS_NOTE := "攻城器械"

var font: Font
var state: Dictionary = {}
var world_size := Vector2(1200, 800)
var rivers: Array = []
var roads: Array = []
var terrain_rect: TextureRect
var zoom := 1.0
var offset := Vector2.ZERO
var fit_zoom := 1.0
var sel_kind := ""
var sel_id := ""
var hover_kind := ""
var hover_id := ""
var effects: Array = []
var speeches := {}
var status_text := ""
var hint := ""
var show_territory := true

var _prev := {}
var _cur := {}
var _anim := 1.0
var _anim_dur := 0.3
var _time := 0.0
var _drag := false
var _hits: Array = []
var _mouse := Vector2.ZERO
var _has_map := false
var _fitted := false


func _ready() -> void:
	font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	focus_mode = Control.FOCUS_CLICK
	terrain_rect = TextureRect.new()
	terrain_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	terrain_rect.stretch_mode = TextureRect.STRETCH_SCALE
	terrain_rect.show_behind_parent = true
	add_child(terrain_rect)
	resized.connect(_on_resized)


# ------------------------------------------------------------- data
func set_map(m: Dictionary) -> void:
	world_size = Vector2(float(m.width), float(m.height))
	var g: Array = m.grid
	var gw := int(g[0])
	var gh := int(g[1])
	var himg := Image.create_from_data(gw, gh, false, Image.FORMAT_R8, Marshalls.base64_to_raw(m.heights))
	var bimg := Image.create_from_data(gw, gh, false, Image.FORMAT_R8, Marshalls.base64_to_raw(m.biomes))
	var htex := ImageTexture.create_from_image(himg)
	var mat := ShaderMaterial.new()
	mat.shader = TerrainShader
	mat.set_shader_parameter("heights", htex)
	mat.set_shader_parameter("biomes", ImageTexture.create_from_image(bimg))
	mat.set_shader_parameter("grid", Vector2(gw, gh))
	terrain_rect.texture = htex
	terrain_rect.material = mat
	rivers = m.rivers
	roads = m.roads
	_has_map = true
	fit()


func set_state(s: Dictionary, duration: float) -> void:
	var shown := {}
	for id in _cur:
		shown[id] = party_world_pos(id)
	state = s
	_cur.clear()
	for id in s.parties:
		var p: Dictionary = s.parties[id]
		_cur[id] = Vector2(p.pos[0], p.pos[1])
	_prev = {}
	for id in _cur:
		_prev[id] = shown.get(id, _cur[id])
	_anim = 0.0
	_anim_dur = max(0.05, duration)


func party_world_pos(id: String) -> Vector2:
	var cur: Vector2 = _cur.get(id, Vector2.ZERO)
	var prev: Vector2 = _prev.get(id, cur)
	if prev.distance_to(cur) > 80.0:
		return cur
	return prev.lerp(cur, _anim)


func settlement_pos(id: String) -> Vector2:
	if not state.has("settlements") or not state.settlements.has(id):
		return Vector2.ZERO
	var p: Array = state.settlements[id].pos
	return Vector2(p[0], p[1])


func faction_color(fid) -> Color:
	if fid == null or not state.has("kingdoms") or not state.kingdoms.has(fid):
		return MUTED
	return Color(state.kingdoms[fid].color)


func add_effect(kind: String, world_pos: Vector2, color: Color, dur: float = 1.8) -> void:
	effects.append({"kind": kind, "pos": world_pos, "color": color, "t": 0.0, "dur": dur})


func say(hero_id: String, text: String) -> void:
	speeches[hero_id] = {"text": text, "t": 0.0}


func select(kind: String, id: String) -> void:
	sel_kind = kind
	sel_id = id
	selection_changed.emit(kind, id)


func animating() -> bool:
	return _anim < 1.0


# ----------------------------------------------------------- camera
func _on_resized() -> void:
	if not _has_map or size.x <= 0 or size.y <= 0:
		return
	var rel := zoom / fit_zoom if _fitted else 1.0
	var center := to_world(size * 0.5) if _fitted else world_size * 0.5
	fit_zoom = min(size.x / world_size.x, size.y / world_size.y)
	if not _fitted:
		fit()
	else:
		focus(center, fit_zoom * rel)


func fit() -> void:
	if size.x <= 0 or size.y <= 0:
		return
	fit_zoom = min(size.x / world_size.x, size.y / world_size.y)
	zoom = fit_zoom
	offset = (size - world_size * zoom) * 0.5
	_fitted = true


func focus(world_pos: Vector2, z: float = -1.0) -> void:
	if z > 0:
		zoom = clamp(z, fit_zoom * 0.9, fit_zoom * 9.0)
	offset = size * 0.5 - world_pos * zoom
	_clamp_view()


func to_screen(w: Vector2) -> Vector2:
	return offset + w * zoom


func to_world(p: Vector2) -> Vector2:
	return (p - offset) / zoom


func _clamp_view() -> void:
	var span := world_size * zoom
	var margin := size * 0.5
	offset.x = clamp(offset.x, size.x - span.x - margin.x, margin.x)
	offset.y = clamp(offset.y, size.y - span.y - margin.y, margin.y)


func _scale() -> float:
	return clamp(sqrt(zoom / max(fit_zoom, 0.001)), 0.8, 1.9)


# ----------------------------------------------------------- input
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var before := to_world(mb.position)
			var f := 1.15 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15
			zoom = clamp(zoom * f, fit_zoom * 0.9, fit_zoom * 9.0)
			offset = mb.position - before * zoom
			_clamp_view()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_drag = mb.pressed
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			grab_focus()
			var h := _hit(mb.position)
			if mb.double_click and h[0] != "":
				focus(to_world(mb.position), max(zoom, fit_zoom * 3.0))
			select(h[0], h[1])
			accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_mouse = mm.position
		if _drag:
			offset += mm.relative
			_clamp_view()
		var h := _hit(mm.position)
		hover_kind = h[0]
		hover_id = h[1]
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if h[0] != "" else Control.CURSOR_ARROW


func _hit(p: Vector2) -> Array:
	for i in range(_hits.size() - 1, -1, -1):
		var r: Rect2 = _hits[i].rect
		if r.has_point(p):
			return [_hits[i].kind, _hits[i].id]
	return ["", ""]


func _process(delta: float) -> void:
	_time += delta
	if _anim < 1.0:
		_anim = min(1.0, _anim + delta / _anim_dur)
	for e in effects:
		e.t += delta
	effects = effects.filter(func(e): return e.t < e.dur)
	for id in speeches.keys():
		speeches[id].t += delta
		if speeches[id].t > 6.0:
			speeches.erase(id)
	var focus_owner := get_viewport().gui_get_focus_owner()
	var typing := focus_owner is LineEdit or focus_owner is SpinBox or focus_owner is TextEdit
	if not typing:
		var pan := Vector2.ZERO
		if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
			pan.x += 1
		if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
			pan.x -= 1
		if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
			pan.y += 1
		if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
			pan.y -= 1
		if pan != Vector2.ZERO:
			offset += pan * 600.0 * delta
			_clamp_view()
	terrain_rect.position = offset
	terrain_rect.size = world_size * zoom
	queue_redraw()


# ------------------------------------------------------------ draw
func _text(pos: Vector2, text: String, fsize: int, color: Color, center := true) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
	var p := pos - Vector2(w * 0.5, 0) if center else pos
	draw_string_outline(font, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, 4, OUTLINE)
	draw_string(font, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, color)


func _draw() -> void:
	_hits.clear()
	if not _has_map:
		draw_rect(Rect2(Vector2.ZERO, size), Color("10171b"))
		_text(size * 0.5, status_text if status_text != "" else "正在加载地图…", 20, CREAM)
		return
	if state.is_empty():
		return
	var s := _scale()
	if show_territory:
		_draw_territory()
	_draw_lines(rivers, true)
	_draw_lines(roads, false)
	_draw_route()
	for sid in state.settlements:
		_draw_settlement(sid, s)
	for pid in state.parties:
		_draw_party(pid, s)
	_draw_effects()
	_draw_speeches()
	_draw_tooltip()
	if hint != "":
		_text(Vector2(12, size.y - 12), hint, 12, MUTED, false)
	if status_text != "":
		_text(Vector2(size.x * 0.5, 28), status_text, 16, GOLD)


func _draw_territory() -> void:
	for st in state.settlements.values():
		if st.kind != "town" and st.kind != "castle":
			continue
		var c := faction_color(st.faction)
		var p := to_screen(Vector2(st.pos[0], st.pos[1]))
		draw_circle(p, 70.0 * zoom, Color(c, 0.07))
		draw_arc(p, 70.0 * zoom, 0, TAU, 48, Color(c, 0.18), 1.5, true)


func _draw_lines(lines: Array, is_river: bool) -> void:
	var view := Rect2(Vector2(-50, -50), size + Vector2(100, 100))
	for l in lines:
		var pts: Array = l.points
		var poly := PackedVector2Array()
		var visible := false
		for pt in pts:
			var sp := to_screen(Vector2(pt[0], pt[1]))
			poly.append(sp)
			if not visible and view.has_point(sp):
				visible = true
		if not visible or poly.size() < 2:
			continue
		if is_river:
			var wdt: float = float(l.width) * 0.7 * zoom
			draw_polyline(poly, RIVER, max(1.2, wdt), true)
		else:
			var main: bool = l.kind == "road"
			draw_polyline(poly, ROAD if main else TRACK, max(1.0, (1.6 if main else 1.0) * min(zoom, 2.5)), true)


func _draw_route() -> void:
	if sel_kind != "party" or not state.parties.has(sel_id):
		return
	var p: Dictionary = state.parties[sel_id]
	if p.target_pos == null or p.inside != null:
		return
	var a := to_screen(party_world_pos(sel_id))
	var b := to_screen(Vector2(p.target_pos[0], p.target_pos[1]))
	var c := GOLD if p.mode != "flee" else RED
	draw_dashed_line(a, b, Color(c, 0.85), 2.0, 7.0, true)
	draw_circle(b, 4, Color(c, 0.85))


func _draw_settlement(sid: String, s: float) -> void:
	var st: Dictionary = state.settlements[sid]
	var kind: String = st.kind
	if kind == "hideout" and not st.active:
		return
	var p := to_screen(Vector2(st.pos[0], st.pos[1]))
	if not Rect2(Vector2(-60, -60), size + Vector2(120, 120)).has_point(p):
		return
	var c := faction_color(st.faction)
	var sel := sel_kind == "settlement" and sel_id == sid
	var hov := hover_kind == "settlement" and hover_id == sid
	var r := 9.0 * s
	if kind == "town":
		_icon_town(p, r * 1.25, c)
	elif kind == "castle":
		_icon_castle(p, r, c)
	elif kind == "village":
		r = 5.5 * s
		_icon_village(p, r, c, bool(st.raided))
	else:
		r = 6.5 * s
		_icon_hideout(p, r)
	if st.siege != null:
		var prog: float = float(st.siege.progress)
		draw_arc(p, r + 9 + 2 * sin(_time * 5.0), 0, TAU, 40, Color(RED, 0.8), 2.5, true)
		draw_arc(p, r + 14, -PI / 2, -PI / 2 + TAU * prog, 40, GOLD, 3.0, true)
	if sel or hov:
		draw_arc(p, r + 6, 0, TAU, 32, Color(GOLD, 1.0 if sel else 0.6), 2.0, true)
	var show_name := kind == "town" or kind == "castle" or sel or hov
	if kind == "village" and zoom > fit_zoom * 1.7:
		show_name = true
	if kind == "hideout" and zoom > fit_zoom * 1.4:
		show_name = true
	if show_name:
		var fs := int((13 if kind == "town" else 12 if kind == "castle" else 11) * s)
		_text(p + Vector2(0, r + fs + 2), st.name, fs, CREAM if kind != "hideout" else Color("e09a8a"))
	_hits.append({"kind": "settlement", "id": sid, "rect": Rect2(p - Vector2(r + 4, r + 4), Vector2(2 * r + 8, 2 * r + 8))})


func _icon_town(p: Vector2, r: float, c: Color) -> void:
	var body := Rect2(p - Vector2(r, r * 0.55), Vector2(2 * r, r * 1.2))
	draw_rect(body.grow(1.5), OUTLINE)
	draw_rect(body, c.darkened(0.15))
	for i in 4:
		var x := p.x - r + i * (2 * r / 3.0) - r * 0.18
		draw_rect(Rect2(x, p.y - r * 0.85, r * 0.36, r * 0.32), OUTLINE)
		draw_rect(Rect2(x + 1, p.y - r * 0.85 + 1, r * 0.36 - 2, r * 0.32 - 1), c.lightened(0.15))
	draw_rect(Rect2(p.x - r * 0.22, p.y + r * 0.05, r * 0.44, r * 0.6), OUTLINE)
	draw_rect(body, CREAM, false, 1.5)


func _icon_castle(p: Vector2, r: float, c: Color) -> void:
	var keep := Rect2(p - Vector2(r * 0.6, r * 1.0), Vector2(r * 1.2, r * 1.7))
	draw_rect(keep.grow(1.5), OUTLINE)
	draw_rect(keep, c.darkened(0.1))
	for i in 3:
		draw_rect(Rect2(p.x - r * 0.6 + i * r * 0.45, p.y - r * 1.3, r * 0.3, r * 0.35), c.lightened(0.1))
	draw_rect(keep, CREAM, false, 1.3)


func _icon_village(p: Vector2, r: float, c: Color, raided: bool) -> void:
	for dx in [-r * 0.7, r * 0.7]:
		var q := p + Vector2(dx, 0)
		draw_rect(Rect2(q - Vector2(r * 0.55, 0), Vector2(r * 1.1, r * 0.8)), Color("d8cdb4") if not raided else Color("5a5450"))
		draw_colored_polygon(PackedVector2Array([q + Vector2(-r * 0.75, 0), q + Vector2(0, -r * 0.8), q + Vector2(r * 0.75, 0)]),
			c.darkened(0.2) if not raided else Color("3a3330"))
	if raided:
		for i in 3:
			var t := fmod(_time * 0.6 + i * 0.33, 1.0)
			draw_circle(p + Vector2(sin(i * 2.1) * 3, -r - t * 14), 2.5 + t * 3, Color(0.35, 0.35, 0.35, 0.5 * (1 - t)))


func _icon_hideout(p: Vector2, r: float) -> void:
	draw_colored_polygon(PackedVector2Array([p + Vector2(-r, r * 0.7), p + Vector2(0, -r), p + Vector2(r, r * 0.7)]), BANDIT_COL)
	draw_polyline(PackedVector2Array([p + Vector2(-r, r * 0.7), p + Vector2(0, -r), p + Vector2(r, r * 0.7), p + Vector2(-r, r * 0.7)]), RED, 1.5)
	draw_circle(p + Vector2(0, r * 0.2), r * 0.22, RED)


func _party_color(p: Dictionary) -> Color:
	match p.kind:
		"bandit":
			return BANDIT_COL
		"hunter":
			return HUNTER_COL
		"merc":
			return MERC_COL if p.contract == null else faction_color(p.contract)
	return faction_color(p.faction)


func _draw_party(pid: String, s: float) -> void:
	var p: Dictionary = state.parties[pid]
	if p.inside != null:
		return
	# army members marching with their leader are drawn as part of the leader's banner
	if p.army != null and state.armies.has(p.army) and p.hero != null and state.armies[p.army].leader != p.hero:
		var lp = state.heroes[state.armies[p.army].leader].party
		if lp != null and state.parties.has(lp) and party_world_pos(lp).distance_to(party_world_pos(pid)) < 10.0:
			return
	var pos := to_screen(party_world_pos(pid))
	if not Rect2(Vector2(-40, -40), size + Vector2(80, 80)).has_point(pos):
		return
	var c := _party_color(p)
	var sel := sel_kind == "party" and sel_id == pid
	var hov := hover_kind == "party" and hover_id == pid
	var kind: String = p.kind
	if sel or hov:
		draw_circle(pos, 10 * s, Color(GOLD, 0.35 if sel else 0.2))
	var hit := Rect2(pos - Vector2(7, 7) * s, Vector2(14, 14) * s)
	if kind == "lord" or kind == "merc":
		var big: bool = p.army != null and state.armies.has(p.army) and state.armies[p.army].leader == p.hero
		var hgt := (24.0 if big else 19.0) * s
		var w := (15.0 if big else 12.0) * s
		draw_line(pos + Vector2(0, 2), pos + Vector2(0, -hgt), OUTLINE, 3.5)
		draw_line(pos + Vector2(0, 2), pos + Vector2(0, -hgt), CREAM, 1.6)
		var flag := PackedVector2Array([pos + Vector2(1, -hgt), pos + Vector2(w, -hgt + w * 0.35), pos + Vector2(1, -hgt + w * 0.7)])
		draw_colored_polygon(flag, c)
		flag.append(flag[0])
		draw_polyline(flag, MERC_COL if kind == "merc" else OUTLINE, 1.5)
		if p.hero != null and state.kingdoms.has(p.faction) and state.kingdoms[p.faction].ruler == p.hero:
			draw_circle(pos + Vector2(0, -hgt - 2), 3.0 * s, GOLD)
		var size_txt := str(int(p.size))
		if big:
			size_txt = "军团 %d" % _army_size(p.army)
		if p.mode == "siege":
			size_txt += " 围城"
		elif p.mode == "raid":
			size_txt += " 劫掠"
			draw_circle(pos + Vector2(4, 4), 3 + 2 * sin(_time * 9.0), Color(1.0, 0.5, 0.1, 0.8))
		elif p.mode == "flee":
			size_txt += " 撤退"
		_text(pos + Vector2(w + 3, -hgt + w * 0.5), size_txt, int(11 * s), CREAM, false)
		if (zoom > fit_zoom * 1.6 or sel or hov) and p.hero != null:
			_text(pos + Vector2(0, 14 * s), state.heroes[p.hero].name, int(11 * s), Color(c.lightened(0.45)))
		hit = Rect2(pos + Vector2(-5, -hgt - 2), Vector2(w + 30, hgt + 8))
	elif kind == "caravan":
		var r := 5.0 * s
		draw_rect(Rect2(pos - Vector2(r, r * 0.7), Vector2(2 * r, r * 1.4)).grow(1.5), OUTLINE)
		draw_rect(Rect2(pos - Vector2(r, r * 0.7), Vector2(2 * r, r * 1.4)), Color("a77b46"))
		draw_rect(Rect2(pos - Vector2(r, r * 0.7), Vector2(2 * r, r * 0.4)), c)
	elif kind == "villager":
		draw_circle(pos, 3.6 * s, OUTLINE)
		draw_circle(pos, 2.6 * s, Color("e8dfc8"))
	elif kind == "bandit":
		var r := 5.5 * s
		var dia := PackedVector2Array([pos + Vector2(0, -r), pos + Vector2(r, 0), pos + Vector2(0, r), pos + Vector2(-r, 0)])
		draw_colored_polygon(dia, BANDIT_COL)
		dia.append(dia[0])
		draw_polyline(dia, RED, 1.6)
		if zoom > fit_zoom * 1.4 or hov:
			_text(pos + Vector2(r + 2, 4), str(int(p.size)), int(10 * s), Color("e09a8a"), false)
	elif kind == "hunter":
		var r := 5.5 * s
		draw_colored_polygon(PackedVector2Array([pos + Vector2(0, -r), pos + Vector2(r, r * 0.8), pos + Vector2(-r, r * 0.8)]), HUNTER_COL)
		draw_polyline(PackedVector2Array([pos + Vector2(0, -r), pos + Vector2(r, r * 0.8), pos + Vector2(-r, r * 0.8), pos + Vector2(0, -r)]), OUTLINE, 1.2)
	_hits.append({"kind": "party", "id": pid, "rect": hit})


func _army_size(aid: String) -> int:
	var a: Dictionary = state.armies[aid]
	var n := 0
	var members: Array = [a.leader] + a.members
	for hid in members:
		var pid = state.heroes[hid].party
		if pid != null and state.parties.has(pid):
			n += int(state.parties[pid].size)
	return n


func _draw_effects() -> void:
	for e in effects:
		var p := to_screen(e.pos)
		var k: float = e.t / e.dur
		var a := 1.0 - k
		var col: Color = e.color
		match e.kind:
			"battle":
				draw_circle(p, 6 + 26 * k, Color(col, 0.3 * a))
				draw_arc(p, 8 + 30 * k, 0, TAU, 32, Color(col, a), 2.5, true)
				_text(p + Vector2(0, -24 - 10 * k), "会战", 13, Color(col, a))
			"conquest", "rebellion":
				for i in 3:
					draw_arc(p, 14 + 40 * k + i * 8, 0, TAU, 40, Color(col, a * (1.0 - i * 0.3)), 3.0, true)
				_text(p + Vector2(0, -32 - 10 * k), "易主" if e.kind == "conquest" else "起义", 15, Color(GOLD, a))
			"capture":
				_text(p + Vector2(0, -26 - 12 * k), "被俘", 13, Color(col, a))
			"siege":
				draw_arc(p, 40 - 18 * k, 0, TAU, 32, Color(RED, a), 2.0, true)
			"raid":
				draw_circle(p, 8 + 10 * k, Color(1.0, 0.45, 0.1, 0.5 * a))
			_:
				draw_arc(p, 8 + 26 * k, 0, TAU, 32, Color(col, a), 2.0, true)


func _draw_speeches() -> void:
	for hid in speeches:
		if not state.heroes.has(hid):
			continue
		var pid = state.heroes[hid].party
		if pid == null or not state.parties.has(pid) or state.parties[pid].inside != null:
			continue
		var sp: Dictionary = speeches[hid]
		var a: float = clamp(6.0 - float(sp.t), 0.0, 1.0)
		var text: String = sp.text
		var fsize := 13
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
		var p := to_screen(party_world_pos(pid)) + Vector2(8, -40)
		var rect := Rect2(p - Vector2(w * 0.5 + 8, 18), Vector2(w + 16, 24))
		rect.position.x = clamp(rect.position.x, 4, size.x - rect.size.x - 4)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(CREAM, 0.93 * a)
		sb.set_corner_radius_all(6)
		draw_style_box(sb, rect)
		draw_string(font, rect.position + Vector2(8, 17), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0.1, 0.1, 0.1, a))


func _draw_tooltip() -> void:
	if hover_kind == "":
		return
	var lines: Array[String] = []
	if hover_kind == "party" and state.parties.has(hover_id):
		var p: Dictionary = state.parties[hover_id]
		var who: String = p.name
		if p.hero != null:
			who = state.heroes[p.hero].name
		lines.append(who)
		var kname: String = {"lord": "领主部队", "caravan": "商队", "villager": "村民", "bandit": "土匪", "hunter": "赏金猎人", "merc": "佣兵团"}.get(p.kind, p.kind)
		var fac := ""
		if p.faction != null and state.kingdoms.has(p.faction):
			fac = " · " + str(state.kingdoms[p.faction].name)
		lines.append("%s%s · %d人（伤%d）· 战力%d" % [kname, fac, int(p.size), int(p.wounded), int(p.power)])
		if p.order != null and p.order.has("label"):
			lines.append(str(p.order.label))
	elif hover_kind == "settlement" and state.settlements.has(hover_id):
		var st: Dictionary = state.settlements[hover_id]
		lines.append(st.name)
		if st.kind == "hideout":
			lines.append("匪巢 · 约%d人" % int(st.garrison_size))
		elif st.kind == "village":
			lines.append("村庄 · 繁荣%d%s" % [int(st.prosperity), " · 遭劫掠" if st.raided else ""])
		else:
			var fac := ""
			if st.faction != null and state.kingdoms.has(st.faction):
				fac = str(state.kingdoms[st.faction].name)
			lines.append("%s · %s · 守军%d · 民心%d" % ["城镇" if st.kind == "town" else "城堡", fac, int(st.garrison_size), int(st.loyalty)])
	if lines.is_empty():
		return
	var w := 0.0
	for l in lines:
		w = max(w, font.get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x)
	var rect := Rect2(_mouse + Vector2(16, 16), Vector2(w + 16, lines.size() * 18 + 10))
	if rect.end.x > size.x:
		rect.position.x = _mouse.x - rect.size.x - 10
	if rect.end.y > size.y:
		rect.position.y = _mouse.y - rect.size.y - 10
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.12, 0.92)
	sb.border_color = Color(1, 1, 1, 0.15)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	draw_style_box(sb, rect)
	for i in lines.size():
		draw_string(font, rect.position + Vector2(8, 20 + i * 18), lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, GOLD if i == 0 else CREAM)
