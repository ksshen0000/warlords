class_name BattleRules
extends RefCounted
## Loads server/rules/battle.toml (combat feel, weapons, loadouts) and server/rules/units.toml
## (troop names / tiers / classes, same ids as the campaign server) for the 3D battle.

const DEFAULT_BATTLE_SIZE := 120
const MIN_BATTLE_SIZE := 40
const MAX_BATTLE_SIZE := 150

## Movement numbers are constant for a scene. Keep the per-tick reads typed.
class Movement:
	var foot_run: float
	var foot_walk: float
	var armor_slow: float
	var foot_accel: float
	var foot_turn: float
	var backward: float
	var horse_speed: float
	var horse_turn: float
	var horse_accel: float
	var canter: float
	var ladder_speed: float

	func _init(rules: BattleRules) -> void:
		foot_run = rules.num("human", "run", 4.4)
		foot_walk = rules.num("human", "walk", 1.6)
		armor_slow = rules.num("human", "armor_slow", 0.012)
		foot_accel = rules.num("human", "accel", 14.0)
		foot_turn = rules.num("human", "turn", 7.0)
		backward = rules.num("human", "backward", 0.6)
		horse_speed = rules.num("horse", "speed", 10.5)
		horse_turn = rules.num("horse", "turn", 2.2)
		horse_accel = rules.num("horse", "accel", 4.5)
		canter = rules.num("horse", "canter", 5.0)
		ladder_speed = rules.num("siege", "ladder_speed", 0.45)

var movement: Movement
var cfg: Dictionary = {}          # battle.toml
var troops: Dictionary = {}       # troop id -> {id, name, culture, tier, cls}
var culture_names: Dictionary = {}


static func rules_dir() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--rules="):
			return a.substr(8)
	return ProjectSettings.globalize_path("res://").path_join("../server/rules").simplify_path()


func load_all(dir: String = "") -> bool:
	if dir == "":
		dir = rules_dir()
	cfg = Toml.load_file(dir.path_join("battle.toml"))
	var units := Toml.load_file(dir.path_join("units.toml"))
	if cfg.is_empty() or units.is_empty():
		return false
	movement = Movement.new(self)
	# same troop ids as server/warlords/data.py
	for c in units.get("cultures", {}):
		var v: Dictionary = units.cultures[c]
		culture_names[c] = v.get("name", c)
		_troop("%s_t1" % c, v.recruit, c, 1, "inf")
		var inf: Array = v.infantry
		var arc: Array = v.archers
		var cav: Array = v.cavalry
		_troop("%s_inf2" % c, inf[0], c, 2, "inf")
		_troop("%s_inf3" % c, inf[1], c, 3, "inf")
		_troop("%s_inf4" % c, inf[2], c, 4, "inf")
		_troop("%s_arc2" % c, arc[0], c, 2, "arc")
		_troop("%s_arc3" % c, arc[1], c, 3, "arc")
		_troop("%s_arc4" % c, arc[2], c, 4, "arc")
		_troop("%s_cav3" % c, cav[0], c, 3, "cav")
		_troop("%s_cav4" % c, cav[1], c, 4, "cav")
	for tid in units.get("troops", {}):
		var t: Dictionary = units.troops[tid]
		_troop(tid, t.name, t.culture, int(t.tier), t.cls)
	return true


func _troop(tid: String, n: String, c: String, tier: int, cls: String) -> void:
	troops[tid] = {"id": tid, "name": n, "culture": c, "tier": tier, "cls": cls}


func sec(name: String) -> Dictionary:
	return cfg.get(name, {})


func num(section: String, key: String, def: float = 0.0) -> float:
	var s = cfg.get(section)
	if s == null:
		return def
	return float(s.get(key, def))


func weapon(wid: String) -> Dictionary:
	var w: Dictionary = cfg.get("weapons", {}).get(wid, {})
	if w.is_empty():
		return {}
	var d := w.duplicate()
	d["id"] = wid
	return d


## A weapon / shield entry of a loadout: an id in battle.toml, or (the player's items, rules/items.toml)
## {base: id, name, …overrides} — the base's numbers with the item's own on top.
func _resolve(entry, table: String) -> Dictionary:
	var base_id: String = entry if entry is String else str(entry.get("base", ""))
	var b: Dictionary = cfg.get(table, {}).get(base_id, {})
	if b.is_empty():
		return {}
	var d := b.duplicate()
	if entry is Dictionary:
		for k in entry:
			if k != "base":
				d[k] = entry[k]
	d["id"] = base_id                       # the model / sounds go by the base weapon
	return d


## Equipment of a troop: {melee: [weapon dicts], ranged: weapon dict or {}, shield: dict or {},
## armor: int (body), head_armor: int, horse: "" / "horse" / "barded", horse_hp / horse_speed / horse_armor,
## look: {head, body} (gear tier for the model; troops use their tier)}
func loadout(tid: String, override: Dictionary = {}) -> Dictionary:
	var lo: Dictionary = cfg.get("loadout", {})
	var spec: Dictionary = {}
	if not override.is_empty():
		spec = override
	elif lo.get("troops", {}).has(tid):
		spec = lo.troops[tid]
	else:
		var t: Dictionary = troops.get(tid, {"culture": "", "tier": 1, "cls": "inf"})
		var key := "%s%d" % [t.cls, int(t.tier)]
		var cult: Dictionary = lo.get(t.culture, {})
		if cult.has(key):
			spec = cult[key]
		else:
			var dflt: Dictionary = lo.get("default", {})
			# nearest defined tier of that class
			for dt in [0, -1, 1, -2, 2, -3, 3]:
				var k2 := "%s%d" % [t.cls, int(t.tier) + dt]
				if cult.has(k2):
					spec = cult[k2]
					break
				if dflt.has(k2):
					spec = dflt[k2]
					break
	var armor := int(spec.get("armor", 0))
	var out := {"melee": [], "ranged": {}, "shield": {}, "armor": armor, "head_armor": int(spec.get("head_armor", armor)),
		"horse": str(spec.get("horse", "")), "look": spec.get("look", {}), "char": spec.get("char", {})}
	for k in ["horse_hp", "horse_speed", "horse_armor"]:
		if spec.has(k):
			out[k] = float(spec[k])
	for wid in spec.get("melee", ["club"]):
		var w := _resolve(wid, "weapons")
		if not w.is_empty():
			out.melee.append(w)
	if out.melee.is_empty():
		out.melee.append(weapon("club"))
	if spec.has("ranged"):
		out.ranged = _resolve(spec.ranged, "weapons")
	if spec.has("shield"):
		out.shield = _resolve(spec.shield, "shields")
	# the weapon slots in order ("m0", "r", "s"…): the player's from his equipment screen; troops: melee, then ranged
	var order: Array = spec.get("order", [])
	if order.is_empty():
		for i in out.melee.size():
			order.append("m%d" % i)
		if not out.ranged.is_empty():
			order.append("r")
		if not out.shield.is_empty():
			order.append("s")
	out["order"] = order
	return out


func troop_name(tid: String) -> String:
	return str(troops.get(tid, {}).get("name", tid))
