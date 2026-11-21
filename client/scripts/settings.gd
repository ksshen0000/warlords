extends Control
## Display / input settings (saved to user://settings.cfg):
## window mode, windowed resolution, UI scale, vsync, mouse confinement and edge scrolling.
## Mouse lock: like Mount & Blade, the cursor is kept inside the window so the map can
## be scrolled by pushing against the screen edge. It is released automatically while
## the window is unfocused, and F10 toggles it at any time.

signal changed

const CREAM := Color("efe6d2")
const MUTED := Color("8c9a94")
const GOLD := Color("f2c75c")
const PATH := "user://settings.cfg"
const MODES := [["窗口", DisplayServer.WINDOW_MODE_WINDOWED],
	["无边框全屏", DisplayServer.WINDOW_MODE_FULLSCREEN],
	["独占全屏", DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]]
const SIZES := [Vector2i(1152, 720), Vector2i(1280, 800), Vector2i(1366, 768), Vector2i(1440, 900),
	Vector2i(1600, 900), Vector2i(1680, 1050), Vector2i(1920, 1080), Vector2i(1920, 1200),
	Vector2i(2560, 1440), Vector2i(3840, 2160)]
# multiplies the automatic canvas_items stretch (which already scales the UI with the window);
# >1 means bigger text but less room, so it is capped where the side panel + menu still fit
const SCALES := [0.8, 0.9, 1.0, 1.1, 1.2, 1.3]

var mode := 0
var win_size := Vector2i(1440, 900)
var ui_scale := 1.0
var vsync := true
var lock_mouse := true
var edge_scroll := true
var edge_speed := 1.0
var battle_size := BattleRules.DEFAULT_BATTLE_SIZE
# Warband-style difficulty options for 3D battles (indices into the lists below)
const DMG_LEVELS := [["1/4", 0.25], ["1/2", 0.5], ["全额", 1.0]]
const AI_LEVELS := ["差", "一般", "好"]
const SPEED_LEVELS := [["最慢", 0.75], ["慢", 0.875], ["正常", 1.0], ["快", 1.125], ["最快", 1.25]]
var player_damage := 2           # damage to player
var ally_damage := 2             # damage to your troops and allies
var ai_level := 1                # combat AI
var combat_speed := 2
var auto_block := false          # block direction: automatic (towards the nearest swing) or by mouse
var auto_attack := false         # attack direction: automatic or by mouse movement
var sfx_volume := 0.8            # battle sounds 0..1
var _diff_label: Label

var _focused := true
var _armed := false        # lock only after the first click inside the window
var _suspended := false    # F10 toggled off for now
var _mode_opt: OptionButton
var _size_opt: OptionButton
var _scale_opt: OptionButton
var _sizes: Array = []
var _headless := false


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_load()
	_build()
	if not _headless:
		get_window().focus_entered.connect(func(): _focused = true; apply_mouse())
		get_window().focus_exited.connect(func(): _focused = false; apply_mouse())
		get_window().size_changed.connect(_on_window_resized)
		apply_display.call_deferred()


# ------------------------------------------------------------ persistence
func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		# first run: keep whatever size the window was opened with (project default or --resolution)
		if not _headless:
			win_size = get_window().size
		return
	mode = clampi(int(cf.get_value("display", "mode", mode)), 0, MODES.size() - 1)
	win_size = cf.get_value("display", "size", win_size)
	ui_scale = clampf(float(cf.get_value("display", "ui_scale", ui_scale)), 0.8, 1.3)
	vsync = bool(cf.get_value("display", "vsync", vsync))
	lock_mouse = bool(cf.get_value("input", "lock_mouse", lock_mouse))
	edge_scroll = bool(cf.get_value("input", "edge_scroll", edge_scroll))
	edge_speed = float(cf.get_value("input", "edge_speed", edge_speed))
	battle_size = clampi(int(cf.get_value("battle", "size", battle_size)),
		BattleRules.MIN_BATTLE_SIZE, BattleRules.MAX_BATTLE_SIZE)
	player_damage = clampi(int(cf.get_value("battle", "player_damage", player_damage)), 0, 2)
	ally_damage = clampi(int(cf.get_value("battle", "ally_damage", ally_damage)), 0, 2)
	ai_level = clampi(int(cf.get_value("battle", "ai_level", ai_level)), 0, 2)
	combat_speed = clampi(int(cf.get_value("battle", "combat_speed", combat_speed)), 0, 4)
	auto_block = bool(cf.get_value("battle", "auto_block", auto_block))
	auto_attack = bool(cf.get_value("battle", "auto_attack", auto_attack))
	sfx_volume = clampf(float(cf.get_value("audio", "sfx", sfx_volume)), 0.0, 1.0)


