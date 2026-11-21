extends PanelContainer
## The player's menu window (Mount & Blade style): settlements, encounters, trade, dialogue,
## and the equipment screen / the smith's shop (menus carrying "gear").

signal action(id: String, data: Dictionary)
signal say(hero: String, text: String)

const CREAM := Color("efe6d2")
const MUTED := Color("8c9a94")
const GOLD := Color("f2c75c")

var title_label: Label
var body: RichTextLabel
var buttons: VBoxContainer
var trade_box: VBoxContainer
var trade_grid: GridContainer
var trade_info: Label
var content: VBoxContainer
var char_box: VBoxContainer
var gear_layer: CanvasLayer
var gear_screen: Control
const GearScreenScript := preload("res://scripts/gear_screen.gd")
var chat_box: VBoxContainer
var chat_log: RichTextLabel
var chat_input: LineEdit
var waiting_label: Label
var menu: Dictionary = {}
var trading := false
var trade_next := false        # back from the market stall in the 3D town walk: open the market straight away
var _sig := ""


func _ready() -> void:
	custom_minimum_size = Vector2(560, 0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.12, 0.14, 0.96)
	sb.border_color = Color("6b5a3a")
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(14)
	add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	add_child(v)
	content = v
	title_label = Label.new()
	title_label.add_theme_font_size_override("font_size", 21)
	title_label.add_theme_color_override("font_color", GOLD)
	v.add_child(title_label)
	body = RichTextLabel.new()
	body.bbcode_enabled = true
	body.fit_content = true
	body.scroll_active = false
	body.add_theme_color_override("default_color", CREAM)
	body.add_theme_font_size_override("normal_font_size", 14)
	v.add_child(body)

	trade_box = VBoxContainer.new()
	trade_info = Label.new()
	trade_info.add_theme_color_override("font_color", MUTED)
	trade_info.add_theme_font_size_override("font_size", 13)
	trade_box.add_child(trade_info)
	trade_grid = GridContainer.new()
	trade_grid.columns = 7
	trade_grid.add_theme_constant_override("h_separation", 8)
	trade_box.add_child(trade_grid)
	v.add_child(trade_box)

	char_box = VBoxContainer.new()
	char_box.add_theme_constant_override("separation", 6)
	v.add_child(char_box)

	chat_box = VBoxContainer.new()
	chat_log = RichTextLabel.new()
	chat_log.bbcode_enabled = true
	chat_log.custom_minimum_size = Vector2(0, 170)
	chat_log.scroll_following = true
	chat_log.add_theme_color_override("default_color", CREAM)
	chat_log.add_theme_font_size_override("normal_font_size", 14)
	chat_box.add_child(chat_log)
	var row := HBoxContainer.new()
	chat_input = LineEdit.new()
	chat_input.placeholder_text = "对他说点什么……（回车发送）"
	chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_input.max_length = 200
	chat_input.text_submitted.connect(func(_t): _send_chat())
	row.add_child(chat_input)
	var send := Button.new()
	send.text = "说"
	send.pressed.connect(_send_chat)
	row.add_child(send)
	chat_box.add_child(row)
	waiting_label = Label.new()
	waiting_label.text = "（对方正在思考……）"
	waiting_label.add_theme_color_override("font_color", MUTED)
	waiting_label.visible = false
	chat_box.add_child(waiting_label)
	v.add_child(chat_box)

	buttons = VBoxContainer.new()
	buttons.add_theme_constant_override("separation", 4)
	v.add_child(buttons)
	visible = false


func _esc(s) -> String:
	return str(s).replace("[", "[lb]")


func open(m: Dictionary) -> void:
	var sig := "%s|%s|%s" % [m.get("type", ""), m.get("id", m.get("party", m.get("hero", ""))), m.get("title", "")]
	if sig != _sig:
		trading = false
		chat_input.text = ""
	if trade_next and m.has("market"):
		trade_next = false
		trading = true
	_sig = sig
	menu = m
	visible = true
	title_label.text = str(m.get("title", ""))
	body.text = _esc(m.get("text", ""))
	_build_buttons()
	_build_trade()
	_build_char()
	_build_gear()
	_build_chat()


func close() -> void:
	visible = false
	if gear_screen:
		gear_screen.visible = false
	_sig = ""
	menu = {}
	trading = false


