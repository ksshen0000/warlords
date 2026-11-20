extends Control
## Campaign map: shader terrain + overlay (rivers, roads, settlements, parties, effects).
## Camera: wheel = zoom at cursor, right/middle drag = pan, WASD/arrows = pan.

signal selection_changed(kind: String, id: String)
signal map_clicked(world_pos: Vector2, kind: String, id: String, shift: bool)

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
const BANDIT_SHIRT := Color("6e3b2e")
const HORSE_COLS := [Color("7a4f2e"), Color("5a3b24"), Color("9c7a55"), Color("3a3330"), Color("b9b2a4"), Color("8c6239")]
const SIEGE_DAYS_NOTE := "攻城器械"
const KIND_NAMES := {"town": "城", "castle": "关塞", "village": "村落", "hideout": "匪巢"}

var font: Font
var state: Dictionary = {}
var world_size := Vector2(1200, 800)
var rivers: Array = []
var roads: Array = []
var fords: Array = []        # ferry crossings over the great river
var terrain_rect: TextureRect
var zoom := 1.0
const MAX_ZOOM := 16.0       # closest zoom, in close_zoom() units
## Screen mapping only (game distances unchanged): how big the land is drawn next to the icons. At every
## "close" zoom (following your party, F, the default views) the terrain is MAP_SCALE times larger while
## settlements and parties keep their pixel size — more room around them. The whole-map view is unaffected.
const MAP_SCALE := 2.0
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
var follow_id := ""          # party the camera keeps centred (the player while travelling)
var player_id := "player"

var _prev := {}
var _cur := {}
var _anim := 1.0
var _anim_dur := 0.3
var _time := 0.0
var _drag := false
var _hits: Array = []
var _mouse := Vector2.ZERO
var settings: Node = null   # settings.gd: edge scrolling
var time_flowing := false   # set by main: legs/hooves animate only while game time passes
var _facing := {}           # party id -> +1 (east) / -1 (west)
var _show_names := false    # hold Alt: show every party's name (Bannerlord)
var _has_map := false
var _parked := {}           # party id -> settlement id: inside the walls / camped at the gate (hidden, listed on hover)
var _at := {}               # settlement id -> [party ids]
var vision := 0.0            # player's sight radius in world units (0 = see everything)
var my_kingdom = null        # player's kingdom id: its settlements are always known
var my_fiefs: Array = []
var known_hideouts: Array = []   # hideouts your scouts have found (others are not drawn)
var _last_seen := {}             # party id -> {"pos": Vector2, "day": int}: where you last saw it
var pin_hover := ""          # "settlement:id" — screenshot/test aid: keeps that tooltip open
const PARK_R := 5.0         # world units: a stationary party this close to a settlement counts as being there
var _fitted := false


func _ready() -> void:
	font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	focus_mode = Control.FOCUS_CLICK
	# open sea beyond the map edge, so any window aspect ratio shows ocean instead of black bars
	var sea := ColorRect.new()
	sea.color = Color8(27, 59, 92)
	sea.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sea.show_behind_parent = true
	sea.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(sea)
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
	fords = m.get("fords", [])
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
		var dx: float = _cur[id].x - _prev[id].x
		if absf(dx) > 0.05:
			_facing[id] = signf(dx)
	_anim = 0.0
	_anim_dur = max(0.05, duration)
	_update_parked()
	for id in _cur:
		if party_known(id):
			_last_seen[id] = {"pos": _cur[id], "day": int(s.get("day", 0))}
	for id in _last_seen.keys():
		if not s.parties.has(id):
			_last_seen.erase(id)


## Like Warband: a party that is in a town (or standing still at its gate, or resting at a
## village / hideout) is not drawn on the map; hovering the settlement lists it instead.
## The player's own party always stays visible.
func _update_parked() -> void:
	_parked.clear()
	_at.clear()
	for pid in state.parties:
		var p: Dictionary = state.parties[pid]
		if pid == player_id or p.kind == "player":
			continue
		var sid = p.inside
		if sid != null and not state.settlements.has(sid):
			_parked[pid] = ""            # captive / limbo: hidden, but not listed anywhere
			continue
		if sid == null:
			if p.mode in ["siege", "raid", "chase", "flee"]:
				continue
			if (_prev.get(pid, _cur[pid]) as Vector2).distance_to(_cur[pid]) > 0.05:
				continue
			var best := PARK_R
			for s_id in state.settlements:
				var st: Dictionary = state.settlements[s_id]
				if st.kind == "hideout" and not st.active:
					continue
				# camping at the gate only counts for the owner's own people (a foreign army
				# loitering outside the walls stays on the map); bandits rest at their hideouts
				if st.kind == "hideout":
					if p.kind != "bandit":
						continue
				elif p.faction == null or p.faction != st.faction:
					continue
				var d: float = (_cur[pid] as Vector2).distance_to(Vector2(st.pos[0], st.pos[1]))
				if d < best:
					best = d
					sid = s_id
		if sid == null:
			continue
		_parked[pid] = sid
		if not _at.has(sid):
			_at[sid] = []
		_at[sid].append(pid)


