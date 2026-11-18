extends PanelContainer
## The player's menu window (Mount & Blade style): settlements, encounters, trade, dialogue.

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
var chat_box: VBoxContainer
var chat_log: RichTextLabel
var chat_input: LineEdit
var waiting_label: Label
var menu: Dictionary = {}
var trading := false
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
	_sig = sig
	menu = m
	visible = true
	title_label.text = str(m.get("title", ""))
	body.text = _esc(m.get("text", ""))
	_build_buttons()
	_build_trade()
	_build_chat()


func close() -> void:
	visible = false
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
	if out == "":
		out = "[color=#8c9a94]（你可以随意和对方交谈：打听消息、套近乎、试探立场……对方会按自己的性格回应，并影响对你的好感。）[/color]"
	chat_log.text = out
	if not waiting_label.visible:
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
