extends Node
## HTTP client for the Python simulation server (python -m warlords.server).
## Requests are queued so player actions never collide with time steps;
## the (large, one-off) map download uses its own channel.

signal response(kind: String, data: Dictionary)
signal failed(kind: String, message: String)

var base_url := "http://127.0.0.1:8765"
var busy := false
var _http: HTTPRequest
var _map_http: HTTPRequest
var _kind := ""
var _queue: Array = []   # [kind, path, method, body]


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 300.0
	add_child(_http)
	_http.request_completed.connect(_on_done)
	_map_http = HTTPRequest.new()
	_map_http.timeout = 60.0
	add_child(_map_http)
	_map_http.request_completed.connect(_on_map_done)


func get_map() -> void:
	_map_http.cancel_request()
	_map_http.request(base_url + "/map")


func get_state() -> void:
	_enqueue("state", "/state", HTTPClient.METHOD_GET, {})


func step(hours: int) -> bool:
	# time steps are dropped (not queued) while anything else is in flight
	if busy or not _queue.is_empty():
		return false
	_enqueue("step", "/step", HTTPClient.METHOD_POST, {"hours": hours})
	return true


func reset(seed: int, tier: int) -> void:
	_queue.clear()
	_enqueue("reset", "/reset", HTTPClient.METHOD_POST, {"seed": seed, "tier": tier})


func set_tier(tier: int) -> void:
	_enqueue("config", "/config", HTTPClient.METHOD_POST, {"tier": tier})


func reload_rules() -> void:
	_enqueue("reload", "/reload", HTTPClient.METHOD_POST, {})


func move(target: Dictionary) -> void:
	_enqueue("move", "/player/move", HTTPClient.METHOD_POST, target)


func act(action: String, data: Dictionary = {}) -> void:
	var body := data.duplicate()
	body["action"] = action
	_enqueue("act", "/player/act", HTTPClient.METHOD_POST, body)


func talk(hero: String, text: String) -> void:
	_enqueue("talk", "/player/talk", HTTPClient.METHOD_POST, {"hero": hero, "text": text})


func pending() -> bool:
	return busy or not _queue.is_empty()


func _enqueue(kind: String, path: String, method: int, body: Dictionary) -> void:
	_queue.append([kind, path, method, body])
	_pump()


func _pump() -> void:
	if busy or _queue.is_empty():
		return
	var job: Array = _queue.pop_front()
	busy = true
	_kind = job[0]
	var headers := PackedStringArray(["Content-Type: application/json"])
	var payload := JSON.stringify(job[3]) if job[2] == HTTPClient.METHOD_POST else ""
	var err := _http.request(base_url + job[1], headers, job[2], payload)
	if err != OK:
		busy = false
		failed.emit.call_deferred(job[0], "请求失败（错误码 %d）" % err)
		_pump.call_deferred()


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
	_pump.call_deferred()


func _on_map_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data = _parse(result, code, body, "map")
	if data != null:
		response.emit.call_deferred("map", data)