func party_world_pos(id: String) -> Vector2:
	var cur: Vector2 = _cur.get(id, Vector2.ZERO)
	var prev: Vector2 = _prev.get(id, cur)
	if prev.distance_to(cur) > 80.0:
		return cur
	return prev.lerp(cur, _anim)


## Fog of war (like Warband's Spotting): other parties are drawn only inside this radius.
func sees(world_pos: Vector2) -> bool:
	if vision <= 0.0 or not _cur.has(player_id):
		return true
	return party_world_pos(player_id).distance_to(world_pos) <= vision


## What your scouts can tell about a party right now: it is in sight (or inside a settlement you
## can see into), it is your own realm's (their reports reach you), or it is your own party.
func party_known(pid: String) -> bool:
	if vision <= 0.0 or pid == player_id or not state.parties.has(pid):
		return true
	var p: Dictionary = state.parties[pid]
	if my_kingdom != null and p.faction == my_kingdom:
		return true
	# where a ruler holds court is public knowledge (you have to be able to find a king to swear to him)
	if p.get("hero") != null and state.kingdoms.has(p.faction) and state.kingdoms[p.faction].ruler == p.hero:
		return true
	if _parked.has(pid):
		return _parked[pid] != "" and knows_settlement(_parked[pid])
	return sees(_cur.get(pid, Vector2.ZERO))


## "Last seen near X on day N" for a party that is out of sight (or "" if never seen).
func last_seen_text(pid: String) -> String:
	if not _last_seen.has(pid):
		return ""
	var ls: Dictionary = _last_seen[pid]
	var best := ""
	var bd := 1e9
	for sid in state.settlements:
		var st: Dictionary = state.settlements[sid]
		if st.kind == "hideout":
			continue
		var d: float = (ls.pos as Vector2).distance_to(Vector2(st.pos[0], st.pos[1]))
		if d < bd:
			bd = d
			best = str(st.name)
	return "最后见于第 %d 天，%s附近" % [int(ls.day), best]


## Settlements are always on the map, but their defences and who is inside are only known
## within sight — or for the player's own kingdom / fiefs.
func knows_settlement(sid: String) -> bool:
	if not state.has("settlements") or not state.settlements.has(sid):
		return false
	var st: Dictionary = state.settlements[sid]
	if my_fiefs.has(sid) or (my_kingdom != null and st.faction == my_kingdom):
		return true
	return sees(settlement_pos(sid))


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
	# a skirmish beyond sight goes unnoticed; a city changing hands is news everyone hears
	if not kind in ["conquest", "rebellion", "siege"] and not sees(world_pos):
		return
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
		zoom = clamp(z, fit_zoom * 0.9, close_zoom(MAX_ZOOM))
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
	return clamp(sqrt(zoom / max(close_zoom(1.0), 0.001)), 0.7, 2.4)


## Zoom levels are tuned for a 1200-unit-wide world; a bigger world (more km on the same screen)
## needs proportionally more zoom to show the same detail.
func close_zoom(k: float) -> float:
	return fit_zoom * k * maxf(1.0, world_size.x / 1200.0) * MAP_SCALE


# ----------------------------------------------------------- input
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var before := to_world(mb.position)
			var f := 1.15 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15
			zoom = clamp(zoom * f, fit_zoom * 0.9, close_zoom(MAX_ZOOM))
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
				focus(to_world(mb.position), max(zoom, close_zoom(3.0)))
			map_clicked.emit(to_world(mb.position), h[0], h[1], mb.shift_pressed)
			accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_mouse = mm.position
		if _drag:
			offset += mm.relative
			follow_id = ""
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
	_show_names = Input.is_key_pressed(KEY_ALT) and not typing
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
		if settings != null and not _drag:
			pan += settings.edge_pan()
		if pan != Vector2.ZERO:
			offset += pan * 600.0 * delta
			follow_id = ""
			_clamp_view()
	if follow_id != "" and _cur.has(follow_id):
		var want := size * 0.5 - party_world_pos(follow_id) * zoom
		offset = offset.lerp(want, clamp(delta * 4.0, 0.0, 1.0))
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
	_draw_fords()
	_draw_fog()
	_draw_route()
	for sid in state.settlements:
		_draw_settlement(sid, s)
	# painter's order: parties further south (lower on screen) are drawn in front
	var order: Array = state.parties.keys()
	order.sort_custom(func(x, y): return _cur.get(x, Vector2.ZERO).y < _cur.get(y, Vector2.ZERO).y)
	for pid in order:
		_draw_party(pid, s)
	_draw_effects()
	_draw_speeches()
	if pin_hover != "":
		var hp := pin_hover.split(":")
		hover_kind = hp[0]
		hover_id = hp[1]
		_mouse = to_screen(settlement_pos(hp[1]))
	_draw_tooltip()
	if hint != "":
		_text(Vector2(12, size.y - 12), hint, 12, MUTED, false)
	if status_text != "":
		_text(Vector2(size.x * 0.5, 28), status_text, 16, GOLD)


