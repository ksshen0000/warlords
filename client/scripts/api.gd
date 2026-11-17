extends Node
## HTTP client for the Python simulation server (python -m warlords.server).
## Two independent channels so the (large, one-off) map download never blocks stepping.

signal response(kind: String, data: Dictionary)
signal failed(kind: String, message: String)

var base_url := "http://127.0.0.1:8765"
var busy := false
var _http: HTTPRequest
var _map_http: HTTPRequest
var _kind := ""


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 900.0  # LLM-driven steps can take a while
	add_child(_http)
	_http.request_completed.connect(_on_done)
	_map_http = HTTPRequest.new()
	_map_http.timeout = 60.0
	add_child(_map_http)
	_map_http.request_completed.connect(_on_map_done)


func get_map() -> void:
	_map_http.cancel_request()
	_map_http.request(base_url + "/map")


func get_state() -> bool:
	return _send("state", "/state", HTTPClient.METHOD_GET, {})


func step(hours: int) -> bool:
	return _send("step", "/step", HTTPClient.METHOD_POST, {"hours": hours})


func reset(seed: int, brain: String) -> bool:
	return _send("reset", "/reset", HTTPClient.METHOD_POST, {"seed": seed, "brain": brain})


func reload_rules() -> bool:
	return _send("reload", "/reload", HTTPClient.METHOD_POST, {})


func _send(kind: String, path: String, method: int, body: Dictionary) -> bool:
	if busy:
		return false
	busy = true
	_kind = kind
	var headers := PackedStringArray(["Content-Type: application/json"])
	var payload := JSON.stringify(body) if method == HTTPClient.METHOD_POST else ""
	var err := _http.request(base_url + path, headers, method, payload)
	if err != OK:
		busy = false
		failed.emit.call_deferred(kind, "请求失败（错误码 %d）" % err)
		return false
	return true


func _parse(result: int, code: int, body: PackedByteArray, kind: String) -> Variant:
	if result != HTTPRequest.RESULT_SUCCESS:
		failed.emit.call_deferred(kind, "无法连接模拟服务器")
		return null
	var data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		failed.emit.call_deferred(kind, "服务器响应格式错误")
		return null
	if code != 200:
		failed.emit.call_deferred(kind, str(data.get("error", "HTTP %d" % code)))
		return null
	return data


func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	busy = false
	var kind := _kind
	var data = _parse(result, code, body, kind)
	if data != null:
		response.emit.call_deferred(kind, data)


func _on_map_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data = _parse(result, code, body, "map")
	if data != null:
		response.emit.call_deferred("map", data)
