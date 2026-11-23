extends Control
## The game's front end, one full-screen page at a time (like Warband's):
##   title  — 继续游戏 / 新的游戏 / 读取存档 / 设置 / 退出游戏 (shown at start-up)
##   new    — ① 开局 (world seed, AI level) → ② 出身 → ③ 家世 → the campaign starts
##   pause  — Esc in the campaign: 继续 / 保存 / 读取 / 设置 / 返回主菜单 / 退出
##   saves  — save or load: the slots on the left, the chosen one's details and its button on the right
## The campaign map stays behind it, dimmed. Everything it does goes through `host` (main.gd): its api,
## its settings window and a few helpers.

const CREAM := Color("efe6d2")
const MUTED := Color("8c9a94")
const GOLD := Color("f2c75c")
const EDGE := Color("6b5a3a")
const RED := Color("ff8f7a")

var host                                   # main.gd
var page := ""                             # title / new / pause / saves
var _back_to := ""                         # where 返回 leads from the saves page ("" = back to the game)
var _save_mode := false                    # saves page: saving (true) or loading
var _saves: Array = []
var _save_dir := ""
var _sel := ""                             # selected slot on the saves page
var _armed := ""                           # a button waiting for its confirming second click
var _new_step := 0                         # 0 开局, 1 出身, 2 家世
var _create_menu: Dictionary = {}
var _busy := ""                            # "正在生成世界…" while waiting for the server

var _dim: ColorRect
var _box: Control                          # the current page's content


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_dim = ColorRect.new()
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)
	visible = false


# ================================================================== pages
func show_title() -> void:
	page = "title"
	_armed = ""
	visible = true
	host.api.list_saves()                  # to know whether 继续游戏 has anything to continue
	_build()


func show_pause() -> void:
	page = "pause"
	_armed = ""
	visible = true
	_build()


func show_saves(saving: bool, back_to: String) -> void:
	page = "saves"
	_save_mode = saving
	_back_to = back_to
	_armed = ""
	_sel = ""
	visible = true
	host.api.list_saves()
	_build()


func show_new() -> void:
	page = "new"
	_new_step = 0
	_busy = ""
	_armed = ""
	visible = true
	_build()


## Character creation menus from the server (pending "create"): shown here while starting a new game.
func show_create(m: Dictionary) -> void:
	page = "new"
	_create_menu = m
	_busy = ""
	_new_step = 1 if str(m.get("title", "")).contains("出身") else 2
	visible = true
	_build()


## A new state from the server: the title and pause pages show what you can do now (continue, save…).
func refresh() -> void:
	if visible and page in ["title", "pause"] and _armed == "":
		_build()


## The AI levels arrive with the server's first state: fill the new-game page's list once they do.
func ai_ready() -> void:
	if visible and page == "new" and _new_step == 0 and _busy == "" and _tier_opt and _tier_opt.item_count == 0:
		var seed := int(_seed_box.value)
		_build()
		_seed_box.value = seed


## Whether character creation menus belong here now (a new game is under way on this page).
func wants_create() -> bool:
	return visible and page == "new" and (_busy != "" or _new_step >= 1)


func set_saves(saves: Array, dir: String) -> void:
	_saves = saves
	_save_dir = dir
	if page in ["saves", "title"]:
		_build()


func close() -> void:
	visible = false
	page = ""
	_armed = ""


## Esc: one step back.
func back() -> void:
	match page:
		"pause":
			close()
		"saves":
			_leave_saves()
		"new":
			if _new_step == 2:
				host.api.act("back")
			elif _new_step == 1:
				show_new()
			elif _busy != "":
				pass                       # waiting for the server
			else:
				show_title()
		"title":
			if host.session_active():
				close()


func _leave_saves() -> void:
	if _back_to == "title":
		show_title()
	elif _back_to == "pause":
		show_pause()
	else:
		close()


