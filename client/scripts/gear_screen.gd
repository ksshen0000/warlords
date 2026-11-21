extends Control
## The equipment screen, laid out like Warband's inventory: your bag as a grid of squares on the left,
## your character in the middle (a live 3D model wearing what is equipped) with the four weapon slots on
## one side and head / body / horse on the other, the smith's wares on the right when trading, armour
## totals and gold along the bottom, and "完成" to close. Items are dragged between squares and slots
## (double-click is a shortcut); hovering shows an item's numbers and price.
## Every move is a server action (gear.py); the screen just redraws from the menu it gets back.

signal request(action: String, data: Dictionary)

const CELL := 68
const BG := Color(0.06, 0.07, 0.08, 1.0)
const PANEL := Color("1a2024")
const EDGE := Color("6b5a3a")
const CREAM := Color("efe6d2")
const MUTED := Color("8c9a94")
const GOLD := Color("f2c75c")
const TIER_COL := [Color("b9b4a8"), Color("b9b4a8"), Color("efe6d2"), Color("8fc6ff"), Color("f2c75c")]

var g: Dictionary = {}
var title := ""
var _bag_grid: GridContainer
var _shop_grid: GridContainer
var _shop_title: Label
var _shop_box: Control
var _weapon_col: VBoxContainer
var _armor_col: VBoxContainer
var _stats: RichTextLabel
var _msg: Label
var _title_label: Label
var _vp: SubViewport
var _model_root: Node3D
var _model_sig := ""
var _agent: Node3D
var _yaw := PI + 0.6                 # three-quarter view, weapon side to the camera (the shield would hide him)
var _drag_yaw := false
var _rules: BattleRules


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = BG
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for m in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + m, 18)
	add_child(margin)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	margin.add_child(outer)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 16)
	outer.add_child(top)
	_title_label = _label("", 22, GOLD)
	top.add_child(_title_label)
	_people_row = HBoxContainer.new()                 # whose gear: you and the companions in the party
	_people_row.add_theme_constant_override("separation", 6)
	top.add_child(_people_row)
	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 16)
	outer.add_child(cols)

	# left: the bag
	var left := _panel_box(cols, "包裹")
	_bag_grid = _grid(left, "bag")
	# middle: weapons | model | armour
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.size_flags_stretch_ratio = 1.15
	cols.add_child(mid)
	var mid_row := HBoxContainer.new()
	mid_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid_row.alignment = BoxContainer.ALIGNMENT_CENTER
	mid_row.add_theme_constant_override("separation", 8)
	mid.add_child(mid_row)
	_weapon_col = VBoxContainer.new()
	_weapon_col.alignment = BoxContainer.ALIGNMENT_CENTER
	_weapon_col.add_theme_constant_override("separation", 6)
	mid_row.add_child(_weapon_col)
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.custom_minimum_size = Vector2(250, 420)
	svc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	svc.gui_input.connect(_on_model_input)
	mid_row.add_child(svc)
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	svc.add_child(_vp)
	_build_stage()
	_armor_col = VBoxContainer.new()
	_armor_col.alignment = BoxContainer.ALIGNMENT_CENTER
	_armor_col.add_theme_constant_override("separation", 6)
	mid_row.add_child(_armor_col)
	_stats = RichTextLabel.new()
	_stats.bbcode_enabled = true
	_stats.fit_content = true
	_stats.scroll_active = false
	_stats.add_theme_color_override("default_color", CREAM)
	_stats.add_theme_font_size_override("normal_font_size", 15)
	mid.add_child(_stats)
	# right: the smith's wares
	_shop_box = _panel_box(cols, "")
	_shop_title = _shop_box.get_child(0) as Label
	_shop_grid = _grid(_shop_box, "shop")
	# bottom: message + done
	var bottom := HBoxContainer.new()
	outer.add_child(bottom)
	_msg = _label("", 15, Color("9ff0b0"))
	_msg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(_msg)
	var hint := _label("拖动物品换装 · 双击：包裹里的换上 / 身上的卸下 / 铺子里的买下 · Esc 或「完成」关闭", 13, MUTED)
	bottom.add_child(hint)
	var done := Button.new()
	done.text = "  完成  "
	done.add_theme_font_size_override("font_size", 17)
	done.focus_mode = Control.FOCUS_NONE
	done.pressed.connect(func(): request.emit("back", {}))
	bottom.add_child(done)
	_rules = BattleRules.new()
	_rules.load_all()


