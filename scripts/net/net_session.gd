class_name NetSession
extends Node
## Room-code matchmaking: the host registers its room code on a PeerJS
## signaling server, the joiner looks it up, and the two exchange WebRTC
## offers through it. After that the game talks peer to peer over two data
## channels: "game" (unreliable, unordered) for rollback inputs and "ctl"
## (reliable) for hello/leave messages. Nobody needs to open ports.

signal status_changed(text: String)
signal connected
signal failed(reason: String)

const PROTO := "ubf-net-4"   # bump when the sim changes so old builds can't desync
const ID_PREFIX := "ubf-game-v1-"
const CODE_CHARS := "ACDEFHJKMNPRTUVWXY"
const CODE_LEN := 4
const DEFAULT_SIGNAL := "wss://0.peerjs.com/peerjs?key=peerjs"
const ICE := [{"urls": ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]},
	{"urls": ["stun:stun.cloudflare.com:3478"]}]

enum { IDLE, SIGNALING, CONNECTING, CONNECTED, FAILED, CLOSED }

var state := IDLE
var is_host := false
var code := ""
var my_id := ""
var peer_id := ""
var ws := WebSocketPeer.new()
var ws_open := false
var pc: WebRTCPeerConnection
var game_ch: WebRTCDataChannel
var ctl_ch: WebRTCDataChannel
var pending_cands: Array = []
var remote_desc_set := false
var hb_t := 0.0
var t := 0.0
var last_recv := 0.0
var hello_sent := false
var got_hello := false
var signal_url := DEFAULT_SIGNAL
var ice_servers: Array = ICE
var rx: Array = []   # received game packets (PackedByteArray)
# Relay fallback: when a direct peer-to-peer link can't be made (firewall,
# strict router), game packets go through the signaling server instead.
const RELAY_AFTER := 7.0
var relay := false
var relay_t := 0.0
var relay_send_n := 0
var force_relay := false
var drop_cands := false
var diag := {"offer": false, "answer": false, "c_out": 0, "c_in": 0}

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--signal="):
			signal_url = a.substr(9)
		elif a == "--no-stun":
			ice_servers = []
		elif a == "--force-relay":
			force_relay = true
		elif a == "--drop-cands":
			drop_cands = true   # dev: simulate a blocked direct link

static func random_code() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var s := ""
	for i in CODE_LEN:
		s += CODE_CHARS[rng.randi() % CODE_CHARS.length()]
	return s

static func clean_code(s: String) -> String:
	var out := ""
	for ch in s.strip_edges().to_upper():
		if CODE_CHARS.contains(ch):
			out += ch
	return out

func host(room: String = "") -> void:
	is_host = true
	code = room if room != "" else random_code()
	my_id = ID_PREFIX + code
	_open_signal()
	status_changed.emit("Setting up room...")

func join(room: String) -> void:
	is_host = false
	code = clean_code(room)
	peer_id = ID_PREFIX + code
	my_id = ID_PREFIX + code + "-" + str(randi() % 1000000)
	_open_signal()
	status_changed.emit("Looking for room %s..." % code)

func close() -> void:
	if relay and peer_id != "":
		_send_sig("CANDIDATE", {"relay": "bye"}, peer_id)
		ws.poll()
	if ctl_ch and ctl_ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		ctl_ch.put_packet(JSON.stringify({"t": "bye"}).to_utf8_buffer())
	if pc:
		pc.close()
	ws.close()
	state = CLOSED

static func webrtc_available() -> bool:
	return ClassDB.class_exists("WebRTCLibPeerConnection")

func _open_signal() -> void:
	state = SIGNALING
	if not webrtc_available():
		state = IDLE
		_fail.call_deferred("Online play needs the file libwebrtc_native...dll in the same folder as the game. Unzip the whole zip, not just the .exe.")
		return
	log_line("connecting to signaling as %s" % my_id)
	var url := signal_url + ("&" if signal_url.contains("?") else "?") + "id=%s&token=%d&version=1.5.4" % [my_id, randi()]
	var tls := TLSOptions.client()
	var err := ws.connect_to_url(url, tls if url.begins_with("wss") else null)
	if err != OK:
		_fail("Couldn't reach the matchmaking server.")

var _log_file: FileAccess
var _last_ws_state := -1
var _last_pc_state := -1

## Writes net-log.txt next to the game so connection problems can be diagnosed.
func log_line(m: String) -> void:
	print("[net] ", m)
	if _log_file == null:
		var dir := OS.get_executable_path().get_base_dir() if OS.has_feature("template") else ProjectSettings.globalize_path("user://")
		_log_file = FileAccess.open(dir.path_join("net-log-%s.txt" % ("host" if is_host else "join")), FileAccess.WRITE)
		if _log_file == null:
			_log_file = FileAccess.open("user://net-log.txt", FileAccess.WRITE)
		if _log_file:
			_log_file.store_line("Unnamed Ball Fighter net log  %s  proto %s  %s" % [Time.get_datetime_string_from_system(), PROTO, "host" if is_host else "join"])
	if _log_file:
		_log_file.store_line("%7.2f  %s" % [t, m])
		_log_file.flush()

