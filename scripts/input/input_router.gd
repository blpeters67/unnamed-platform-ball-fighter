extends Node
## Turns keyboards and controllers into per-player input bitmasks.
## Players join by pressing any button. Controllers can be plugged in or
## pulled at any time and nothing needs configuring.

signal device_joined(slot: int, device: String)
signal device_left(slot: int, device: String)
signal toast(text: String)

const MAX_SLOTS := 2
const DEADZONE := 0.45
const C_DEADZONE := 0.6
const TRIGGER := 0.35

var slots: Array[String] = ["", ""]   # device id per player slot ("" = empty)
var _flick_age := {}                  # device -> frames since a stick flick
var _prev_mag := {}                   # device -> stick magnitude history
var _smash_latch := {}
var _prev_raw := {}

const KB1 := {
	"left": [KEY_A], "right": [KEY_D], "up": [KEY_W], "down": [KEY_S],
	"attack": [KEY_K, KEY_ENTER], "special": [KEY_J], "jump": [KEY_SPACE], "ball": [KEY_SHIFT, KEY_SEMICOLON],
	"shield": [KEY_L], "grab": [KEY_U], "burst": [KEY_O], "smash": [KEY_H],
	"start": [KEY_ESCAPE], "back": [KEY_F2],
}
const KB2 := {
	"left": [KEY_LEFT], "right": [KEY_RIGHT], "up": [KEY_UP], "down": [KEY_DOWN],
	"attack": [KEY_KP_1, KEY_COMMA], "special": [KEY_KP_2, KEY_PERIOD], "jump": [KEY_KP_0],
	"ball": [KEY_KP_3, KEY_SLASH], "shield": [KEY_KP_ENTER], "grab": [KEY_KP_4, KEY_M],
	"burst": [KEY_KP_6, KEY_N], "smash": [KEY_KP_5, KEY_B], "start": [KEY_KP_ADD, KEY_BACKSPACE], "back": [KEY_KP_SUBTRACT],
}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Input.joy_connection_changed.connect(_on_joy_changed)

func _on_joy_changed(device: int, connected: bool) -> void:
	var id := "joy%d" % device
	var nm := Input.get_joy_name(device)
	if connected:
		toast.emit("Controller connected: %s" % (nm if nm != "" else "Gamepad"))
	else:
		var s := slots.find(id)
		if s >= 0:
			toast.emit("P%d controller disconnected. Plug it back in to keep playing." % (s + 1))
		else:
			toast.emit("Controller disconnected")

func all_devices() -> Array[String]:
	var out: Array[String] = ["kb1", "kb2"]
	for j in Input.get_connected_joypads():
		out.append("joy%d" % j)
	return out

## Call once per frame. Assigns unassigned devices to empty slots when they
## press a button. Returns the slot a device joined, or -1.
func poll_joins(allow_join: bool = true) -> void:
	for d in all_devices():
		var raw := _raw(d)
		var prev: int = _prev_raw.get(d, 0)
		_prev_raw[d] = raw
		if not allow_join or slots.has(d):
			continue
		var newly := raw & ~prev
		if newly & (Inp.ATTACK | Inp.SPECIAL | Inp.JUMP | Inp.START | Inp.BALL):
			var s := slots.find("")
			if s >= 0:
				slots[s] = d
				device_joined.emit(s, d)
				toast.emit("P%d joined (%s)" % [s + 1, device_label(d)])

func leave(slot: int) -> void:
	var d := slots[slot]
	if d != "":
		slots[slot] = ""
		device_left.emit(slot, d)

func device_label(d: String) -> String:
	if d == "kb1":
		return "Keyboard"
	if d == "kb2":
		return "Keyboard (arrows)"
	if d.begins_with("joy"):
		var nm := Input.get_joy_name(int(d.substr(3)))
		return nm if nm != "" else "Controller"
	return "?"

func is_pad(d: String) -> bool:
	return d.begins_with("joy")

func bits_for_slot(slot: int) -> int:
	var d := slots[slot]
	if d == "":
		return 0
	return bits(d)

var _xhist := {}
var _dash_prev := {}  # device -> direction of the last reported dash
var _kb_prev_dir := {}