func save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("display", "mode", mode)
	cf.set_value("display", "size", win_size)
	cf.set_value("display", "ui_scale", ui_scale)
	cf.set_value("display", "vsync", vsync)
	cf.set_value("input", "lock_mouse", lock_mouse)
	cf.set_value("input", "edge_scroll", edge_scroll)
	cf.set_value("input", "edge_speed", edge_speed)
	cf.set_value("battle", "size", battle_size)
	cf.set_value("battle", "player_damage", player_damage)
	cf.set_value("battle", "ally_damage", ally_damage)
	cf.set_value("battle", "ai_level", ai_level)
	cf.set_value("battle", "combat_speed", combat_speed)
	cf.set_value("battle", "auto_block", auto_block)
	cf.set_value("battle", "auto_attack", auto_attack)
	cf.set_value("audio", "sfx", sfx_volume)
	cf.save(PATH)


# ------------------------------------------------------------ battle difficulty
## What the 3D battle reads (setup["difficulty"]).
func difficulty() -> Dictionary:
	return {"player_damage": DMG_LEVELS[player_damage][1], "ally_damage": DMG_LEVELS[ally_damage][1],
		"ai_level": ai_level, "combat_speed": SPEED_LEVELS[combat_speed][1],
		"auto_block": auto_block, "auto_attack": auto_attack, "sfx_volume": sfx_volume}


## Warband shows a difficulty rating for the chosen options; ours adds up to 100%.
func difficulty_percent() -> int:
	return [0, 15, 30][player_damage] + [0, 10, 20][ally_damage] + [0, 12, 25][ai_level] \
		+ (0 if auto_block else 15) + (0 if auto_attack else 10)


func _opt(grid: GridContainer, label: String, items: Array, sel: int, tip: String, cb: Callable) -> void:
	var o := OptionButton.new()
	for it in items:
		o.add_item(str(it[0]) if it is Array else str(it))
	o.select(sel)
	o.tooltip_text = tip
	o.item_selected.connect(func(i):
		cb.call(i)
		save()
		_update_diff())
	_row(grid, label, o)


func _update_diff() -> void:
	if _diff_label:
		_diff_label.text = "战斗难度 %d%%" % difficulty_percent()


# ------------------------------------------------------------ applying
func is_windowed() -> bool:
	return MODES[mode][1] == DisplayServer.WINDOW_MODE_WINDOWED


func apply_display() -> void:
	if Engine.get_write_movie_path() != "":
		return              # Movie Maker (promo recordings): keep the recording's own resolution, not the saved window
	if _headless:
		return
	var win := get_window()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
	var want: int = MODES[mode][1]
	if win.mode != want:
		win.mode = want
	if is_windowed():
		var screen := DisplayServer.window_get_current_screen()
		var usable := DisplayServer.screen_get_usable_rect(screen)
		var s := Vector2i(mini(win_size.x, usable.size.x), mini(win_size.y, usable.size.y))
		s = s.max(win.min_size)
		if win.size != s:
			win.size = s
			win.position = usable.position + (usable.size - s) / 2
	_apply_scale()
	apply_mouse()


func _apply_scale() -> void:
	get_tree().root.content_scale_factor = ui_scale


func _on_window_resized() -> void:
	if is_windowed() and get_window().mode == Window.MODE_WINDOWED:
		win_size = get_window().size
	apply_mouse()


func mouse_locked() -> bool:
	if _headless or not _focused or _suspended or not _armed:
		return false
	return lock_mouse or not is_windowed()