func show_menu(m: Dictionary) -> void:
	if not is_node_ready():
		await ready
	g = m.get("gear", {})
	_title_label.text = str(m.get("title", "装备"))
	_msg.text = str(g.get("msg", ""))
	_msg.add_theme_color_override("font_color", Color("9ff0b0") if g.get("msg_ok", true) else Color("ff8f7a"))
	visible = true
	_fill()


# ------------------------------------------------------------------ contents
var _people_row: HBoxContainer


func _fill_people() -> void:
	for c in _people_row.get_children():
		c.queue_free()
	var people: Array = g.get("people", [])
	if people.size() <= 1:
		return
	for p in people:
		var b := Button.new()
		b.text = str(p.name)
		b.focus_mode = Control.FOCUS_NONE
		b.disabled = str(p.id) == str(g.get("who", "player"))
		var pid: String = str(p.id)
		b.pressed.connect(func(): request.emit("who", {"who": pid}))
		_people_row.add_child(b)


func _fill() -> void:
	_fill_people()
	var smith: bool = g.has("shop")
	# bag: one square per item (Warband has no stacks), padded with empty squares
	for c in _bag_grid.get_children():
		c.queue_free()
	var bag_items: Array = []
	for it in g.get("bag", []):
		for _k in int(it.n):
			bag_items.append(it)
	var cols := maxi(_bag_grid.columns, 1)
	for i in maxi(cols * 7, (bag_items.size() / cols + 2) * cols):
		_bag_grid.add_child(_cell("bag", bag_items[i] if i < bag_items.size() else null))
	# slots
	for c in _weapon_col.get_children() + _armor_col.get_children():
		c.queue_free()
	for s in g.get("slots", []):
		var col := _weapon_col if str(s.slot).begins_with("w") else _armor_col
		var cell := _cell("slot", s.item, str(s.slot), str(s.label))
		col.add_child(cell)
	# shop
	_shop_box.visible = true
	for c in _shop_grid.get_children():
		c.queue_free()
	if smith:
		_shop_title.text = "铺子里的货"
		var wares: Array = []
		for it in g.shop:
			for _k in int(it.n):
				wares.append(it)
		var sc := maxi(_shop_grid.columns, 1)
		for i in maxi(sc * 7, (wares.size() / sc + 2) * sc):
			_shop_grid.add_child(_cell("shop", wares[i] if i < wares.size() else null))
	else:
		_shop_title.text = "（进城找兵器铺才能买卖）"
	# totals
	var lo: Dictionary = g.get("loadout", {})
	_stats.text = "[center]头部护甲 [b]%d[/b]　　身体护甲 [b]%d[/b]　　%s　　[color=#f2c75c]金 %d[/color][/center]" % [
		int(g.get("head_armor", 0)), int(g.get("body_armor", 0)),
		("坐骑 [b]%s[/b]" % g.horse) if str(g.get("horse", "")) != "" else "步行", int(g.get("gold", 0))]
	_update_model(lo)


func _cell(where: String, it, slot := "", label := "") -> Control:
	var c := ItemCell.new()
	c.screen = self
	c.where = where
	c.item = it if it != null else {}
	c.slot = slot
	c.slot_label = label
	c.custom_minimum_size = Vector2(CELL, CELL)
	return c


## Drop rules (what the cell under the mouse accepts) and the action each drop sends.
func can_drop(target: ItemCell, d: Dictionary) -> bool:
	var it: Dictionary = d.item
	match target.where:
		"slot":
			if d.from == "slot" and d.slot == target.slot:
				return false
			return _fits(str(it.type), target.slot)
		"bag":
			return d.from != "bag"
		"shop":
			return g.has("shop") and d.from != "shop"
	return false


