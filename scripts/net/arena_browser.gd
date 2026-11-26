class_name ArenaBrowser
extends Node
## Live list of public arenas. Every public host keeps a retained message on
## unnamedballfighter/v1/arenas/<CODE>; subscribing to the wildcard returns
## all of them at once and then streams changes (an empty message = closed).

var mq := MqttWs.new()
var brokers: Array = NetSession.BROKERS
var broker_i := 0
var t := 0.0
var arenas := {}          # code -> {"name": String, "proto": String}
var status := "Looking for arenas..."
var ok := false
var subscribed := false

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--signal="):
			brokers = Array(a.substr(9).split(","))
	_connect()

func _connect() -> void:
	t = 0.0
	subscribed = false
	mq.connect_to(brokers[broker_i], "ubfbrowse%06d" % (randi() % 1000000))

func _process(dt: float) -> void:
	t += dt
	mq.poll(dt)
	if mq.state == MqttWs.DISCONNECTED or (mq.state == MqttWs.CONNECTING and t > 6.0):
		mq.close()
		broker_i += 1
		if broker_i >= brokers.size():
			broker_i = 0
			status = "Couldn't reach the arena list. Retrying..."
			ok = false
		_connect()
		return
	if mq.state == MqttWs.CONNECTED and not subscribed:
		subscribed = true
		mq.subscribe(NetSession.arena_topic("+"))
		ok = true
		status = ""
	for m in mq.inbox:
		var code: String = String(m[0]).get_file()
		var p: PackedByteArray = m[1]
		if p.size() == 0:
			arenas.erase(code)
			continue
		var info = JSON.parse_string(p.get_string_from_utf8())
		if info is Dictionary:
			arenas[code] = {"name": str(info.get("name", "?")).left(24), "proto": str(info.get("proto", ""))}
	mq.inbox.clear()

## Arenas sorted with joinable (same version) ones first.
func list() -> Array:
	var out := []
	for c in arenas:
		out.append({"code": c, "name": arenas[c].name, "ok": arenas[c].proto == NetSession.PROTO})
	out.sort_custom(func(a, b): return a.ok and not b.ok if a.ok != b.ok else a.name < b.name)
	return out

func _exit_tree() -> void:
	mq.close()