## Ferry crossings: the only places to cross the great river.
## Dims the world beyond the player's sight radius, with a soft edge.
func _draw_fog() -> void:
	if vision <= 0.0 or not _cur.has(player_id):
		return
	var c := to_screen(party_world_pos(player_id))
	var r := vision * zoom
	var far := 0.0
	for corner in [Vector2.ZERO, Vector2(size.x, 0), size, Vector2(0, size.y)]:
		far = maxf(far, c.distance_to(corner))
	if far <= r:
		return
	var edge := clampf(r * 0.12, 4.0, 18.0)
	for i in 4:      # soft edge: four thin bands fading in
		var w := edge / 4.0
		draw_arc(c, r - edge + w * (i + 0.5), 0, TAU, 128, Color(0.03, 0.05, 0.07, 0.3 * (i + 1) / 5.0), w + 0.5)
	var wide := far - r + 4.0
	draw_arc(c, r + wide * 0.5, 0, TAU, 128, Color(0.03, 0.05, 0.07, 0.3), wide)
	draw_arc(c, r, 0, TAU, 128, Color(GOLD, 0.22), 1.2, true)


func _draw_fords() -> void:
	var s := _scale()
	for f in fords:
		var p := to_screen(Vector2(f[0], f[1]))
		if not Rect2(Vector2(-30, -30), size + Vector2(60, 60)).has_point(p):
			continue
		var k := s * 1.1
		# ferry boat with a little sail
		var hull := PackedVector2Array([p + Vector2(-7, -1) * k, p + Vector2(7, -1) * k,
			p + Vector2(5, 3) * k, p + Vector2(-5, 3) * k])
		var ring := hull.duplicate()
		ring.append(hull[0])
		draw_polyline(ring, OUTLINE, 2.0 * k, true)
		draw_colored_polygon(hull, Color("8a5a32"))
		draw_line(p + Vector2(0, -1) * k, p + Vector2(0, -11) * k, OUTLINE, 1.6 * k)
		draw_colored_polygon(PackedVector2Array([p + Vector2(0.5, -10.5) * k, p + Vector2(6, -3) * k, p + Vector2(0.5, -3) * k]), CREAM)
		if zoom > close_zoom(1.5):
			_text(p + Vector2(0, 15) * k, "渡口", int(11 * s), Color("cfe3f0"))


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
			_draw_river(l, poly)
		else:
			var main: bool = l.kind == "road"
			draw_polyline(poly, ROAD if main else TRACK, max(1.0, (1.6 if main else 1.0) * min(zoom, 2.5)), true)


## Rivers share one look with the terrain shader's water (terrain.gdshader): the shallow-water blue with a
## pale rim like its foam along the shore — the thin upper reaches and the open lower stretches of the great
## rivers alike (the open stretch is drawn over its water cells, with gaps at the fords for the sandbars).
## Points run from the source to the mouth; the width grows evenly along the way.
const RIVER_CORE := Color(0.22, 0.42, 0.55)
const RIVER_RIM := Color(0.50, 0.63, 0.68)


