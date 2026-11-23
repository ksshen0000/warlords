extends Control
## The quest log (Q), as in Warband: the jobs you have taken on the left (and, below them, the ones that are
## over), the chosen one's details on the right — who asked, where, by when, the reward, how far along it is,
## what to do next and the giver's own words — with buttons to find it on the map or ride to the giver.
## Reads the player view (player.quest_list / player.quest_log); time stops while it is open.

const CREAM := Color("efe6d2")
const MUTED := Color("8c9a94")
const GOLD := Color("f2c75c")
const EDGE := Color("6b5a3a")
const RED := Color("ff8f7a")
const GREEN := Color("8fd3a0")

var host                                   # main.gd
var _quests: Array = []
var _log: Array = []
var _sel := ""
var _root: Control


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.05, 0.06, 0.94)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	visible = false


func open(player: Dictionary) -> void:
	visible = true
	show_player(player)


func close() -> void:
	visible = false


func show_player(player: Dictionary) -> void:
	_quests = player.get("quest_list", [])
	_log = player.get("quest_log", [])
	if visible:
		_build()


func _build() -> void:
	if _root:
		_root.queue_free()
	var m := MarginContainer.new()
	m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 40)
	add_child(m)
	_root = m
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 14)
	m.add_child(outer)
	outer.add_child(_label("差事", 30, GOLD))
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 18)
	outer.add_child(row)

	# left: the jobs in hand, then the closed ones
	var lp := _panel(row)
	lp.custom_minimum_size = Vector2(440, 0)
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	lp.add_child(sc)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	sc.add_child(list)
	list.add_child(_label("进行中（%d）" % _quests.size(), 17, GOLD))
	if _quests.is_empty():
		list.add_child(_label("　眼下没有差事。进城向城主打听：剿匪、送信、运货。", 14, MUTED))
	var ids: Array = []
	for q in _quests:
		ids.append(str(q.id))
	if not ids.has(_sel):
		_sel = ids[0] if ids.size() else ""
	for q in _quests:
		var b := Button.new()
		b.toggle_mode = true
		b.button_pressed = str(q.id) == _sel
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 46)
		b.add_theme_font_size_override("font_size", 16)
		var left := int(q.left)
		b.text = "  〔%s〕%s　剩 %d 天" % [q.kind_name, q.title, left]
		if left <= 2:
			b.add_theme_color_override("font_color", RED)
		var qid := str(q.id)
		b.pressed.connect(func():
			_sel = qid
			_build())
		list.add_child(b)
	list.add_child(_spacer(12))
	list.add_child(_label("已了结", 17, MUTED))
	if _log.is_empty():
		list.add_child(_label("　（还没有）", 14, MUTED))
	for e in _log:
		var res := str(e.result)
		var col := GREEN if res == "完成" else (RED if res == "失败" else MUTED)
		var l := _label("　第 %d 天　%s　%s" % [int(e.day), res, e.title], 14, col)
		l.tooltip_text = "%s（%s）委托 · %s" % [e.giver, e.town, e.note]
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		list.add_child(l)

	# right: the chosen job
	var rp := _panel(row)
	rp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var dv := VBoxContainer.new()
	dv.add_theme_constant_override("separation", 10)
	rp.add_child(dv)
	var cur: Dictionary = {}
	for q in _quests:
		if str(q.id) == _sel:
			cur = q
	if cur.is_empty():
		dv.add_child(_label("选中左边的一件差事查看详情。", 16, MUTED))
	else:
		dv.add_child(_label(str(cur.title), 26, GOLD))
		var info := RichTextLabel.new()
		info.bbcode_enabled = true
		info.fit_content = true
		info.scroll_active = false
		info.add_theme_font_size_override("normal_font_size", 17)
		info.add_theme_color_override("default_color", CREAM)
		var left := int(cur.left)
		var t := "[color=#8c9a94]委托人[/color]　%s（%s）\n" % [cur.giver_name, cur.town_name]
		t += "[color=#8c9a94]期限[/color]　　第 %d 天前　[color=#%s]还剩 %d 天[/color]\n" % [int(cur.deadline),
			"ff8f7a" if left <= 2 else "efe6d2", left]
		t += "[color=#8c9a94]酬劳[/color]　　[color=#f2c75c]%d 金[/color] · 名望 +%d · 委托人更器重你\n" % [int(cur.reward), int(cur.renown)]
		if str(cur.progress) != "":
			t += "[color=#8c9a94]进展[/color]　　%s\n" % cur.progress
		if str(cur.todo) != "":
			t += "\n[b]该做的事[/b]　%s" % cur.todo
		info.text = t
		dv.add_child(info)
		if str(cur.text) != "":
			var quote := _label(str(cur.text), 16, Color("cfc4a8"))
			quote.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			dv.add_child(_spacer(4))
			dv.add_child(quote)
		dv.add_child(_label("误了期限算失败：委托人会对你不满。", 13, MUTED))
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dv.add_child(fill)
	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_END
	btns.add_theme_constant_override("separation", 10)
	dv.add_child(btns)
	if not cur.is_empty():
		if cur.target_pos != null:
			var tp: Array = cur.target_pos
			btns.add_child(_button("在地图上查看目标", func():
				close()
				host.look_at_map(Vector2(float(tp[0]), float(tp[1])))))
		var town := str(cur.town)
		btns.add_child(_button("前往委托人（%s）" % cur.town_name, func():
			close()
			host.go_to_place(town)))
	btns.add_child(_button("关闭", close))


func _panel(parent: Control) -> PanelContainer:
	var p := PanelContainer.new()
	p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.12, 0.14, 0.96)
	sb.border_color = EDGE
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(18)
	p.add_theme_stylebox_override("panel", sb)
	parent.add_child(p)
	return p


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(110, 40)
	b.add_theme_font_size_override("font_size", 16)
	b.pressed.connect(cb)
	return b


func _label(t: String, fs: int, col: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", col)
	return l


func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c
