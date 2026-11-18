extends SceneTree
## godot --headless --path client --script res://battle/tests/toml_dump.gd -- <file.toml> <out.json>
func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var d := Toml.load_file(a[0])
	var f := FileAccess.open(a[1], FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()
	quit()
