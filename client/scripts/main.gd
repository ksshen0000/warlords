extends Control
## Warlords client: campaign map + side panel (details / realms / council) + chronicle.
##
## Command line (after `--`): --server=URL --seed=N --steps=N --select=kind:id --tab=N
##                            --zoom=x,y,z --report=last --capture=PATH

const ApiScript := preload("res://scripts/api.gd")
const MapViewScript := preload("res://scripts/map_view.gd")
const BattleReportScript := preload("res://scripts/battle_report.gd")

const SPEEDS := [["慢（每步1小时）", 1], ["中（每步3小时）", 3], ["快（每步6小时）", 6], ["极速（每步12小时）", 12]]
const STEP_INTERVAL := 0.45
const BRAIN_LABELS := {"rule": "规则 AI", "claude": "Claude", "openai": "OpenAI", "deepseek": "DeepSeek"}
const KIND_NAMES := {"lord": "领主部队", "caravan": "商队", "villager": "村民", "bandit": "土匪",
	"hunter": "赏金猎人", "merc": "佣兵团"}
const ORDER_NAMES := {"recruit": "招募", "besiege": "围攻", "defend": "驻防", "attack": "追击", "raid": "劫掠",
	"hideout": "剿匪", "patrol": "巡逻", "sell": "出售俘虏", "rest": "休整", "caravan": "组建商队",
	"wait": "待命", "retreat": "撤退", "follow": "随军"}
const MODE_NAMES := {"idle": "驻留", "move": "行军", "siege": "围城", "raid": "劫掠", "inside": "城内",
	"flee": "撤退", "chase": "追击", "follow": "随军"}
const TRAITS := {"aggression": "好战", "caution": "谨慎", "honor": "荣誉", "greed": "贪婪"}
const MINOR := ["order", "recruit", "speech", "release", "siege_end", "flee", "prisoners_sold",
	"desertion", "raid_start", "caravan_founded", "brain_error", "hideout_new", "decision_opened"]
const REPORT_TYPES := ["battle", "conquest", "assault_failed", "hideout_cleared"]
const EVENT_COLORS := {
	"battle": "e8a25b", "conquest": "f2c75c", "rebellion": "f2c75c", "war": "ff6b5b", "peace": "8fd3a0",
	"peace_rejected": "c8a878", "capture": "c99cff", "ransom": "c99cff", "defection": "ff8fb1",
	"siege_start": "e57373", "assault_failed": "9fb4bf", "raid": "ff9a5a", "kingdom_destroyed": "ff4b4b",
	"decision_resolved": "8fc6ff", "fief_granted": "8fc6ff", "army_formed": "b6d77a", "army_disbanded": "9fb4bf",
	"merc_hired": "b48ce0", "merc_left": "9fb4bf", "hideout_cleared": "d9b44a", "unrest": "d0a070",
	"starvation": "a1887f", "speech": "d8dfe2", "order": "7d8f96",
}
const PANEL_BG := Color("1b252b")
const CREAM := Color("efe6d2")
const MUTED := Color("8c9a94")
const GOLD := Color("f2c75c")

var api: Node
var map: Control
var report_popup: Control
var state: Dictionary = {}
var goods := {}
var connected := false
var playing := false
var speed_idx := 1
var wait_left := 0.0
var retry_left := 0.0
var log_lines: Array = []
var report_events := {}
var _report_seq := 0
var show_minor := false
var auto_report := false
var brain := "rule"
var brains: Array = ["rule", "claude", "openai", "deepseek"]
var map_seed := -1

var auto_steps := 0
var capture_path := ""
var pending_select := ""
var pending_report := false
var pending_zoom := ""
var pending_tab := -1

