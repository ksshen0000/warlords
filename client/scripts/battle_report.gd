extends Control
## Modal battle report: each side's troops (before / killed / wounded), captures, loot,
## and a round-by-round chart of remaining troops with each side's luck.

const CREAM := Color("efe6d2")
const MUTED := Color("8c9a94")
const GOLD := Color("f2c75c")
const RED := Color("ff8f8f")
const GREEN := Color("8fd3a0")
const CLS := {"inf": "步", "arc": "射", "cav": "骑"}

var title_label: Label
var summary: RichTextLabel
var side_a: RichTextLabel
var side_d: RichTextLabel
var chart: RoundChart


class RoundChart:
	extends Control
	var rounds: Array = []
	var start := [0, 0]
	var colors := [Color.WHITE, Color.WHITE]
	var names := ["攻方", "守方"]

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		draw_rect(Rect2(Vector2.ZERO, size), Color("141c20"))
		if rounds.is_empty():
			return
		var pad_l := 48.0
		var pad_r := 20.0
		var top := 34.0
		var bottom := 52.0
		var w := size.x - pad_l - pad_r
		var h := size.y - top - bottom
		var n := rounds.size()
		var vmax: float = max(1.0, max(float(start[0]), float(start[1])))
		var xs: Array[float] = []
		for i in n + 1:
			xs.append(pad_l + w * i / float(n))
		for g in 3:
			var gy: float = top + h * g / 2.0
			draw_line(Vector2(pad_l, gy), Vector2(pad_l + w, gy), Color(1, 1, 1, 0.06))
			draw_string(font, Vector2(6, gy + 4), str(int(vmax * (1.0 - g / 2.0))), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, MUTED)
		for si in 2:
			var lx := size.x - pad_r - 330.0 + si * 170.0
			draw_rect(Rect2(lx, 6, 12, 12), colors[si])
			draw_string(font, Vector2(lx + 18, 17), names[si], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, CREAM)
		for si in 2:
			var key := "attacker" if si == 0 else "defender"
			var pts := PackedVector2Array([Vector2(xs[0], top + h * (1.0 - float(start[si]) / vmax))])
			for i in n:
				pts.append(Vector2(xs[i + 1], top + h * (1.0 - float(rounds[i][key]) / vmax)))
			draw_polyline(pts, colors[si], 3.0, true)
			for i in pts.size():
				draw_circle(pts[i], 4.0, colors[si])
				var v: int = int(start[si]) if i == 0 else int(rounds[i - 1][key])
				draw_string(font, pts[i] + Vector2(-8, -8 if si == 0 else 18), str(v), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, colors[si])
		draw_string(font, Vector2(xs[0] - 12, size.y - 30), "开战", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, MUTED)
		for i in n:
			var r: Dictionary = rounds[i]
			var x: float = xs[i + 1]
			draw_string(font, Vector2(x - 22, size.y - 30), "第%d回合" % int(r.round), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, MUTED)
			var la: float = r.attacker_luck
			var ld: float = r.defender_luck
			draw_string(font, Vector2(x - 30, size.y - 12), "×%.2f" % la, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, GREEN if la >= 1.0 else RED)
			draw_string(font, Vector2(x + 4, size.y - 12), "×%.2f" % ld, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, GREEN if ld >= 1.0 else RED)
		draw_string(font, Vector2(4, size.y - 12), "运气", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, MUTED)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
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
	panel.custom_minimum_size = Vector2(900, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("1e2a30")
	sb.border_color = Color("3b4b50")
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	var head := HBoxContainer.new()
	title_label = Label.new()
	title_label.add_theme_font_size_override("font_size", 22)
	title_label.add_theme_color_override("font_color", GOLD)
	head.add_child(title_label)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	var close_btn := Button.new()
	close_btn.text = "关闭 (Esc)"
	close_btn.pressed.connect(close)
	head.add_child(close_btn)
	v.add_child(head)
	summary = _rich()
	v.add_child(summary)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 300)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var sides := HBoxContainer.new()
	sides.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sides.add_theme_constant_override("separation", 24)
	side_a = _rich()
	side_d = _rich()
	for r in [side_a, side_d]:
		r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sides.add_child(r)
	scroll.add_child(sides)
	v.add_child(scroll)
	var ct := Label.new()
	ct.text = "战况：各回合剩余兵力（下方为双方本回合运气系数，>1 发挥超常）"
	ct.add_theme_font_size_override("font_size", 13)
	ct.add_theme_color_override("font_color", MUTED)
	v.add_child(ct)
	chart = RoundChart.new()
	chart.custom_minimum_size = Vector2(0, 190)
	v.add_child(chart)


func _rich() -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.add_theme_color_override("default_color", CREAM)
	r.add_theme_font_size_override("normal_font_size", 14)
	r.add_theme_font_size_override("bold_font_size", 15)
	return r


func close() -> void:
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


func _esc(s) -> String:
	return str(s).replace("[", "[lb]")


