extends CanvasLayer
## Battle HUD: crosshair with the attack / block direction, bow reticle, health (and horse), weapon
## and ammo, both armies' strength, order messages, kill feed, and the result screen.

const CREAM := Color("efe6d2")
const GOLD := Color("f2c75c")
const MUTED := Color("aab4ae")
const FRIENDLY := Color("a3d3ac")
const HOSTILE := Color("ffa49b")
const PANEL := Color(0.07, 0.085, 0.09, 0.78)
const RIM := Color(0.72, 0.65, 0.51, 0.36)
const RETICLE_SHADOW := Color(0.05, 0.06, 0.06, 0.65)
const GROUP_NAMES := {"inf": "步兵", "arc": "射手", "cav": "骑兵"}
const STANCE_NAMES := {"hold": "驻守", "follow": "跟随", "charge": "冲锋", "stand": "站住", "retreat": "撤退"}

var battle: Battle
var canvas: Control
var font: Font
var _msgs: Array = []          # [text, color, age]
var _feed: Array = []
var _marker := 0.0
var _marker_txt := ""
var _result_panel: Control
var show_map := false          # Backspace: battle overview (Warband)


func toggle_map() -> void:
	show_map = not show_map


func setup(b: Battle) -> void:
	battle = b
	font = load("res://assets/fonts/DroidSansFallbackFull.ttf")
	canvas = Control.new()
	canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.draw.connect(_draw)
	add_child(canvas)


func message(t: String, c: Color) -> void:
	_msgs.append([t, c, 0.0])
	if _msgs.size() > 5:
		_msgs.pop_front()


func feed(t: String, c: Color) -> void:
	_feed.append([t, c, 0.0])
	if _feed.size() > 7:
		_feed.pop_front()


var _hurt := 0.0


func hurt(dmg: int) -> void:
	_hurt = clampf(0.25 + dmg / 60.0, 0.0, 0.8)


func hit_marker(dmg: int, early: bool) -> void:
	_marker = 0.6
	_marker_txt = ("磕碰 " if early else "") + "命中 %d" % dmg


func _process(dt: float) -> void:
	for m in _msgs:
		m[2] += dt
	_msgs = _msgs.filter(func(m): return m[2] < 6.0)
	for m in _feed:
		m[2] += dt
	_feed = _feed.filter(func(m): return m[2] < 8.0)
	_marker = maxf(0.0, _marker - dt)
	_hurt = maxf(0.0, _hurt - dt * 1.5)
	canvas.queue_redraw()


func _t(p: Vector2, s: String, size: int, c: Color, center := false) -> void:
	var q := p
	if center:
		q.x -= _width(s, size) * 0.5
	canvas.draw_string_outline(font, q, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4, Color(0, 0, 0, 0.8))
	canvas.draw_string(font, q, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, c)


func _width(s: String, size: int) -> float:
	return font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


func _panel(rect: Rect2, accent: Color = RIM) -> void:
	canvas.draw_rect(rect, PANEL)
	canvas.draw_rect(rect, RIM, false, 1.0)
	canvas.draw_rect(Rect2(rect.position, Vector2(2, rect.size.y)), accent)


func _bar(p: Vector2, w: float, frac: float, c: Color, label: String) -> void:
	canvas.draw_rect(Rect2(p, Vector2(w, 10)), Color(0.03, 0.035, 0.04, 0.85))
	var filled := (w - 2) * clampf(frac, 0, 1)
	canvas.draw_rect(Rect2(p + Vector2(1, 1), Vector2(filled, 8)), c)
	canvas.draw_rect(Rect2(p + Vector2(1, 1), Vector2(filled, 2)), c.lightened(0.28))
	_t(p + Vector2(w + 8, 10), label, 14, CREAM)