func _draw_river(l: Dictionary, poly: PackedVector2Array) -> void:
	var pts: Array = l.points
	var w0 := float(l.width)
	var w1 := float(l.get("width_end", l.width))
	var gaps: Array = l.get("gaps", [])
	var gap_r := float(l.get("gap_r", 0.0))
	var total := 0.0
	for i in range(1, poly.size()):
		total += poly[i - 1].distance_to(poly[i])
	if total <= 0.0:
		return
	# segments to draw: [a, b, width px]
	var segs: Array = []
	var run := 0.0
	for i in range(1, poly.size()):
		var a := poly[i - 1]
		var b := poly[i]
		run += a.distance_to(b)
		if not gaps.is_empty():
			var mid := (Vector2(pts[i - 1][0], pts[i - 1][1]) + Vector2(pts[i][0], pts[i][1])) * 0.5
			var skip := false
			for g in gaps:
				if mid.distance_to(Vector2(g[0], g[1])) < gap_r:
					skip = true
					break
			if skip:
				continue
		segs.append([a, b, maxf(1.2, lerpf(w0, w1, run / total) * 0.7 * zoom)])
	var rim := maxf(1.0, 0.9 * minf(zoom, 3.0))         # the pale shore line on each bank
	for pass_i in 2:
		for sg in segs:
			var w: float = sg[2] + (2.0 * rim if pass_i == 0 else 0.0)
			var c := RIVER_RIM if pass_i == 0 else RIVER_CORE
			draw_line(sg[0], sg[1], c, w, true)
			if w > 3.0:
				draw_circle(sg[1], w * 0.5, c)
				draw_circle(sg[0], w * 0.5, c)


