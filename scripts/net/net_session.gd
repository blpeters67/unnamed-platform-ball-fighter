class_name NetSession
extends Node
## Room-code matchmaking. Both players connect to a public MQTT broker over a
## secure WebSocket and meet on a topic named after the room code. The host
## keeps a "room is open" message there; the joiner sends a WebRTC offer to
## the host through the broker, and after that the game talks peer to peer
## over two data channels: "game" (unreliable, unordered) for rollback inputs
## and "ctl" (reliable) for hello/leave. If no direct link opens (strict
## router, firewall), the game packets keep going through the broker instead.
## Nobody needs to open ports.

signal status_changed(text: String)
signal connected
signal failed(reason: String)

const PROTO := "ubf-net-5"   # bump when the sim or protocol changes
const TOPIC_ROOT := "unnamedballfighter/v1/"
const CODE_CHARS := "ACDEFHJKMNPRTUVWXY"
const CODE_LEN := 4
## Public brokers, tried in order. Both players walk the same list.
const BROKERS := ["wss://broker.emqx.io:8084/mqtt", "wss://broker.hivemq.com:8884/mqtt", "wss://test.mosquitto.org:8081/mqtt"]
const ICE := [{"urls": ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]},
	{"urls": ["stun:stun.cloudflare.com:3478"]}]
const RELAY_AFTER := 7.0

enum { IDLE, SIGNALING, CONNECTING, CONNECTED, FAILED, CLOSED }

var state := IDLE
var is_host := false
var code := ""
var my_id := ""
var peer_id := ""
var mq := MqttWs.new()
var broker_i := 0
var brokers: Array = BROKERS
var mq_t := 0.0          # time since the current broker attempt started
var subscribed := false
var room_seen := false
var room_wait := 0.0
var pc: WebRTCPeerConnection
var game_ch: WebRTCDataChannel
var ctl_ch: WebRTCDataChannel
var pending_cands: Array = []
var remote_desc_set := false
var t := 0.0
var last_recv := 0.0
var hello_sent := false
var got_hello := false
var ice_servers: Array = ICE
var rx: Array = []   # received game packets (PackedByteArray)
var relay := false
var relay_t := 0.0
var relay_send_n := 0
var force_relay := false
var drop_cands := false
var diag := {"broker": "", "offer": false, "answer": false, "c_out": 0, "c_in": 0}
var _log_file: FileAccess
var _last_pc_state := -1

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--signal="):
			brokers = Array(a.substr(9).split(","))
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

static func webrtc_available() -> bool:
	return ClassDB.class_exists("WebRTCLibPeerConnection")

func _topic(who: String) -> String:
	return TOPIC_ROOT + code + "/" + who

# ------------------------------------------------------------ public API
func host(room: String = "") -> void:
	is_host = true
	code = room if room != "" else random_code()
	my_id = "host"
	status_changed.emit("Setting up room...")
	_start()

func join(room: String) -> void:
	is_host = false
	code = clean_code(room)
	peer_id = "host"
	my_id = "j%06d" % (randi() % 1000000)
	status_changed.emit("Looking for room %s..." % code)
	_start()

func close() -> void:
	if state == CLOSED:
		return
	if peer_id != "" and peer_id != "host" or (not is_host and state == CONNECTED):
		_send_sig("BYE", {}, peer_id)
	if is_host:
		mq.publish(_topic("room"), PackedByteArray(), true)   # close the room
	if ctl_ch and ctl_ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		ctl_ch.put_packet(JSON.stringify({"t": "bye"}).to_utf8_buffer())
	if pc:
		pc.close()
	mq.poll(0.0)
	mq.close()
	state = CLOSED

func send_game(bytes: PackedByteArray) -> void:
	if relay:
		# Every packet repeats recent inputs, so 30 Hz is plenty through the
		# broker and keeps the load on the shared server down.
		relay_send_n += 1
		if relay_send_n % 2 == 0:
			mq.publish(_topic(peer_id + "/d"), bytes)
		return
	if game_ch and game_ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		game_ch.put_packet(bytes)

func take_packets() -> Array:
	var out := rx
	rx = []
	return out

func diag_text() -> String:
	var parts := []
	parts.append("server " + (diag.broker if diag.broker != "" else "none"))
	if not is_host:
		parts.append("room found" if room_seen else "room not found")
	parts.append("offer sent" if diag.offer else "no offer")
	parts.append("answer back" if diag.answer else "no answer")
	parts.append("candidates %d out / %d in" % [diag.c_out, diag.c_in])
	if pc:
		parts.append("link state %d" % pc.get_connection_state())
	if relay:
		parts.append("relay tried")
	return ", ".join(parts)