var time_label: Label
var status_label: Label
var play_btn: Button
var speed_opt: OptionButton
var seed_box: SpinBox
var brain_opt: OptionButton
var tabs: TabContainer
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
	if not api.busy:
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
		elif a == "--report=last":
			pending_report = true
		elif a.begins_with("--seed="):
			seed_box.value = int(a.substr(7))
			api.reset(int(seed_box.value), "rule")


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

	map = MapViewScript.new()
	map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map.hint = "左键选择 · 双击放大 · 滚轮缩放 · 右键拖动 / WASD 平移 · 空格 播放/暂停 · N 推进 · F 定位所选 · Home 全图"
	map.selection_changed.connect(func(_k, _i):
		if _k != "":
			tabs.current_tab = 0
		_refresh_details())
	root.add_child(map)

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
	side.add_child(head)
	status_label = _label("连接中…", 13, MUTED)
	side.add_child(status_label)

	var row := HBoxContainer.new()
	play_btn = Button.new()
	play_btn.text = "播放"
	play_btn.custom_minimum_size = Vector2(70, 0)
	play_btn.pressed.connect(_toggle_play)
	row.add_child(play_btn)
	var step_btn := Button.new()
	step_btn.text = "推进"
	step_btn.tooltip_text = "按当前速度推进一步（N）"
	step_btn.pressed.connect(_step_once)
	row.add_child(step_btn)
	speed_opt = OptionButton.new()
	for s in SPEEDS:
		speed_opt.add_item(s[0])
	speed_opt.selected = speed_idx
	speed_opt.item_selected.connect(func(i): speed_idx = i)
	row.add_child(speed_opt)
	var minor := CheckBox.new()
	minor.text = "琐事"
	minor.tooltip_text = "编年史中显示命令、招募、台词等"
	minor.toggled.connect(func(on): show_minor = on; _render_log())
	row.add_child(minor)
	var auto := CheckBox.new()
	auto.text = "战报"
	auto.tooltip_text = "发生攻城等大战时自动弹出战报并暂停"
	auto.toggled.connect(func(on): auto_report = on)
	row.add_child(auto)
	var terr := CheckBox.new()
	terr.text = "政区"
	terr.button_pressed = true
	terr.toggled.connect(func(on): map.show_territory = on)
	row.add_child(terr)
	side.add_child(row)

	var row2 := HBoxContainer.new()
	row2.add_child(_label("种子", 14, MUTED))
	seed_box = SpinBox.new()
	seed_box.min_value = 0
	seed_box.max_value = 99999
	seed_box.value = 3
	row2.add_child(seed_box)
	brain_opt = OptionButton.new()
	_fill_brains()
	row2.add_child(brain_opt)
	var reset_btn := Button.new()
	reset_btn.text = "新的一局"
	reset_btn.pressed.connect(_new_game)
	row2.add_child(reset_btn)
	var reload_btn := Button.new()
	reload_btn.text = "重载规则"
	reload_btn.tooltip_text = "重新读取 rules/balance.toml 和 rules/doctrine.toml（不重开游戏）"
	reload_btn.pressed.connect(func():
		if api.reload_rules():
			status_label.text = "正在重载规则文档…")
	row2.add_child(reload_btn)
	side.add_child(row2)

	tabs = TabContainer.new()
	tabs.custom_minimum_size = Vector2(0, 360)
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.size_flags_stretch_ratio = 1.3
	detail_text = _rich()
	detail_text.name = "详情"
	realms_text = _rich()
	realms_text.name = "诸国"
	council_text = _rich()
	council_text.name = "议会"
	for r in [detail_text, realms_text, council_text]:
		tabs.add_child(r)
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


func _fill_brains() -> void:
	brain_opt.clear()
	for b in brains:
		brain_opt.add_item(BRAIN_LABELS.get(b, str(b)))
	brain_opt.selected = max(0, brains.find(brain))


# ------------------------------------------------------------- control
func _toggle_play() -> void:
	playing = not playing
	play_btn.text = "暂停" if playing else "播放"
	wait_left = 0.0


func _step_once() -> void:
	if connected and not api.busy:
		api.step(int(SPEEDS[speed_idx][1]))
		_busy_status()


func _new_game() -> void:
	var b: String = brains[brain_opt.selected]
	if api.reset(int(seed_box.value), b):
		status_label.text = "正在生成新世界…"


func _busy_status() -> void:
	if brain != "rule":
		status_label.text = "领主们正在思考…（%s）" % BRAIN_LABELS.get(brain, brain)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if report_popup.visible:
			return
		match event.keycode:
			KEY_SPACE:
				_toggle_play()
			KEY_N:
				_step_once()
			KEY_ESCAPE:
				map.select("", "")
			KEY_HOME:
				map.fit()
			KEY_F:
				_focus_selection()


func _focus_selection() -> void:
	if map.sel_kind == "party" and state.parties.has(map.sel_id):
		map.focus(map.party_world_pos(map.sel_id), max(map.zoom, map.fit_zoom * 3.0))
	elif map.sel_kind == "settlement" and state.settlements.has(map.sel_id):
		map.focus(map.settlement_pos(map.sel_id), max(map.zoom, map.fit_zoom * 3.0))