# ================================================================== building
func _build() -> void:
	if _box:
		_box.queue_free()
	_box = null
	match page:
		"title":
			_dim.color = Color(0.05, 0.07, 0.08, 1.0)      # the title hides the game entirely
			_build_title()
		"pause":
			_dim.color = Color(0.03, 0.05, 0.06, 0.70)
			_build_pause()
		"saves":
			_dim.color = Color(0.05, 0.07, 0.08, 1.0) if _back_to == "title" else Color(0.03, 0.05, 0.06, 0.92)
			_build_saves()
		"new":
			_dim.color = Color(0.05, 0.07, 0.08, 1.0)
			_build_new()


func _page_root() -> MarginContainer:
	var m := MarginContainer.new()
	m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 40)
	add_child(m)
	_box = m
	return m


# ------------------------------------------------------------------ title
func _build_title() -> void:
	var m := _page_root()
	var center := CenterContainer.new()
	m.add_child(center)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	center.add_child(v)
	var t := _label("流民帅：南北朝", 72, GOLD)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var sub := _label("架空乱世 · 骑砍式战略沙盒", 22, CREAM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sub)
	v.add_child(_rule())
	v.add_child(_spacer(22))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	var holder := CenterContainer.new()
	holder.add_child(col)
	v.add_child(holder)
	var cont := _menu_button(col, "继续游戏", _continue)
	var latest := _latest_save()
	if host.session_active():
		cont.tooltip_text = "回到当前的战局"
	elif not latest.is_empty():
		cont.tooltip_text = "读取最近的存档：%s" % _save_line(latest)
	else:
		cont.disabled = true
	_menu_button(col, "新的游戏", show_new)
	_menu_button(col, "读取存档", func(): show_saves(false, "title"))
	_menu_button(col, "设置", func(): host.settings.open())
	_menu_button(col, "退出游戏", func(): get_tree().quit())
	var note := ""
	if host.session_active():
		note = "战局进行中：" + host.clock_text()
	elif not latest.is_empty():
		note = "最近的存档：" + _save_line(latest)
	var nl := _label(note, 14, MUTED)
	nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(nl)
	v.add_child(_spacer(30))
	var lore := _label("周朝崩塌已二十余年。北方诸部攻陷洛阳，周室南渡，六国并立，流民遍野。", 15, MUTED)
	lore.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(lore)


func _rule() -> Control:
	var c := ColorRect.new()
	c.color = Color(EDGE, 0.9)
	c.custom_minimum_size = Vector2(520, 2)
	var h := CenterContainer.new()
	h.add_child(c)
	return h


func _continue() -> void:
	if host.session_active():
		close()
		return
	var latest := _latest_save()
	if not latest.is_empty():
		host.load_slot(str(latest.slot))


func _latest_save() -> Dictionary:
	var best: Dictionary = {}
	for s in _saves:
		if bool(s.get("empty", true)) or bool(s.get("broken", false)):
			continue
		if best.is_empty() or float(s.get("saved_at", 0)) > float(best.get("saved_at", 0)):
			best = s
	return best


# ------------------------------------------------------------------ pause
func _build_pause() -> void:
	var m := _page_root()
	var center := CenterContainer.new()
	m.add_child(center)
	var panel := _panel(center, Vector2(380, 0))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	var t := _label("暂停", 28, GOLD)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var sub := _label(host.clock_text(), 14, MUTED)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sub)
	v.add_child(_spacer(6))
	_menu_button(v, "继续", close)
	var sv := _menu_button(v, "保存游戏", func(): show_saves(true, "pause"))
	if not host.can_save():
		sv.disabled = true
		sv.tooltip_text = "先关掉当前的菜单（城镇、对话、交易…）再存档"
	_menu_button(v, "读取存档", func(): show_saves(false, "pause"))
	_menu_button(v, "设置", func(): host.settings.open())
	_menu_button(v, "返回主菜单", show_title)
	var q := _menu_button(v, "再点一次退出（未存的进度会丢失）" if _armed == "quit" else "退出游戏", func():
		if _armed == "quit":
			get_tree().quit()
		else:
			_armed = "quit"
			_build())
	if _armed == "quit":
		q.add_theme_color_override("font_color", RED)
	# developer bits that used to sit in the side panel
	v.add_child(_spacer(8))
	var dev := HBoxContainer.new()
	dev.add_theme_constant_override("separation", 6)
	dev.add_child(_label("AI 档位", 13, MUTED))
	var tier := OptionButton.new()
	tier.focus_mode = Control.FOCUS_NONE
	_fill_tiers(tier)
	tier.item_selected.connect(func(i): host.api.set_tier(tier.get_item_id(i)))
	tier.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dev.add_child(tier)
	var reload := Button.new()
	reload.text = "重载规则"
	reload.focus_mode = Control.FOCUS_NONE
	reload.tooltip_text = "重新读取 rules/*.toml（数值、准则、AI 档位），不重开游戏"
	reload.pressed.connect(func(): host.api.reload_rules())
	dev.add_child(reload)
	v.add_child(dev)