var external_mouse := false   # a 3D battle is running and owns the mouse


func apply_mouse() -> void:
	if _headless or external_mouse:
		return
	var want := Input.MOUSE_MODE_CONFINED if mouse_locked() else Input.MOUSE_MODE_VISIBLE
	if Input.mouse_mode != want:
		Input.mouse_mode = want


## True when the map should pan because the cursor is pressed against a window edge.
func edge_pan() -> Vector2:
	if not edge_scroll or not mouse_locked() or visible:
		return Vector2.ZERO
	var vp := get_viewport()
	var p := vp.get_mouse_position()
	var r := vp.get_visible_rect().size
	var m := 4.0
	var d := Vector2.ZERO
	if p.x <= m:
		d.x = 1
	elif p.x >= r.x - m:
		d.x = -1
	if p.y <= m:
		d.y = 1
	elif p.y >= r.y - m:
		d.y = -1
	return d * edge_speed


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and not _armed:
		_armed = true
		apply_mouse()
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.keycode == KEY_F11 or (k.keycode == KEY_ENTER and k.alt_pressed):
			mode = 0 if not is_windowed() else 1
			save()
			apply_display()
			_sync_widgets()
			get_viewport().set_input_as_handled()
		elif k.keycode == KEY_F10:
			_suspended = not _suspended
			apply_mouse()
			changed.emit()
			get_viewport().set_input_as_handled()
		elif k.keycode == KEY_ESCAPE and visible:
			close()
			get_viewport().set_input_as_handled()


func status_text() -> String:
	if _headless:
		return ""
	if mouse_locked():
		return "鼠标已锁定在窗口内（F10 解锁）"
	if _suspended:
		return "鼠标未锁定（F10 锁定）"
	return ""


# ------------------------------------------------------------ UI
func open() -> void:
	_sync_widgets()
	visible = true


func close() -> void:
	visible = false


func _row(grid: GridContainer, label: String, c: Control) -> void:
	var l := Label.new()
	l.text = label
	l.add_theme_color_override("font_color", MUTED)
	grid.add_child(l)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(c)