func _draw_route() -> void:
	if state.parties.has(player_id):
		var pp: Dictionary = state.parties[player_id]
		if pp.target_pos != null and pp.inside == null:
			var a0 := to_screen(party_world_pos(player_id))
			var b0 := to_screen(Vector2(pp.target_pos[0], pp.target_pos[1]))
			draw_dashed_line(a0, b0, Color(0.55, 1.0, 0.6, 0.9), 2.5, 8.0, true)
			draw_arc(b0, 6, 0, TAU, 20, Color(0.55, 1.0, 0.6, 0.9), 2.0, true)
	if sel_kind != "party" or not state.parties.has(sel_id) or sel_id == player_id:
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
	if kind == "hideout" and (not st.active or (vision > 0.0 and not known_hideouts.has(sid))):
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
	if kind == "village" and zoom > close_zoom(1.7):
		show_name = true
	if kind == "hideout" and zoom > close_zoom(1.4):
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
	if _parked.has(pid):
		return
	if pid != player_id and not sees(party_world_pos(pid)):
		return
	# army members marching with their leader are drawn as part of the leader's column
	if p.army != null and state.armies.has(p.army) and p.hero != null and state.armies[p.army].leader != p.hero:
		var lp = state.heroes[state.armies[p.army].leader].party
		if lp != null and state.parties.has(lp) and party_world_pos(lp).distance_to(party_world_pos(pid)) < 10.0:
			return
	var pos := to_screen(party_world_pos(pid))
	if not Rect2(Vector2(-60, -60), size + Vector2(120, 120)).has_point(pos):
		return
	var c := _party_color(p)
	var sel := sel_kind == "party" and sel_id == pid
	var hov := hover_kind == "party" and hover_id == pid
	var kind: String = p.kind
	var face: float = _facing.get(pid, 1.0)
	var moving := _is_moving(pid, p)
	var ph := _time * 11.0 + float(pid.hash() % 97)
	var k := s * 1.1
	var horse: Color = HORSE_COLS[absi(pid.hash()) % HORSE_COLS.size()]
	var label := ""
	var label_col := CREAM
	var top := 22.0 * k

	# ground shadow + selection ring (like the M&B map party marker)
	draw_set_transform(pos, 0.0, Vector2(1.0, 0.4))
	draw_circle(Vector2.ZERO, 11.0 * k, Color(0, 0, 0, 0.28))
	if sel or hov:
		draw_arc(Vector2.ZERO, 14.0 * k, 0, TAU, 32, Color(GOLD, 0.9 if sel else 0.5), 2.5)
	if kind == "player":
		draw_arc(Vector2.ZERO, 17.0 * k, 0, TAU, 32, Color(0.55, 1.0, 0.6, 0.35 + 0.2 * sin(_time * 3.0)), 2.5)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	match kind:
		"player":
			var bc := Color.WHITE if p.side == "__player" else faction_color(p.side)
			_draw_escort(pos, k, face, ph, moving, horse, bc, int(p.size))
			_draw_rider(pos, k * 1.1, face, ph, moving, horse, Color("3f6fb0"), bc, 1.25, GOLD)
			top = 46.0 * k
			label = ("你 %d" % int(p.size)) if (hov or sel or _show_names) else ""
			label_col = GOLD
		"lord", "merc":
			var big: bool = p.army != null and state.armies.has(p.army) and state.armies[p.army].leader == p.hero
			var ruler: bool = p.hero != null and state.kingdoms.has(p.faction) and state.kingdoms[p.faction].ruler == p.hero
			var n := _army_size(p.army) if big else int(p.size)
			_draw_escort(pos, k, face, ph, moving, horse, c, n)
			_draw_rider(pos, k * (1.12 if big else 1.0), face, ph, moving, horse, c.darkened(0.15), c,
				1.35 if big else 1.0, GOLD if ruler else (MERC_COL if kind == "merc" else Color.TRANSPARENT))
			top = (49.0 if big else 39.0) * k
			if sel or hov or _show_names:
				label = ("军团 %d" % n) if big else str(n)
				if p.hero != null:
					label = "%s %s" % [state.heroes[p.hero].name, label]
			label_col = Color(c.lightened(0.55))
		"caravan":
			_draw_packhorse(pos + Vector2(-7 * face, 1) * k, k, face, ph + 1.5, moving, Color("8a6a48"))
			_draw_rider(pos + Vector2(4 * face, 0) * k, k * 0.9, face, ph, moving, horse, Color("a77b46"), c, 0.7, Color.TRANSPARENT)
			top = 30.0 * k
			label = "商队 %d" % int(p.size) if (hov or sel or _show_names) else ""
		"villager":
			_draw_packhorse(pos + Vector2(5 * face, 1) * k, k * 0.8, face, ph + 1.5, moving, Color("9a9086"))
			_draw_walker(pos + Vector2(-4 * face, 0) * k, k, face, ph, moving, Color("d8cdb0"), false)
			top = 14.0 * k
			label = "村民" if (hov or sel or _show_names) else ""
		"bandit":
			var n := clampi(1 + int(p.size) / 12, 2, 4)
			for i in n:
				var off := Vector2((i - (n - 1) * 0.5) * 6.0, (i % 2) * 3.0 - 1.5) * k
				_draw_walker(pos + off, k, face, ph + i * 1.7, moving, BANDIT_SHIRT, i == 0)
			top = 17.0 * k
			label = str(int(p.size)) if (hov or sel or _show_names) else ""
			label_col = Color("e09a8a")
		"refugee":
			# a straggling file of people in grey, bundles on their backs, one donkey
			var n := clampi(2 + int(p.size) / 8, 3, 5)
			_draw_packhorse(pos + Vector2(-(n * 3.0 + 4) * face, 1) * k, k * 0.7, face, ph + 2.3, moving, Color("8e8478"))
			for i in n:
				var off := Vector2((i - (n - 1) * 0.5) * -5.0 * face, (i % 2) * 2.5 - 1.0) * k
				var shirt := Color("8d8a80") if i % 2 == 0 else Color("a49a86")
				_draw_walker(pos + off, k * (0.8 if i % 3 == 2 else 0.95), face, ph + i * 1.3, moving, shirt, false)
				draw_circle(pos + off + Vector2(-2.2 * face, -10.5) * k, 2.0 * k, Color("6d5a40"))   # bundle
			top = 15.0 * k
			label = ("流民 %d" % int(p.size)) if (hov or sel or _show_names) else ""
			label_col = Color("cfc6b0")
		"hunter":
			_draw_rider(pos + Vector2(-5 * face, 1) * k, k * 0.85, face, ph + 2.0, moving, HORSE_COLS[2], HUNTER_COL.darkened(0.3), HUNTER_COL, 0.0, Color.TRANSPARENT)
			_draw_rider(pos + Vector2(4 * face, 0) * k, k * 0.9, face, ph, moving, horse, HUNTER_COL.darkened(0.2), HUNTER_COL, 0.0, Color.TRANSPARENT)
			top = 18.0 * k
			label = "游侠 %d" % int(p.size) if (hov or sel or _show_names) else ""
		_:
			_draw_walker(pos, k, face, ph, moving, c, false)

	var named := label != ""
	if p.mode == "siege" and named:
		label += " 围城"
	elif p.mode == "raid":
		if named:
			label += " 劫掠"
		draw_circle(pos + Vector2(8, 2) * k, (3 + 2 * sin(_time * 9.0)) * k, Color(1.0, 0.5, 0.1, 0.8))
	elif p.mode == "flee" and kind != "player" and named:
		label += " 撤退"
	if label.strip_edges() != "":
		_text(pos + Vector2(0, -top - 5 * k), label.strip_edges(), int((13 if kind == "player" else 11) * s), label_col)
	_hits.append({"kind": "party", "id": pid, "rect": Rect2(pos + Vector2(-13, -top) * Vector2(k, 1), Vector2(26 * k, top + 6 * k))})


func _is_moving(pid: String, p: Dictionary) -> bool:
	if not time_flowing or p.mode in ["siege", "raid", "idle"]:
		return false
	return _prev.get(pid, Vector2.ZERO).distance_to(_cur.get(pid, Vector2.ZERO)) > 0.01