func drop(target: ItemCell, d: Dictionary) -> void:
	var iid: String = d.item.id
	match [d.from, target.where]:
		["bag", "slot"]:
			request.emit("equip", {"item": iid, "slot": target.slot})
		["slot", "slot"]:
			request.emit("move", {"from": d.slot, "to": target.slot})
		["shop", "slot"]:
			request.emit("gear_buy", {"item": iid, "slot": target.slot})
		["shop", "bag"]:
			request.emit("gear_buy", {"item": iid})
		["slot", "bag"]:
			request.emit("unequip", {"slot": d.slot})
		["bag", "shop"]:
			request.emit("gear_sell", {"item": iid})
		["slot", "shop"]:
			request.emit("gear_sell", {"slot": d.slot})


func activate(c: ItemCell) -> void:
	if c.item.is_empty():
		return
	match c.where:
		"bag":
			request.emit("equip", {"item": c.item.id})
		"slot":
			request.emit("unequip", {"slot": c.slot})
		"shop":
			request.emit("gear_buy", {"item": c.item.id})


func _fits(t: String, slot: String) -> bool:
	if slot.begins_with("w"):
		return t in ["melee", "ranged", "shield"]
	return t == slot


func tooltip_for(c: ItemCell) -> String:
	var it: Dictionary = c.item
	var s := "%s\n%s · %s\n" % [it.name, it.type_name, ["", "一", "二", "三", "四"][clampi(int(it.tier), 0, 4)] + "等"]
	s += str(it.desc) + "\n"
	match c.where:
		"shop":
			s += "价钱 %d 金" % int(it.price)
		_:
			s += "值 %d 金" % int(it.price) + ("　卖给铺子 %d 金" % int(it.sell) if g.has("shop") else "")
	return s


# ------------------------------------------------------------------ the character model
func _build_stage() -> void:
	var cam := Camera3D.new()
	cam.fov = 32
	cam.position = Vector3(0, 1.35, 5.4)
	cam.look_at_from_position(cam.position, Vector3(0, 1.05, 0))
	_vp.add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-40), deg_to_rad(-35), 0)
	sun.light_color = Color("ffddb1")
	sun.light_energy = 1.08
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 12.0
	_vp.add_child(sun)
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-26, 147, 0)
	rim.light_color = Color("accbdf")
	rim.light_energy = 0.78
	_vp.add_child(rim)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color("171f23")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color("a2a8a9")
	e.ambient_light_energy = 0.75
	env.environment = e
	_vp.add_child(env)
	# a round of floor to stand on
	var floor := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.22
	cm.bottom_radius = 1.22
	cm.height = 0.04
	floor.mesh = cm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color("4f534d")
	fm.roughness = 0.95
	floor.material_override = fm
	floor.position.y = -0.02
	_vp.add_child(floor)
	var rim_mesh := CylinderMesh.new()
	rim_mesh.top_radius = 1.27
	rim_mesh.bottom_radius = 1.27
	rim_mesh.height = 0.08
	var rim_floor := MeshInstance3D.new()
	rim_floor.mesh = rim_mesh
	var rim_material := StandardMaterial3D.new()
	rim_material.albedo_color = Color("797661")
	rim_material.roughness = 0.84
	rim_floor.material_override = rim_material
	rim_floor.position.y = -0.078
	_vp.add_child(rim_floor)
	_model_root = Node3D.new()
	_vp.add_child(_model_root)


