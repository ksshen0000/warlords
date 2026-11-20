extends Node3D
## Promo footage: runs a 3D battle with the AI playing both sides, hides the HUD and flies a scripted
## camera through a list of shots. Meant for Godot's Movie Maker (fixed frame rate, frames to disk):
##   godot --path client --write-movie out/f.png --fixed-fps 30 --resolution 1920x1080 \
##         res://tools/promo/promo_battle.tscn -- --setup=... --promo=field|siege
## See tools/promo/make_promo.sh.

var b: Battle
var cam: Camera3D
var t := 0.0
var shots: Array = []          # [start, end, func(dt, local_t, first)]
var _cur := -1
var _look := Vector3.ZERO
var _subject: Agent = null
var _anchor := Vector3.ZERO
var end_time := 60.0


func _ready() -> void:
	var mode := "field"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--promo="):
			mode = a.substr(8)
	b = load("res://battle/battle.tscn").instantiate()
	add_child(b)
	if b.hud:
		b.hud.visible = false
	cam = Camera3D.new()
	cam.fov = 55.0
	cam.far = 1200.0
	add_child(cam)
	cam.current = true
	if mode == "siege":
		_siege_shots()
	else:
		_field_shots()
	end_time = shots[-1][1]


func _process(dt: float) -> void:
	cam.current = true
	t += dt
	if t >= end_time:
		get_tree().quit()
		return
	for i in shots.size():
		var s: Array = shots[i]
		if t >= s[0] and t < s[1]:
			var first := i != _cur
			_cur = i
			s[2].call(dt, t - s[0], first)
			break


# ------------------------------------------------------------------ helpers
func _alive(side := -1, div := "") -> Array:
	var out: Array = []
	for a in b.agents:
		if a.alive() and not a.routed and (side < 0 or a.side == side) and (div == "" or a.division == div):
			out.append(a)
	return out


func _centroid(lst: Array, fallback := Vector3.ZERO) -> Vector3:
	if lst.is_empty():
		return fallback
	var c := Vector3.ZERO
	for a in lst:
		c += a.global_position
	return c / lst.size()


## Where the fighting is thickest: the mean position of soldiers whose target is within a few metres.
func _melee_point(fallback: Vector3) -> Vector3:
	var c := Vector3.ZERO
	var n := 0
	for a in _alive():
		var tg = a.ai.get("target")
		if tg != null and is_instance_valid(tg) and tg.alive() and a.global_position.distance_to(tg.global_position) < 3.5:
			c += a.global_position
			n += 1
	return c / n if n > 4 else fallback


func _move(want: Vector3, look: Vector3, dt: float, first: bool, k := 2.5, kl := 3.0) -> void:
	var g := b.field.height_at(want.x, want.z) + 0.6
	want.y = maxf(want.y, g)
	if first:
		cam.global_position = want
		_look = look
	else:
		cam.global_position = cam.global_position.lerp(want, 1.0 - exp(-k * dt))
		_look = _look.lerp(look, 1.0 - exp(-kl * dt))
	if cam.global_position.distance_to(_look) > 0.01:
		cam.look_at(_look, Vector3.UP)


func _pick(lst: Array, near: Vector3) -> Agent:
	var best: Agent = null
	var bd := INF
	for a in lst:
		var d: float = a.global_position.distance_to(near)
		if d < bd:
			bd = d
			best = a
	return best


