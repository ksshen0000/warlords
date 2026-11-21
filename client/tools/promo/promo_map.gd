extends Node
## Promo footage of the campaign map: runs the normal client against a running server, lets time flow
## and moves the map camera through a few shots (for Godot's Movie Maker; see make_promo.sh).

var main: Control
var map: Control
var t := -1.0
var z0 := 1.0
var c0 := Vector2.ZERO
const LEN := 18.0


func _ready() -> void:
	main = load("res://main.tscn").instantiate()
	add_child(main)


func _process(dt: float) -> void:
	map = main.map
	if t < 0.0:
		# wait for the map and the first state
		if main.map_seed < 0 or not map.state.has("parties"):
			return
		map.fit()
		z0 = map.zoom
		c0 = map.world_size * 0.5
		t = 0.0
	main.auto_steps = 100000          # keep time flowing
	main.speed_idx = 1
	t += dt
	if t >= LEN:
		get_tree().quit()
		return
	var me: Vector2 = map.party_world_pos("player")
	if t < 6.0:
		var k := t / 6.0
		map.focus(c0.lerp(c0 * 0.6 + me * 0.4, k * 0.3), z0 * lerpf(1.0, 1.35, k))
	else:
		var k := clampf((t - 6.0) / 5.0, 0.0, 1.0)
		k = k * k * (3.0 - 2.0 * k)
		var start := c0.lerp(c0 * 0.6 + me * 0.4, 0.3)
		var zk: float = exp(lerpf(log(z0 * 1.35), log(map.close_zoom(3.5 / map.MAP_SCALE)), k))
		map.focus(start.lerp(me, k), zk)
