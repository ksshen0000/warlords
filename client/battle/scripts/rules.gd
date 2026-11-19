class_name BattleRules
extends RefCounted
## Loads server/rules/battle.toml (combat feel, weapons, loadouts) and server/rules/units.toml
## (troop names / tiers / classes, same ids as the campaign server) for the 3D battle.

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


## Equipment of a troop: {melee: [weapon dicts], ranged: weapon dict or {}, shield: dict or {},
## armor: int, horse: "" / "horse" / "barded"}
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
	var out := {"melee": [], "ranged": {}, "shield": {}, "armor": int(spec.get("armor", 0)), "horse": str(spec.get("horse", ""))}
	for wid in spec.get("melee", ["club"]):
		var w := weapon(wid)
		if not w.is_empty():
			out.melee.append(w)
	if out.melee.is_empty():
		out.melee.append(weapon("club"))
	if spec.has("ranged"):
		out.ranged = weapon(spec.ranged)
	if spec.has("shield"):
		var s: Dictionary = cfg.get("shields", {}).get(spec.shield, {})
		if not s.is_empty():
			out.shield = s.duplicate()
			out.shield["id"] = spec.shield
	return out


func troop_name(tid: String) -> String:
	return str(troops.get(tid, {}).get("name", tid))