func _ease(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


# ------------------------------------------------------------------ open field
func _field_shots() -> void:
	# 1. crane down over our army as it forms up
	shots.append([0.0, 7.0, func(dt: float, lt: float, first: bool):
		var own := _centroid(_alive(0), Vector3(0, 0, 55))
		var foe := _centroid(_alive(1), Vector3(0, 0, -55))
		var k := _ease(lt / 7.0)
		var want := own + Vector3(lerpf(-30.0, -10.0, k), lerpf(24.0, 4.0, k), lerpf(34.0, 13.0, k))
		_move(want, own.lerp(foe, 0.35) + Vector3(0, 1.5, 0), dt, first, 8.0, 8.0)])
	# 2. over the archers' shoulders as they loose
	shots.append([7.0, 14.0, func(dt: float, lt: float, first: bool):
		var arc := _alive(0, "arc")
		var c := _centroid(arc, Vector3(0, 0, 40))
		var foe := _centroid(_alive(1), Vector3(0, 0, -40))
		var dir := (foe - c).normalized()
		var side := Vector3(dir.z, 0, -dir.x)
		var want := c + side * (9.0 - lt * 0.3) + dir * 5.0 + Vector3(0, 1.3, 0)
		_move(want, c - side * 3.0 + dir * 2.0 + Vector3(0, 3.0, 0), dt, first, 4.0, 4.0)])
	# 3. ride alongside a horseman as the cavalry close
	shots.append([14.0, 24.0, func(dt: float, lt: float, first: bool):
		if first or _subject == null or not _subject.alive():
			var cav := _alive(1, "cav")
			if cav.is_empty():
				cav = _alive(0, "cav")
			_subject = _pick(cav, _centroid(cav)) if not cav.is_empty() else null
		if _subject == null:
			return
		var p := _subject.global_position
		var fwd := _subject.forward()
		var rgt := _subject.right()
		var want := p + rgt * 6.5 + fwd * lerpf(3.0, -2.0, lt / 10.0) + Vector3(0, 2.0, 0)
		_move(want, p + fwd * 4.0 + Vector3(0, 1.6, 0), dt, first, 5.0, 6.0)])
	# 4. slow orbit through the thick of the melee
	shots.append([24.0, 40.0, func(dt: float, lt: float, first: bool):
		if first:
			_anchor = _melee_point(_centroid(_alive()))
		_anchor = _anchor.lerp(_melee_point(_anchor), 1.0 - exp(-0.6 * dt))
		var ang := 0.6 + lt * 0.16
		var r := 10.5 + 2.0 * sin(lt * 0.3)
		var want := _anchor + Vector3(cos(ang) * r, 4.2, sin(ang) * r)
		_move(want, _anchor + Vector3(0, 0.6, 0), dt, first, 3.0, 2.0)])
	# 5. behind the commander, in the press
	shots.append([40.0, 48.0, func(dt: float, lt: float, first: bool):
		var h: Agent = b.player if b.player and b.player.alive() else _pick(_alive(0), _anchor)
		if h == null:
			return
		var p := h.global_position
		var fwd := h.forward()
		var want := p - fwd * (4.5 if h.mounted else 3.2) + h.right() * 0.8 + Vector3(0, 2.6 if h.mounted else 2.0, 0)
		_move(want, p + fwd * 6.0 + Vector3(0, 1.4, 0), dt, first, 4.0, 3.0)])
	# 6. rise up over the whole field
	shots.append([48.0, 58.0, func(dt: float, lt: float, first: bool):
		if first:
			_anchor = _melee_point(_centroid(_alive()))
		var c := _anchor
		var k := _ease(lt / 10.0)
		var ang := 2.2 + lt * 0.05
		var r := lerpf(18.0, 45.0, k)
		var want := c + Vector3(cos(ang) * r, lerpf(6.0, 34.0, k), sin(ang) * r)
		_move(want, c, dt, first, 6.0, 4.0)])


# ------------------------------------------------------------------ siege assault
func _siege_shots() -> void:
	var sd: float = b.field.siege.sd                  # u = z * sd ; the wall front face at u = 18
	var lad: Array = b.field.siege.ladders
	var H: float = b.field.siege.h
	var mid_lad: float = lad[lad.size() / 2]
	# 1. the wall from the fields, the attackers marching up
	shots.append([0.0, 8.0, func(dt: float, lt: float, first: bool):
		var k := _ease(lt / 8.0)
		var want := b.field.siege_point(lerpf(-60.0, -25.0, k), lerpf(-70.0, -40.0, k)) + Vector3(0, lerpf(22.0, 9.0, k), 0)
		_move(want, b.field.siege_point(0.0, 18.0) + Vector3(0, H * 0.7, 0), dt, first, 8.0, 8.0)])
	# 2. on the wall walk, behind the defending archers, looking out
	shots.append([8.0, 16.0, func(dt: float, lt: float, first: bool):
		var p := b.field.wall_point(mid_lad + 9.0 + lt * 0.5, 0.75)
		var out := b.field.siege_point(mid_lad, -40.0)
		_move(p + Vector3(0, 1.8, 0), out, dt, first, 6.0, 6.0)])
	# 3. the attackers at the foot of the wall (late approach); filled in from the sim: whoever is at a ladder
	shots.append([16.0, 26.0, func(dt: float, lt: float, first: bool):
		var x := _busiest_ladder(mid_lad)
		var base := b.field.siege_point(x, 12.0)
		var want := b.field.siege_point(x + 9.0, 5.0 - lt * 0.2) + Vector3(0, 1.8, 0)
		_move(want, base + Vector3(0, H * 0.55, 0), dt, first, 2.0, 2.0)])
	# 4. up on the battlements at the head of a ladder: the fight for the wall
	shots.append([26.0, 40.0, func(dt: float, lt: float, first: bool):
		var x := _busiest_ladder(mid_lad)
		var head := b.field.wall_point(x, 0.3)
		var ang := 0.9 + lt * 0.09
		var want := head + Vector3(cos(ang) * 7.0 * 1.0, 3.2, sin(ang) * 7.0 * sd)
		_move(want, head + Vector3(0, 0.8, 0), dt, first, 2.0, 2.0)])
	# 5. high over the wall
	shots.append([40.0, 50.0, func(dt: float, lt: float, first: bool):
		var k := _ease(lt / 10.0)
		var c := b.field.siege_point(0.0, 18.0)
		var want := b.field.siege_point(lerpf(40.0, 70.0, k), lerpf(-20.0, -60.0, k)) + Vector3(0, lerpf(18.0, 45.0, k), 0)
		_move(want, c, dt, first, 6.0, 4.0)])


## The ladder with the most soldiers close to its head (ties: the middle one).
func _busiest_ladder(fallback: float) -> float:
	var best := fallback
	var bn := 0
	for x in b.field.siege.ladders:
		var head: Vector3 = b.field.siege_point(x, 18.0)
		var n := 0
		for a in _alive():
			var p: Vector3 = a.global_position
			if absf(p.x - x) < 5.0 and absf(p.z - head.z) < 9.0:
				n += 1
		if n > bn:
			bn = n
			best = x
	return best