func _draw() -> void:
	if battle == null:
		return
	var vs := canvas.size
	var c := vs * 0.5
	if show_map:
		_draw_map(vs)
	if _hurt > 0.0:
		# red vignette when you take a hit
		for i in 6:
			var w := 18.0 + i * 14.0
			var col := Color(0.7, 0.05, 0.03, _hurt * (0.35 - i * 0.05))
			canvas.draw_rect(Rect2(0, 0, vs.x, w), col)
			canvas.draw_rect(Rect2(0, vs.y - w, vs.x, w), col)
			canvas.draw_rect(Rect2(0, 0, w, vs.y), col)
			canvas.draw_rect(Rect2(vs.x - w, 0, w, vs.y), col)
	var p := battle.player
	# strength of both sides
	var n := [0, 0]
	for a in battle.agents:
		if a.active():
			n[a.side] += 1
	var me := battle.player_side
	var strength: Array[String] = []
	for side in [me, 1 - me]:
		var reserve: int = battle.reserves[side].size()
		strength.append("%s  %d 人%s" % [battle.side_names[side], n[side], ("（援军 %d）" % reserve) if reserve > 0 else ""])
	var sel: Array[String] = []
	if not battle.setup.get("arena", false):
		for g in battle.ctrl.selected:
			var o: Dictionary = battle.orders[me][g]
			var stance: String = STANCE_NAMES.get(o.type, o.type)
			sel.append("%s:%s%s" % [GROUP_NAMES[g], stance, " / 停射" if o.get("hold_fire", false) else ""])
	var orders := "  ".join(sel)
	var score_w := maxf(_width(strength[0], 17), _width(strength[1], 17)) + 30.0
	_panel(Rect2(12, 12, score_w, 54))
	canvas.draw_rect(Rect2(22, 23, 3, 11), FRIENDLY)
	canvas.draw_rect(Rect2(22, 46, 3, 11), HOSTILE)
	_t(Vector2(32, 33), strength[0], 17, FRIENDLY)
	_t(Vector2(32, 56), strength[1], 17, HOSTILE)
	if not orders.is_empty():
		_panel(Rect2(12, 70, maxf(score_w, _width(orders, 14) + 24.0), 26))
		_t(Vector2(24, 89), orders, 14, CREAM)
	# messages (top centre) and kill feed (right)
	for i in _msgs.size():
		var m: Array = _msgs[i]
		_t(Vector2(c.x, 34 + i * 24), m[0], 17, Color(m[1], clampf(6.0 - m[2], 0, 1)), true)
	for i in _feed.size():
		var m: Array = _feed[i]
		var w := _width(m[0], 15)
		var x := vs.x - w - 23.0
		var y := 12.0 + i * 24.0
		var opacity := clampf(8.0 - m[2], 0, 1)
		canvas.draw_rect(Rect2(x - 9, y, w + 20, 22), Color(PANEL, 0.67 * opacity))
		canvas.draw_rect(Rect2(vs.x - 14, y + 4, 2, 14), Color(m[1], opacity))
		_t(Vector2(x, y + 16), m[0], 15, Color(m[1], opacity))
	if battle.over:
		return
	if battle.phase_pending:
		_panel(Rect2(c - Vector2(250, 52), Vector2(500, 104)), GOLD.darkened(0.32))
		_t(c - Vector2(0, 13), "第 %d 阶段结束，援军待命" % battle.phase, 22, GOLD, true)
		var retreat := "撤出城池" if battle.siege_def == battle.player_side else "撤离战场"
		_t(c + Vector2(0, 22), "回车  重新列阵     Tab  %s" % retreat, 17, CREAM, true)
		return
	if p == null or not p.alive():
		_t(Vector2(c.x, vs.y - 60), "你已倒下 —— Tab 让部下继续作战（加速）", 18, Color("ff8f8f"), true)
		return
	if not p.is_player:
		_t(Vector2(c.x, vs.y - 40), "观战（AI 代你作战）", 16, MUTED, true)
		return
	# health / horse / weapon
	var wname: String = (p.ranged.get("name", "") + ("  剩 %d" if p.is_thrower() else "  箭 %d") % p.ammo) if p.using_ranged else str(p.weapon().get("name", ""))
	if p.shield_up():
		wname += " + " + str(p.shield.get("name", "盾"))
		if p.shield_max > 0.0:
			wname += " %d/%d" % [int(ceil(p.shield_hp)), int(p.shield_max)]
	elif not p.shield.is_empty():
		wname += "（%s负于背）" % str(p.shield.get("name", "盾"))
	if p.using_ranged and p.ranged.get("kind", "") == "crossbow" and not p.crossbow_loaded and not p.can_reload():
		wname += "  马上无法上弦"
	wname += "   （滚轮换武器）"
	var y := vs.y - (98.0 if p.mounted else 78.0)
	_panel(Rect2(12, y - 10, maxf(296.0, _width(wname, 15) + 24.0), 72 if p.mounted else 52))
	_bar(Vector2(24, y), 180, p.hp / p.max_hp, Color("bd5444"), "生命 %d" % int(maxf(0, p.hp)))
	if p.mounted:
		_bar(Vector2(24, y + 20), 180, p.horse_hp / maxf(1.0, p.horse_max_hp), Color("a68652"), "坐骑 %d" % int(p.horse_hp))
	_t(Vector2(24, vs.y - 45), wname, 15, CREAM)
	if battle.has_method("interact_hint"):
		var hint: String = battle.interact_hint(p)
		if hint != "":
			_t(Vector2(vs.x * 0.5, vs.y * 0.62), hint, 18, Color("f2c75c"), true)
	# crosshair / reticle
	if p.using_ranged:
		var r := 4.0 + tan(deg_to_rad(p.spread())) * vs.y * 0.9 if p.state == Agent.AIM else 22.0
		canvas.draw_arc(c, r, 0, TAU, 32, RETICLE_SHADOW, 3.5, true)
		canvas.draw_arc(c, r, 0, TAU, 32, Color(CREAM, 0.85), 1.4, true)
		canvas.draw_circle(c, 2.6, RETICLE_SHADOW)
		canvas.draw_circle(c, 1.4, CREAM)
		if p.state == Agent.RELOAD:
			_t(c + Vector2(0, 40), "上弦中……", 14, MUTED, true)
	else:
		canvas.draw_circle(c, 3.1, RETICLE_SHADOW)
		canvas.draw_circle(c, 1.7, CREAM)
		var dir: int = p.attack_dir if p.state in [Agent.READY, Agent.STRIKE] else battle.ctrl.current_dir()
		var col := GOLD if p.state in [Agent.READY, Agent.STRIKE] else Color(1, 1, 1, 0.35)
		if p.state == Agent.BLOCK:
			dir = p.block_dir
			col = Color("8fc3ff")
		# arrow pointing to the side the swing comes from (block: the side you guard)
		var v: Vector2 = {Agent.Dir.UP: Vector2(0, -1), Agent.Dir.RIGHT: Vector2(1, 0), Agent.Dir.LEFT: Vector2(-1, 0), Agent.Dir.DOWN: Vector2(0, 1)}[dir]
		if p.state == Agent.BLOCK and dir in [Agent.Dir.RIGHT, Agent.Dir.LEFT]:
			v = -v
		var tip: Vector2 = c + v * 34.0
		var base: Vector2 = c + v * 18.0
		var perp := Vector2(-v.y, v.x) * 8.0
		canvas.draw_colored_polygon(PackedVector2Array([tip + v * 2.0, base + perp * 1.25 - v, base - perp * 1.25 - v]),
			Color(RETICLE_SHADOW, col.a * 0.82))
		canvas.draw_colored_polygon(PackedVector2Array([tip, base + perp, base - perp]), col)
		if p.state == Agent.READY and p.state_t >= p.ready_time():
			canvas.draw_arc(c, 40, 0, TAU, 32, Color(GOLD, 0.6), 2.0, true)
	if _marker > 0.0:
		_t(c + Vector2(0, -46), _marker_txt, 16, Color(1, 0.85, 0.5, _marker / 0.6), true)
	_t(Vector2(c.x, vs.y - 14), "鼠标方向+左键 攻击 · 右键 格挡 · 1/2/3/0 选兵 F1-F9 下令 · Tab 撤离 · Esc 释放鼠标", 13, Color(1, 1, 1, 0.5), true)