func _update_model(lo: Dictionary) -> void:
	var sig := JSON.stringify(lo) + str(g.get("color", ""))
	if sig == _model_sig:
		return
	_model_sig = sig
	if _agent:
		_agent.queue_free()
		_agent = null
	var a := Agent.new()
	a.rules = _rules
	var tid := str(g.get("troop", "zhou_cav3"))
	a.troop = _rules.troops.get(tid, {"id": tid, "name": "你", "culture": "", "tier": 3, "cls": "cav"}).duplicate()
	a.color = Color(str(g.get("color", "#3f6fb0")))
	var l := _rules.loadout(tid, lo)
	a.armor = int(l.armor)
	a.head_armor = int(l.head_armor)
	a.look = l.get("look", {})
	a.melee = l.melee
	a.ranged = l.ranged
	a.shield = l.shield
	a.horse_kind = l.horse
	a.mounted = a.horse_kind != ""
	a.using_ranged = false
	a.melee_idx = 0
	a.rng_seed = 1
	_model_root.add_child(a)
	a.rig = AgentRig.new()
	a.add_child(a.rig)
	a.rig.build(a)
	_agent = a
	# a rider stands taller: pull the camera back
	var cam := _vp.get_child(0) as Camera3D
	var dist := 8.6 if a.mounted else 6.6
	var look_y := 1.4 if a.mounted else 0.95
	cam.look_at_from_position(Vector3(0, look_y + 0.45, dist), Vector3(0, look_y, 0))


func _process(dt: float) -> void:
	if not visible or _agent == null:
		return
	_agent.rotation.y = _yaw
	_agent.rig.show_pose(_agent, _agent.pose(), 0.0, 0.0, dt)


func _on_model_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_drag_yaw = e.pressed
	elif e is InputEventMouseMotion and _drag_yaw:
		_yaw += (e as InputEventMouseMotion).relative.x * 0.012     # drag the model round