func _fail(reason: String) -> void:
	if state == FAILED or state == CLOSED:
		return
	log_line("FAIL: " + reason)
	state = FAILED
	if pc:
		pc.close()
	ws.close()
	failed.emit(reason)

func _send_sig(type: String, payload: Dictionary, dst: String) -> void:
	if payload.get("relay", "") != "d":
		log_line("send %s %s to %s (ws %d)" % [type, str(payload.get("relay", "")), dst, ws.get_ready_state()])
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"type": type, "payload": payload, "dst": dst}))

func _process(dt: float) -> void:
	t += dt
	_poll_signal(dt)
	if pc:
		pc.poll()
		_poll_channels()
		if state == CONNECTING or state == CONNECTED:
			var cs := pc.get_connection_state()
			if cs != _last_pc_state:
				_last_pc_state = cs
				log_line("direct link state %d" % cs)
			if cs == WebRTCPeerConnection.STATE_FAILED and state == CONNECTING and not is_host:
				_start_relay()
			elif cs == WebRTCPeerConnection.STATE_CLOSED and state == CONNECTED and not relay:
				_fail("Your friend left.")
	if state == CONNECTING and not is_host and not relay and (t > RELAY_AFTER or force_relay):
		_start_relay()
	if relay and state == CONNECTING and not is_host:
		relay_t += get_process_delta_time()
		if relay_t > 1.0:
			relay_t = 0.0
			_send_sig("CANDIDATE", {"relay": "start", "proto": PROTO}, peer_id)
	if state == CONNECTING and t > 30.0:
		_fail("Couldn't connect to your friend (%s). Try again, or try hosting from the other PC." % diag_text())
	if state == CONNECTED and t - last_recv > 5.0:
		_fail("Lost connection to your friend.")

func _poll_signal(dt: float) -> void:
	if state == CLOSED:
		return
	ws.poll()
	var rs := ws.get_ready_state()
	if rs != _last_ws_state:
		_last_ws_state = rs
		log_line("signal socket state %d%s" % [rs, (" close code %d reason '%s'" % [ws.get_close_code(), ws.get_close_reason()]) if rs == WebSocketPeer.STATE_CLOSED else ""])
	if rs == WebSocketPeer.STATE_CLOSED:
		if state == SIGNALING or (state == CONNECTING and not is_host):
			_fail("Lost the matchmaking server (code %d, step: %s)." % [ws.get_close_code(), diag_text()])
		elif relay and state == CONNECTED:
			_fail("Lost connection to the matchmaking server.")
		return
	if rs != WebSocketPeer.STATE_OPEN:
		return
	hb_t += dt
	if hb_t > 5.0:
		hb_t = 0.0
		ws.send_text(JSON.stringify({"type": "HEARTBEAT"}))
	while ws.get_available_packet_count() > 0:
		var msg = JSON.parse_string(ws.get_packet().get_string_from_utf8())
		if msg is Dictionary:
			_on_sig(msg)

func _on_sig(msg: Dictionary) -> void:
	var type: String = msg.get("type", "")
	var payload = msg.get("payload", {})
	if not (payload is Dictionary and payload.get("relay", "") == "d"):
		log_line("recv %s from %s %s" % [type, str(msg.get("src", "")), JSON.stringify(payload).left(160) if type in ["ERROR", "ID-TAKEN", "EXPIRE"] else ""])
	match type:
		"OPEN":
			if is_host:
				status_changed.emit("Room ready")
			else:
				state = CONNECTING
				t = 0.0
				if not force_relay:
					_make_pc()
					pc.create_offer()
				status_changed.emit("Connecting to room %s..." % code)
		"ID-TAKEN":
			if is_host:
				# Someone already has this code; pick another one.
				ws.close()
				ws = WebSocketPeer.new()
				host()
			else:
				ws.close()
				ws = WebSocketPeer.new()
				join(code)
		"EXPIRE":
			if not is_host:
				_fail("No room with code %s. Check the code with your friend." % code)
		"ERROR":
			_fail("Matchmaking server error: %s" % str(payload.get("msg", "")) if payload is Dictionary else "Matchmaking server error.")
		"OFFER":
			if is_host and state == SIGNALING and payload is Dictionary:
				if payload.get("proto", "") != PROTO:
					_send_sig("ANSWER", {"err": "version", "proto": PROTO}, msg.get("src", ""))
					status_changed.emit("A friend tried to join with a different game version.")
					return
				peer_id = msg.get("src", "")
				_make_pc()
				state = CONNECTING
				t = 0.0
				pc.set_remote_description("offer", payload.get("sdp", ""))
				remote_desc_set = true
				_flush_cands()
				status_changed.emit("Friend found, connecting...")
		"ANSWER":
			if not is_host and payload is Dictionary:
				if payload.get("err", "") == "version":
					_fail("Your friend has a different version of the game. Both of you need the newest build.")
					return
				diag.answer = true
				if pc == null:
					return
				pc.set_remote_description("answer", payload.get("sdp", ""))
				remote_desc_set = true
				_flush_cands()
		"CANDIDATE":
			if payload is Dictionary and payload.has("relay"):
				_on_relay(payload, msg.get("src", ""))
			elif payload is Dictionary and msg.get("src", "") == peer_id and not drop_cands:
				diag.c_in += 1
				pending_cands.append(payload)
				_flush_cands()

