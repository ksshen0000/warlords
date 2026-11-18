extends SceneTree
## Headless check: build every kind of player menu and make sure nothing errors.
## Run: godot --headless --path . -s tests/menu_test.gd

const PlayerMenu := preload("res://scripts/player_menu.gd")


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var m = PlayerMenu.new()
	root.add_child(m)
	await process_frame
	var fired := []
	m.action.connect(func(id, data): fired.append([id, data]))
	m.say.connect(func(h, t): fired.append(["say", h, t]))
	var market := {"grain": {"name": "粮食", "stock": 12, "price": 9.5, "carry": 3},
		"salt": {"name": "盐", "stock": 2, "price": 40.0, "carry": 0}}
	var settlement := {"type": "settlement", "id": "zhou0", "title": "建康", "kind": "town",
		"text": "城 · 周 · 守将：卫晞\n繁荣 80", "market": market, "cargo_cap": 60,
		"options": [{"id": "recruit", "label": "招募志愿兵", "enabled": true, "hint": ""},
			{"id": "trade", "label": "去市集交易", "enabled": true, "hint": ""},
			{"id": "talk", "label": "拜见卫晞", "enabled": true, "hint": "", "hero": "weixi"},
			{"id": "besiege", "label": "围攻", "enabled": false, "hint": "需要先为某国效力"},
			{"id": "leave", "label": "离开", "enabled": true, "hint": ""}]}
	m.open(settlement)
	await process_frame
	assert(m.visible and m.buttons.get_child_count() == 5)
	(m.buttons.get_child(2) as Button).pressed.emit()
	assert(fired[-1][0] == "talk" and fired[-1][1].hero == "weixi")
	m.trading = true
	m.open(settlement)
	await process_frame
	assert(m.trade_box.visible and m.trade_grid.get_child_count() == 7 * 3)
	var encounter := {"type": "encounter", "party": "bd3", "initiator": "them", "title": "山贼",
		"text": "【对方截住了你！】", "options": [{"id": "fight", "label": "迎战", "enabled": true, "hint": ""},
			{"id": "flee", "label": "设法脱身", "enabled": true, "hint": ""}]}
	m.open(encounter)
	await process_frame
	assert(not m.trade_box.visible and m.buttons.get_child_count() == 2)
	var talk := {"type": "talk", "hero": "weixi", "title": "与卫晞交谈", "text": "周皇帝",
		"options": [{"id": "back", "label": "告辞", "enabled": true, "hint": ""}],
		"chat": [["player", "你好"], ["lord", "足下远来，辛苦了。"]]}
	m.open(talk)
	await process_frame
	assert(m.chat_box.visible and m.chat_log.text.contains("足下"))
	m.chat_input.text = "最近边境太平吗？"
	m._send_chat()
	assert(fired[-1][0] == "say" and fired[-1][2] == "最近边境太平吗？")
	m.set_waiting(false)
	var create := {"type": "create", "title": "你的出身", "text": "你生在哪里？",
		"options": [{"id": "origin", "label": "江左（周）", "enabled": true, "hint": "江左水乡……", "choice": "zhou"},
			{"id": "origin", "label": "漠北（柔）", "enabled": true, "hint": "漠北草原……", "choice": "rou"}]}
	m.open(create)
	await process_frame
	assert(m.buttons.get_child_count() == 4)   # two buttons + two description labels
	(m.buttons.get_child(2) as Button).pressed.emit()
	assert(fired[-1][0] == "origin" and fired[-1][1].choice == "rou")
	m.open({"type": "notice", "title": "重获自由", "text": "你逃了出来", "options": [{"id": "ok", "label": "继续", "enabled": true, "hint": ""}]})
	await process_frame
	m.close()
	print("MENU_TEST_OK fired=%d" % fired.size())
	quit()