# ------------------------------------------------------------------ helpers
func _label(t: String, fs: int, col: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", col)
	return l


func _panel_box(parent: Control, t: String) -> VBoxContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL
	sb.border_color = EDGE
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(10)
	pc.add_theme_stylebox_override("panel", sb)
	parent.add_child(pc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	pc.add_child(v)
	v.add_child(_label(t, 17, GOLD))
	return v


func _grid(parent: VBoxContainer, where: String) -> GridContainer:
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(sc)
	var gr := GridContainer.new()
	gr.columns = 5
	gr.add_theme_constant_override("h_separation", 4)
	gr.add_theme_constant_override("v_separation", 4)
	gr.set_meta("where", where)
	gr.size_flags_horizontal = Control.SIZE_SHRINK_CENTER | Control.SIZE_EXPAND
	sc.add_child(gr)
	# as many squares per row as fit (Warband's bag fills its panel)
	sc.resized.connect(func(): gr.columns = maxi(3, int((sc.size.x - 4) / (CELL + 4))))
	return gr


# ================================================================== one square
class ItemCell extends Control:
	var screen
	var where := ""                  # bag / slot / shop
	var item: Dictionary = {}
	var slot := ""
	var slot_label := ""
	var _hover := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_entered.connect(func():
			_hover = true
			queue_redraw())
		mouse_exited.connect(func():
			_hover = false
			queue_redraw())
		tooltip_text = " " if not item.is_empty() else ""

	func _make_custom_tooltip(_t: String) -> Object:
		if item.is_empty():
			return null
		var pc := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.07, 0.08, 0.09, 0.97)
		sb.border_color = Color("6b5a3a")
		sb.set_border_width_all(1)
		sb.set_content_margin_all(10)
		pc.add_theme_stylebox_override("panel", sb)
		var l := Label.new()
		l.text = screen.tooltip_for(self)
		l.add_theme_color_override("font_color", Color("efe6d2"))
		l.add_theme_font_size_override("font_size", 14)
		pc.add_child(l)
		return pc

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.double_click and e.button_index == MOUSE_BUTTON_LEFT:
			screen.activate(self)
			accept_event()

	func _get_drag_data(_p: Vector2) -> Variant:
		if item.is_empty():
			return null
		var prev := ItemCell.new()
		prev.screen = screen
		prev.item = item
		prev.where = "drag"
		prev.size = Vector2(56, 56)
		prev.modulate.a = 0.85
		set_drag_preview(prev)
		return {"from": where, "item": item, "slot": slot}

	func _can_drop_data(_p: Vector2, d: Variant) -> bool:
		return d is Dictionary and d.has("item") and screen.can_drop(self, d)

	func _drop_data(_p: Vector2, d: Variant) -> void:
		screen.drop(self, d)

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var tier: int = int(item.get("tier", 1))
		draw_rect(r, Color("232a2f") if where != "slot" else Color("2a2620"))
		var edge := Color("4a4436")
		if _hover and not item.is_empty():
			edge = Color("f2c75c")
		elif not item.is_empty():
			edge = Color("6b5a3a")
		draw_rect(r, edge, false, 2.0 if _hover else 1.0)
		if item.is_empty():
			if slot_label != "":
				var f := get_theme_default_font()
				draw_string(f, Vector2(0, size.y * 0.5 + 6), slot_label, HORIZONTAL_ALIGNMENT_CENTER, size.x, 14, Color("6a6458"))
			return
		Icons.draw(self, item, Rect2(Vector2(8, 4), Vector2(size.x - 16, size.y - 22)))
		var f2 := get_theme_default_font()
		var col: Color = [Color("b9b4a8"), Color("b9b4a8"), Color("efe6d2"), Color("8fc6ff"), Color("f2c75c")][clampi(tier, 0, 4)]
		draw_string(f2, Vector2(0, size.y - 5), str(item.get("name", "")), HORIZONTAL_ALIGNMENT_CENTER, size.x, 11, col)


# ================================================================== item icons (drawn, no image files)
class Icons:
	const WOOD := Color("8a6038")
	const STEEL := Color("c8ccd0")
	const DARK := Color("4a4a48")

	static func draw(c: CanvasItem, it: Dictionary, r: Rect2) -> void:
		var t := str(it.get("type", ""))
		var b := str(it.get("base", ""))
		var p := func(x: float, y: float) -> Vector2: return r.position + Vector2(x * r.size.x, y * r.size.y)
		match t:
			"melee":
				match b:
					"sword":
						c.draw_line(p.call(0.2, 0.85), p.call(0.82, 0.15), STEEL, 3.5)
						c.draw_line(p.call(0.2, 0.85), p.call(0.34, 0.69), WOOD, 4.5)
						c.draw_arc(p.call(0.15, 0.9), r.size.x * 0.07, 0, TAU, 12, STEEL, 2.0)       # the ring pommel
					"knife":
						c.draw_line(p.call(0.3, 0.75), p.call(0.68, 0.33), STEEL, 3.5)
						c.draw_line(p.call(0.25, 0.8), p.call(0.36, 0.68), WOOD, 4.5)
					"mace", "club":
						c.draw_line(p.call(0.25, 0.85), p.call(0.66, 0.3), WOOD, 4.0)
						c.draw_circle(p.call(0.7, 0.25), r.size.x * (0.13 if b == "mace" else 0.09), DARK if b == "mace" else WOOD)
					"axe":
						c.draw_line(p.call(0.2, 0.95), p.call(0.72, 0.08), WOOD, 3.5)
						c.draw_colored_polygon(PackedVector2Array([p.call(0.62, 0.12), p.call(0.92, 0.1), p.call(0.88, 0.42), p.call(0.66, 0.3)]), STEEL)
					_:
						# spear / ji / lance: a long shaft and a head
						c.draw_line(p.call(0.12, 0.95), p.call(0.82, 0.12), WOOD, 3.0)
						c.draw_colored_polygon(PackedVector2Array([p.call(0.78, 0.2), p.call(0.92, 0.02), p.call(0.86, 0.24)]), STEEL)
						if b == "ji":
							c.draw_colored_polygon(PackedVector2Array([p.call(0.7, 0.24), p.call(0.62, 0.1), p.call(0.76, 0.18)]), STEEL)
						if b == "lance":
							c.draw_line(p.call(0.74, 0.27), p.call(0.8, 0.22), Color("a8402a"), 5.0)    # tassel
			"ranged":
				if b == "crossbow":
					c.draw_line(p.call(0.5, 0.95), p.call(0.5, 0.2), WOOD, 5.0)
					c.draw_arc(p.call(0.5, 0.55), r.size.x * 0.42, PI * 1.15, PI * 1.85, 16, DARK, 3.0)
					c.draw_line(p.call(0.17, 0.32), p.call(0.83, 0.32), Color("d8d0b8"), 1.0)
				else:
					c.draw_arc(p.call(0.3, 0.5), r.size.y * 0.48, -PI * 0.42, PI * 0.42, 18, WOOD if b != "horsebow" else Color("6b4a2a"), 3.5)
					c.draw_line(p.call(0.45, 0.04), p.call(0.45, 0.96), Color("d8d0b8"), 1.0)
			"shield":
				if b == "large":
					c.draw_rect(Rect2(p.call(0.22, 0.05), r.size * Vector2(0.56, 0.9)), WOOD.darkened(0.2))
					c.draw_rect(Rect2(p.call(0.22, 0.05), r.size * Vector2(0.56, 0.9)), DARK, false, 2.0)
				else:
					var rad := r.size.y * 0.45
					c.draw_circle(p.call(0.5, 0.5), rad, Color("b08a4a") if b == "rattan" else Color("7a4a32"))
					c.draw_arc(p.call(0.5, 0.5), rad, 0, TAU, 24, DARK, 2.0)
					if b == "rattan":
						c.draw_arc(p.call(0.5, 0.5), rad * 0.6, 0, TAU, 20, Color("8a6a38"), 1.5)
					c.draw_circle(p.call(0.5, 0.5), rad * 0.2, STEEL)
			"head":
				var lv := int(it.get("tier", 1))
				var col := Color("8a7a60") if lv <= 1 else Color("8a8e92")
				c.draw_arc(p.call(0.5, 0.62), r.size.x * 0.32, PI, TAU, 18, col, r.size.x * 0.18)
				c.draw_line(p.call(0.18, 0.66), p.call(0.82, 0.66), col.darkened(0.2), 4.0)
				if lv >= 2:
					c.draw_line(p.call(0.5, 0.18), p.call(0.5, 0.3), col, 3.0)          # the crest spike
				if lv >= 3:
					c.draw_rect(Rect2(p.call(0.2, 0.68), r.size * Vector2(0.6, 0.22)), col.darkened(0.3))   # neck guard
			"body":
				var lv2 := int(it.get("tier", 1))
				var col2 := Color("7a5a3a") if lv2 <= 1 else Color("7e8286")
				var pts := PackedVector2Array([p.call(0.25, 0.1), p.call(0.75, 0.1), p.call(0.88, 0.3), p.call(0.78, 0.92),
					p.call(0.22, 0.92), p.call(0.12, 0.3)])
				c.draw_colored_polygon(pts, col2)
				for k in 4:
					var y := 0.3 + k * 0.15
					c.draw_line(p.call(0.2, y), p.call(0.8, y), col2.darkened(0.35), 1.0)
				if lv2 >= 4:
					c.draw_circle(p.call(0.38, 0.36), r.size.x * 0.08, Color("d8dce0"))   # the bright plates
					c.draw_circle(p.call(0.62, 0.36), r.size.x * 0.08, Color("d8dce0"))
			"horse":
				var hc := Color("6b4a2e") if str(it.get("kind", "")) != "barded" else Color("6e7276")
				c.draw_rect(Rect2(p.call(0.18, 0.38), r.size * Vector2(0.56, 0.26)), hc)
				c.draw_colored_polygon(PackedVector2Array([p.call(0.66, 0.42), p.call(0.82, 0.12), p.call(0.95, 0.18), p.call(0.8, 0.46)]), hc)
				for x in [0.22, 0.32, 0.6, 0.7]:
					c.draw_line(p.call(x, 0.62), p.call(x, 0.92), hc.darkened(0.2), 3.0)
				c.draw_line(p.call(0.18, 0.42), p.call(0.08, 0.66), Color("2b2622"), 2.5)     # tail