func _process(delta: float) -> void:
	if not connected:
		retry_left -= delta
		if retry_left <= 0.0 and not api.busy:
			retry_left = 2.0
			api.get_state()
			if map_seed < 0:
				api.get_map()
		return
	if playing or auto_steps > 0:
		wait_left -= delta
		if wait_left <= 0.0 and not api.busy and not map.animating():
			api.step(int(SPEEDS[speed_idx][1]))
			_busy_status()
	elif capture_path != "" and not api.busy and not map.animating() and map_seed >= 0:
		_capture()


func _capture() -> void:
	var path := capture_path
	capture_path = ""
	if pending_report:
		pending_report = false
		var ids := report_events.keys()
		var pick = null
		for i in range(ids.size() - 1, -1, -1):
			var ev: Dictionary = report_events[ids[i]]
			if pick == null or (ev.type == "conquest" and pick.type != "conquest") or \
					(ev.type == "battle" and pick.type == "battle" and ev.report.attacker_start + ev.report.defender_start > pick.report.attacker_start + pick.report.defender_start):
				pick = ev
		if pick != null:
			report_popup.open(pick, state)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		get_viewport().get_texture().get_image().save_png(path)
		print("captured ", path)
	print("WARLORDS_OK day=%d events=%d parties=%d zoom=%.3f fit=%.3f size=%s" % [int(state.day), log_lines.size(), state.parties.size(), map.zoom, map.fit_zoom, str(map.size)])
	get_tree().quit()


# ------------------------------------------------------------- network
func _on_failed(kind: String, message: String) -> void:
	if kind == "reset" or kind == "reload":
		status_label.text = ("新开局失败：" if kind == "reset" else "重载失败：") + message
		return
	if kind == "map":
		map_seed = -1
	connected = false
	if playing:
		_toggle_play()
	map.status_text = "无法连接模拟服务器，请先运行：python3 -m warlords.server" if state.is_empty() else "与服务器断开，正在重连…"
	status_label.text = message


func _on_response(kind: String, data: Dictionary) -> void:
	if kind == "map":
		map_seed = int(data.seed)
		map.set_map(data.map)
		_apply_pending_view()
		return
	if kind == "reload":
		status_label.text = "规则文档已重载（数值与准则立即生效）"
		return
	connected = true
	map.status_text = ""
	brain = str(data.get("brain", brain))
	if data.has("brains"):
		brains = data.brains
		_fill_brains()
	var seed := int(data.get("seed", 0))
	if kind == "reset" or (kind == "state" and state.is_empty()):
		log_lines.clear()
		report_events.clear()
		map.speeches.clear()
		map.effects.clear()
		report_popup.close()
		seed_box.value = seed
		if seed != map_seed:
			api.get_map()
	var to_open = null
	var evs: Array = data.get("events", [])
	state = data.state
	goods = state.get("goods", {})
	for ev in evs:
		_handle_event(ev)
		if auto_report and ev.has("_rid") and ev.type in ["conquest", "assault_failed"]:
			to_open = ev
	map.set_state(state, STEP_INTERVAL * 0.95)
	wait_left = STEP_INTERVAL
	if to_open != null:
		report_popup.open(to_open, state)
		if playing:
			_toggle_play()
	if kind == "step" and auto_steps > 0:
		auto_steps -= 1
	if pending_select != "":
		var parts := pending_select.split(":")
		pending_select = ""
		if parts[0] == "hero" and state.heroes.has(parts[1]) and state.heroes[parts[1]].party != null:
			map.select("party", str(state.heroes[parts[1]].party))
		else:
			map.select(parts[0], parts[1])
	if pending_tab >= 0:
		tabs.current_tab = pending_tab
		pending_tab = -1
	status_label.text = "已连接 · %s · 种子 %d" % [BRAIN_LABELS.get(brain, brain), seed]
	_refresh_all()


func _apply_pending_view() -> void:
	if pending_zoom == "":
		return
	var v := pending_zoom.split(",")
	if v.size() == 3:
		map.focus(Vector2(float(v[0]), float(v[1])), map.fit_zoom * float(v[2]))


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
	if t in REPORT_TYPES and ev.has("report"):
		_report_seq += 1
		ev["_rid"] = _report_seq
		report_events[_report_seq] = ev
		if report_events.size() > 400:
			report_events.erase(report_events.keys()[0])
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
			_refresh_details()
		1:
			realms_text.text = _realms()
		2:
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
	if state.kingdoms.has(fid):
		return state.kingdoms[fid].name
	return "土匪" if str(fid) == "__bandit" else "中立"