func _side_info(state: Dictionary, side) -> Array:
	if side == null:
		return ["?", MUTED]
	var sid := str(side)
	if state.kingdoms.has(sid):
		return [state.kingdoms[sid].name, Color(state.kingdoms[sid].color)]
	if sid == "__bandit":
		return ["土匪", Color("c0605a")]
	return ["中立", Color("d9b44a")]


func open(ev: Dictionary, state: Dictionary) -> void:
	var rep: Dictionary = ev.report
	var kind: String = ev.type
	var place: String = str(ev.get("place", ""))
	var titles := {"battle": "之战", "conquest": "攻城战", "assault_failed": "攻城战", "hideout_cleared": "剿匪"}
	title_label.text = "第 %d 天 · %s%s" % [int(ev.day), place, titles.get(kind, "")]
	var sa = null
	var sd = null
	if ev.has("sides"):
		sa = ev.sides[0]
		sd = ev.sides[1]
	elif kind == "conquest":
		sa = ev.new
		sd = ev.old
	elif kind == "assault_failed" and state.settlements.has(ev.settlement):
		sd = state.settlements[ev.settlement].faction
	elif kind == "hideout_cleared":
		sd = "__bandit"
	var fa := _side_info(state, sa)
	var fd := _side_info(state, sd)
	var att_won: bool = rep.winner == "attacker"
	var wc: Color = fa[1] if att_won else fd[1]
	var res := "[font_size=17][b][color=#%s]%s获胜[/color][/b][/font_size]" % [wc.to_html(false), "攻方" if att_won else "守方"]
	res += "    兵力 %d : %d    伤亡 [color=#ff8f8f]%d : %d[/color]（其中阵亡 %d : %d）    共 %d 回合" % [
		int(rep.attacker_start), int(rep.defender_start), int(rep.attacker_losses), int(rep.defender_losses),
		int(rep.attacker_killed), int(rep.defender_killed), rep.rounds.size()]
	var extra: Array[String] = []
	if ev.has("terrain"):
		extra.append("地形：%s" % ev.terrain)
	if float(rep.defender_bonus) > 1.0:
		extra.append("守方地利/城防 ×%.2f" % float(rep.defender_bonus))
	if ev.has("loot") and int(ev.loot) > 0:
		extra.append("战利品约 %d 金" % int(ev.loot))
	if ev.has("prisoners") and int(ev.prisoners) > 0:
		extra.append("俘虏 %d 人" % int(ev.prisoners))
	var captured: Array = rep.get("captured", [])
	if captured.size():
		var names: Array[String] = []
		for hid in captured:
			if state.heroes.has(hid):
				names.append(state.heroes[hid].name)
		extra.append("[color=#c99cff]被俘：%s[/color]" % "、".join(names))
	if extra.size():
		res += "\n" + "    ".join(extra)
	summary.text = res
	side_a.text = _side_text("攻方", fa, rep.attacker, att_won)
	side_d.text = _side_text("守方", fd, rep.defender, not att_won)
	chart.rounds = rep.rounds
	chart.start = [int(rep.attacker_start), int(rep.defender_start)]
	var cd: Color = fd[1]
	if cd.is_equal_approx(fa[1]):
		cd = cd.lightened(0.3)
	chart.colors = [fa[1], cd]
	chart.names = ["攻方 · " + str(fa[0]), "守方 · " + str(fd[0])]
	chart.queue_redraw()
	visible = true


func _side_text(role: String, fac: Array, units: Array, won: bool) -> String:
	var col: String = fac[1].to_html(false)
	var out := "[b][color=#%s]%s · %s[/color][/b]  %s\n" % [col, role, _esc(fac[0]),
		"[color=#8fd3a0]胜[/color]" if won else "[color=#ff8f8f]败[/color]"]
	for u in units:
		out += "\n[b]%s[/b] [color=#8c9a94]统御 %d[/color]\n" % [_esc(u.label), int(u.tactics)]
		out += "[table=4]"
		for c in ["兵种", "战前", "阵亡", "受伤"]:
			out += "[cell][color=#8c9a94]%s  [/color][/cell]" % c
		var t_start := 0
		var t_k := 0
		var t_w := 0
		for r in u.rows:
			var st := int(r.start)
			var k := int(r.killed)
			var w := int(r.wounded)
			t_start += st
			t_k += k
			t_w += w
			out += "[cell][color=#8c9a94]%s[/color]%s%s  [/cell][cell]%d[/cell][cell]%s[/cell][cell]%s[/cell]" % [
				CLS.get(r.cls, ""), "★".repeat(int(r.tier)), _esc(r.name), st,
				"[color=#ff8f8f]%d[/color]" % k if k else "—", "[color=#e8b86a]%d[/color]" % w if w else "—"]
		out += "[cell][b]合计[/b][/cell][cell][b]%d[/b][/cell][cell][color=#ff8f8f]%d[/color][/cell][cell][color=#e8b86a]%d[/color][/cell]" % [t_start, t_k, t_w]
		out += "[/table]\n"
	return out