func show_result(r: Dictionary) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.12, 0.94)
	sb.border_color = Color("6b5a3a")
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", sb)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	var lab := RichTextLabel.new()
	lab.bbcode_enabled = true
	lab.fit_content = true
	lab.custom_minimum_size = Vector2(560, 0)
	box.add_child(lab)
	var btn := Button.new()
	btn.text = "返回大地图" if battle.embedded else "离开"
	btn.pressed.connect(battle.close)
	box.add_child(btn)
	var me: int = r.player_side
	var won: bool = r.winner == me
	var head := "[font_size=26][color=#%s]%s[/color][/font_size]\n" % ["8fd3a0" if won else "ff8f8f",
		"胜利！" if won else ("撤离战场" if r.how == "retreat" else "战败")]
	var body := ""
	for s in 2:
		var sd: Dictionary = r.sides[s]
		body += "\n[b]%s[/b]%s\n" % [sd.name, "（你）" if s == me else ""]
		var tot := {"killed": 0, "wounded": 0, "routed": 0, "fine": 0}
		for tid in sd.troops:
			var t: Dictionary = sd.troops[tid]
			for k in tot:
				tot[k] += int(t[k])
			body += "  %s：阵亡 %d · 重伤 %d · 溃逃 %d · 完好 %d\n" % [battle.rules.troop_name(tid), t.killed, t.wounded, t.routed, t.fine]
		body += "  [color=#aab4ae]合计 阵亡 %d · 重伤 %d · 溃逃 %d · 完好 %d[/color]\n" % [tot.killed, tot.wounded, tot.routed, tot.fine]
	lab.text = head + "用时 %d 秒\n" % int(r.time) + body + "\n[color=#aab4ae]回车 / Tab 离开战场[/color]"
	panel.position = (canvas.size - panel.get_combined_minimum_size()) * 0.5