# ------------------------------------------------------------------ saves
func _build_saves() -> void:
	var m := _page_root()
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 14)
	m.add_child(outer)
	outer.add_child(_label("保存游戏" if _save_mode else "读取存档", 30, GOLD))
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 18)
	outer.add_child(row)

	# left: the slots
	var lp := _panel(row, Vector2(460, 0))
	lp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	lp.add_child(list)
	if _saves.is_empty():
		list.add_child(_label("正在读取存档列表…", 15, MUTED))
	if _sel == "" and not _saves.is_empty():
		_sel = _default_slot()
	for s in _saves:
		var slot: String = str(s.slot)
		if _save_mode and slot == "auto":
			continue                       # the auto-save is written by the game, not by you
		var b := Button.new()
		b.toggle_mode = true
		b.button_pressed = slot == _sel
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 52)
		b.add_theme_font_size_override("font_size", 16)
		var name := str(s.get("name", slot))
		if bool(s.get("empty", true)):
			b.text = "  %s　（空）" % name
			b.add_theme_color_override("font_color", MUTED)
		elif bool(s.get("broken", false)):
			b.text = "  %s　（存档损坏）" % name
			b.add_theme_color_override("font_color", RED)
		else:
			b.text = "  %s　第 %d 天 · %s" % [name, int(s.day), str(s.get("who", ""))]
		b.pressed.connect(func():
			_sel = slot
			_armed = ""
			_build())
		list.add_child(b)

	# right: the chosen slot
	var rp := _panel(row, Vector2(0, 0))
	rp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var dv := VBoxContainer.new()
	dv.add_theme_constant_override("separation", 10)
	rp.add_child(dv)
	var cur := _slot(_sel)
	var empty := cur.is_empty() or bool(cur.get("empty", true))
	if not cur.is_empty():
		dv.add_child(_label(str(cur.get("name", _sel)), 24, GOLD))
		if bool(cur.get("broken", false)):
			dv.add_child(_label("这个存档已损坏，无法读取。", 16, RED))
		elif empty:
			dv.add_child(_label("空存档位", 16, MUTED))
		else:
			var lvl = cur.get("level")
			var info := RichTextLabel.new()
			info.bbcode_enabled = true
			info.fit_content = true
			info.scroll_active = false
			info.add_theme_font_size_override("normal_font_size", 17)
			info.add_theme_color_override("default_color", CREAM)
			info.text = ("[b]%s[/b]%s\n第 %d 天 %02d 时\n金 %d · 部队 %d 人 · 名望 %d\n地图种子 %d\n[color=#8c9a94]存于 %s[/color]") % [
				str(cur.get("who", "")), ("　%d 级" % int(lvl)) if lvl != null else "",
				int(cur.day), int(cur.get("hour", 0)), int(cur.get("gold", 0)), int(cur.get("troops", 0)),
				int(cur.get("renown", 0)), int(cur.get("seed", 0)), _when(cur)]
			dv.add_child(info)
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dv.add_child(fill)
	var note := ""
	if _save_mode:
		note = "每 3 天自动存档一次（自动存档位）。" if host.can_save() else "先关掉当前的菜单（城镇、对话、交易…）再存档。"
	elif host.session_active():
		note = "读取后，当前战局里没存的进度会丢失。"
	if _save_dir != "":
		note += "\n存档位置：" + _save_dir
	var nl := _label(note, 13, MUTED)
	nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dv.add_child(nl)
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 10)
	btns.alignment = BoxContainer.ALIGNMENT_END
	dv.add_child(btns)
	var back_btn := _button("返回", _leave_saves)
	btns.add_child(back_btn)
	if _save_mode:
		var overwrite := not empty
		var go := _button("再点一次覆盖" if _armed == "save" else ("覆盖此存档" if overwrite else "保存到这里"), func():
			if overwrite and _armed != "save":
				_armed = "save"
				_build()
				return
			_armed = ""
			host.api.save_game(_sel))
		go.disabled = cur.is_empty() or not host.can_save()
		btns.add_child(go)
	else:
		var confirm: bool = host.session_active()
		var go := _button("再点一次读取" if _armed == "load" else "读取", func():
			if confirm and _armed != "load":
				_armed = "load"
				_build()
				return
			_armed = ""
			host.load_slot(_sel))
		go.disabled = empty or bool(cur.get("broken", false))
		btns.add_child(go)