## Builds an outline+fill polygon in figure space (x mirrored by facing), units * k.
func _shape(pos: Vector2, k: float, face: float, pts: Array, col: Color, outline := true) -> void:
	var poly := PackedVector2Array()
	for q in pts:
		poly.append(pos + Vector2(q.x * face, q.y) * k)
	if outline:
		var ring := poly.duplicate()
		ring.append(poly[0])
		draw_polyline(ring, OUTLINE, 2.2 * k, true)
	draw_colored_polygon(poly, col)


func _limb(pos: Vector2, k: float, face: float, a: Vector2, b: Vector2, col: Color, w: float) -> void:
	var pa := pos + Vector2(a.x * face, a.y) * k
	var pb := pos + Vector2(b.x * face, b.y) * k
	draw_line(pa, pb, OUTLINE, (w + 1.6) * k, true)
	draw_line(pa, pb, col, w * k, true)


## A horse with its rider; the rider carries a banner (banner_scale 0 = none).
## Figure space: origin at the hooves, +x = forward, -y = up; one unit ~ 1 px at k = 1.
func _draw_rider(pos: Vector2, k: float, face: float, ph: float, moving: bool, horse: Color,
		tunic: Color, banner: Color, banner_scale: float, trim: Color) -> void:
	var g := sin(ph) if moving else 0.0
	var g2 := sin(ph + PI) if moving else 0.0
	var bob := absf(sin(ph)) * 0.8 if moving else 0.0
	var o := pos + Vector2(0, -bob) * k
	# far legs (darker), then body, then near legs
	var far := horse.darkened(0.3)
	_limb(o, k, face, Vector2(-5, -6), Vector2(-5 - 2.5 * g2, 0 + bob), far, 1.6)
	_limb(o, k, face, Vector2(5, -6), Vector2(5 + 2.5 * g, 0 + bob), far, 1.6)
	# tail
	_limb(o, k, face, Vector2(-8, -9), Vector2(-10.5 - 0.8 * g, -4.5), horse.darkened(0.45), 1.5)
	# body, neck, head
	_shape(o, k, face, [Vector2(-8, -10), Vector2(-4, -11.5), Vector2(5, -11.5), Vector2(8, -10),
		Vector2(8, -6.5), Vector2(4, -5.5), Vector2(-5, -5.5), Vector2(-8.5, -7)], horse)
	_shape(o, k, face, [Vector2(5, -11), Vector2(8.5, -16.5), Vector2(11, -16.5), Vector2(12.5, -14),
		Vector2(11, -13.2), Vector2(9.5, -13.5), Vector2(8.5, -9)], horse)
	_limb(o, k, face, Vector2(8.5, -16.3), Vector2(6.5, -12.5), horse.darkened(0.45), 1.2)  # mane
	_limb(o, k, face, Vector2(-5, -6), Vector2(-5 + 2.5 * g, 0 + bob), horse, 1.8)
	_limb(o, k, face, Vector2(5, -6), Vector2(5 - 2.5 * g2, 0 + bob), horse, 1.8)
	# saddle cloth in the party colour
	_shape(o, k, face, [Vector2(-3, -11.8), Vector2(3, -11.8), Vector2(2.5, -7.5), Vector2(-2.5, -7.5)], banner.darkened(0.2), false)
	# rider: leg, torso, head
	_limb(o, k, face, Vector2(0, -11), Vector2(1.5, -7.5), Color("4a3a2a"), 1.6)
	_shape(o, k, face, [Vector2(-1.8, -11.5), Vector2(1.8, -11.5), Vector2(1.5, -17), Vector2(-1.5, -17)], tunic)
	draw_circle(o + Vector2(0.3 * face, -18.8) * k, 2.3 * k, OUTLINE)
	draw_circle(o + Vector2(0.3 * face, -18.8) * k, 1.6 * k, Color("e3c3a0"))
	draw_circle(o + Vector2(0.3 * face, -19.6) * k, 1.4 * k, Color("8d939a"))   # helmet
	if banner_scale <= 0.0:
		_limb(o, k, face, Vector2(1.5, -14), Vector2(8, -21), Color("b8b0a0"), 0.9)   # spear
		return
	# banner pole held upright, flag streaming backwards and waving
	var hgt := 16.0 * banner_scale
	var bx := 2.2
	var base_y := -13.0
	var tip := base_y - 8.0 - hgt
	_limb(o, k, face, Vector2(bx, base_y), Vector2(bx, tip), Color("d9cfb8"), 1.0)
	var fw := 8.5 * banner_scale
	var fh := 6.5 * banner_scale
	var flag := PackedVector2Array()
	var n := 5
	for i in n + 1:
		var t := float(i) / n
		var wave := sin(_time * 5.0 + t * 4.0 + ph * 0.1) * 0.9 * t * banner_scale
		flag.append(o + Vector2((bx - t * fw) * face, tip + 0.5 + wave) * k)
	for i in range(n, -1, -1):
		var t := float(i) / n
		var wave := sin(_time * 5.0 + t * 4.0 + ph * 0.1) * 0.9 * t * banner_scale
		flag.append(o + Vector2((bx - t * fw) * face, tip + 0.5 + fh + wave - t * 1.2) * k)
	var ring := flag.duplicate()
	ring.append(flag[0])
	draw_colored_polygon(flag, banner)
	draw_polyline(ring, trim if trim.a > 0.0 else OUTLINE, (1.6 if trim.a > 0.0 else 1.2) * k, true)
	if trim == GOLD:
		draw_circle(o + Vector2(bx * face, tip - 1.2) * k, 1.6 * k, GOLD)


