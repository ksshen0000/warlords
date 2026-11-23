extends "res://scripts/gear_screen.gd"
## The party screen (P), laid out like Warband's: your troops on the left (one row per type with
## healthy / wounded counts and an experience bar), the selected type in the middle (a 3D model, its
## numbers, the upgrade paths and dismissal), prisoners on the right, and the totals along the bottom.
## Borrows the stage, the model turntable and the panel helpers of the equipment screen.
## Every button is a server action (player.py, pending type "party").

var p: Dictionary = {}
var _rows_box: VBoxContainer
var _info: RichTextLabel
var _actions: VBoxContainer
var _pris_box: VBoxContainer
var _totals: RichTextLabel
var _troop_sig := ""
var _confirm := ""                    # a "dismiss all" waiting for its second click


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
	_title_label = _label("部队", 22, GOLD)
	outer.add_child(_title_label)
	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 16)
	outer.add_child(cols)

	# left: your men
	var left := _panel_box(cols, "你的部队")
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(sc)
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 3)
	sc.add_child(_rows_box)

	# middle: the selected troop
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.size_flags_stretch_ratio = 1.1
	mid.add_theme_constant_override("separation", 8)
	cols.add_child(mid)
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.custom_minimum_size = Vector2(250, 330)
	svc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	svc.gui_input.connect(_on_model_input)
	mid.add_child(svc)
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	svc.add_child(_vp)
	_build_stage()
	_info = RichTextLabel.new()
	_info.bbcode_enabled = true
	_info.fit_content = true
	_info.scroll_active = false
	_info.add_theme_color_override("default_color", CREAM)
	_info.add_theme_font_size_override("normal_font_size", 15)
	mid.add_child(_info)
	_actions = VBoxContainer.new()
	_actions.add_theme_constant_override("separation", 4)
	mid.add_child(_actions)

	# right: prisoners
	var right := _panel_box(cols, "俘虏")
	_pris_box = VBoxContainer.new()
	_pris_box.add_theme_constant_override("separation", 3)
	right.add_child(_pris_box)

	# bottom: totals + done
	var bottom := HBoxContainer.new()
	outer.add_child(bottom)
	_totals = RichTextLabel.new()
	_totals.bbcode_enabled = true
	_totals.fit_content = true
	_totals.scroll_active = false
	_totals.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_totals.add_theme_color_override("default_color", CREAM)
	_totals.add_theme_font_size_override("normal_font_size", 15)
	bottom.add_child(_totals)
	bottom.add_child(_label("点选兵种查看 · 拖动模型转身 · P / Esc 或「完成」关闭", 13, MUTED))
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
	p = m.get("party", {})
	visible = true
	_fill()


func _fill() -> void:
	var sel := str(p.get("selected", ""))
	for c in _rows_box.get_children():
		c.queue_free()
	var cur: Dictionary = {}
	for r in p.get("rows", []):
		if str(r.id) == sel:
			cur = r
		_rows_box.add_child(_troop_row(r, str(r.id) == sel))
	if p.get("rows", []).is_empty():
		_rows_box.add_child(_label("（没有士兵）", 15, MUTED))
	for c in p.get("companions", []):
		_rows_box.add_child(_label("　%s（同伴，%d 级%s）" % [c.name, int(c.level),
			"，养伤" if int(c.wounded) > 0 else ""], 14, Color("8fd3a0")))
	_show_troop(cur)
	# prisoners
	for c in _pris_box.get_children():
		c.queue_free()
	var any := false
	for h in p.get("captives", []):
		_pris_box.add_child(_label("%s（敌将）" % h.name, 15, GOLD))
		any = true
	var npris := 0
	for r in p.get("prisoners", []):
		_pris_box.add_child(_label("%s　%d" % [r.name, int(r.n)], 15, CREAM))
		npris += int(r.n)
		any = true
	if not any:
		_pris_box.add_child(_label("（没有俘虏）", 15, MUTED))
	else:
		_pris_box.add_child(_label("进城可把俘虏卖给赎金掮客；敌将可提审", 13, MUTED))
	_totals.text = "人数 [b]%d / %d[/b]（伤 %d）　　俘虏 %d　　日饷 [b]%.1f[/b] 金　　[color=#f2c75c]金 %d[/color]　　日行 %.1f" % [
		int(p.get("size", 0)), int(p.get("limit", 0)), int(p.get("size", 0)) - int(p.get("healthy", 0)), npris,
		float(p.get("wages", 0)), int(p.get("gold", 0)), float(p.get("speed", 0))]


