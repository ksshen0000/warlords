extends SceneTree
## Fixed simulation workload with no server, API or wall-clock frame pacing.
## godot --headless --path client --script res://battle/tests/benchmark.gd -- --size=150
## godot --fixed-fps 60 --path client --script res://battle/tests/benchmark.gd -- --terrain=forest --ticks=720


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var size := BattleRules.MAX_BATTLE_SIZE
	var ticks := 1800
	var siege := false
	var terrain := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--size="):
			size = clampi(int(arg.substr(7)), 2, BattleRules.MAX_BATTLE_SIZE)
		elif arg.begins_with("--ticks="):
			ticks = maxi(1, int(arg.substr(8)))
		elif arg == "--siege":
			siege = true
		elif arg.begins_with("--terrain="):
			terrain = arg.substr(10)
	var setup: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://battle/sample_setup.json"))
	setup["battle_size"] = size
	if not terrain.is_empty():
		setup["terrain"] = terrain
	if siege:
		setup["siege"] = {"defender": 1, "walls": 2, "ladders": 4}
		setup["dismounted"] = true
	for side in setup.sides:
		for tid in side.troops:
			side.troops[tid] *= 4
	var battle := Battle.new()
	battle.embedded = true
	battle.auto = true
	battle.preset_setup = setup
	var rendered := DisplayServer.get_name() != "headless"
	if rendered:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	root.add_child(battle)
	battle.set_physics_process(false)
	battle.set_process(rendered)
	var samples := PackedFloat64Array()
	var frame_samples := PackedFloat64Array()
	var previous_frame := 0
	var total := 0.0
	for tick in ticks:
		if battle.over:
			break
		if rendered:
			await process_frame
			var now := Time.get_ticks_usec()
			if tick >= 45:
				frame_samples.append((now - previous_frame) / 1000.0)
			previous_frame = now
		var start := Time.get_ticks_usec()
		battle._physics_process(1.0 / 60.0)
		var ms := (Time.get_ticks_usec() - start) / 1000.0
		samples.append(ms)
		total += ms
	samples.sort()
	var measured := samples.size()
	print("BENCH %s size=%d ticks=%d mean=%.3fms p95=%.3fms max=%.3fms ai=%.3fms step=%.3fms overlap=%.3fms" % [
		"siege" if siege else "field", size, measured, total / measured, samples[mini(measured - 1, int(measured * 0.95))], samples[-1],
		battle.prof.ai / measured / 1000.0, battle.prof.step / measured / 1000.0, battle.prof.overlap / measured / 1000.0])
	print("COUNTERS ", JSON.stringify(battle.stats))
	if not frame_samples.is_empty():
		frame_samples.sort()
		var frames := frame_samples.size()
		print("RENDER %s frames=%d p50=%.3fms p95=%.3fms" % [
			setup["terrain"], frames, frame_samples[frames / 2], frame_samples[mini(frames - 1, int(frames * 0.95))]])
	battle.free()
	quit()
