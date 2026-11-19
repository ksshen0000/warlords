class_name Toml
extends RefCounted
## Minimal TOML reader for the project's rule documents (server/rules/*.toml):
## [table] / [a.b] headers, key = value, strings, numbers, booleans, (multi-line) arrays,
## inline tables and # comments. Not a full TOML implementation (no dates, no [[arrays of tables]]
## beyond appending dictionaries, no multi-line strings).

var _s := ""
var _i := 0


static func load_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("toml: cannot open %s" % path)
		return {}
	var t := Toml.new()
	return t.parse(f.get_as_text())


func parse(text: String) -> Dictionary:
	_s = text
	_i = 0
	var root := {}
	var cur := root
	while true:
		_skip_ws_lines()
		if _i >= _s.length():
			break
		var c := _s[_i]
		if c == "[":
			var arr := _s.substr(_i, 2) == "[["
			_i += 2 if arr else 1
			var path := _read_key_path("]")
			_i += 2 if arr else 1
			cur = root
			for k in path.size():
				var key: String = path[k]
				var last := k == path.size() - 1
				if last and arr:
					if not cur.has(key):
						cur[key] = []
					var d := {}
					cur[key].append(d)
					cur = d
				else:
					if not cur.has(key):
						cur[key] = {}
					var nxt = cur[key]
					if nxt is Array:
						nxt = nxt[nxt.size() - 1]
					cur = nxt
		else:
			var path := _read_key_path("=")
			_i += 1
			_skip_inline_ws()
			var v = _value()
			var tgt := cur
			for k in path.size() - 1:
				if not tgt.has(path[k]):
					tgt[path[k]] = {}
				tgt = tgt[path[k]]
			tgt[path[path.size() - 1]] = v
		_skip_to_eol()
	return root


func _skip_inline_ws() -> void:
	while _i < _s.length() and (_s[_i] == " " or _s[_i] == "\t"):
		_i += 1


func _skip_to_eol() -> void:
	while _i < _s.length() and _s[_i] != "\n":
		_i += 1


func _skip_ws_lines() -> void:
	while _i < _s.length():
		var c := _s[_i]
		if c == " " or c == "\t" or c == "\n" or c == "\r":
			_i += 1
		elif c == "#":
			_skip_to_eol()
		else:
			break


func _read_key_path(stop: String) -> Array:
	var out: Array = []
	var cur := ""
	while _i < _s.length() and _s[_i] != stop:
		var c := _s[_i]
		if c == "\"":
			cur += _string()
			continue
		if c == ".":
			out.append(cur.strip_edges())
			cur = ""
		else:
			cur += c
		_i += 1
	out.append(cur.strip_edges())
	return out


func _string() -> String:
	_i += 1
	var out := ""
	while _i < _s.length() and _s[_i] != "\"":
		if _s[_i] == "\\" and _i + 1 < _s.length():
			_i += 1
			var e := _s[_i]
			out += {"n": "\n", "t": "\t", "\"": "\"", "\\": "\\"}.get(e, e)
		else:
			out += _s[_i]
		_i += 1
	_i += 1
	return out


func _value():
	_skip_inline_ws()
	var c := _s[_i]
	if c == "\"":
		return _string()
	if c == "[":
		_i += 1
		var arr: Array = []
		while true:
			_skip_ws_lines()
			if _s[_i] == "]":
				_i += 1
				break
			arr.append(_value())
			_skip_ws_lines()
			if _s[_i] == ",":
				_i += 1
		return arr
	if c == "{":
		_i += 1
		var d := {}
		while true:
			_skip_inline_ws()
			if _s[_i] == "}":
				_i += 1
				break
			var path := _read_key_path("=")
			_i += 1
			var v = _value()
			var tgt := d
			for k in path.size() - 1:
				if not tgt.has(path[k]):
					tgt[path[k]] = {}
				tgt = tgt[path[k]]
			tgt[path[path.size() - 1]] = v
			_skip_inline_ws()
			if _s[_i] == ",":
				_i += 1
		return d
	var tok := ""
	while _i < _s.length() and not (_s[_i] in [",", "]", "}", "\n", "\r", "#"]):
		tok += _s[_i]
		_i += 1
	tok = tok.strip_edges()
	if tok == "true":
		return true
	if tok == "false":
		return false
	tok = tok.replace("_", "")
	if tok.is_valid_int():
		return int(tok)
	if tok.is_valid_float():
		return float(tok)
	return tok