func _default_slot() -> String:
	if not _save_mode:
		var latest := _latest_save()
		if not latest.is_empty():
			return str(latest.slot)
	for s in _saves:
		if str(s.slot) != "auto" and (not _save_mode or bool(s.get("empty", true))):
			return str(s.slot)
	return str(_saves[0].slot) if not _save_mode else "1"


func _slot(slot: String) -> Dictionary:
	for s in _saves:
		if str(s.slot) == slot:
			return s
	return {}


# ------------------------------------------------------------------ new game
var _seed_box: SpinBox
var _tier_opt: OptionButton


func _build_new() -> void:
	var m := _page_root()
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 14)
	m.add_child(outer)
	# steps along the top
	var steps := HBoxContainer.new()
	steps.add_theme_constant_override("separation", 24)
	outer.add_child(steps)
	for i in 3:
		var names := ["① 开局", "② 出身", "③ 家世"]
		steps.add_child(_label(names[i], 20, GOLD if i == _new_step else (CREAM if i < _new_step else MUTED)))
	var body := VBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	outer.add_child(body)
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 10)
	outer.add_child(nav)

	if _busy != "":
		var c := CenterContainer.new()
		c.size_flags_vertical = Control.SIZE_EXPAND_FILL
		c.add_child(_label(_busy, 22, CREAM))
		body.add_child(c)
		return

	if _new_step == 0:
		body.add_child(_label("开局设置", 30, GOLD))
		var p := _panel(body, Vector2(640, 0))
		p.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		var g := GridContainer.new()
		g.columns = 2
		g.add_theme_constant_override("h_separation", 16)
		g.add_theme_constant_override("v_separation", 12)
		p.add_child(g)
		g.add_child(_label("地图种子", 17, CREAM))
		var sr := HBoxContainer.new()
		_seed_box = SpinBox.new()
		_seed_box.min_value = 0
		_seed_box.max_value = 99999
		_seed_box.value = host.current_seed()
		_seed_box.custom_minimum_size = Vector2(140, 0)
		sr.add_child(_seed_box)
		var rnd := _button("随机", func(): _seed_box.value = randi() % 100000)
		sr.add_child(rnd)
		g.add_child(sr)
		g.add_child(_label("将领 AI", 17, CREAM))
		_tier_opt = OptionButton.new()
		_tier_opt.custom_minimum_size = Vector2(320, 0)
		_fill_tiers(_tier_opt)
		g.add_child(_tier_opt)
		var tip := _label("同一个种子生成同一片天下：城池、村落、匪巢的位置和各国将领都一样。\n将领 AI：0 档完全离线（规则 AI）；更高档位让将领用大模型思考（需要在 server/local.toml 配置 API key）。", 14, MUTED)
		tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tip.custom_minimum_size = Vector2(640, 0)
		body.add_child(tip)
		if host.session_active():
			body.add_child(_label("注意：开始新游戏后，当前战局里没存的进度会丢失。", 15, RED))
		nav.add_child(_button("返回", show_title))
		nav.add_child(_grow())
		nav.add_child(_button("下一步：选择出身", func():
			_busy = "正在生成天下…"
			_build()
			host.new_game(int(_seed_box.value), _tier_opt.get_selected_id() if _tier_opt.item_count > 0 else -1)))
		return

	# 出身 / 家世: the server's creation menu as cards
	body.add_child(_label(str(_create_menu.get("title", "")), 30, GOLD))
	var intro := _label(str(_create_menu.get("text", "")), 16, CREAM)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(intro)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(sc)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	sc.add_child(grid)
	var has_back := false
	for o in _create_menu.get("options", []):
		if str(o.id) == "back":
			has_back = true
			continue
		grid.add_child(_card(o))
	if has_back:
		nav.add_child(_button("上一步：重选出身", func(): host.api.act("back")))
	else:
		nav.add_child(_button("上一步：开局设置", show_new))
	nav.add_child(_grow())
	nav.add_child(_label("点选一项继续", 14, MUTED))


