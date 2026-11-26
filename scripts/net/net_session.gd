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

const PROTO := "ubf-net-3"   # bump when the sim changes so old builds can't desync
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

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--signal="):
			signal_url = a.substr(9)
		elif a == "--no-stun":
			ice_servers = []

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
	if ctl_ch and ctl_ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		ctl_ch.put_packet(JSON.stringify({"t": "bye"}).to_utf8_buffer())
	if pc:
		pc.close()
	ws.close()
	state = CLOSED

func _open_signal() -> void:
	state = SIGNALING
	var url := signal_url + ("&" if signal_url.contains("?") else "?") + "id=%s&token=%d&version=1.5.4" % [my_id, randi()]
	var tls := TLSOptions.client()
	var err := ws.connect_to_url(url, tls if url.begins_with("wss") else null)
	if err != OK:
		_fail("Couldn't reach the matchmaking server.")

func _fail(reason: String) -> void:
	if state == FAILED or state == CLOSED:
		return
	state = FAILED
	if pc:
		pc.close()
	ws.close()
	failed.emit(reason)

func _send_sig(type: String, payload: Dictionary, dst: String) -> void:
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
			if cs == WebRTCPeerConnection.STATE_FAILED:
				_fail("Couldn't connect directly to your friend's PC. A strict router or firewall may be blocking it.")
			elif cs == WebRTCPeerConnection.STATE_CLOSED and state == CONNECTED:
				_fail("Your friend left.")
	if state == CONNECTING and t > 25.0:
		_fail("Connecting took too long. Try again, or try hosting from the other PC.")
	if state == CONNECTED and t - last_recv > 5.0:
		_fail("Lost connection to your friend.")

func _poll_signal(dt: float) -> void:
	if state == CLOSED:
		return
	ws.poll()
	var rs := ws.get_ready_state()
	if rs == WebSocketPeer.STATE_CLOSED:
		if state == SIGNALING:
			_fail("Couldn't reach the matchmaking server. Check your internet connection.")
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
	match type:
		"OPEN":
			if is_host:
				status_changed.emit("Room ready")
			else:
				_make_pc()
				state = CONNECTING
				t = 0.0
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
				pc.set_remote_description("answer", payload.get("sdp", ""))
				remote_desc_set = true
				_flush_cands()
		"CANDIDATE":
			if payload is Dictionary and msg.get("src", "") == peer_id:
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
		_send_sig("OFFER" if type == "offer" else "ANSWER", {"sdp": sdp, "proto": PROTO}, peer_id))
	pc.ice_candidate_created.connect(func(mid: String, idx: int, cand: String):
		_send_sig("CANDIDATE", {"mid": mid, "idx": idx, "cand": cand}, peer_id))
	game_ch = pc.create_data_channel("game", {"negotiated": true, "id": 1, "ordered": false, "maxRetransmits": 0})
	ctl_ch = pc.create_data_channel("ctl", {"negotiated": true, "id": 2})

func _poll_channels() -> void:
	if ctl_ch == null or game_ch == null:
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
		ws.close()   # the signaling server isn't needed any more
		status_changed.emit("Connected!")
		connected.emit()
	if game_ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		while game_ch.get_available_packet_count() > 0:
			rx.append(game_ch.get_packet())
			last_recv = t

func send_game(bytes: PackedByteArray) -> void:
	if game_ch and game_ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		game_ch.put_packet(bytes)

func take_packets() -> Array:
	var out := rx
	rx = []
	return out
