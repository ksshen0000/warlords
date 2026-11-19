extends Control
## Warlords client: campaign map with the player's party, M&B-style time (paused unless
## travelling or holding space), menus, side panel (party / details / realms / council), chronicle.
##
## Command line (after `--`): --server=URL --seed=N --steps=N --select=kind:id --hover=settlement:id --tab=N --speed=N
##                            --zoom=x,y,z --report=last --capture=PATH --goto=x,y --menu=leave

const ApiScript := preload("res://scripts/api.gd")
const MapViewScript := preload("res://scripts/map_view.gd")
const BattleReportScript := preload("res://scripts/battle_report.gd")
const PlayerMenuScript := preload("res://scripts/player_menu.gd")
const SettingsScript := preload("res://scripts/settings.gd")

const SPEEDS := [["慢", 0.8], ["正常", 0.4], ["快", 0.18], ["很快", 0.08], ["极快", 0.035]]   # real seconds per game hour
const KIND_NAMES := {"lord": "将军部曲", "caravan": "商队", "villager": "村民", "bandit": "匪寇",
	"hunter": "游侠", "merc": "义从", "player": "你的部队", "refugee": "流民"}
const ORDER_NAMES := {"recruit": "招募", "besiege": "围攻", "defend": "驻防", "attack": "追击", "raid": "劫掠",
	"hideout": "剿匪", "patrol": "巡逻", "sell": "出售俘虏", "rest": "休整", "caravan": "组建商队",
	"wait": "待命", "retreat": "撤退", "follow": "随军"}
const MODE_NAMES := {"idle": "驻留", "move": "行军", "siege": "围城", "raid": "劫掠", "inside": "城内",
	"flee": "撤退", "chase": "追击", "follow": "随军"}
const TRAITS := {"aggression": "好战", "caution": "谨慎", "honor": "荣誉", "greed": "贪婪"}
const MINOR := ["order", "recruit", "speech", "release", "siege_end", "flee", "prisoners_sold",
	"desertion", "raid_start", "caravan_founded", "brain_error", "hideout_new", "decision_opened", "refugees"]
const REPORT_TYPES := ["battle", "conquest", "assault_failed", "hideout_cleared"]
# news that reaches you from anywhere (a city changing hands, wars, peace, a realm falling…);
# everything else is only recorded when it happens within sight or concerns your own realm
const NEWS := ["war", "peace", "conquest", "rebellion", "kingdom_destroyed", "defection", "succession", "execution",
	"recruit_captive", "fief_granted", "unrest", "starvation", "player", "player_war", "player_defeated"]
const EVENT_COLORS := {
	"battle": "e8a25b", "conquest": "f2c75c", "rebellion": "f2c75c", "war": "ff6b5b", "peace": "8fd3a0",
	"peace_rejected": "c8a878", "capture": "c99cff", "ransom": "c99cff", "defection": "ff8fb1",
	"siege_start": "e57373", "assault_failed": "9fb4bf", "raid": "ff9a5a", "kingdom_destroyed": "ff4b4b",
	"decision_resolved": "8fc6ff", "fief_granted": "8fc6ff", "army_formed": "b6d77a", "army_disbanded": "9fb4bf",
	"merc_hired": "b48ce0", "merc_left": "9fb4bf", "hideout_cleared": "d9b44a", "unrest": "d0a070",
	"starvation": "a1887f", "speech": "d8dfe2", "order": "7d8f96",
	"player": "9ff0b0", "player_war": "ff6b5b", "player_defeated": "ff6b5b",
	"quest": "f2c75c", "quest_done": "f2c75c", "quest_failed": "ff8f8f",
}
const PANEL_BG := Color("1b252b")
const CREAM := Color("efe6d2")
const MUTED := Color("8c9a94")
const GOLD := Color("f2c75c")

var api: Node
var map: Control
var report_popup: Control
var menu_panel: PanelContainer
var settings: Control
var state: Dictionary = {}
var player: Dictionary = {}
var ai_info: Dictionary = {}
var goods := {}
var connected := false
var speed_idx := 1
var wait_left := 0.0
var retry_left := 0.0
var log_lines: Array = []
var report_events := {}
var _report_seq := 0
var show_minor := false
var follow := true
var hold := false          # key 1: pause even while travelling (cleared by 2/3/4, Space or a new order)
var map_seed := -1
var toast_left := 0.0

var auto_steps := 0
var capture_path := ""
var pending_select := ""
var pending_report := false
var pending_zoom := ""
var pending_tab := -1
var pending_goto := ""
var pending_menu := ""

var time_label: Label
var clock_label: Label
var status_label: Label
var toast_label: Label
var speed_opt: OptionButton
var seed_box: SpinBox
var tier_opt: OptionButton
var tabs: TabContainer
var party_text: RichTextLabel
var detail_text: RichTextLabel
var realms_text: RichTextLabel
var council_text: RichTextLabel
var log_text: RichTextLabel


func _ready() -> void:
	var font: Font = load("res://assets/fonts/DroidSansFallbackFull.ttf")
	var theme := Theme.new()
	theme.default_font = font
	theme.default_font_size = 15
	ThemeDB.fallback_font = font
	get_tree().root.theme = theme
	api = ApiScript.new()
	add_child(api)
	api.response.connect(_on_response)
	api.failed.connect(_on_failed)
	_build_ui()
	_parse_args()
	api.get_map()
	api.get_state()


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--server="):
			api.base_url = a.substr(9)
		elif a.begins_with("--steps="):
			auto_steps = int(a.substr(8))
		elif a.begins_with("--capture="):
			capture_path = a.substr(10)
		elif a.begins_with("--select="):
			pending_select = a.substr(9)
		elif a.begins_with("--zoom="):
			pending_zoom = a.substr(7)
		elif a.begins_with("--speed="):
			speed_idx = clamp(int(a.substr(8)), 0, SPEEDS.size() - 1)
			speed_opt.selected = speed_idx
		elif a.begins_with("--tab="):
			pending_tab = int(a.substr(6))
		elif a.begins_with("--goto="):
			pending_goto = a.substr(7)
		elif a.begins_with("--menu="):
			pending_menu = a.substr(7)
		elif a.begins_with("--hover="):
			map.pin_hover = a.substr(8)
		elif a == "--settings":
			settings.open.call_deferred()
		elif a == "--report=last":
			pending_report = true
		elif a.begins_with("--seed="):
			seed_box.value = int(a.substr(7))
			api.reset(int(seed_box.value), -1)


