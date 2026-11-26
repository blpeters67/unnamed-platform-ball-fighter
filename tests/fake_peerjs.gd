extends SceneTree
## Minimal local stand-in for the PeerJS signaling server, for testing
## netplay between two game instances on one machine:
##   godot --headless --script tests/fake_peerjs.gd   (listens on ws://127.0.0.1:9010)

var server := TCPServer.new()
var pending: Array = []   # WebSocketPeers mid-handshake
var peers := {}           # id -> WebSocketPeer

func _init() -> void:
	var err := server.listen(9010, "127.0.0.1")
	print("fake peerjs listening: ", err == OK)

func _process(_dt: float) -> bool:
	while server.is_connection_available():
		var ws := WebSocketPeer.new()
		ws.accept_stream(server.take_connection())
		pending.append(ws)
	for ws in pending.duplicate():
		ws.poll()
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			pending.erase(ws)
			var url: String = ws.get_requested_url()
			var id := ""
			for part in url.split("?")[-1].split("&"):
				if part.begins_with("id="):
					id = part.substr(3)
			if peers.has(id):
				ws.send_text(JSON.stringify({"type": "ID-TAKEN", "payload": {"msg": "ID is taken"}}))
				ws.close()
			else:
				peers[id] = ws
				ws.send_text(JSON.stringify({"type": "OPEN"}))
				print("open ", id)
		elif ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			pending.erase(ws)
	for id in peers.keys():
		var ws: WebSocketPeer = peers[id]
		ws.poll()
		if ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			peers.erase(id)
			continue
		while ws.get_available_packet_count() > 0:
			var m = JSON.parse_string(ws.get_packet().get_string_from_utf8())
			if not (m is Dictionary) or not m.has("dst"):
				continue
			m["src"] = id
			if peers.has(m.dst):
				peers[m.dst].send_text(JSON.stringify(m))
			else:
				ws.send_text(JSON.stringify({"type": "EXPIRE", "src": m.dst}))
	return false
