extends CanvasLayer
## Battle HUD: crosshair with the attack / block direction, bow reticle, health (and horse), weapon
## and ammo, both armies' strength, order messages, kill feed, and the result screen.

const CREAM := Color("efe6d2")
const GOLD := Color("f2c75c")
const MUTED := Color("aab4ae")

var battle: Battle
var canvas: Control
var font: Font
var _msgs: Array = []          # [text, color, age]
var _feed: Array = []
var _marker := 0.0
var _marker_txt := ""
var _result_panel: Control


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
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var q := p - Vector2(w * 0.5, 0) if center else p
	canvas.draw_string_outline(font, q, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4, Color(0, 0, 0, 0.8))
	canvas.draw_string(font, q, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, c)


func _bar(p: Vector2, w: float, frac: float, c: Color, label: String) -> void:
	canvas.draw_rect(Rect2(p, Vector2(w, 12)), Color(0, 0, 0, 0.55))
	canvas.draw_rect(Rect2(p + Vector2(1, 1), Vector2((w - 2) * clampf(frac, 0, 1), 10)), c)
	_t(p + Vector2(w + 8, 11), label, 14, CREAM)


func _draw() -> void:
	if battle == null:
		return
	var vs := canvas.size
	var c := vs * 0.5
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
	_t(Vector2(16, 28), "%s  %d 人%s" % [battle.side_names[me], n[me], ("（援军 %d）" % battle.reserves[me].size()) if battle.reserves[me].size() else ""], 17, Color("8fd3a0"))
	_t(Vector2(16, 52), "%s  %d 人%s" % [battle.side_names[1 - me], n[1 - me], ("（援军 %d）" % battle.reserves[1 - me].size()) if battle.reserves[1 - me].size() else ""], 17, Color("ff8f8f"))
	var sel_names := {"inf": "步兵", "arc": "射手", "cav": "骑兵"}
	var sel: Array[String] = []
	for g in battle.ctrl.selected:
		var o: Dictionary = battle.orders[me][g]
		sel.append("%s:%s" % [sel_names[g], {"hold": "驻守", "follow": "跟随", "charge": "冲锋", "stand": "站住", "retreat": "撤退"}.get(o.type, o.type)])
	_t(Vector2(16, 76), "  ".join(sel), 14, MUTED)
	# messages (top centre) and kill feed (right)
	for i in _msgs.size():
		var m: Array = _msgs[i]
		_t(Vector2(c.x, 34 + i * 24), m[0], 17, Color(m[1], clampf(6.0 - m[2], 0, 1)), true)
	for i in _feed.size():
		var m: Array = _feed[i]
		var w := font.get_string_size(m[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
		_t(Vector2(vs.x - w - 16, 30 + i * 22), m[0], 15, Color(m[1], clampf(8.0 - m[2], 0, 1)))
	if battle.over:
		return
	if p == null or not p.alive():
		_t(Vector2(c.x, vs.y - 60), "你已倒下 —— Tab 让部下继续作战（加速）", 18, Color("ff8f8f"), true)
		return
	if not p.is_player:
		_t(Vector2(c.x, vs.y - 40), "观战（AI 代你作战）", 16, MUTED, true)
		return
	# health / horse / weapon
	var y := vs.y - 70
	_bar(Vector2(20, y), 200, p.hp / p.max_hp, Color("c0392b"), "生命 %d" % int(maxf(0, p.hp)))
	if p.mounted:
		_bar(Vector2(20, y + 20), 200, p.horse_hp / battle.rules.num("horse", "hp", 110), Color("a07a4a"), "坐骑 %d" % int(p.horse_hp))
	var wname: String = (p.ranged.get("name", "") + "  箭 %d" % p.ammo) if p.using_ranged else str(p.weapon().get("name", ""))
	if not p.shield.is_empty() and not p.using_ranged:
		wname += " + " + str(p.shield.get("name", "盾"))
	_t(Vector2(20, y + 48), wname + "   （滚轮换武器）", 15, CREAM)
	# crosshair / reticle
	if p.using_ranged:
		var r := 4.0 + tan(deg_to_rad(p.spread())) * vs.y * 0.9 if p.state == Agent.AIM else 22.0
		canvas.draw_arc(c, r, 0, TAU, 32, Color(1, 1, 1, 0.75), 1.5, true)
		canvas.draw_circle(c, 1.5, Color.WHITE)
		if p.state == Agent.RELOAD:
			_t(c + Vector2(0, 40), "上弦中……", 14, MUTED, true)
	else:
		canvas.draw_circle(c, 2.0, Color(1, 1, 1, 0.8))
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
	var lab := RichTextLabel.new()
	lab.bbcode_enabled = true
	lab.fit_content = true
	lab.custom_minimum_size = Vector2(560, 0)
	panel.add_child(lab)
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
	lab.text = head + "用时 %d 秒\n" % int(r.time) + body + "\n[color=#aab4ae]回车 / Tab 离开[/color]"
	panel.position = (canvas.size - panel.get_combined_minimum_size()) * 0.5
