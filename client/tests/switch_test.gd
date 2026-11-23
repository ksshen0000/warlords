extends SceneTree
## Headless check of Warband-style weapon switching (Agent.switch_weapon): the wheel goes through the
## weapon slots in their order, both ways, skips the shield and kit that is no use now, and the switch
## takes a moment during which you can't strike or block.
## Run: godot --headless --path . -s tests/switch_test.gd

func _initialize() -> void:
	call_deferred("run")


func _agent(rules: BattleRules, spec: Dictionary, mounted: bool) -> Agent:
	var a := Agent.new()
	a.rules = rules
	a.troop = {"id": "t", "name": "t", "culture": "zhou", "tier": 3, "cls": "inf"}
	var l := rules.loadout("t", spec)
	a.melee = l.melee
	a.ranged = l.ranged
	a.ammo = int(l.ranged.get("ammo", 0))
	a.shield = l.shield
	a.weapon_order = (l.order as Array).duplicate()
	a.mounted = mounted
	a.horse_kind = "horse" if mounted else ""
	a.melee_idx = a._first_usable(0)
	a.using_ranged = false
	root.add_child(a)
	a.rig = AgentRig.new()
	a.add_child(a.rig)
	a.rig.build(a)
	return a


## Turn the wheel once and let the switch run its course; returns the slot now in hand.
func wheel(a: Agent, step: int) -> String:
	a.switch_weapon(step)
	if a.switch_t > 0.0:
		a.start_attack(Agent.Dir.RIGHT)
		if a.state != Agent.IDLE:
			print("  ✗ 换武器途中竟能出手")
			return "BAD"
		a._finish_switch()
		a.switch_t = 0.0
	return a.current_slot()


func run() -> void:
	var rules := BattleRules.new()
	rules.load_all()
	var ok := true
	# slots as laid out on the equipment screen: sword, bow, shield, spear
	var spec := {"melee": ["sword", "spear"], "ranged": "bow", "shield": "round", "order": ["m0", "r", "s", "m1"]}
	var a := _agent(rules, spec, false)
	var seen: Array = [a.current_slot()]
	for i in 4:
		seen.append(wheel(a, 1))
	print("步行，滚轮往下：", seen)
	ok = ok and seen == ["m0", "r", "m1", "m0", "r"]
	var back: Array = [a.current_slot()]
	for i in 3:
		back.append(wheel(a, -1))
	print("步行，滚轮往上：", back)
	ok = ok and back == ["r", "m0", "m1", "r"]
	# the shield: on the arm with the sword, on the back with the bow
	wheel(a, -1)
	print("拿刀时盾在左臂：", a.shield_up(), "；", "拿弓时盾在背上：", (func(): wheel(a, 1); return a.shield_on_back()).call())
	ok = ok and a.shield_on_back()
	# mounted, with a weapon that is no use on a horse: it is skipped
	var spec2 := {"melee": ["sword", "large_axe_test"], "ranged": "crossbow", "order": ["m0", "m1", "r"]}
	var b := _agent(rules, spec2, true)
	if b.melee.size() > 1:
		b.melee[1]["mount"] = false
	var mseen: Array = [b.current_slot()]
	for i in 3:
		mseen.append(wheel(b, 1))
	print("骑马（第二件马上用不了）：", mseen)
	ok = ok and not mseen.has("m1")
	print("SWITCH_TEST_" + ("OK" if ok else "FAIL"))
	quit(0 if ok else 1)