func _hero_link(hid) -> String:
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
	if k == "party" and state.parties.has(id):
		var p: Dictionary = state.parties[id]
		detail_text.text = _hero_details(p.hero) if p.hero != null else _party_details(p)
	elif k == "hero" and state.heroes.has(id):
		detail_text.text = _hero_details(id)
	elif k == "settlement" and state.settlements.has(id):
		detail_text.text = _settlement_details(id)
	elif k == "kingdom" and state.kingdoms.has(id):
		detail_text.text = _kingdom_details(id)
	else:
		detail_text.text = ("[color=#8c9a94]点击地图上的旗帜、城镇、村庄或其他部队查看详情。\n\n"
			+ "图例：城墙 = 城镇，塔楼 = 城堡，小屋 = 村庄（冒烟 = 被劫掠），红色帐篷 = 匪巢；\n"
			+ "旗帜 = 领主（金点 = 君主，大旗 = 军团），紫边旗 = 佣兵团，棕色方块 = 商队，\n"
			+ "白点 = 村民，暗红菱形 = 土匪，金色三角 = 赏金猎人。\n"
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
	out += "金币 %d · 影响力 %d · 声望 %d" % [int(h.gold), int(h.influence), int(h.renown)]
	if kd.ruler != hid:
		out += " · 对君主好感 %+d" % int(h.relations.get(kd.ruler, 0))
	out += "\n"
	if h.captive_of != null:
		out += "[color=#c99cff]被%s俘虏%s，已关押 %d 天[/color]\n" % [_fname(h.captive_of),
			("，关在" + _settle_link(h.captive_at)) if h.captive_at != null else "", int(h.captive_days)]
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
	var kinds := {"town": "城镇", "castle": "城堡", "village": "村庄", "hideout": "匪巢"}
	var out := "[b][font_size=19]%s[/font_size][/b]  %s" % [_esc(s.name), kinds.get(s.kind, s.kind)]
	if s.kind == "hideout":
		return out + "\n匪众约 %d 人\n" % int(s.garrison_size) + _troop_table(s.garrison)
	out += " · %s\n" % _kingdom_link(s.faction)
	out += "领主：%s\n" % _hero_link(s.owner)
	if s.kind == "village":
		out += "所属：%s · 繁荣 %d · 民兵 %d · 特产 %s（库存 %d）\n" % [_settle_link(s.bound), int(s.prosperity),
			int(s.militia), goods.get(s.produce, s.produce), int(s.stock)]
		if s.raided:
			out += "[color=#ff9a5a]刚遭劫掠，正在恢复[/color]\n"
		return out
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
	for pid in state.parties:
		var p: Dictionary = state.parties[pid]
		if p.inside == sid:
			here.append((_hero_link(p.hero) if p.hero != null else _esc(p.name)) + "(%d)" % int(p.size))
	if here.size():
		out += "城内：%s\n" % "  ".join(here)
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
	out += "[color=#8c9a94]领主：[/color]\n"
	for hid in state.heroes:
		var h: Dictionary = state.heroes[hid]
		if h.kingdom != kid:
			continue
		var st := ""
		if h.captive_of != null:
			st = "[color=#c99cff]被俘[/color]"
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
			var tag := "俘" if h.captive_of != null else ""
			if tag == "" and h.party != null and state.parties.has(h.party):
				tag = str(int(state.parties[h.party].size))
			hs.append("%s[color=#8c9a94](%s)[/color]" % [_hero_link(hid), tag])
		out += "    " + "  ".join(hs) + "\n\n"
	return out


func _council() -> String:
	var ds: Array = state.decisions.values()
	if ds.is_empty():
		return "[color=#8c9a94]各国议会暂无议题。领主们会定期提议宣战或议和，新征服的城池会交由议会投票分封。[/color]"
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



func _render_log() -> void:
	var out := ""
	for ev in log_lines:
		var t: String = ev.type
		if t in MINOR and not show_minor:
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
			map.focus(Vector2(float(v[0]), float(v[1])), max(map.zoom, map.fit_zoom * 3.0))
		"hero":
			if state.heroes.has(id) and state.heroes[id].party != null and state.parties.has(state.heroes[id].party):
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
