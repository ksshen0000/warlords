extends SceneTree
## godot --headless --path client --script res://battle/tests/battle_features.gd

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)
		push_error(label)


func _run() -> void:
	_check(Battle.deployment_slots([1000, 15], 40) == [25, 15], "lopsided armies share one budget")
	_check(Battle.deployment_slots([1, 200], 300) == [1, 149], "oversized requests clamp and spare slots are reused")
	_check(Battle.deployment_slots([1, 1], 2) == [1, 1], "arena keeps two slots")
	_check(Battle.deployment_slots([150, 150], 120, [0, 5]) == [48, 72], "tactics affects the split")

	var battle := Battle.new()
	battle.embedded = true
	battle.preset_setup = {"battle_size": 4, "dismounted": true, "sides": [
		{"hero": {"name": "你", "player": true, "troop": "zhou_inf2"}, "troops": {"zhou_arc2": 4}},
		{"troops": {"yan_inf2": 5}}]}
	root.add_child(battle)
	battle.set_physics_process(false)
	battle.set_process(false)
	var player := battle.player
	var archer: Agent = battle.agents[1]
	var target: Agent = battle.agents[2]
	player.position = battle.field.ground(Vector3.ZERO)
	player.heading = 0.0
	player.intent_yaw = 0.0
	target.position = battle.field.ground(Vector3(0, 0, -1.25))
	battle._rebuild_grid()

	battle.command(0, ["arc"], "hold_fire")
	BattleAI.update(archer, battle, 1.0 / 60.0)
	_check(not archer.using_ranged and archer.ammo > 0, "hold fire draws melee and saves ammo")
	battle.command(0, ["arc"], "fire")
	BattleAI.update(archer, battle, 1.0 / 60.0)
	_check(archer.using_ranged, "free fire lets the archer use their bow again")

	target._set_state(Agent.BLOCK, 1.0)
	player.start_kick()
	for i in 12:
		player.step(1.0 / 60.0)
	_check(target.state == Agent.STUN and battle.stats.get("kicks", 0) == 1, "kick interrupts the guard")
	var ground_y := player.position.y
	player.start_jump()
	for i in 12:
		player.step(1.0 / 60.0)
	_check(player.jumping and player.position.y > ground_y + 0.4, "jump lifts the collision body")
	for i in 50:
		player.step(1.0 / 60.0)
	_check(not player.jumping and is_equal_approx(player.position.y, ground_y), "jump returns to ground")

	var controller := battle.ctrl
	var key := InputEventKey.new()
	key.keycode = KEY_R
	key.pressed = true
	controller._unhandled_input(key)
	_check(controller.first_person and not player.rig.visible, "first-person camera hides the local model")
	controller._unhandled_input(key)
	_check(not controller.first_person and player.rig.visible, "third-person camera restores the local model")

	battle.rules.cfg.battle.reinforce_at = 0.6
	var other: Agent = battle.agents[3]
	other.routed = true
	battle._reinforce()
	_check(battle.agents.size() == 4, "fleeing troops still occupy deployment slots")
	battle._retire_routed(other)
	battle._reinforce()
	_check(battle.agents.size() == 5, "an exited soldier frees an actual reinforcement slot")
	player.hp -= 10.0
	var health := player.hp
	target.die(true)
	battle.agents[4].die(true)
	battle._headless = false    # exercise the manual intermission in a headless test
	battle._check_end()
	_check(battle.phase_pending and battle.phase == 1, "a player-led phase waits for input")
	key.keycode = KEY_ENTER
	controller._unhandled_input(key)
	battle._headless = true
	_check(battle.phase == 2 and not battle.over, "a fresh phase deploys remaining reserves")
	_check(player.hp == health and player.position == player.spawn_origin, "survivors return to their lines with wounds")
	var alive := battle.agents.filter(func(a): return a.alive())
	_check(alive.size() == 4 and target.outcome == "wounded", "phase respects the budget and preserves casualty records")

	battle.free()
	_check_siege_start()
	if failures.is_empty():
		print("BATTLE_FEATURES_OK")
	quit(0 if failures.is_empty() else 1)


func _check_siege_start() -> void:
	var battle := Battle.new()
	battle.embedded = true
	battle.preset_setup = {"player_side": 1, "dismounted": true,
		"siege": {"defender": 1, "walls": 2, "ladders": 3}, "sides": [
			{"troops": {"yan_inf2": 5}},
			{"hero": {"name": "你", "player": true, "troop": "zhou_cav3"}, "troops": {"zhou_arc2": 4}}]}
	root.add_child(battle)
	_check(battle.player.side == 1 and battle.field.level(battle.player.position) == 1,
		"the defending player spawns on the wall")
	_check(battle.orders[1]["arc"].get("wall", false), "the defending player's archers hold the wall at spawn")
	battle.command(1, ["arc"], "follow")
	_check(not battle.orders[1]["arc"].get("wall", false), "manual movement orders override the default wall formation")
	battle.free()