func _troop_row(r: Dictionary, on: bool) -> Control:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.toggle_mode = true
	b.button_pressed = on
	b.custom_minimum_size = Vector2(0, 34)
	var txt := "%s　%d" % [r.name, int(r.healthy)]
	if int(r.wounded) > 0:
		txt += "（伤 %d）" % int(r.wounded)
	if int(r.ready) > 0:
		txt += "　▲%d" % int(r.ready)
	b.text = txt
	b.add_theme_font_size_override("font_size", 15)
	var col: Color = TIER_COL[clampi(int(r.tier), 0, 4)]
	b.add_theme_color_override("font_color", col)
	b.add_theme_color_override("font_pressed_color", GOLD)
	b.tooltip_text = "%s · %d 级%s · %s" % [r.culture, int(r.tier), r.cls, "可以晋升" if int(r.ready) > 0 else "经验 %d / %d" % [int(r.xp), int(r.need)]]
	var tid := str(r.id)
	b.pressed.connect(func():
		_confirm = ""
		request.emit("party_select", {"choice": tid}))
	# experience toward the next rank, as a thin bar under the name
	if int(r.need) > 0:
		var bar := ProgressBar.new()
		bar.show_percentage = false
		bar.max_value = 1.0
		var per_man := float(r.xp) / maxf(1.0, float(r.need) * maxf(1.0, float(r.healthy)))
		bar.value = clampf(per_man, 0.0, 1.0)
		bar.custom_minimum_size = Vector2(0, 3)
		bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		bar.offset_top = -4
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var fill := StyleBoxFlat.new()
		fill.bg_color = Color("8fd3a0") if int(r.ready) > 0 else Color("6b8fb0")
		bar.add_theme_stylebox_override("fill", fill)
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color(0, 0, 0, 0.35)
		bar.add_theme_stylebox_override("background", bg)
		b.add_child(bar)
	return b


func _show_troop(r: Dictionary) -> void:
	for c in _actions.get_children():
		c.queue_free()
	if r.is_empty():
		_info.text = ""
		_set_model("")
		return
	_set_model(str(r.id))
	var t := "[font_size=19][b]%s[/b][/font_size]　[color=#8c9a94]%s · %d 级%s[/color]\n" % [r.name, r.culture, int(r.tier), r.cls]
	t += "健康 %d　受伤 %d　· 每人日饷 %.2f 金　· 战力 %.1f\n" % [int(r.healthy), int(r.wounded), float(r.wage), float(r.power)]
	if int(r.need) > 0:
		t += "经验 %d（每晋升一人需 %d）　[color=#%s]%d 人可晋升[/color]" % [int(r.xp), int(r.need),
			"8fd3a0" if int(r.ready) > 0 else "8c9a94", int(r.ready)]
	else:
		t += "[color=#8c9a94]已是最高一级[/color]"
	_info.text = t
	var gold := int(p.get("gold", 0))
	var cost := int(r.cost)
	var can := mini(int(r.ready), gold / cost) if cost > 0 else int(r.ready)
	for u in r.get("upgrades", []):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var tgt := str(u.id)
		for n in ([1, can] if can > 1 else [1]):
			var b := Button.new()
			b.focus_mode = Control.FOCUS_NONE
			b.text = "晋升 %s 为%s（%d 级%s）· %d 金" % ["1 人" if n == 1 else "%d 人" % n, u.name, int(u.tier), u.cls, cost * n]
			b.disabled = can < 1
			var nn: int = n
			b.pressed.connect(func(): request.emit("promote", {"choice": "%s:%d" % [tgt, nn]}))
			row.add_child(b)
		_actions.add_child(row)
	var drow := HBoxContainer.new()
	drow.add_theme_constant_override("separation", 6)
	var tid := str(r.id)
	var total := int(r.healthy) + int(r.wounded)
	var d1 := Button.new()
	d1.focus_mode = Control.FOCUS_NONE
	d1.text = "遣散 1 人"
	d1.pressed.connect(func(): request.emit("dismiss", {"choice": "%s:1" % tid}))
	drow.add_child(d1)
	if total > 1:
		var da := Button.new()
		da.focus_mode = Control.FOCUS_NONE
		da.text = "再点一次确认遣散 %d 人" % total if _confirm == tid else "遣散全部 %d 人" % total
		da.pressed.connect(func():
			if _confirm == tid:
				_confirm = ""
				request.emit("dismiss", {"choice": "%s:%d" % [tid, total]})
			else:
				_confirm = tid
				_show_troop(r))
		drow.add_child(da)
	_actions.add_child(drow)


func _set_model(tid: String) -> void:
	if tid == _troop_sig:
		return
	_troop_sig = tid
	if _agent:
		_agent.queue_free()
		_agent = null
	if tid == "":
		return
	var a := Agent.new()
	a.rules = _rules
	a.troop = _rules.troops.get(tid, {"id": tid, "name": tid, "culture": "", "tier": 1, "cls": "inf"}).duplicate()
	a.color = Color("#3f6fb0")
	var l := _rules.loadout(tid, {})
	a.armor = int(l.armor)
	a.head_armor = int(l.head_armor)
	a.look = l.get("look", {})
	a.melee = l.melee
	a.ranged = l.ranged
	a.shield = l.shield
	a.horse_kind = l.horse
	a.mounted = a.horse_kind != ""
	a.using_ranged = str(a.troop.get("cls", "")) in ["arc", "harc"] and str(a.ranged) != ""
	a.melee_idx = 0
	a.rng_seed = 1
	_model_root.add_child(a)
	a.rig = AgentRig.new()
	a.add_child(a.rig)
	a.rig.build(a)
	_agent = a
	var cam := _vp.get_child(0) as Camera3D
	var dist := 8.6 if a.mounted else 6.6
	var look_y := 1.4 if a.mounted else 0.95
	cam.look_at_from_position(Vector3(0, look_y + 0.45, dist), Vector3(0, look_y, 0))