## Battle overview (Backspace): every soldier as a dot, your divisions' order points, you as an arrow.
## Drawn with your army at the bottom, facing up.
func _draw_map(vs: Vector2) -> void:
	var size := minf(vs.y * 0.72, vs.x * 0.6)
	var r := Rect2(Vector2((vs.x - size) * 0.5, (vs.y - size) * 0.5), Vector2(size, size))
	canvas.draw_rect(r.grow(10), Color(0.05, 0.07, 0.06, 0.96))
	canvas.draw_rect(r, Color(0.2, 0.27, 0.17, 1.0))
	canvas.draw_rect(r, Color("6b5a3a"), false, 2.0)
	var flip := -1.0 if battle.player_side == 1 else 1.0
	# frame the fighting: the box around everyone still standing (and the order points), at least 80 m
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for a in battle.agents:
		if a.visible and a.alive():
			var q := Vector2(a.global_position.x, a.global_position.z) * flip
			lo = lo.min(q)
			hi = hi.max(q)
	if lo.x == INF:
		lo = Vector2(-50, -50)
		hi = Vector2(50, 50)
	var mid := (lo + hi) * 0.5
	var span := maxf(80.0, maxf(hi.x - lo.x, hi.y - lo.y) * 1.15)
	var to_map := func(p: Vector3) -> Vector2:
		var q := (Vector2(p.x, p.z) * flip - mid) / span + Vector2(0.5, 0.5)
		return r.position + q.clamp(Vector2.ZERO, Vector2.ONE) * size
	var fd: BattleField = battle.field
	if not fd.siege.is_empty():
		# the town wall, its ladders (brown) and the stairs down into the town (grey)
		var sd: float = fd.siege.sd
		var band := func(x0: float, x1: float, u0: float, u1: float, c: Color) -> void:
			var a0: Vector2 = to_map.call(Vector3(x0, 0, u0 * sd))
			var a1: Vector2 = to_map.call(Vector3(x1, 0, u1 * sd))
			canvas.draw_rect(Rect2(a0.min(a1), (a1 - a0).abs()).grow(0.5), c)
		band.call(-fd.size * 0.5, fd.size * 0.5, BattleField.W_FRONT, BattleField.W_BACK, Color("8a8478"))
		for lx in fd.siege.ladders:
			band.call(lx - BattleField.LADDER_HALF, lx + BattleField.LADDER_HALF, BattleField.W_FRONT - BattleField.LADDER_LEN, BattleField.W_FRONT, Color("a0703a"))
		for sx in fd.siege.stairs:
			band.call(sx - BattleField.STAIR_HALF, sx + BattleField.STAIR_HALF, BattleField.W_BACK, BattleField.W_BACK + BattleField.STAIR_LEN, Color("6f6a60"))
	for a in battle.agents:
		if not a.visible:
			continue
		var col: Color = (battle.side_colors[a.side] as Color).lightened(0.25)
		if not a.alive():
			canvas.draw_circle(to_map.call(a.global_position), 1.2, Color(col, 0.25))
			continue
		var rad := 3.4 if a.mounted else 2.6
		if a.routed:
			col = col.darkened(0.5)
		canvas.draw_circle(to_map.call(a.global_position), rad, col)
	# your divisions' orders
	var names := {"inf": "步", "arc": "射", "cav": "骑"}
	for div in names:
		var o: Dictionary = battle.orders[battle.player_side].get(div, {})
		if o.is_empty() or o.get("type", "") == "charge":
			continue
		var at: Vector2 = to_map.call(o.pos)
		canvas.draw_circle(at, 7.0, Color(GOLD, 0.35))
		canvas.draw_string(font, at + Vector2(-6, 5), names[div], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, GOLD)
	var p = battle.player
	if p and p.alive():
		var at: Vector2 = to_map.call(p.global_position)
		var f: Vector3 = p.forward() * flip
		var d := Vector2(f.x, f.z).normalized()
		var n := Vector2(-d.y, d.x)
		canvas.draw_colored_polygon(PackedVector2Array([at + d * 11, at - d * 6 + n * 6, at - d * 6 - n * 6]), CREAM)
	canvas.draw_string(font, r.position + Vector2(0, -16), "战场全图（Backspace 关闭）· 金色：你下令驻守的位置 · 图宽 %d 米" % int(span),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, MUTED)
	for s in 2:
		var alive: int = battle.alive_by_side[s].size()
		var txt := "%s %d 人" % [battle.side_names[s], alive]
		canvas.draw_string(font, r.position + Vector2(0 if s == battle.player_side else size * 0.55, size + 26), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, battle.side_colors[s])