## Extra riders trailing behind a lord, more for bigger parties (purely visual).
func _draw_escort(pos: Vector2, k: float, face: float, ph: float, moving: bool, horse: Color, c: Color, n: int) -> void:
	var extra := 0
	if n >= 30:
		extra = 1
	if n >= 90:
		extra = 2
	for i in extra:
		var off := Vector2(-9.0 - i * 6.0, -3.0 + i * 5.0) * k
		off.x *= face
		_draw_rider(pos + off, k * 0.78, face, ph + 1.3 + i, moving, horse.darkened(0.15 + i * 0.1), c.darkened(0.35), c, 0.0, Color.TRANSPARENT)


func _draw_walker(pos: Vector2, k: float, face: float, ph: float, moving: bool, shirt: Color, rag: bool) -> void:
	var g := sin(ph) * 2.2 if moving else 0.0
	_limb(pos, k, face, Vector2(0, -6), Vector2(-g, 0), Color("3c3228"), 1.5)
	_limb(pos, k, face, Vector2(0, -6), Vector2(g, 0), Color("4d4134"), 1.5)
	_shape(pos, k, face, [Vector2(-1.8, -6), Vector2(1.8, -6), Vector2(1.5, -11.5), Vector2(-1.5, -11.5)], shirt)
	_limb(pos, k, face, Vector2(0.5, -10.5), Vector2(3 + g * 0.3, -7), shirt.darkened(0.2), 1.1)
	draw_circle(pos + Vector2(0.2 * face, -13.3) * k, 2.2 * k, OUTLINE)
	draw_circle(pos + Vector2(0.2 * face, -13.3) * k, 1.5 * k, Color("d9b896"))
	if rag:
		# tattered red rag on a stick: the bandit band's "banner"
		_limb(pos, k, face, Vector2(2.5, -9), Vector2(2.5, -20), Color("6b5a44"), 0.9)
		_shape(pos, k, face, [Vector2(2.5, -20), Vector2(-3, -19), Vector2(-1.5, -17.5), Vector2(-3.5, -16), Vector2(2.5, -16)], Color("9e2b25"))


func _draw_packhorse(pos: Vector2, k: float, face: float, ph: float, moving: bool, col: Color) -> void:
	var g := sin(ph) * 2.0 if moving else 0.0
	_limb(pos, k, face, Vector2(-4, -5), Vector2(-4 - g, 0), col.darkened(0.3), 1.5)
	_limb(pos, k, face, Vector2(4, -5), Vector2(4 + g, 0), col.darkened(0.3), 1.5)
	_shape(pos, k, face, [Vector2(-6.5, -9), Vector2(5, -9.5), Vector2(6.5, -8), Vector2(6, -5), Vector2(-6, -5)], col)
	_shape(pos, k, face, [Vector2(4.5, -9), Vector2(7, -13), Vector2(9.5, -12.5), Vector2(9, -10.5), Vector2(6.5, -8)], col)
	_limb(pos, k, face, Vector2(-4, -5), Vector2(-4 + g, 0), col, 1.6)
	_limb(pos, k, face, Vector2(4, -5), Vector2(4 - g, 0), col, 1.6)
	# packs
	_shape(pos, k, face, [Vector2(-5, -9), Vector2(2, -9), Vector2(2.5, -13), Vector2(-4.5, -13)], Color("c9a46a"))
	_limb(pos, k, face, Vector2(-1.5, -9), Vector2(-1.5, -13), Color("6b4c2c"), 0.8)


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
		if pid == null or not state.parties.has(pid) or _parked.has(pid) or not sees(party_world_pos(pid)):
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