## Full input for a device, with smash-flick and dash detection layered on top.
func bits(d: String) -> int:
	var raw := _raw(d)
	if d == "kb1" or d == "kb2":
		# Keyboard: tapping a direction dashes (like a full stick flick).
		var pd: int = _kb_prev_dir.get(d, 0)
		var dirs := raw & (Inp.LEFT | Inp.RIGHT)
		if dirs & ~pd:
			raw |= Inp.DASH
		_kb_prev_dir[d] = dirs
	if d.begins_with("joy"):
		var j := int(d.substr(3))
		var lx := Input.get_joy_axis(j, JOY_AXIS_LEFT_X)
		var dpad_x := Input.is_joy_button_pressed(j, JOY_BUTTON_DPAD_LEFT) or Input.is_joy_button_pressed(j, JOY_BUTTON_DPAD_RIGHT)
		var xh: Array = _xhist.get(d, [0.0, 0.0, 0.0])
		if dpad_x:
			lx = -1.0 if Input.is_joy_button_pressed(j, JOY_BUTTON_DPAD_LEFT) else 1.0
		# Dash: stick pushed hard sideways quickly (from near-center or the other side)
		if absf(lx) > 0.8:
			for old in xh:
				if absf(old) < 0.35 or signf(old) == -signf(lx):
					raw |= Inp.DASH
					break
		elif absf(lx) > DEADZONE and absf(lx) < 0.75:
			raw |= Inp.WALK_SLOW
		# Only report a dash once per flick (same direction), so holding the
		# stick doesn't re-dash; flicking the other way always does (dash dance).
		var ds := signf(lx) if absf(lx) > 0.8 else 0.0
		if raw & Inp.DASH:
			if _dash_prev.get(d, 0.0) == ds:
				raw &= ~Inp.DASH
			_dash_prev[d] = ds
		elif ds == 0.0:
			_dash_prev[d] = 0.0
		xh.push_front(lx)
		xh.resize(3)
		_xhist[d] = xh
		var v := Vector2(Input.get_joy_axis(j, JOY_AXIS_LEFT_X), Input.get_joy_axis(j, JOY_AXIS_LEFT_Y))
		var mag := v.length()
		var hist: Array = _prev_mag.get(d, [0.0, 0.0, 0.0])
		var age: int = _flick_age.get(d, 99)
		if mag > 0.85 and (hist[0] < 0.3 or hist[1] < 0.3 or hist[2] < 0.3):
			age = 0
		else:
			age = mini(age + 1, 99)
		_flick_age[d] = age
		hist.push_front(mag)
		hist.resize(3)
		_prev_mag[d] = hist
		var latch: bool = _smash_latch.get(d, false)
		if raw & Inp.ATTACK:
			if not latch and age <= 4 and not (_prev_bits_attack(d)):
				latch = true
		else:
			latch = false
		_smash_latch[d] = latch
		_prev_attack[d] = (raw & Inp.ATTACK) != 0
		if latch:
			raw |= Inp.SMASH
	return raw

var _prev_attack := {}
func _prev_bits_attack(d: String) -> bool:
	return _prev_attack.get(d, false)

func _keys(map: Dictionary, k: String) -> bool:
	for key in map[k]:
		if Input.is_physical_key_pressed(key):
			return true
	return false