## Writes net-log-host/join.txt next to the game for diagnosing problems.
func log_line(m: String) -> void:
	print("[net] ", m)
	if _log_file == null:
		var dir := OS.get_executable_path().get_base_dir() if OS.has_feature("template") else ProjectSettings.globalize_path("user://")
		_log_file = FileAccess.open(dir.path_join("net-log-%s.txt" % ("host" if is_host else "join")), FileAccess.WRITE)
		if _log_file == null:
			_log_file = FileAccess.open("user://net-log.txt", FileAccess.WRITE)
		if _log_file:
			_log_file.store_line("Unnamed Ball Fighter net log  %s  %s  %s" % [Time.get_datetime_string_from_system(), PROTO, "host" if is_host else "join"])
	if _log_file:
		_log_file.store_line("%7.2f  %s" % [t, m])
		_log_file.flush()

# ------------------------------------------------------------ signaling
func _start() -> void:
	if not webrtc_available():
		_fail.call_deferred("Online play needs the file libwebrtc_native...dll in the same folder as the game. Unzip the whole zip, not just the .exe.")
		return
	state = SIGNALING
	broker_i = 0
	_connect_broker()

func _connect_broker() -> void:
	var url: String = brokers[broker_i]
	diag.broker = url.get_slice("/", 2).get_slice(":", 0)
	log_line("connecting to %s as %s (room %s)" % [url, my_id, code])
	mq_t = 0.0
	subscribed = false
	room_seen = false
	room_wait = 0.0
	var cid := "ubf%s%s%04x" % [code, my_id, randi() % 65536]
	var err: int
	if is_host:
		# If the host vanishes, the broker clears the "room open" flag itself.
		err = mq.connect_to(url, cid, _topic("room"), PackedByteArray(), true)
	else:
		err = mq.connect_to(url, cid)
	if err != OK:
		_next_broker("connect error %d" % err)

func _next_broker(why: String) -> void:
	log_line("server %s failed: %s" % [diag.broker, why])
	mq.close()
	broker_i += 1
	if broker_i < brokers.size():
		_connect_broker()
	else:
		_fail("Couldn't reach any matchmaking server (%s). Check your internet connection." % why)

func _send_sig(type: String, payload: Dictionary, dst: String) -> void:
	log_line("send %s to %s" % [type, dst])
	var msg := {"type": type, "payload": payload, "src": my_id}
	mq.publish(_topic(dst), JSON.stringify(msg).to_utf8_buffer())

func _fail(reason: String) -> void:
	if state == FAILED or state == CLOSED:
		return
	log_line("FAIL: " + reason)
	state = FAILED
	if pc:
		pc.close()
	if is_host:
		mq.publish(_topic("room"), PackedByteArray(), true)
	mq.close()
	failed.emit(reason)

func _process(dt: float) -> void:
	t += dt
	if state == IDLE or state == FAILED or state == CLOSED:
		return
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
		relay_t += dt
		if relay_t > 1.0:
			relay_t = 0.0
			_send_sig("RELAY", {"proto": PROTO}, peer_id)
	if state == CONNECTING and t > 30.0:
		_fail("Couldn't connect to your friend (%s). Try again, or try hosting from the other PC." % diag_text())
	if state == CONNECTED and t - last_recv > 5.0:
		_fail("Lost connection to your friend.")

func _poll_signal(dt: float) -> void:
	mq_t += dt
	var was := mq.state
	mq.poll(dt)
	if mq.state == MqttWs.DISCONNECTED:
		if state == SIGNALING and not subscribed:
			_next_broker("closed, code %d" % mq.close_code)
		elif state == SIGNALING or (state == CONNECTING and not is_host) or (relay and state == CONNECTED):
			log_line("server connection lost, code %d" % mq.close_code)
			_fail("Lost the matchmaking server (code %d, %s)." % [mq.close_code, diag_text()])
		return
	if mq.state == MqttWs.CONNECTING and mq_t > 6.0 and state == SIGNALING:
		_next_broker("timed out")
		return
	if mq.state == MqttWs.CONNECTED and not subscribed:
		subscribed = true
		log_line("server connected (was %d)" % was)
		mq.subscribe(_topic(my_id))
		mq.subscribe(_topic(my_id + "/d"))
		if is_host:
			# Claim the room only if no other host has it right now.
			mq.subscribe(_topic("room"))
			room_wait = 0.0
		else:
			mq.subscribe(_topic("room"))
	for m in mq.inbox:
		_on_mq(m[0], m[1])
	mq.inbox.clear()
	if subscribed and state == SIGNALING:
		room_wait += dt
		if is_host and room_wait > 1.2 and not room_seen and diag.offer == false and peer_id == "":
			# Nobody else holds this code: open the room.
			room_seen = true
			mq.publish(_topic("room"), JSON.stringify({"proto": PROTO}).to_utf8_buffer(), true)
			log_line("room open")
			status_changed.emit("Room ready")
		elif not is_host and room_wait > 5.0 and not room_seen:
			_fail("No room with code %s. Check the code with your friend, and make sure they're on the Host screen." % code)