func _build_buttons() -> void:
	for c in buttons.get_children():
		c.queue_free()
	if trading:
		var back := Button.new()
		back.text = "返回"
		back.pressed.connect(func():
			trading = false
			open(menu))
		buttons.add_child(back)
		return
	for o in menu.get("options", []):
		if o.id == "trade":
			var tb := Button.new()
			tb.text = str(o.label)
			tb.alignment = HORIZONTAL_ALIGNMENT_LEFT
			tb.pressed.connect(func():
				trading = true
				open(menu))
			buttons.add_child(tb)
			continue
		var b := Button.new()
		b.text = str(o.label)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.disabled = not bool(o.enabled)
		var long_hint: bool = menu.get("type", "") == "create"
		if str(o.get("hint", "")) != "":
			b.tooltip_text = str(o.hint)
			if not long_hint:
				b.text += "  —— " + str(o.hint)
		var data := {}
		if o.get("hero") != null:
			data["hero"] = o.hero
		if o.get("choice") != null:
			data["choice"] = o.choice
		for k in ["topic", "target"]:
			if o.get(k) != null:
				data[k] = o[k]
		var oid: String = o.id
		b.pressed.connect(func(): action.emit(oid, data))
		buttons.add_child(b)
		if long_hint and str(o.get("hint", "")) != "":
			# character creation: describe each choice under its button, M&B style
			var d := Label.new()
			d.text = str(o.hint)
			d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			d.custom_minimum_size = Vector2(520, 0)
			d.add_theme_color_override("font_color", MUTED)
			d.add_theme_font_size_override("font_size", 13)
			buttons.add_child(d)


func _build_trade() -> void:
	trade_box.visible = trading and menu.has("market")
	if not trade_box.visible:
		return
	for c in trade_grid.get_children():
		c.queue_free()
	var carried := 0
	for g in menu.market:
		carried += int(menu.market[g].carry)
	trade_info.text = "载货 %d / %d　　买入价随库存浮动；带到缺货的城里能卖出高价" % [carried, int(menu.get("cargo_cap", 0))]
	for h in ["货物", "库存", "价格", "携带", "", "", ""]:
		var l := Label.new()
		l.text = h
		l.add_theme_color_override("font_color", MUTED)
		trade_grid.add_child(l)
	for g in menu.market:
		var m: Dictionary = menu.market[g]
		for txt in [str(m.name), str(int(m.stock)), "%d 金" % int(m.price), str(int(m.carry))]:
			var l := Label.new()
			l.text = txt
			trade_grid.add_child(l)
		for spec in [["买 1", "buy", 1], ["买 5", "buy", 5], ["卖 5", "sell", 5]]:
			var b := Button.new()
			b.text = spec[0]
			var good: String = g
			var act: String = spec[1]
			var qty: int = spec[2]
			if act == "sell":
				b.disabled = int(m.carry) <= 0
			else:
				b.disabled = int(m.stock) < 4
			b.pressed.connect(func(): action.emit(act, {"good": good, "qty": qty}))
			trade_grid.add_child(b)


# ------------------------------------------------------------ equipment / the smith
## Menus carrying "gear" are shown full-screen, Warband-inventory style (gear_screen.gd), above everything;
## this panel steps aside meanwhile. The screen's drags come back out through the usual action signal.
func _build_gear() -> void:
	var on: bool = menu.has("gear")
	content.visible = not on
	self_modulate.a = 0.0 if on else 1.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE if on else Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(0 if on else (720 if menu.has("char") else 560), 0)
	if on:
		if gear_layer == null:
			gear_layer = CanvasLayer.new()
			gear_layer.layer = 20
			get_tree().root.add_child(gear_layer)
			gear_screen = GearScreenScript.new()
			gear_layer.add_child(gear_screen)
			gear_screen.request.connect(func(a, d): action.emit(a, d))
		gear_screen.show_menu(menu)
	elif gear_screen:
		gear_screen.visible = false


func _exit_tree() -> void:
	if gear_layer:
		gear_layer.queue_free()