func _check(text: String, on: bool, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = on
	c.toggled.connect(cb)
	return c


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			close())
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(520, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.12, 0.14, 0.98)
	sb.border_color = Color("6b5a3a")
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	var title := Label.new()
	title.text = "设置"
	title.add_theme_font_size_override("font_size", 21)
	title.add_theme_color_override("font_color", GOLD)
	v.add_child(title)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 8)
	v.add_child(grid)

	_mode_opt = OptionButton.new()
	for m in MODES:
		_mode_opt.add_item(m[0])
	_mode_opt.item_selected.connect(func(i):
		mode = i
		_after_change())
	_row(grid, "显示模式", _mode_opt)

	_size_opt = OptionButton.new()
	_size_opt.item_selected.connect(func(i):
		win_size = _sizes[i]
		_after_change())
	_row(grid, "窗口大小", _size_opt)

	_scale_opt = OptionButton.new()
	for s in SCALES:
		_scale_opt.add_item("%d%%" % int(round(s * 100)))
	_scale_opt.item_selected.connect(func(i):
		ui_scale = SCALES[i]
		_after_change())
	_row(grid, "界面缩放", _scale_opt)

	var spd := HSlider.new()
	spd.min_value = 0.3
	spd.max_value = 2.5
	spd.step = 0.1
	spd.value = edge_speed
	spd.custom_minimum_size = Vector2(160, 0)
	spd.value_changed.connect(func(x):
		edge_speed = x
		save())
	_row(grid, "边缘滚屏速度", spd)

	var bs := HSlider.new()
	bs.min_value = BattleRules.MIN_BATTLE_SIZE
	bs.max_value = BattleRules.MAX_BATTLE_SIZE
	bs.step = 10
	bs.value = battle_size
	bs.custom_minimum_size = Vector2(160, 0)
	bs.tooltip_text = "亲自上阵时战场上同时最多多少人（其余作为援军分波上场）；电脑慢就调小"
	var bs_label := Label.new()
	bs_label.text = "战场规模 %d" % battle_size
	bs_label.add_theme_color_override("font_color", MUTED)
	bs.value_changed.connect(func(x):
		battle_size = int(x)
		bs_label.text = "战场规模 %d" % battle_size
		save())
	grid.add_child(bs_label)
	bs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(bs)

	# ---- 3D battle difficulty (Warband's options)
	_diff_label = Label.new()
	_diff_label.add_theme_color_override("font_color", GOLD)
	v.add_child(_diff_label)
	_update_diff()
	var dg := GridContainer.new()
	dg.columns = 2
	dg.add_theme_constant_override("h_separation", 14)
	dg.add_theme_constant_override("v_separation", 8)
	v.add_child(dg)
	_opt(dg, "你受到的伤害", DMG_LEVELS, player_damage, "亲自上阵时你本人（和你的坐骑）受到的伤害比例",
		func(i): player_damage = i)
	_opt(dg, "友军受到的伤害", DMG_LEVELS, ally_damage, "你的部下和友军受到的伤害比例",
		func(i): ally_damage = i)
	_opt(dg, "战斗 AI", AI_LEVELS, ai_level, "敌我士兵格挡、反应和射箭的本事",
		func(i): ai_level = i)
	_opt(dg, "战斗速度", SPEED_LEVELS, combat_speed, "出招、收招的快慢（不影响跑动）",
		func(i): combat_speed = i)
	_opt(dg, "格挡方向", ["手动（鼠标方向）", "自动"], 1 if auto_block else 0, "自动：按住右键时自动挡向最近的来招",
		func(i): auto_block = i == 1)
	_opt(dg, "攻击方向", ["手动（鼠标方向）", "自动"], 1 if auto_attack else 0, "自动：挑对方没有防住的方向出招",
		func(i): auto_attack = i == 1)

	var vol := HSlider.new()
	vol.min_value = 0.0
	vol.max_value = 1.0
	vol.step = 0.05
	vol.value = sfx_volume
	vol.custom_minimum_size = Vector2(160, 0)
	vol.value_changed.connect(func(x):
		sfx_volume = x
		save())
	_row(dg, "战斗音效音量", vol)

	v.add_child(_check("垂直同步", vsync, func(on):
		vsync = on
		_after_change()))
	v.add_child(_check("窗口模式下锁定鼠标（全屏时始终锁定）", lock_mouse, func(on):
		lock_mouse = on
		_after_change()))
	v.add_child(_check("鼠标推到屏幕边缘时滚动地图", edge_scroll, func(on):
		edge_scroll = on
		_after_change()))

	var hint := Label.new()
	hint.text = "F11 / Alt+回车 切换全屏 · F10 临时解锁/锁定鼠标 · 切到其他窗口时自动释放鼠标\n设置保存在 %s" % ProjectSettings.globalize_path(PATH)
	hint.add_theme_color_override("font_color", MUTED)
	hint.add_theme_font_size_override("font_size", 12)
	v.add_child(hint)

	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.pressed.connect(close)
	v.add_child(close_btn)
	_sync_widgets()


func _after_change() -> void:
	save()
	apply_display()
	_sync_widgets()
	changed.emit()


func _sync_widgets() -> void:
	if _mode_opt == null:
		return
	_mode_opt.select(mode)
	# windowed sizes that fit on this screen (plus the current one)
	var usable := Vector2i(99999, 99999)
	if not _headless:
		usable = DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()).size
	_sizes = []
	for s in SIZES:
		if s.x <= usable.x and s.y <= usable.y:
			_sizes.append(s)
	if not _sizes.has(win_size):
		_sizes.append(win_size)
		_sizes.sort_custom(func(a, b): return a.x * a.y < b.x * b.y)
	_size_opt.clear()
	for s in _sizes:
		_size_opt.add_item("%d × %d" % [s.x, s.y])
	_size_opt.select(_sizes.find(win_size))
	_size_opt.disabled = not is_windowed()
	var si := SCALES.find(ui_scale)
	_scale_opt.select(si if si >= 0 else SCALES.find(1.0))