# ------------------------------------------------------------------ UI
func _style(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_content_margin_all(10)
	sb.set_corner_radius_all(6)
	return sb


func _label(text: String, fsize: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", fsize)
	l.add_theme_color_override("font_color", color)
	return l


func _rich() -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.add_theme_font_size_override("normal_font_size", 14)
	r.add_theme_font_size_override("bold_font_size", 15)
	r.add_theme_color_override("default_color", CREAM)
	r.meta_underlined = false
	r.meta_clicked.connect(_on_meta)
	r.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return r


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color("10171b")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var root := HBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	var map_holder := Control.new()
	map_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(map_holder)
	map = MapViewScript.new()
	map.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	map.hint = "左键 行军 · 按住空格 等待 · 1 暂停 2 正常 3 快进 · P 部队 N 百科 K 朝议 L 日志 · 按住 Alt 显示名字 · F 回到自己 · Esc 菜单"
	map.selection_changed.connect(func(_k, _i):
		if _k != "" and _k != "player":
			tabs.current_tab = 1
		_refresh_details())
	map.map_clicked.connect(_on_map_clicked)
	map_holder.add_child(map)

	clock_label = _label("", 15, GOLD)
	clock_label.position = Vector2(14, 10)
	map_holder.add_child(clock_label)
	toast_label = _label("", 15, Color("9ff0b0"))
	toast_label.position = Vector2(14, 34)
	map_holder.add_child(toast_label)

	var menu_anchor := CenterContainer.new()
	menu_anchor.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	menu_anchor.offset_top = -10
	menu_anchor.grow_vertical = Control.GROW_DIRECTION_BEGIN
	menu_anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_holder.add_child(menu_anchor)
	menu_panel = PlayerMenuScript.new()
	menu_panel.action.connect(func(id, data): api.act(id, data))
	menu_panel.say.connect(func(hero, text): api.talk(hero, text))
	menu_anchor.add_child(menu_panel)

	var side_margin := MarginContainer.new()
	side_margin.custom_minimum_size = Vector2(500, 0)
	for m in ["left", "right", "top", "bottom"]:
		side_margin.add_theme_constant_override("margin_" + m, 8)
	root.add_child(side_margin)
	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 6)
	side_margin.add_child(side)

	var head := HBoxContainer.new()
	head.add_child(_label("战旗领主", 22, GOLD))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	time_label = _label("第 0 天", 20, CREAM)
	head.add_child(time_label)
	var gear := Button.new()
	gear.text = "设置"
	gear.tooltip_text = "显示模式、分辨率、界面缩放、鼠标锁定（F11 全屏，F10 锁/解鼠标）"
	gear.focus_mode = Control.FOCUS_NONE
	gear.pressed.connect(func(): settings.open())
	head.add_child(gear)
	side.add_child(head)
	status_label = _label("连接中…", 13, MUTED)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(status_label)

	var row := HBoxContainer.new()
	row.add_child(_label("时间流速", 14, MUTED))
	speed_opt = OptionButton.new()
	for s in SPEEDS:
		speed_opt.add_item(s[0])
	speed_opt.selected = speed_idx
	speed_opt.item_selected.connect(func(i): speed_idx = i)
	row.add_child(speed_opt)
	var fol := CheckBox.new()
	fol.text = "跟随"
	fol.button_pressed = true
	fol.tooltip_text = "行军时镜头跟随你的部队"
	fol.toggled.connect(func(on): follow = on)
	row.add_child(fol)
	var minor := CheckBox.new()
	minor.text = "琐事"
	minor.tooltip_text = "编年史显示全部：视野外的战斗、各国朝议，以及命令、招募、台词等琐事（不勾选时只记你听得到的消息）"
	minor.toggled.connect(func(on): show_minor = on; _render_log())
	row.add_child(minor)
	var terr := CheckBox.new()
	terr.text = "政区"
	terr.button_pressed = true
	terr.toggled.connect(func(on): map.show_territory = on)
	row.add_child(terr)
	side.add_child(row)

	var row2 := HBoxContainer.new()
	row2.add_child(_label("AI", 14, MUTED))
	tier_opt = OptionButton.new()
	tier_opt.tooltip_text = "AI 参与程度（rules/ai.toml）"
	tier_opt.item_selected.connect(func(i): api.set_tier(tier_opt.get_item_id(i)))
	row2.add_child(tier_opt)
	row2.add_child(_label(" 种子", 14, MUTED))
	seed_box = SpinBox.new()
	seed_box.min_value = 0
	seed_box.max_value = 99999
	seed_box.value = 3
	row2.add_child(seed_box)
	var reset_btn := Button.new()
	reset_btn.text = "新的一局"
	reset_btn.pressed.connect(func():
		api.reset(int(seed_box.value), int(ai_info.get("tier", -1)))
		status_label.text = "正在生成新世界…")
	row2.add_child(reset_btn)
	var reload_btn := Button.new()
	reload_btn.text = "重载规则"
	reload_btn.tooltip_text = "重新读取 rules/balance.toml、doctrine.toml、ai.toml（不重开游戏）"
	reload_btn.pressed.connect(func(): api.reload_rules())
	row2.add_child(reload_btn)
	side.add_child(row2)

	tabs = TabContainer.new()
	tabs.custom_minimum_size = Vector2(0, 360)
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.size_flags_stretch_ratio = 1.3
	party_text = _rich()
	party_text.name = "部队"
	detail_text = _rich()
	detail_text.name = "详情"
	realms_text = _rich()
	realms_text.name = "诸国"
	council_text = _rich()
	council_text.name = "朝议"
	for r in [party_text, detail_text, realms_text, council_text]:
		tabs.add_child(r)
	for i in 4:
		tabs.set_tab_title(i, ["部队 P", "详情 N", "诸国 N", "朝议 K"][i])
	tabs.tab_changed.connect(func(_i): _refresh_tabs())
	side.add_child(tabs)

	var lp := PanelContainer.new()
	lp.add_theme_stylebox_override("panel", _style(PANEL_BG))
	lp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var lv := VBoxContainer.new()
	lv.add_child(_label("编年史（点击跳转地图位置）", 12, MUTED))
	log_text = _rich()
	log_text.scroll_following = true
	lv.add_child(log_text)
	lp.add_child(lv)
	side.add_child(lp)

	report_popup = BattleReportScript.new()
	add_child(report_popup)
	settings = SettingsScript.new()
	add_child(settings)
	map.settings = settings


func _fill_tiers() -> void:
	var tiers: Dictionary = ai_info.get("tiers", {})
	if tiers.is_empty():
		return
	var keys := tiers.keys()
	keys.sort()
	if tier_opt.item_count != keys.size():
		tier_opt.clear()
		for k in keys:
			tier_opt.add_item("%s 档 · %s" % [k, tiers[k].name], int(k))
			tier_opt.set_item_tooltip(tier_opt.item_count - 1, str(tiers[k].description))
	tier_opt.select(tier_opt.get_item_index(int(ai_info.get("tier", 0))))


# ------------------------------------------------------------- control
func _menu_open() -> bool:
	return player.get("menu") != null


func _typing() -> bool:
	var f := get_viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit


func _on_map_clicked(world_pos: Vector2, kind: String, id: String, shift: bool) -> void:
	if shift:
		map.select(kind, id)
		return
	if kind != "":
		map.select(kind, id)
	if _menu_open() or player.get("captive", false):
		return
	if kind == "party" and id == "player":
		tabs.current_tab = 0
		return
	hold = false
	if kind == "settlement":
		api.move({"kind": "place", "id": id})
	elif kind == "party":
		api.move({"kind": "party", "id": id})
	else:
		api.move({"kind": "point", "pos": [world_pos.x, world_pos.y]})
	if follow:
		map.follow_id = "player"


## Mount & Blade style keys. Warband: time passes while you travel or hold Space;
## Bannerlord: 1 pause / 2 play / 3 fast forward, C·P·I party, N encyclopedia, K kingdom,
## L / Q log, Alt names, Esc closes the top window or opens the game menu.
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var key := (event as InputEventKey).keycode
	if report_popup.visible:
		if key in [KEY_ESCAPE, KEY_ENTER, KEY_KP_ENTER]:
			report_popup.close()
			get_viewport().set_input_as_handled()
		return
	if settings.visible or _typing():
		return
	var handled := true
	match key:
		KEY_ESCAPE:
			if map.sel_kind != "":
				map.select("", "")
			elif _menu_open() and _menu_has("leave"):
				api.act("leave")
			elif _menu_open() and _menu_has("ok"):
				api.act("ok")
			else:
				settings.open()
		KEY_1:
			hold = true
			_toast("暂停（2 继续 · 3 快进）")
		KEY_2:
			_set_speed(1)
		KEY_3:
			_set_speed(2)
		KEY_4:
			_set_speed(3)
		KEY_5:
			_set_speed(4)
		KEY_C, KEY_P, KEY_I:
			tabs.current_tab = 0
		KEY_N:
			tabs.current_tab = 1 if map.sel_kind != "" else 2
		KEY_K:
			tabs.current_tab = 3
		KEY_L, KEY_Q:
			log_text.scroll_to_line(max(0, log_text.get_line_count() - 1))
			log_text.grab_focus()
		KEY_T:
			# Warband "Camp": wait here (time passes while held; tap to show the hint)
			_toast("按住空格在此扎营等待")
		KEY_HOME:
			map.fit()
		KEY_F, KEY_TAB:
			if state.has("parties") and state.parties.has("player"):
				map.focus(map.party_world_pos("player"), max(map.zoom, map.close_zoom(3.0)))
				if follow:
					map.follow_id = "player"
		_:
			handled = false
	if handled:
		get_viewport().set_input_as_handled()


func _menu_has(id: String) -> bool:
	for o in player.get("menu", {}).get("options", []):
		if o.id == id and bool(o.enabled):
			return true
	return false


func _set_speed(i: int) -> void:
	hold = false
	speed_idx = i
	speed_opt.selected = i
	_toast("时间流速：%s" % SPEEDS[i][0])


func _focus_selection() -> void:
	if map.sel_kind == "party" and state.parties.has(map.sel_id):
		map.focus(map.party_world_pos(map.sel_id), max(map.zoom, map.close_zoom(3.0)))
	elif map.sel_kind == "settlement" and state.settlements.has(map.sel_id):
		map.focus(map.settlement_pos(map.sel_id), max(map.zoom, map.close_zoom(3.0)))


func _time_wanted() -> bool:
	if not connected or _menu_open() or report_popup.visible or settings.visible or map_seed < 0:
		return false
	var space := Input.is_key_pressed(KEY_SPACE) and not _typing()
	if hold and not space:
		return false
	if auto_steps > 0:
		return true
	if player.get("captive", false):
		return true
	if space:
		hold = false
	return bool(player.get("moving", false)) or space


func _process(delta: float) -> void:
	if toast_left > 0:
		toast_left -= delta
		if toast_left <= 0:
			toast_label.text = ""
	if not connected:
		retry_left -= delta
		if retry_left <= 0.0 and not api.pending():
			retry_left = 2.0
			api.get_state()
			if map_seed < 0:
				api.get_map()
		return
	var flowing := _time_wanted()
	map.time_flowing = flowing
	if flowing:
		wait_left -= delta
		if wait_left <= 0.0 and not api.pending():
			if api.step(1):
				wait_left = float(SPEEDS[speed_idx][1])
	if player.get("captive", false):
		clock_label.text = "⛓ 被俘中……时间流逝"
	elif _menu_open():
		clock_label.text = "⏸ 菜单"
	elif settings.visible:
		clock_label.text = "⏸ 设置"
	elif hold:
		clock_label.text = "⏸ 已暂停（2 继续 · 3 快进 · 空格等待）"
	elif flowing:
		clock_label.text = "▶ 时间流逝 · %s" % SPEEDS[speed_idx][0]
	else:
		clock_label.text = "⏸ 暂停（左键行军，按住空格等待）"
	var ms: String = settings.status_text()
	if ms != "":
		clock_label.text += "　·　" + ms
	if not flowing and capture_path != "" and not api.pending() and not map.animating() and map_seed >= 0:
		_capture()


func _toast(text: String) -> void:
	toast_label.text = text
	toast_left = 4.0


func _capture() -> void:
	var path := capture_path
	capture_path = ""
	if pending_report:
		pending_report = false
		var ids := report_events.keys()
		var pick = null
		for i in range(ids.size() - 1, -1, -1):
			var ev: Dictionary = report_events[ids[i]]
			if pick == null or (ev.get("player", false) and not pick.get("player", false)):
				pick = ev
		if pick != null:
			report_popup.open(pick, state)
	await get_tree().create_timer(2.0).timeout
	await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		get_viewport().get_texture().get_image().save_png(path)
		print("captured ", path)
	print("WARLORDS_OK day=%d events=%d parties=%d menu=%s gold=%s" % [int(state.day), log_lines.size(),
		state.parties.size(), str(player.get("menu") != null), str(player.get("gold"))])
	print("DISPLAY driver=%s window=%s mode=%d mouse_mode=%d" % [DisplayServer.get_name(), str(get_window().size),
		get_window().mode, Input.mouse_mode])
	get_tree().quit()


# ------------------------------------------------------------- network
func _on_failed(kind: String, message: String) -> void:
	if kind in ["reset", "reload", "move", "act", "talk", "config"]:
		_toast(message)
		if kind == "talk":
			menu_panel.set_waiting(false)
		return
	if kind == "map":
		map_seed = -1
	connected = false
	map.status_text = "无法连接模拟服务器，请先运行：python3 -m warlords.server" if state.is_empty() else "与服务器断开，正在重连…"
	status_label.text = message


func _on_response(kind: String, data: Dictionary) -> void:
	var t_resp := Time.get_ticks_usec()
	_on_response_inner(kind, data)
	if kind == "step" and OS.get_cmdline_user_args().has("--prof"):
		print("PROF step: net %.1fms parse %.1fms (%d KB) apply %.1fms" % [api.prof.get("net", 0), api.prof.get("parse", 0),
			int(api.prof.get("bytes", 0)) / 1024, (Time.get_ticks_usec() - t_resp) / 1000.0])


func _on_response_inner(kind: String, data: Dictionary) -> void:
	if kind == "map":
		map_seed = int(data.seed)
		map.set_map(data.map)
		_apply_pending_view()
		return
	if kind == "talk":
		menu_panel.set_waiting(false)
	var result: Dictionary = data.get("result", {})
	if str(result.get("message", "")) != "":
		_toast(str(result.message))
	if kind == "reload":
		_toast("规则文档已重载（数值、准则、AI 档位立即生效）")
	connected = true
	map.status_text = ""
	var seed := int(data.get("seed", 0))
	if kind == "reset" or (kind == "state" and state.is_empty()):
		log_lines.clear()
		report_events.clear()
		map.speeches.clear()
		map.effects.clear()
		report_popup.close()
		menu_panel.close()
		seed_box.value = seed
		if seed != map_seed:
			api.get_map()
		map.follow_id = "player"
	state = data.state
	var was_creating := bool(player.get("creating", false))
	player = data.get("player", {})
	# fog of war: only what the player's scouts can see is drawn (creating a character = see all)
	map.vision = 0.0 if player.is_empty() or bool(player.get("creating", false)) else float(player.get("vision", 0.0))
	map.my_kingdom = player.get("kingdom")
	map.my_fiefs = player.get("fiefs", [])
	map.known_hideouts = player.get("known_hideouts", [])
	if was_creating and not bool(player.get("creating", false)) and state.has("parties"):
		# character creation just finished: fly the camera to where you start
		var pp: Dictionary = data.get("state", {}).get("parties", {}).get("player", {})
		if pp.has("pos"):
			map.focus.call_deferred(Vector2(pp.pos[0], pp.pos[1]), map.close_zoom(3.0))
	ai_info = data.get("ai", {})
	goods = state.get("goods", {})
	_fill_tiers()
	var to_open = null
	for ev in data.get("events", []):
		_handle_event(ev)
		if ev.has("_rid") and ev.get("player", false):
			to_open = ev
	map.set_state(state, float(SPEEDS[speed_idx][1]) * 0.95)
	if to_open != null:
		report_popup.open(to_open, state)
	if kind == "step" and auto_steps > 0:
		auto_steps -= 1
	if player.get("menu") != null and str(player.menu.get("type", "")) == "battle":
		menu_panel.close()
		map.follow_id = ""
		_start_battle(player.menu)
	elif player.get("menu") != null:
		menu_panel.open(player.menu)
		map.follow_id = ""
	else:
		menu_panel.close()
	if not bool(player.get("moving", false)) and not player.get("captive", false):
		map.follow_id = ""
	_apply_pending_actions()
	var pend := int(ai_info.get("pending", 0))
	var llm := str(ai_info.get("llm")) + " " + str(ai_info.get("model")) if ai_info.get("llm") != null else "无（规则 AI）"
	status_label.text = "AI：%s · %s 档「%s」%s · 种子 %d" % [llm, str(ai_info.get("tier", "?")),
		str(ai_info.get("tier_name", "")), ("· %d 位将军正在思考" % pend) if pend > 0 else "", seed]
	if str(ai_info.get("error", "")) != "":
		status_label.text += "\nLLM 不可用：" + str(ai_info.error)
	_refresh_all()


# ------------------------------------------------------------- 3D battles
var _battle: Node = null


## "亲自上阵": the server opened a battle — leave the map for the 3D field (client/battle), then send
## the casualties back. Headless runs (tests) let the troops fight it out instead.
func _start_battle(m: Dictionary) -> void:
	if _battle != null:
		return
	if DisplayServer.get_name() == "headless" or OS.get_cmdline_user_args().has("--no3d"):
		api.act("autoresolve")
		return
	var script: Script = load("res://battle/scripts/battle.gd")
	_battle = script.new()
	_battle.preset_setup = m.get("setup", {}).duplicate()
	_battle.preset_setup["battle_size"] = settings.battle_size
	_battle.embedded = true
	if OS.get_cmdline_user_args().has("--battle-auto"):
		_battle.auto = true                       # tests: the AI plays your character
	_battle.closed.connect(_on_battle_closed)
	visible = false
	process_mode = Node.PROCESS_MODE_DISABLED
	settings.external_mouse = true
	get_tree().root.add_child(_battle)


func _on_battle_closed(result: Dictionary) -> void:
	_battle = null
	visible = true
	process_mode = Node.PROCESS_MODE_INHERIT
	settings.external_mouse = false
	settings.apply_mouse()
	api.battle(result)


func _apply_pending_actions() -> void:
	if pending_select != "":
		var parts := pending_select.split(":")
		pending_select = ""
		map.select(parts[0], parts[1])
	if pending_tab >= 0:
		tabs.current_tab = pending_tab
		pending_tab = -1
	if pending_menu != "" and player.get("menu") != null and not api.pending():
		# --menu=origin:zhao,background:lowborn,leave  — one step per state update (tests / screenshots)
		var steps := pending_menu.split(",")
		var step: String = steps[0]
		steps.remove_at(0)
		pending_menu = ",".join(steps)
		var parts := step.split(":")
		api.act(parts[0], {"choice": parts[1]} if parts.size() > 1 else {})
	elif pending_goto != "" and player.get("menu") == null:
		var v := pending_goto.split(",")
		pending_goto = ""
		api.move({"kind": "point", "pos": [float(v[0]), float(v[1])]})


func _apply_pending_view() -> void:
	if pending_zoom == "":
		return
	var v := pending_zoom.split(",")
	if v.size() == 3:
		map.focus(Vector2(float(v[0]), float(v[1])), map.close_zoom(float(v[2])))


func _handle_event(ev: Dictionary) -> void:
	var t: String = ev.type
	var pos = ev.get("pos")
	if pos != null:
		var wp := Vector2(pos[0], pos[1])
		match t:
			"battle":
				map.add_effect("battle", wp, Color("ffa040"))
			"conquest":
				map.add_effect("conquest", wp, map.faction_color(ev.new), 2.4)
			"rebellion":
				map.add_effect("rebellion", wp, map.faction_color(ev.new), 2.4)
			"capture":
				map.add_effect("capture", wp, Color("c99cff"))
			"raid", "raid_start":
				map.add_effect("raid", wp, Color("ff7a30"))
			"hideout_cleared":
				map.add_effect("battle", wp, Color("d9b44a"))
	if t == "siege_start" and ev.has("settlement"):
		map.add_effect("siege", map.settlement_pos(ev.settlement), Color("e5534b"))
	if t == "speech" and ev.has("hero"):
		var txt: String = ev.text
		var i := txt.find("「")
		map.say(ev.hero, txt.substr(i + 1).trim_suffix("」") if i >= 0 else txt)
	if ev.get("player", false) and t in ["player", "player_war", "player_defeated", "ransom", "fief_granted", "quest_done", "quest_failed"]:
		_toast(str(ev.text))
	if t in REPORT_TYPES and ev.has("report"):
		_report_seq += 1
		ev["_rid"] = _report_seq
		report_events[_report_seq] = ev
		if report_events.size() > 400:
			report_events.erase(report_events.keys()[0])
	ev["_known"] = _heard_of(ev)
	log_lines.append(ev)
	if log_lines.size() > 800:
		log_lines = log_lines.slice(log_lines.size() - 800)


# -------------------------------------------------------------- render
func _refresh_all() -> void:
	var hour := int(state.hour) % 24
	time_label.text = "第 %d 天 %02d时" % [int(state.day), hour]
	_refresh_tabs()
	_render_log()


func _refresh_tabs() -> void:
	match tabs.current_tab:
		0:
			party_text.text = _player_panel()
		1:
			_refresh_details()
		2:
			realms_text.text = _realms()
		3:
			council_text.text = _council()


func _esc(s) -> String:
	return str(s).replace("[", "[lb]")


func _fcol(fid) -> String:
	if fid == null or not state.kingdoms.has(fid):
		return "aab4ae"
	return Color(state.kingdoms[fid].color).to_html(false)


func _fname(fid) -> String:
	if fid == null:
		return "无"
	if str(fid) == "__player":
		return "你"
	if state.kingdoms.has(fid):
		return state.kingdoms[fid].name
	return "匪寇" if str(fid) == "__bandit" else "中立"


func _hero_link(hid) -> String:
	if str(hid) == "player":
		return "[color=#9ff0b0]你[/color]"
	if hid == null or not state.heroes.has(hid):
		return "?"
	var h: Dictionary = state.heroes[hid]
	return "[url=hero:%s][color=#%s]%s[/color][/url]" % [hid, _fcol(h.kingdom), _esc(h.name)]


func _settle_link(sid) -> String:
	if sid == null or not state.settlements.has(sid):
		return "?"
	var s: Dictionary = state.settlements[sid]
	return "[url=settlement:%s][color=#%s]%s[/color][/url]" % [sid, _fcol(s.faction), _esc(s.name)]


func _kingdom_link(kid) -> String:
	if kid == null or not state.kingdoms.has(kid):
		return _fname(kid)
	return "[url=kingdom:%s][color=#%s]%s[/color][/url]" % [kid, _fcol(kid), _esc(state.kingdoms[kid].name)]


func _troop_table(troops: Array) -> String:
	if troops.is_empty():
		return "[color=#8c9a94]无[/color]\n"
	var out := "[table=3]"
	for t in troops:
		var cls: String = {"inf": "步", "arc": "射", "cav": "骑"}.get(t.cls, "")
		out += "[cell][color=#8c9a94]%s[/color]%s%s  [/cell][cell]%d[/cell][cell]%s[/cell]" % [
			cls, "★".repeat(int(t.tier)), _esc(t.name), int(t.healthy),
			"[color=#e8b86a]+%d伤[/color]" % int(t.wounded) if int(t.wounded) > 0 else ""]
	return out + "[/table]\n"


func _target_text(order) -> String:
	if order == null:
		return "无"
	var o: Dictionary = order
	var txt: String = ORDER_NAMES.get(o.type, o.type)
	var tgt = o.get("target")
	if tgt != null:
		if state.settlements.has(tgt):
			txt += " " + _settle_link(tgt)
		elif state.parties.has(tgt):
			var q: Dictionary = state.parties[tgt]
			txt += " " + (_hero_link(q.hero) if q.hero != null else _esc(q.name))
		elif state.heroes.has(tgt):
			txt += " " + _hero_link(tgt)
	if str(o.get("reason", "")) != "":
		txt += " [color=#8c9a94]——%s[/color]" % _esc(o.reason)
	return txt


func _refresh_details() -> void:
	if state.is_empty():
		return
	var k: String = map.sel_kind
	var id: String = map.sel_id
	if k == "party" and id == "player":
		detail_text.text = _player_panel()
	elif k == "party" and state.parties.has(id):
		var p: Dictionary = state.parties[id]
		detail_text.text = _hero_details(p.hero) if p.hero != null else _party_details(p)
	elif k == "hero" and state.heroes.has(id):
		detail_text.text = _hero_details(id)
	elif k == "settlement" and state.settlements.has(id):
		detail_text.text = _settlement_details(id)
	elif k == "kingdom" and state.kingdoms.has(id):
		detail_text.text = _kingdom_details(id)
	else:
		detail_text.text = ("[color=#8c9a94]点击地图上的人马、城池、村落查看详情。\n\n"
			+ "图例：城墙 = 城，塔楼 = 关塞，小屋 = 村落（冒烟 = 被劫掠），红色帐篷 = 匪巢；\n"
			+ "骑马举旗 = 将军（金边 = 君主，大旗 = 大军），紫边旗 = 义从，驮马 = 商队，\n"
			+ "牵驴的农夫 = 村民，举破红布的步行者 = 匪寇，两名持矛骑手 = 游侠，\n"
			+ "一串背包袱的灰衣人 = 流民（可收编、可安置到你的封地）。\n"
			+ "城池外的红圈 = 正被围攻，金色弧线 = 攻城器械进度。[/color]")


func _hero_details(hid: String) -> String:
	var h: Dictionary = state.heroes[hid]
	var kd: Dictionary = state.kingdoms[h.kingdom]
	var out := "[b][font_size=19]%s[/font_size][/b]  %s%s\n" % [_esc(h.name), _kingdom_link(h.kingdom),
		"  [color=#f2c75c]君主[/color]" if kd.ruler == hid else ""]
	out += "[color=#8c9a94]%s[/color]\n" % _esc(h.persona)
	var tr: Array[String] = []
	for t in TRAITS:
		tr.append("%s%+d" % [TRAITS[t], int(h.traits[t])])
	out += "性格：%s · 统御 %d\n" % ["  ".join(tr), int(h.tactics)]
	out += "金币 %d · 影响力 %d · 名望 %d" % [int(h.gold), int(h.influence), int(h.renown)]
	if kd.ruler != hid:
		out += " · 对君主好感 %+d" % int(h.relations.get(kd.ruler, 0))
	out += "\n"
	if str(h.captive_of) == "__dead":
		out += "[color=#ff8f8f]已被斩首[/color]\n"
	elif h.captive_of != null:
		out += "[color=#c99cff]被%s俘虏%s，已关押 %d 天[/color]\n" % [_fname(h.captive_of),
			("，关在" + _settle_link(h.captive_at)) if h.captive_at != null else "", int(h.captive_days)]
	elif h.party != null and state.parties.has(h.party) and not map.party_known(h.party):
		var ls: String = map.last_seen_text(h.party)
		out += "[color=#8c9a94]行踪不明（不在你的视野内）%s[/color]\n" % (("——" + ls) if ls != "" else "")
	elif h.party != null and state.parties.has(h.party):
		var p: Dictionary = state.parties[h.party]
		out += "部队：[b]%d[/b] 人（伤 %d）· 战力 %d · 日行 %d 里 · %s\n" % [int(p.size), int(p.wounded), int(p.power),
			int(p.speed), MODE_NAMES.get(p.mode, p.mode)]
		out += "任务：%s\n" % _target_text(p.order)
		if p.army != null and state.armies.has(p.army):
			var a: Dictionary = state.armies[p.army]
			var ms: Array[String] = []
			for m in a.members:
				ms.append(_hero_link(m))
			out += "军团：统帅 %s，成员 %s，军心 %d\n" % [_hero_link(a.leader), "、".join(ms), int(a.cohesion)]
		if int(p.prisoners) > 0:
			out += "押送俘虏 %d 人\n" % int(p.prisoners)
		out += _troop_table(p.troops)
	if str(h.last_speech) != "":
		out += "[i]「%s」[/i]\n" % _esc(h.last_speech)
	var fiefs: Array[String] = []
	for sid in state.settlements:
		var s: Dictionary = state.settlements[sid]
		if s.owner == hid and (s.kind == "town" or s.kind == "castle"):
			fiefs.append(_settle_link(sid))
	out += "封地：%s\n" % ("、".join(fiefs) if fiefs.size() else "无")
	if h.caravans.size():
		out += "商队：%d 支\n" % h.caravans.size()
	var rels: Array = []
	for o in h.relations:
		if state.heroes.has(o) and int(h.relations[o]) != 0:
			rels.append([int(h.relations[o]), o])
	rels.sort_custom(func(a, b): return abs(a[0]) > abs(b[0]))
	if rels.size():
		var parts: Array[String] = []
		for r in rels.slice(0, 6):
			parts.append("%s [color=#%s]%+d[/color]" % [_hero_link(r[1]), "8fd3a0" if r[0] > 0 else "ff8f8f", r[0]])
		out += "人际：%s\n" % "  ".join(parts)
	if h.memory.size():
		out += "[color=#8c9a94]记忆：[/color]\n"
		for m in h.memory:
			out += "[color=#b8c4bf]  · %s[/color]\n" % _esc(m)
	return out


func _player_panel() -> String:
	if player.is_empty() or not state.parties.has("player"):
		return "[color=#8c9a94]（没有玩家部队）[/color]"
	if bool(player.get("creating", false)):
		return "[color=#8c9a94]正在创建角色：先选出身地区，再选家世。\n\n出身决定你的文化、兵源与起点；家世决定起始的钱、部众、名望与门第。[/color]"
	var p: Dictionary = state.parties["player"]
	var status := "无主之人"
	if player.get("kingdom") != null:
		status = "%s之臣" % _kingdom_link(player.kingdom)
	elif player.get("contract") != null:
		status = "%s的义从（日薪 %d 金，至第 %d 天）" % [_kingdom_link(player.contract), int(player.contract_pay), int(player.contract_until)]
	var out := "[b][font_size=19]你的部队[/font_size][/b]  %s\n" % status
	if str(player.get("background_name", "")) != "":
		out += "[color=#8c9a94]出身 %s · %s[/color]\n" % [player.origin_name, player.background_name]
	if player.get("captive", false):
		out += "[color=#ff8f8f]你正被关押，第 %d 天 %02d 时前后有机会逃脱[/color]\n" % [int(int(player.captive_until) / 24), int(player.captive_until) % 24]
	out += "金币 [b]%d[/b] · 名望 %d · 部队 %d/%d 人（伤 %d）· 战力 %d · 日行 %d 里 · 视野 %d 里%s\n" % [int(player.gold), int(player.renown),
		int(p.size) + int(p.wounded), int(player.limit), int(p.wounded), int(p.power), int(p.speed),
		int(player.get("vision", 0)), "（夜）" if player.get("night", false) else ""]
	if int(player.get("dread", 0)) > 0:
		out += "[color=#ff8f8f]威名 %d[/color] [color=#8c9a94]（斩过敌将，敌将更易畏死归降，但其国人与同族记恨你）[/color]\n" % int(player.dread)
	var caps: Array[String] = []
	for c in player.get("captives", []):
		caps.append(_hero_link(c.id))
	if caps.size():
		out += "关押的将军：%s [color=#8c9a94]（进城可提审：招降 / 索赎 / 释放 / 斩首）[/color]\n" % "、".join(caps)
	var wars: Array[String] = []
	for k in player.get("wars", []):
		wars.append(_kingdom_link(k))
	if wars.size() and player.get("kingdom") == null and player.get("contract") == null:
		out += "[color=#ff6b5b]与你为敌：[/color]%s\n" % "、".join(wars)
	var fiefs: Array[String] = []
	for sid in player.get("fiefs", []):
		fiefs.append(_settle_link(sid))
	if fiefs.size():
		out += "封地：%s\n" % "、".join(fiefs)
	if int(p.prisoners) > 0:
		out += "俘虏 %d 人（到城里卖给赎金掮客）\n" % int(p.prisoners)
	var cargo: Dictionary = player.get("cargo", {})
	var cs: Array[String] = []
	for g in cargo:
		if int(cargo[g]) > 0:
			cs.append("%s×%d" % [goods.get(g, g), int(cargo[g])])
	out += "货物（%d/%d）：%s\n" % [_sum_values(cargo), int(player.cargo_cap), "、".join(cs) if cs.size() else "无"]
	out += _troop_table(p.troops)
	var rels: Array = []
	var rd: Dictionary = player.get("relations", {})
	for hid in rd:
		rels.append([int(rd[hid]), hid])
	rels.sort_custom(func(a, b): return abs(a[0]) > abs(b[0]))
	if rels.size():
		var parts: Array[String] = []
		for r in rels.slice(0, 8):
			parts.append("%s [color=#%s]%+d[/color]" % [_hero_link(r[1]), "8fd3a0" if r[0] > 0 else "ff8f8f", r[0]])
		out += "诸将对你的看法：%s\n" % "  ".join(parts)
	var qs: Array = player.get("quests", [])
	if qs.size():
		out += "\n[color=#f2c75c]差事[/color]\n"
		for line in qs:
			out += "[color=#efe6d2]· %s[/color]\n" % _esc(line)
	var adv: Array = player.get("advice", [])
	if adv.size():
		out += "\n[color=#f2c75c]下一步[/color]\n"
		for line in adv:
			out += "[color=#cfd6dc]· %s[/color]\n" % _esc(line)
	return out


func _sum_values(d: Dictionary) -> int:
	var n := 0
	for k in d:
		n += int(d[k])
	return n


func _party_details(p: Dictionary) -> String:
	var out := "[b][font_size=18]%s[/font_size][/b]  %s" % [_esc(p.name), KIND_NAMES.get(p.kind, p.kind)]
	if p.faction != null and state.kingdoms.has(p.faction):
		out += " · " + _kingdom_link(p.faction)
	if p.kind == "merc":
		out += " · " + ("受雇于" + _kingdom_link(p.contract) if p.contract != null else "待雇")
	out += "\n%d 人（伤 %d）· 战力 %d · 日行 %d 里 · %s\n" % [int(p.size), int(p.wounded), int(p.power), int(p.speed),
		MODE_NAMES.get(p.mode, p.mode)]
	if p.owner != null:
		out += "东家：%s\n" % _hero_link(p.owner)
	if p.home != null and state.settlements.has(p.home):
		out += "据点：%s\n" % _settle_link(p.home)
	if int(p.gold) > 0:
		out += "金币：%d\n" % int(p.gold)
	if p.cargo.size():
		var cs: Array[String] = []
		for g in p.cargo:
			cs.append("%s×%d" % [goods.get(g, g), int(p.cargo[g])])
		out += "货物：%s\n" % "、".join(cs)
	if int(p.prisoners) > 0:
		out += "俘虏：%d 人\n" % int(p.prisoners)
	return out + _troop_table(p.troops)


func _settlement_details(sid: String) -> String:
	var s: Dictionary = state.settlements[sid]
	var kinds := {"town": "城", "castle": "关塞", "village": "村落", "hideout": "匪巢"}
	var out := "[b][font_size=19]%s[/font_size][/b]  %s" % [_esc(s.name), kinds.get(s.kind, s.kind)]
	var known: bool = map.knows_settlement(sid)
	if s.kind == "hideout":
		if not known:
			return out + "\n[color=#8c9a94]不在视野内，匪众多少不得而知——走近些再看。[/color]\n"
		return out + "\n匪众约 %d 人\n" % int(s.garrison_size) + _troop_table(s.garrison)
	out += " · %s\n" % _kingdom_link(s.faction)
	out += "守将：%s\n" % _hero_link(s.owner)
	if s.kind == "village":
		if known:
			out += "所属：%s · 繁荣 %d · 民兵 %d · 特产 %s（库存 %d）\n" % [_settle_link(s.bound), int(s.prosperity),
				int(s.militia), goods.get(s.produce, s.produce), int(s.stock)]
		else:
			out += "所属：%s · 特产 %s\n" % [_settle_link(s.bound), goods.get(s.produce, s.produce)]
		if s.raided:
			out += "[color=#ff9a5a]刚遭劫掠，正在恢复[/color]\n"
		return out
	if not known:
		out += "城墙 %d 级\n[color=#8c9a94]不在视野内：城防、守军与城中驻扎的部队看不清——走近些再看。[/color]\n" % int(s.walls)
		if s.siege != null:
			out += "[color=#e5534b]传闻正被%s围攻[/color]\n" % _fname(s.siege.kingdom)
		return out + _recent_battles(sid)
	out += "繁荣 %d · 民心 %d · 存粮 %d · 城墙 %d 级 · 民兵 %d\n" % [int(s.prosperity), int(s.loyalty), int(s.food),
		int(s.walls), int(s.militia)]
	if int(s.loyalty) < 30:
		out += "[color=#ff8f8f]民心低落，可能叛乱[/color]\n"
	if s.siege != null:
		out += "[color=#e5534b]正被%s围攻，攻城器械进度 %d%%[/color]\n" % [_fname(s.siege.kingdom), int(float(s.siege.progress) * 100)]
	var vs: Array[String] = []
	for v in s.villages:
		vs.append(_settle_link(v))
	if vs.size():
		out += "村庄：%s\n" % "、".join(vs)
	var here: Array[String] = []
	var camp: Array[String] = []
	for pid in map._at.get(sid, []):
		var p: Dictionary = state.parties[pid]
		var txt := (_hero_link(p.hero) if p.hero != null else _esc(p.name)) + "(%d)" % int(p.size)
		if p.inside == sid or not s.kind in ["town", "castle"]:
			here.append(txt)
		else:
			camp.append(txt)
	if here.size():
		out += "%s：%s\n" % ["城内" if s.kind in ["town", "castle"] else "此地", "  ".join(here)]
	if camp.size():
		out += "城外扎营：%s\n" % "  ".join(camp)
	out += "[color=#8c9a94]守军 %d 人：[/color]\n" % int(s.garrison_size) + _troop_table(s.garrison)
	if s.has("market"):
		out += "[color=#8c9a94]市场：[/color]\n[table=3]"
		for g in s.market:
			var m: Dictionary = s.market[g]
			out += "[cell]%s  [/cell][cell]库存 %d  [/cell][cell]%d 金[/cell]" % [goods.get(g, g), int(m.stock), int(m.price)]
		out += "[/table]\n"
	return out + _recent_battles(sid)


func _recent_battles(sid: String) -> String:
	var s: Dictionary = state.settlements[sid]
	var recent: Array[String] = []
	var ids := report_events.keys()
	for i in range(ids.size() - 1, -1, -1):
		var ev: Dictionary = report_events[ids[i]]
		if ev.get("settlement") == sid or str(ev.get("place", "")).begins_with(s.name):
			recent.append("[url=report:%d][color=#f2c75c]第%d天 %s[/color][/url]" % [int(ev._rid), int(ev.day),
				{"battle": "会战", "conquest": "攻陷", "assault_failed": "强攻失败", "hideout_cleared": "剿匪"}.get(ev.type, "")])
			if recent.size() >= 5:
				break
	return ("最近战事：%s\n" % "  ".join(recent)) if recent.size() else ""


func _kingdom_details(kid: String) -> String:
	var k: Dictionary = state.kingdoms[kid]
	var out := "[b][font_size=19][color=#%s]%s[/color][/font_size][/b]%s\n" % [_fcol(kid), _esc(k.name), "（已覆灭）" if not k.alive else ""]
	out += "君主：%s · 城池 %d · 实力 %d\n" % [_hero_link(k.ruler), int(k.fiefs), int(k.strength)]
	for e in k.wars:
		var wv: Dictionary = k.wars[e]
		out += "[color=#ff6b5b]交战[/color] %s：%d 天，战争分数 %+d，伤亡 我%d / 敌%d\n" % [_kingdom_link(e),
			int(state.day) - int(wv.since), int(wv.score), int(wv.losses[0]), int(wv.losses[1])]
	for e in k.truces:
		out += "[color=#8fd3a0]停战[/color] %s：至第 %d 天\n" % [_kingdom_link(e), int(k.truces[e])]
	for e in k.tributes:
		out += "向 %s 支付岁贡 %d 金/日（至第 %d 天）\n" % [_kingdom_link(e), int(k.tributes[e].amount), int(k.tributes[e].until)]
	for m in k.mercenaries:
		if state.parties.has(m):
			out += "雇佣：%s（%d 人）\n" % [_esc(state.parties[m].name), int(state.parties[m].size)]
	out += "[color=#8c9a94]诸将：[/color]\n"
	for hid in state.heroes:
		var h: Dictionary = state.heroes[hid]
		if h.kingdom != kid:
			continue
		var st := ""
		if str(h.captive_of) == "__dead":
			st = "[color=#ff8f8f]已死[/color]"
		elif h.captive_of != null:
			st = "[color=#c99cff]被俘[/color]"
		elif h.party != null and state.parties.has(h.party) and not map.party_known(h.party):
			st = "[color=#8c9a94]行踪不明[/color]"
		elif h.party != null and state.parties.has(h.party):
			var p: Dictionary = state.parties[h.party]
			st = "%d人 · %s" % [int(p.size), ORDER_NAMES.get(p.order.type, "") if p.order != null else MODE_NAMES.get(p.mode, "")]
		out += "  %s %s  [color=#8c9a94]影响%d 金%d[/color]\n" % [_hero_link(hid), st, int(h.influence), int(h.gold)]
	return out


func _realms() -> String:
	var out := ""
	for kid in state.kingdoms:
		var k: Dictionary = state.kingdoms[kid]
		if not k.alive:
			out += "[color=#%s]■[/color] [s]%s[/s] [color=#8c9a94]已覆灭[/color]\n\n" % [_fcol(kid), _esc(k.name)]
			continue
		var wars: Array[String] = []
		for e in k.wars:
			wars.append("%s(%+d)" % [_kingdom_link(e), int(k.wars[e].score)])
		out += "[color=#%s]■[/color] [b]%s[/b]  [color=#8c9a94]君主[/color] %s  [color=#8c9a94]城池 %d · 实力 %d[/color]\n" % [
			_fcol(kid), _kingdom_link(kid), _hero_link(k.ruler), int(k.fiefs), int(k.strength)]
		out += "    交战：%s\n" % ("、".join(wars) if wars.size() else "[color=#8fd3a0]和平[/color]")
		var hs: Array[String] = []
		for hid in state.heroes:
			var h: Dictionary = state.heroes[hid]
			if h.kingdom != kid:
				continue
			var tag := "死" if str(h.captive_of) == "__dead" else ("俘" if h.captive_of != null else "")
			if tag == "" and h.party != null and state.parties.has(h.party):
				tag = str(int(state.parties[h.party].size)) if map.party_known(h.party) else "?" 
			hs.append("%s[color=#8c9a94](%s)[/color]" % [_hero_link(hid), tag])
		out += "    " + "  ".join(hs) + "\n\n"
	return out


func _council() -> String:
	var ds: Array = state.decisions.values()
	if ds.is_empty():
		return "[color=#8c9a94]各国朝议暂无议题。将军们会定期建言宣战或议和，新攻下的城池会交由朝议推举分封。[/color]"
	ds.sort_custom(func(a, b): return int(a.created) > int(b.created))
	var out := ""
	var kinds := {"war": "宣战", "peace": "议和", "fief": "分封"}
	for d in ds:
		var subj := ""
		if d.kind == "fief":
			subj = _settle_link(d.subject)
		else:
			subj = _kingdom_link(d.subject)
		out += "[b]%s[/b] · %s · %s" % [_kingdom_link(d.kingdom), kinds.get(d.kind, d.kind), subj]
		if d.proposer != null:
			out += " · 提议人 %s" % _hero_link(d.proposer)
		out += "  [color=#8c9a94]第%d天[/color]\n" % int(int(d.created) / 24)
		if str(d.note) != "":
			out += "  [i]「%s」[/i]\n" % _esc(d.note)
		var labels := {}
		for o in d.options:
			labels[o.id] = str(o.label).split("（")[0]
		for hid in d.votes:
			var v: Dictionary = d.votes[hid]
			out += "  %s → %s [color=#8c9a94](权重%.1f)%s[/color]\n" % [_hero_link(hid), _esc(labels.get(v.option, v.option)),
				float(v.weight), ("——" + _esc(v.reason)) if str(v.get("reason", "")) != "" else ""]
		if d.resolved and d.result != null:
			out += "  [color=#8fc6ff]裁决：%s[/color]%s\n" % [_esc(labels.get(d.result, d.result)), ""]
		elif not d.resolved:
			out += "  [color=#f2c75c]表决中…[/color]\n"
		out += "\n"
	return out



## Would word of this event reach the player? (fog of war for the chronicle)
func _heard_of(ev: Dictionary) -> bool:
	var t: String = ev.type
	if ev.get("player", false) or t in NEWS:
		return true
	var mine = player.get("kingdom")
	if mine != null:
		for k in ["kingdom", "by", "new", "old", "faction"]:
			if str(ev.get(k, "")) == str(mine):
				return true
		if t in ["decision_opened", "decision_resolved"]:
			return str(ev.get("kingdom", "")) == str(mine)
	if t in ["decision_opened", "decision_resolved"]:
		return false                      # other realms' court business stays behind closed doors
	var pos = ev.get("pos")
	if pos == null and ev.has("settlement") and state.get("settlements", {}).has(ev.settlement):
		return map.knows_settlement(str(ev.settlement))
	if pos == null and ev.has("hero") and state.get("heroes", {}).has(ev.hero):
		var pid = state.heroes[ev.hero].party
		return pid != null and map.party_known(str(pid))
	if pos == null:
		return true
	return map.sees(Vector2(pos[0], pos[1]))


func _render_log() -> void:
	var out := ""
	for ev in log_lines:
		var t: String = ev.type
		if (t in MINOR or not ev.get("_known", true)) and not show_minor:
			continue
		var c: String = EVENT_COLORS.get(t, "cfd8dc")
		var text := _esc(ev.text)
		if t == "speech":
			text = "[i]%s[/i]" % text
		var pos = ev.get("pos")
		if pos == null and ev.has("settlement") and state.settlements.has(ev.settlement):
			pos = state.settlements[ev.settlement].pos
		if pos != null:
			text = "[url=goto:%d,%d][color=#%s]%s[/color][/url]" % [int(pos[0]), int(pos[1]), c, text]
		else:
			text = "[color=#%s]%s[/color]" % [c, text]
		if ev.has("_rid") and report_events.has(ev._rid):
			text += " [url=report:%d][color=#f2c75c]〔战报〕[/color][/url]" % int(ev._rid)
		out += "[color=#5f6f69]%d日%02d时[/color] %s\n" % [int(ev.day), int(ev.hour) % 24, text]
	log_text.text = out


func _on_meta(meta) -> void:
	var s := str(meta)
	var i := s.find(":")
	if i < 0:
		return
	var kind := s.substr(0, i)
	var id := s.substr(i + 1)
	match kind:
		"report":
			var rid := int(id)
			if report_events.has(rid):
				report_popup.open(report_events[rid], state)
		"goto":
			var v := id.split(",")
			map.focus(Vector2(float(v[0]), float(v[1])), max(map.zoom, map.close_zoom(3.0)))
		"hero":
			if state.heroes.has(id) and state.heroes[id].party != null and state.parties.has(state.heroes[id].party) \
					and map.party_known(str(state.heroes[id].party)):
				map.select("party", str(state.heroes[id].party))
				_focus_selection()
			else:
				map.select("hero", id)
		"settlement":
			map.select("settlement", id)
			_focus_selection()
		"kingdom":
			map.select("kingdom", id)
		_:
			map.select(kind, id)
