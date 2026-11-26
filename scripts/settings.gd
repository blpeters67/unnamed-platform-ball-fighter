extends Node
## Player settings saved to user://settings.cfg: name, display, rumble and
## button bindings. Loaded before InputRouter (autoload order).

const PATH := "user://settings.cfg"

## Remappable actions, in the order the Controls screen lists them.
const ACTIONS := ["attack", "special", "jump", "ball", "shield", "grab", "burst", "smash", "start", "back"]
const KB_MOVE := ["left", "right", "up", "down"]
const LABELS := {"attack": "Attack", "special": "Special", "jump": "Jump", "ball": "Throw / recall ball",
	"shield": "Shield (tap = parry)", "grab": "Grab", "burst": "Burst", "smash": "Smash modifier",
	"start": "Pause", "back": "CPU / sandbag toggle", "left": "Left", "right": "Right", "up": "Up", "down": "Down"}

const KB1_DEFAULT := {
	"left": [KEY_A], "right": [KEY_D], "up": [KEY_W], "down": [KEY_S],
	"attack": [KEY_K, KEY_ENTER], "special": [KEY_J], "jump": [KEY_SPACE], "ball": [KEY_SHIFT, KEY_SEMICOLON],
	"shield": [KEY_L], "grab": [KEY_U], "burst": [KEY_O], "smash": [KEY_H],
	"start": [KEY_ESCAPE], "back": [KEY_F2],
}
const KB2_DEFAULT := {
	"left": [KEY_LEFT], "right": [KEY_RIGHT], "up": [KEY_UP], "down": [KEY_DOWN],
	"attack": [KEY_KP_1, KEY_COMMA], "special": [KEY_KP_2, KEY_PERIOD], "jump": [KEY_KP_0],
	"ball": [KEY_KP_3, KEY_SLASH], "shield": [KEY_KP_ENTER], "grab": [KEY_KP_4, KEY_M],
	"burst": [KEY_KP_6, KEY_N], "smash": [KEY_KP_5, KEY_B], "start": [KEY_KP_ADD, KEY_BACKSPACE], "back": [KEY_KP_SUBTRACT],
}
## Controller bindings: ints are buttons, "axis:N" are triggers.
const PAD_DEFAULT := {
	"attack": [JOY_BUTTON_B], "special": [JOY_BUTTON_A], "jump": [JOY_BUTTON_X, JOY_BUTTON_Y],
	"ball": ["axis:%d" % JOY_AXIS_TRIGGER_RIGHT], "shield": [JOY_BUTTON_RIGHT_SHOULDER],
	"grab": ["axis:%d" % JOY_AXIS_TRIGGER_LEFT], "burst": [JOY_BUTTON_LEFT_SHOULDER], "smash": [],
	"start": [JOY_BUTTON_START], "back": [JOY_BUTTON_BACK],
}

var player_name := ""
var fullscreen := false
var rumble := true
var kb1: Dictionary = KB1_DEFAULT.duplicate(true)
var kb2: Dictionary = KB2_DEFAULT.duplicate(true)
var pad: Dictionary = PAD_DEFAULT.duplicate(true)

func _ready() -> void:
	var c := ConfigFile.new()
	if c.load(PATH) == OK:
		player_name = c.get_value("player", "name", "")
		fullscreen = c.get_value("display", "fullscreen", false)
		rumble = c.get_value("player", "rumble", true)
		kb1 = _merge(KB1_DEFAULT, c.get_value("controls", "kb1", {}))
		kb2 = _merge(KB2_DEFAULT, c.get_value("controls", "kb2", {}))
		pad = _merge(PAD_DEFAULT, c.get_value("controls", "pad", {}))
	if player_name == "":
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		player_name = ["Courier", "Hooker", "Juggler", "Comboist", "Baller", "Spinner"][rng.randi() % 6] + str(rng.randi_range(10, 99))
		save()
	apply_display()

func _merge(def: Dictionary, saved) -> Dictionary:
	var out := def.duplicate(true)
	if saved is Dictionary:
		for k in saved:
			if out.has(k) and saved[k] is Array:
				out[k] = saved[k]
	return out

func save() -> void:
	var c := ConfigFile.new()
	c.set_value("player", "name", player_name)
	c.set_value("player", "rumble", rumble)
	c.set_value("display", "fullscreen", fullscreen)
	c.set_value("controls", "kb1", kb1)
	c.set_value("controls", "kb2", kb2)
	c.set_value("controls", "pad", pad)
	c.save(PATH)

func apply_display() -> void:
	if DisplayServer.get_name() == "headless":
		return
	get_window().mode = Window.MODE_FULLSCREEN if fullscreen else Window.MODE_WINDOWED

func map_for(device: String) -> Dictionary:
	match device:
		"kb1": return kb1
		"kb2": return kb2
		_: return pad

func reset(device: String) -> void:
	match device:
		"kb1": kb1 = KB1_DEFAULT.duplicate(true)
		"kb2": kb2 = KB2_DEFAULT.duplicate(true)
		_: pad = PAD_DEFAULT.duplicate(true)
	save()

## Human-readable name of one binding.
static func binding_name(b, is_pad: bool) -> String:
	if b is String and b.begins_with("axis:"):
		var ax := int(b.substr(5))
		return {JOY_AXIS_TRIGGER_LEFT: "LT", JOY_AXIS_TRIGGER_RIGHT: "RT"}.get(ax, "Axis %d" % ax)
	if b is int and is_pad:
		return {JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
			JOY_BUTTON_BACK: "Back", JOY_BUTTON_GUIDE: "Guide", JOY_BUTTON_START: "Start",
			JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3", JOY_BUTTON_LEFT_SHOULDER: "LB",
			JOY_BUTTON_RIGHT_SHOULDER: "RB", JOY_BUTTON_DPAD_UP: "D-pad up", JOY_BUTTON_DPAD_DOWN: "D-pad down",
			JOY_BUTTON_DPAD_LEFT: "D-pad left", JOY_BUTTON_DPAD_RIGHT: "D-pad right",
			JOY_BUTTON_MISC1: "Share", JOY_BUTTON_PADDLE1: "Paddle 1", JOY_BUTTON_PADDLE2: "Paddle 2",
			JOY_BUTTON_PADDLE3: "Paddle 3", JOY_BUTTON_PADDLE4: "Paddle 4", JOY_BUTTON_TOUCHPAD: "Touchpad"}.get(b, "Button %d" % b)
	if b is int:
		return OS.get_keycode_string(b)
	return "?"

static func bindings_text(list: Array, is_pad: bool) -> String:
	if list.is_empty():
		return "(none)"
	var names := []
	for b in list:
		names.append(binding_name(b, is_pad))
	return " / ".join(names)