## "  · 120 里，约 0.8 天" from the player's party (straight line; mountains and rivers make it longer)
func _distance_note(target: Vector2) -> String:
	if not _cur.has(player_id) or not state.parties.has(player_id):
		return ""
	var d := party_world_pos(player_id).distance_to(target)
	if d < 6.0:
		return ""
	var per_day := float(state.parties[player_id].get("speed", 150))
	return "  · %d 里，约 %.1f 天" % [int(d), d * 1.15 / maxf(per_day, 1.0)]


## Tooltip lines for the parties staying in / camped at a settlement (Warband-style).
func _visitor_lines(sid: String) -> Array[String]:
	var out: Array[String] = []
	var ids: Array = _at.get(sid, [])
	if ids.is_empty():
		return out
	var st: Dictionary = state.settlements[sid]
	var named: Array = []
	var counts := {}
	for pid in ids:
		var p: Dictionary = state.parties[pid]
		if p.kind in ["lord", "merc", "hunter"] or p.hero != null:
			named.append(p)
		else:
			var k: String = {"caravan": "商队", "villager": "村民", "bandit": "匪寇", "refugee": "流民"}.get(p.kind, p.kind)
			counts[k] = int(counts.get(k, 0)) + 1
	named.sort_custom(func(x, y): return int(x.size) > int(y.size))
	var walled: bool = st.kind == "town" or st.kind == "castle"
	out.append("—— %s ——" % ("城中" if walled else "此地"))
	for i in mini(named.size(), 8):
		var p: Dictionary = named[i]
		var who: String = state.heroes[p.hero].name if p.hero != null else str(p.name)
		var fac := ""
		if p.faction != null and state.kingdoms.has(p.faction):
			fac = " · " + str(state.kingdoms[p.faction].name)
		var where := "" if (not walled or p.inside != null) else " · 城外扎营"
		out.append("%s%s · %d人%s" % [who, fac, int(p.size), where])
	if named.size() > 8:
		out.append("……另有%d支部曲" % (named.size() - 8))
	if not counts.is_empty():
		var bits: Array[String] = []
		for k in counts:
			bits.append("%s×%d" % [k, counts[k]] if counts[k] > 1 else k)
		out.append(" · ".join(bits))
	return out


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
		var kname: String = {"lord": "将军部曲", "caravan": "商队", "villager": "村民", "bandit": "匪寇", "hunter": "游侠", "merc": "义从", "player": "你的部队", "refugee": "流民"}.get(p.kind, p.kind)
		var fac := ""
		if p.faction != null and state.kingdoms.has(p.faction):
			fac = " · " + str(state.kingdoms[p.faction].name)
		lines.append("%s%s · %d人（伤%d）· 战力%d" % [kname, fac, int(p.size), int(p.wounded), int(p.power)])
		if p.order != null and p.order.has("label"):
			lines.append(str(p.order.label))
	elif hover_kind == "settlement" and state.settlements.has(hover_id):
		var st: Dictionary = state.settlements[hover_id]
		lines.append(st.name + _distance_note(Vector2(st.pos[0], st.pos[1])))
		var known := knows_settlement(hover_id)
		if not known:
			var fac2 := ""
			if st.faction != null and state.kingdoms.has(st.faction):
				fac2 = " · " + str(state.kingdoms[st.faction].name)
			lines.append("%s%s" % [KIND_NAMES.get(st.kind, st.kind), fac2 if st.kind != "hideout" else ""])
			if st.kind == "village" and st.raided:
				lines.append("遭劫掠（远远望见烟火）")
			lines.append("—— 不在视野内，走近些才看得清 ——")
		elif st.kind == "hideout":
			lines.append("匪巢 · 约%d人" % int(st.garrison_size))
		elif st.kind == "village":
			lines.append("村庄 · 繁荣%d%s" % [int(st.prosperity), " · 遭劫掠" if st.raided else ""])
		else:
			var fac := ""
			if st.faction != null and state.kingdoms.has(st.faction):
				fac = str(state.kingdoms[st.faction].name)
			lines.append("%s · %s · 守军%d · 民心%d" % ["城" if st.kind == "town" else "关塞", fac, int(st.garrison_size), int(st.loyalty)])
		if known:
			lines.append_array(_visitor_lines(hover_id))
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
		draw_string(font, rect.position + Vector2(8, 20 + i * 18), lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, GOLD if i == 0 else (MUTED if lines[i].begins_with("——") else CREAM))