func _raw(d: String) -> int:
	var b := 0
	if d == "kb1" or d == "kb2":
		var m: Dictionary = KB1 if d == "kb1" else KB2
		# The arrow keys belong to the main keyboard player unless a second
		# keyboard player has joined (from the numpad). Steam's desktop mode
		# turns a controller's D-pad into arrow keys, so arrows must never
		# make someone join on their own.
		var kb2_in := slots.has("kb2")
		if d == "kb1":
			if _keys(m, "left") or (not kb2_in and Input.is_physical_key_pressed(KEY_LEFT)): b |= Inp.LEFT
			if _keys(m, "right") or (not kb2_in and Input.is_physical_key_pressed(KEY_RIGHT)): b |= Inp.RIGHT
			if _keys(m, "up") or (not kb2_in and Input.is_physical_key_pressed(KEY_UP)): b |= Inp.UP
			if _keys(m, "down") or (not kb2_in and Input.is_physical_key_pressed(KEY_DOWN)): b |= Inp.DOWN
		elif kb2_in:
			if _keys(m, "left"): b |= Inp.LEFT
			if _keys(m, "right"): b |= Inp.RIGHT
			if _keys(m, "up"): b |= Inp.UP
			if _keys(m, "down"): b |= Inp.DOWN
		if _keys(m, "attack"): b |= Inp.ATTACK
		if _keys(m, "special"): b |= Inp.SPECIAL
		if _keys(m, "jump"): b |= Inp.JUMP
		if _keys(m, "ball"): b |= Inp.BALL
		if _keys(m, "shield"): b |= Inp.SHIELD
		if _keys(m, "grab"): b |= Inp.GRAB
		if _keys(m, "burst"): b |= Inp.BURST
		if _keys(m, "smash"): b |= Inp.SMASH
		if _keys(m, "start"): b |= Inp.START
		if _keys(m, "back"): b |= Inp.BACK
		if (b & Inp.LEFT) and (b & Inp.RIGHT): b &= ~(Inp.LEFT | Inp.RIGHT)
		if (b & Inp.UP) and (b & Inp.DOWN): b &= ~(Inp.UP | Inp.DOWN)
		return b
	if not d.begins_with("joy"):
		return 0
	var j := int(d.substr(3))
	if not Input.get_connected_joypads().has(j):
		return 0
	var lx := Input.get_joy_axis(j, JOY_AXIS_LEFT_X)
	var ly := Input.get_joy_axis(j, JOY_AXIS_LEFT_Y)
	if lx < -DEADZONE or Input.is_joy_button_pressed(j, JOY_BUTTON_DPAD_LEFT): b |= Inp.LEFT
	if lx > DEADZONE or Input.is_joy_button_pressed(j, JOY_BUTTON_DPAD_RIGHT): b |= Inp.RIGHT
	if ly < -DEADZONE or Input.is_joy_button_pressed(j, JOY_BUTTON_DPAD_UP): b |= Inp.UP
	if ly > DEADZONE or Input.is_joy_button_pressed(j, JOY_BUTTON_DPAD_DOWN): b |= Inp.DOWN
	# Keep diagonals from triggering both tilts: only the dominant axis counts
	# for attacks, but both stay set for movement/DI.
	var rx := Input.get_joy_axis(j, JOY_AXIS_RIGHT_X)
	var ry := Input.get_joy_axis(j, JOY_AXIS_RIGHT_Y)
	if absf(rx) > C_DEADZONE or absf(ry) > C_DEADZONE:
		if absf(rx) >= absf(ry):
			b |= Inp.C_LEFT if rx < 0 else Inp.C_RIGHT
		else:
			b |= Inp.C_UP if ry < 0 else Inp.C_DOWN
	if Input.is_joy_button_pressed(j, JOY_BUTTON_B): b |= Inp.ATTACK
	if Input.is_joy_button_pressed(j, JOY_BUTTON_A): b |= Inp.SPECIAL
	if Input.is_joy_button_pressed(j, JOY_BUTTON_X) or Input.is_joy_button_pressed(j, JOY_BUTTON_Y): b |= Inp.JUMP
	if Input.is_joy_button_pressed(j, JOY_BUTTON_RIGHT_SHOULDER): b |= Inp.SHIELD
	if Input.is_joy_button_pressed(j, JOY_BUTTON_LEFT_SHOULDER): b |= Inp.BURST
	if Input.get_joy_axis(j, JOY_AXIS_TRIGGER_RIGHT) > TRIGGER: b |= Inp.BALL
	if Input.get_joy_axis(j, JOY_AXIS_TRIGGER_LEFT) > TRIGGER: b |= Inp.GRAB
	if Input.is_joy_button_pressed(j, JOY_BUTTON_START): b |= Inp.START
	if Input.is_joy_button_pressed(j, JOY_BUTTON_BACK): b |= Inp.BACK
	return b


func rumble(slot: int, weak: float, strong: float, dur: float) -> void:
	if slot < 0 or slot >= MAX_SLOTS:
		return
	var d := slots[slot]
	if d.begins_with("joy"):
		Input.start_joy_vibration(int(d.substr(3)), clampf(weak, 0, 1), clampf(strong, 0, 1), dur)