func _card(o: Dictionary) -> Control:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 118)
	b.disabled = not bool(o.get("enabled", true))
	var v := VBoxContainer.new()
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 16
	v.offset_right = -16
	v.offset_top = 12
	v.offset_bottom = -10
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 6)
	b.add_child(v)
	var t := _label(str(o.label), 21, GOLD)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(t)
	var d := _label(str(o.get("hint", "")), 14, CREAM)
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(d)
	var data := {"choice": o.get("choice")}
	var id := str(o.id)
	b.pressed.connect(func():
		_busy = "正在安排你的起点…" if id == "background" else ""
		if _busy != "":
			_build()
		host.api.act(id, data))
	return b


# ================================================================== helpers
func _fill_tiers(opt: OptionButton) -> void:
	var tiers: Dictionary = host.ai_info.get("tiers", {})
	var keys := tiers.keys()
	keys.sort()
	for k in keys:
		opt.add_item("%s 档 · %s" % [k, tiers[k].name], int(k))
		opt.set_item_tooltip(opt.item_count - 1, str(tiers[k].description))
	if opt.item_count > 0:
		opt.select(maxi(0, opt.get_item_index(int(host.ai_info.get("tier", 0)))))


func _menu_column(parent: Control) -> VBoxContainer:
	var c := VBoxContainer.new()
	c.alignment = BoxContainer.ALIGNMENT_CENTER
	c.custom_minimum_size = Vector2(320, 0)
	c.add_theme_constant_override("separation", 10)
	parent.add_child(c)
	return c


func _menu_button(parent: Control, text: String, cb: Callable) -> Button:
	var b := _button(text, cb)
	b.custom_minimum_size = Vector2(300, 50)
	b.add_theme_font_size_override("font_size", 20)
	parent.add_child(b)
	return b


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(110, 40)
	b.add_theme_font_size_override("font_size", 17)
	b.pressed.connect(cb)
	return b


func _panel(parent: Control, min_size: Vector2) -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = min_size
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.12, 0.14, 0.96)
	sb.border_color = EDGE
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(18)
	p.add_theme_stylebox_override("panel", sb)
	parent.add_child(p)
	return p


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


func _grow() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


func _save_line(s: Dictionary) -> String:
	return "%s · 第 %d 天 · %s" % [str(s.get("name", s.slot)), int(s.get("day", 0)), str(s.get("who", ""))]


func _when(s: Dictionary) -> String:
	var tz := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	return Time.get_datetime_string_from_unix_time(int(float(s.get("saved_at", 0))) + tz, true)