func _on_mq(topic: String, payload: PackedByteArray) -> void:
	if topic == _topic(my_id + "/d"):
		if relay:
			rx.append(payload)
			last_recv = t
		return
	if topic == _topic("room"):
		if payload.size() == 0:
			return
		if is_host:
			if not room_seen and state == SIGNALING:
				# Someone else already hosts this code: pick another one.
				log_line("code %s taken, picking another" % code)
				code = random_code()
				mq.close()
				_connect_broker()
			return
		if not room_seen and state == SIGNALING:
			room_seen = true
			var info = JSON.parse_string(payload.get_string_from_utf8())
			if info is Dictionary and info.get("proto", "") != PROTO:
				_fail("Your friend has a different version of the game. Both of you need the newest build.")
				return
			log_line("room found")
			state = CONNECTING
			t = 0.0
			status_changed.emit("Connecting to room %s..." % code)
			if not force_relay:
				_make_pc()
				pc.create_offer()
		return
	var msg = JSON.parse_string(payload.get_string_from_utf8())
	if msg is Dictionary:
		_on_sig(msg)

func _on_sig(msg: Dictionary) -> void:
	var type: String = msg.get("type", "")
	var payload = msg.get("payload", {})
	var src: String = msg.get("src", "")
	if not (payload is Dictionary):
		return
	log_line("recv %s from %s" % [type, src])
	match type:
		"OFFER":
			if is_host and state == SIGNALING:
				if payload.get("proto", "") != PROTO:
					_send_sig("ANSWER", {"err": "version"}, src)
					status_changed.emit("A friend tried to join with a different game version.")
					return
				peer_id = src
				mq.publish(_topic("room"), PackedByteArray(), true)   # room is full now
				_make_pc()
				state = CONNECTING
				t = 0.0
				pc.set_remote_description("offer", payload.get("sdp", ""))
				remote_desc_set = true
				_flush_cands()
				status_changed.emit("Friend found, connecting...")
		"ANSWER":
			if not is_host:
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
			if src == peer_id and not drop_cands:
				diag.c_in += 1
				pending_cands.append(payload)
				_flush_cands()
		"RELAY":
			if not is_host or (peer_id != "" and src != peer_id):
				return
			if payload.get("proto", "") != PROTO:
				_send_sig("ANSWER", {"err": "version"}, src)
				return
			if peer_id == "":
				mq.publish(_topic("room"), PackedByteArray(), true)
			peer_id = src
			_send_sig("RELAY_OK", {}, src)
			if not relay:
				relay = true
				if pc:
					pc.close()
				if state != CONNECTED:
					_relay_connected()
		"RELAY_OK":
			if relay and state == CONNECTING and src == peer_id:
				_relay_connected()
		"BYE":
			if src == peer_id and state == CONNECTED:
				_fail("Your friend left.")

func _flush_cands() -> void:
	if not remote_desc_set or pc == null:
		return
	for c in pending_cands:
		pc.add_ice_candidate(c.get("mid", ""), int(c.get("idx", 0)), c.get("cand", ""))
	pending_cands.clear()

# ------------------------------------------------------------ WebRTC
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
		log_line("connected directly")
		status_changed.emit("Connected!")
		connected.emit()
	if game_ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		while game_ch.get_available_packet_count() > 0:
			rx.append(game_ch.get_packet())
			last_recv = t

func _start_relay() -> void:
	if relay:
		return
	relay = true
	relay_t = 1.0
	if pc:
		pc.close()
	log_line("starting relay")
	status_changed.emit("Direct link blocked, connecting through the server...")

func _relay_connected() -> void:
	state = CONNECTED
	last_recv = t
	log_line("connected through relay")
	status_changed.emit("Connected (through the server)!")
	connected.emit()