# ------------------------------------------------------------ the character sheet (C)
func _build_char() -> void:
	for c in char_box.get_children():
		c.queue_free()
	var ch: Dictionary = menu.get("char", {})
	char_box.visible = not ch.is_empty()
	if not char_box.visible:
		return
	custom_minimum_size = Vector2(720, 0)
	var pts: Dictionary = ch.get("points", {})
	# whose sheet (you, then the companions)
	var people: Array = menu.get("people", [])
	if people.size() > 1:
		var tabs := HBoxContainer.new()
		for p in people:
			var b := Button.new()
			b.text = str(p.name)
			b.focus_mode = Control.FOCUS_NONE
			b.disabled = str(p.id) == str(menu.get("who", "player"))
			b.add_theme_color_override("font_disabled_color", GOLD)
			var pid: String = str(p.id)
			b.pressed.connect(func(): action.emit("who", {"who": pid}))
			tabs.add_child(b)
		char_box.add_child(tabs)
	# level bar
	var bar := ProgressBar.new()
	bar.min_value = float(ch.get("this_xp", 0))
	bar.max_value = maxf(float(ch.get("next_xp", 1)), bar.min_value + 1.0)
	bar.value = float(ch.get("xp", 0))
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 8)
	char_box.add_child(bar)
	# attributes
	char_box.add_child(_head_label("属性（可分配 %d 点）" % int(pts.get("attr", 0))))
	var ar := HBoxContainer.new()
	ar.add_theme_constant_override("separation", 14)
	for a in ch.get("attr", []):
		var l := Label.new()
		l.text = "%s %d" % [a.name, int(a.value)]
		l.add_theme_color_override("font_color", CREAM)
		ar.add_child(l)
		var b := Button.new()
		b.text = "+"
		b.focus_mode = Control.FOCUS_NONE
		b.disabled = int(pts.get("attr", 0)) <= 0
		var key: String = a.id
		b.pressed.connect(func(): action.emit("spend", {"kind": "attr", "key": key}))
		ar.add_child(b)
	char_box.add_child(ar)
	# skills
	char_box.add_child(_head_label("技能（可分配 %d 点；技能不能超过对应属性 ÷ 3；★ = 队伍技能，取队里最高的人）" % int(pts.get("skill", 0))))
	var g := GridContainer.new()
	g.columns = 5
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 2)
	for sk in ch.get("skills", []):
		var n := Label.new()
		n.text = ("★" if sk.party else "  ") + str(sk.name)
		n.custom_minimum_size = Vector2(70, 0)
		n.add_theme_color_override("font_color", GOLD if int(sk.level) > 0 else CREAM)
		g.add_child(n)
		var at := Label.new()
		at.text = str(sk.attr)
		at.add_theme_color_override("font_color", MUTED)
		at.add_theme_font_size_override("font_size", 12)
		g.add_child(at)
		var lv := Label.new()
		lv.text = "%d / %d" % [int(sk.level), int(sk.cap)]
		lv.custom_minimum_size = Vector2(46, 0)
		lv.add_theme_color_override("font_color", CREAM)
		g.add_child(lv)
		var ef := Label.new()
		ef.text = str(sk.now)
		ef.custom_minimum_size = Vector2(380, 0)
		ef.clip_text = true
		ef.add_theme_font_size_override("font_size", 12)
		ef.add_theme_color_override("font_color", CREAM if int(sk.level) > 0 else MUTED)
		g.add_child(ef)
		var b := Button.new()
		b.text = "+"
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = "下一级：" + str(sk.next)
		b.disabled = int(pts.get("skill", 0)) <= 0 or int(sk.level) >= int(sk.cap)
		var key: String = sk.id
		b.pressed.connect(func(): action.emit("spend", {"kind": "skill", "key": key}))
		g.add_child(b)
	char_box.add_child(g)
	# weapon proficiencies
	char_box.add_child(_head_label("武器熟练度（亲自上阵打中敌人就会提高；影响伤害和出手速度）"))
	var pr := HBoxContainer.new()
	pr.add_theme_constant_override("separation", 16)
	for p in ch.get("prof", []):
		var l := Label.new()
		l.text = "%s %d" % [p.name, int(p.value)]
		l.add_theme_color_override("font_color", CREAM)
		pr.add_child(l)
	char_box.add_child(pr)
	if str(menu.get("msg", "")) != "":
		var m := Label.new()
		m.text = str(menu.msg)
		m.add_theme_color_override("font_color", Color("9ff0b0") if menu.get("msg_ok", true) else Color("ff8f7a"))
		char_box.add_child(m)


func _head_label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_color_override("font_color", MUTED)
	l.add_theme_font_size_override("font_size", 13)
	return l


func _build_chat() -> void:
	chat_box.visible = menu.get("type", "") == "talk"
	if not chat_box.visible:
		return
	var who := str(menu.get("title", "")).trim_prefix("与").trim_suffix("交谈")
	var out := ""
	for line in menu.get("chat", []):
		if str(line[0]) == "player":
			out += "[color=#8fc6ff]你：[/color]%s\n" % _esc(line[1])
		else:
			out += "[color=#f2c75c]%s：[/color]%s\n" % [_esc(who), _esc(line[1])]
	var free: bool = menu.get("free_text", false)
	chat_input.get_parent().visible = free              # typing freely needs the LLM; topics always work
	if out == "":
		out = "[color=#8c9a94]（%s）[/color]" % ("可以挑下面的话题，也可以随意说话：对方会按自己的性格回应，并影响对你的好感。" if free
			else "挑下面的话题和对方交谈：打听局势、问差事、试探立场……")
	chat_log.text = out
	if free and not waiting_label.visible:
		chat_input.grab_focus.call_deferred()


func set_waiting(on: bool) -> void:
	waiting_label.visible = on
	chat_input.editable = not on


func _send_chat() -> void:
	var t := chat_input.text.strip_edges()
	if t == "" or menu.get("type", "") != "talk":
		return
	chat_input.text = ""
	set_waiting(true)
	say.emit(str(menu.hero), t)
