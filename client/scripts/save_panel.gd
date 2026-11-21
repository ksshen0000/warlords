extends PanelContainer
## Save / load (Warband's "Save Game" / "Load Game"): the auto-save and five slots, each with the day,
## who you are, gold, men and when it was written. Loading asks for a second click (it drops the
## current, unsaved campaign).

signal save_requested(slot: String)
signal load_requested(slot: String)

const CREAM := Color("efe6d2")
const MUTED := Color("8c9a94")
const GOLD := Color("f2c75c")

var _list: VBoxContainer
var _note: Label
var _armed := ""            # slot whose 读取 was clicked once
var _can_save := true


func _ready() -> void:
	visible = false
	custom_minimum_size = Vector2(640, 0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.12, 0.14, 0.97)
	sb.border_color = Color("6b5a3a")
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(16)
	add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	add_child(v)
	var head := HBoxContainer.new()
	var t := Label.new()
	t.text = "存档 / 读档"
	t.add_theme_font_size_override("font_size", 21)
	t.add_theme_color_override("font_color", GOLD)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(close)
	head.add_child(close_btn)
	v.add_child(head)
	_note = Label.new()
	_note.add_theme_color_override("font_color", MUTED)
	_note.add_theme_font_size_override("font_size", 13)
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_note)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	v.add_child(_list)


func open(can_save: bool) -> void:
	_can_save = can_save
	_armed = ""
	visible = true
	_note.text = "正在读取存档列表…"


func close() -> void:
	visible = false
	_armed = ""


func show_list(saves: Array, dir: String = "") -> void:
	for c in _list.get_children():
		c.queue_free()
	_note.text = ("每 3 天自动存档一次（打开菜单时不存）。" if _can_save else "创建角色或打开菜单时不能存档，可以读档。") \
		+ ("\n存档位置：" + dir if dir != "" else "")
	for s in saves:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var name := Label.new()
		name.text = str(s.get("name", s.slot))
		name.custom_minimum_size = Vector2(84, 0)
		name.add_theme_color_override("font_color", GOLD)
		row.add_child(name)
		var info := Label.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.add_theme_font_size_override("font_size", 13)
		if bool(s.get("empty", true)):
			info.text = "（空）"
			info.add_theme_color_override("font_color", MUTED)
		elif bool(s.get("broken", false)):
			info.text = "（存档损坏，无法读取）"
			info.add_theme_color_override("font_color", Color("ff8f7a"))
		else:
			var when := Time.get_datetime_string_from_unix_time(int(float(s.get("saved_at", 0))) + _tz(), true)
			var lvl = s.get("level")
			info.text = "第 %d 天 · %s%s · 金 %d · %d 人 · 名望 %d\n%s" % [int(s.day), str(s.get("who", "")),
				(" · %d 级" % int(lvl)) if lvl != null else "", int(s.get("gold", 0)), int(s.get("troops", 0)),
				int(s.get("renown", 0)), when]
			info.add_theme_color_override("font_color", CREAM)
		row.add_child(info)
		var slot: String = str(s.slot)
		if slot != "auto":
			var sv := Button.new()
			sv.text = "存到这里" if bool(s.get("empty", true)) else "覆盖"
			sv.disabled = not _can_save
			sv.focus_mode = Control.FOCUS_NONE
			sv.pressed.connect(func(): save_requested.emit(slot))
			row.add_child(sv)
		var ld := Button.new()
		ld.text = "确定读取？" if _armed == slot else "读取"
		ld.disabled = bool(s.get("empty", true)) or bool(s.get("broken", false))
		ld.focus_mode = Control.FOCUS_NONE
		ld.pressed.connect(func():
			if _armed == slot:
				_armed = ""
				load_requested.emit(slot)
			else:
				_armed = slot
				show_list(saves, dir))
		row.add_child(ld)
		_list.add_child(row)


func _tz() -> int:
	return int(Time.get_time_zone_from_system().get("bias", 0)) * 60
