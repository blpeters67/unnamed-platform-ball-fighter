class_name MqttWs
extends RefCounted
## Tiny MQTT 3.1.1 client over WebSocket (QoS 0 only), used to find the
## other player through a public broker. Call poll() every frame; received
## messages pile up in `inbox` as [topic, payload_bytes].

enum { DISCONNECTED, CONNECTING, CONNECTED }

var ws := WebSocketPeer.new()
var state := DISCONNECTED
var inbox: Array = []
var close_code := -1
var _buf := PackedByteArray()
var _client_id := ""
var _will: Array = []
var _keepalive := 30
var _ping_t := 0.0
var _next_id := 1
var _connect_sent := false

func connect_to(url: String, client_id: String, will_topic: String = "", will_payload := PackedByteArray(), will_retain := false) -> int:
	_client_id = client_id
	_will = [will_topic, will_payload, will_retain] if will_topic != "" else []
	ws = WebSocketPeer.new()
	ws.supported_protocols = PackedStringArray(["mqtt"])
	ws.outbound_buffer_size = 1 << 18
	ws.inbound_buffer_size = 1 << 18
	state = CONNECTING
	_connect_sent = false
	_buf.clear()
	return ws.connect_to_url(url, TLSOptions.client() if url.begins_with("wss") else null)

func poll(dt: float) -> void:
	if state == DISCONNECTED:
		return
	ws.poll()
	var rs := ws.get_ready_state()
	if rs == WebSocketPeer.STATE_CLOSED:
		close_code = ws.get_close_code()
		state = DISCONNECTED
		return
	if rs != WebSocketPeer.STATE_OPEN:
		return
	if not _connect_sent:
		_connect_sent = true
		_send_connect()
	while ws.get_available_packet_count() > 0:
		_buf.append_array(ws.get_packet())
	_parse()
	if state == CONNECTED:
		_ping_t += dt
		if _ping_t > _keepalive * 0.5:
			_ping_t = 0.0
			ws.send(PackedByteArray([0xC0, 0x00]))

func close() -> void:
	if state == CONNECTED:
		ws.send(PackedByteArray([0xE0, 0x00]))
	ws.close()
	state = DISCONNECTED

func subscribe(topic: String) -> void:
	var body := PackedByteArray()
	body.append(_next_id >> 8)
	body.append(_next_id & 0xFF)
	_next_id = (_next_id % 65535) + 1
	body.append_array(_str(topic))
	body.append(0)   # QoS 0
	_send_packet(0x82, body)

func publish(topic: String, payload: PackedByteArray, retain := false) -> void:
	if state != CONNECTED:
		return
	var body := _str(topic)
	body.append_array(payload)
	_send_packet(0x30 | (0x01 if retain else 0x00), body)

# ------------------------------------------------------------ internals
func _send_connect() -> void:
	var body := PackedByteArray()
	body.append_array(_str("MQTT"))
	body.append(4)   # protocol level 3.1.1
	var flags := 0x02   # clean session
	if _will.size() > 0:
		flags |= 0x04
		if _will[2]:
			flags |= 0x20
	body.append(flags)
	body.append(_keepalive >> 8)
	body.append(_keepalive & 0xFF)
	body.append_array(_str(_client_id))
	if _will.size() > 0:
		body.append_array(_str(_will[0]))
		var wp: PackedByteArray = _will[1]
		body.append(wp.size() >> 8)
		body.append(wp.size() & 0xFF)
		body.append_array(wp)
	_send_packet(0x10, body)

func _send_packet(header: int, body: PackedByteArray) -> void:
	var out := PackedByteArray([header])
	var n := body.size()
	while true:
		var b := n % 128
		n /= 128
		if n > 0:
			b |= 0x80
		out.append(b)
		if n == 0:
			break
	out.append_array(body)
	ws.send(out)

static func _str(s: String) -> PackedByteArray:
	var u := s.to_utf8_buffer()
	var out := PackedByteArray([u.size() >> 8, u.size() & 0xFF])
	out.append_array(u)
	return out

func _parse() -> void:
	while _buf.size() >= 2:
		var mult := 1
		var length := 0
		var i := 1
		var complete := false
		while i < _buf.size() and i <= 4:
			var b := _buf[i]
			length += (b & 0x7F) * mult
			mult *= 128
			i += 1
			if b & 0x80 == 0:
				complete = true
				break
		if not complete or _buf.size() < i + length:
			return
		var header := _buf[0]
		var body := _buf.slice(i, i + length)
		_buf = _buf.slice(i + length)
		_handle(header, body)

func _handle(header: int, body: PackedByteArray) -> void:
	match header >> 4:
		2:   # CONNACK
			if body.size() >= 2 and body[1] == 0:
				state = CONNECTED
			else:
				close_code = 4000 + (body[1] if body.size() >= 2 else 99)
				ws.close()
				state = DISCONNECTED
		3:   # PUBLISH
			var tl := (body[0] << 8) | body[1]
			var topic := body.slice(2, 2 + tl).get_string_from_utf8()
			var p := 2 + tl
			if (header >> 1) & 0x03 > 0:
				p += 2   # packet id (QoS > 0, not expected)
			inbox.append([topic, body.slice(p)])
		_:
			pass   # SUBACK, PINGRESP, ...