func _flush_cands() -> void:
	if not remote_desc_set or pc == null:
		return
	for c in pending_cands:
		pc.add_ice_candidate(c.get("mid", ""), int(c.get("idx", 0)), c.get("cand", ""))
	pending_cands.clear()

func _make_pc() -> void:
	pc = WebRTCPeerConnection.new()
	var err := pc.initialize({"iceServers": ice_servers})
	if err != OK:
		_fail("Online play isn't available in this build (WebRTC missing).")
		return
	pc.session_description_created.connect(func(type: String, sdp: String):
		pc.set_local_description(type, sdp)
		diag.offer = true
		_send_sig("OFFER" if type == "offer" else "ANSWER", {"sdp": sdp, "proto": PROTO}, peer_id))
	pc.ice_candidate_created.connect(func(mid: String, idx: int, cand: String):
		diag.c_out += 1
		_send_sig("CANDIDATE", {"mid": mid, "idx": idx, "cand": cand}, peer_id))
	game_ch = pc.create_data_channel("game", {"negotiated": true, "id": 1, "ordered": false, "maxRetransmits": 0})
	ctl_ch = pc.create_data_channel("ctl", {"negotiated": true, "id": 2})

func _poll_channels() -> void:
	if ctl_ch == null or game_ch == null or relay:
		return
	if ctl_ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		if not hello_sent:
			hello_sent = true
			ctl_ch.put_packet(JSON.stringify({"t": "hello", "proto": PROTO}).to_utf8_buffer())
		while ctl_ch.get_available_packet_count() > 0:
			var m = JSON.parse_string(ctl_ch.get_packet().get_string_from_utf8())
			last_recv = t
			if m is Dictionary:
				if m.get("t") == "hello":
					got_hello = true
				elif m.get("t") == "bye":
					_fail("Your friend left.")
					return
	if state == CONNECTING and got_hello and game_ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		state = CONNECTED
		last_recv = t
		# The signaling socket stays open so the relay can take over if needed.
		status_changed.emit("Connected!")
		connected.emit()
	if game_ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		while game_ch.get_available_packet_count() > 0:
			rx.append(game_ch.get_packet())
			last_recv = t

func send_game(bytes: PackedByteArray) -> void:
	if relay:
		# Every packet repeats recent inputs, so 30 Hz is plenty here and
		# keeps the load on the shared server down.
		relay_send_n += 1
		if relay_send_n % 2 == 0:
			_send_sig("CANDIDATE", {"relay": "d", "b": Marshalls.raw_to_base64(bytes)}, peer_id)
		return
	if game_ch and game_ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		game_ch.put_packet(bytes)

func take_packets() -> Array:
	var out := rx
	rx = []
	return out

func _start_relay() -> void:
	if relay:
		return
	relay = true
	relay_t = 1.0
	if pc:
		pc.close()
	status_changed.emit("Direct link blocked, connecting through the server...")

func _on_relay(payload: Dictionary, src: String) -> void:
	var kind: String = payload.get("relay", "")
	match kind:
		"start":
			if not is_host or (state != SIGNALING and state != CONNECTING and state != CONNECTED):
				return
			if peer_id != "" and src != peer_id:
				return
			if payload.get("proto", "") != PROTO:
				_send_sig("ANSWER", {"err": "version", "proto": PROTO}, src)
				return
			peer_id = src
			_send_sig("CANDIDATE", {"relay": "ok"}, src)
			if not relay:
				relay = true
				if pc:
					pc.close()
				if state != CONNECTED:
					_relay_connected()
		"ok":
			if relay and state == CONNECTING and src == peer_id:
				_relay_connected()
		"d":
			if relay and src == peer_id:
				rx.append(Marshalls.base64_to_raw(payload.get("b", "")))
				last_recv = t
		"bye":
			if src == peer_id and state == CONNECTED:
				_fail("Your friend left.")

func _relay_connected() -> void:
	state = CONNECTED
	last_recv = t
	status_changed.emit("Connected (through the server)!")
	connected.emit()

func diag_text() -> String:
	var parts := []
	parts.append("offer sent" if diag.offer else "no offer")
	parts.append("answer back" if diag.answer else "no answer")
	parts.append("candidates %d out / %d in" % [diag.c_out, diag.c_in])
	if pc:
		parts.append("link state %d" % pc.get_connection_state())
	if relay:
		parts.append("relay tried")
	return ", ".join(parts)
