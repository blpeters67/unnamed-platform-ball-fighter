extends Control
## All the menus outside a match: main menu, online arenas (public lobbies
## anyone can browse and join), private rooms by code, local play with
## character and stage select, training, settings and control remapping.

signal play_local(training: bool)
signal play_online(net: NetSession, slot: int)
signal quit_game

enum { MAIN, ARENAS, PRIVATE, HOST, JOIN, SETTINGS, CONTROLS, CSS, SSS, NAME }

var font_ui: Font = load("res://assets/fonts/InterDisplay-ExtraBold.otf")
var font_big: Font = load("res://assets/fonts/InterDisplay-BlackItalic.otf")
var screen := MAIN
var sel := 0
var sels := {}            # remembered cursor per screen
var net: NetSession
var browser: ArenaBrowser
var status := ""
var status_bad := false
var code_in := ["", "", "", ""]
var cur := 0
var t := 0.0
var notice := ""          # shown on the main screen (e.g. why the last match ended)
var hosting_public := false
var training := false
# Controls screen
var ctl_dev := 0          # 0 keyboard P1, 1 keyboard P2, 2 controller
var listening := false
var listen_t := 0.0
var name_edit := ""

const MAIN_ITEMS := ["Online Arenas", "Private Match", "Local Play", "Training", "Settings", "Quit"]
const MAIN_HINTS := ["Browse public arenas or host your own. Anyone can join.",
	"Play a friend with a 4-letter room code. Not listed publicly.",
	"Fight the CPU, or plug in a second controller for couch versus.",
	"Practice combos on a sandbag or a CPU (Back / F2 switches).",
	"Your name, controls, fullscreen and rumble.", ""]
const PRIVATE_ITEMS := ["Host a private room", "Join with a code", "Back"]
const CTL_DEVS := ["KEYBOARD (P1)", "KEYBOARD (P2 / arrows)", "CONTROLLER"]
const CTL_DEV_IDS := ["kb1", "kb2", "pad"]
const CHARS := [["JUNO", "the Courier", true], ["???", "", false], ["???", "", false], ["???", "", false]]
const STAGES := [["HALO TERRACE", true], ["???", false], ["???", false], ["???", false]]

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _go(s: int) -> void:
	sels[screen] = sel
	screen = s
	sel = sels.get(s, 0)
	if s != ARENAS and browser:
		browser.queue_free()
		browser = null
	if s == ARENAS and browser == null:
		browser = ArenaBrowser.new()
		add_child(browser)

func _process(dt: float) -> void:
	t += dt
	size = get_viewport_rect().size
	if listening:
		listen_t += dt
		if listen_t > 6.0:
			listening = false
		InputRouter.menu_pressed()   # keep edge detection current
		queue_redraw()
		return
	var p := InputRouter.menu_pressed(screen == JOIN or screen == NAME)
	match screen:
		MAIN: _list_input(p, MAIN_ITEMS.size(), _main_pick, func(): pass)
		PRIVATE: _list_input(p, PRIVATE_ITEMS.size(), _private_pick, func(): _go(MAIN))
		ARENAS: _arenas_input(p)
		HOST: _host_input(p)
		JOIN: _join_input(p)
		SETTINGS: _list_input(p, 5, _settings_pick, func(): _go(MAIN))
		CONTROLS: _controls_input(p)
		CSS: _grid_input(p, CHARS.size(), _css_pick, func(): _go(MAIN))
		SSS: _grid_input(p, STAGES.size(), _sss_pick, func(): _go(CSS))
		NAME: _name_input(p)
	queue_redraw()

func _list_input(p: int, n: int, pick: Callable, back: Callable) -> void:
	if p & InputRouter.M_UP:
		sel = posmod(sel - 1, n)
		Sfx.play("menu")
	if p & InputRouter.M_DOWN:
		sel = posmod(sel + 1, n)
		Sfx.play("menu")
	if p & InputRouter.M_OK:
		Sfx.play("select")
		pick.call(sel)
	elif p & InputRouter.M_BACK:
		Sfx.play("menu")
		back.call()

func _grid_input(p: int, n: int, pick: Callable, back: Callable) -> void:
	if p & InputRouter.M_LEFT:
		sel = posmod(sel - 1, n)
		Sfx.play("menu")
	if p & InputRouter.M_RIGHT:
		sel = posmod(sel + 1, n)
		Sfx.play("menu")
	if p & InputRouter.M_OK:
		Sfx.play("select")
		pick.call(sel)
	elif p & InputRouter.M_BACK:
		Sfx.play("menu")
		back.call()

func _css_pick(i: int) -> void:
	if CHARS[i][2]:
		_go(SSS)

func _sss_pick(i: int) -> void:
	if STAGES[i][1]:
		play_local.emit(training)

func _main_pick(i: int) -> void:
	notice = ""
	match i:
		0: _go(ARENAS)
		1: _go(PRIVATE)
		2:
			training = false
			_go(CSS)
		3:
			training = true
			_go(CSS)
		4: _go(SETTINGS)
		5: quit_game.emit()

func _private_pick(i: int) -> void:
	match i:
		0: _start_host(false)
		1: _start_join_screen()
		2: _go(MAIN)

# ---------------------------------------------------------------- online
func _arenas_input(p: int) -> void:
	var rows := 1 + (browser.list().size() if browser else 0)
	sel = mini(sel, rows - 1)
	if p & InputRouter.M_UP:
		sel = posmod(sel - 1, rows)
		Sfx.play("menu")
	if p & InputRouter.M_DOWN:
		sel = posmod(sel + 1, rows)
		Sfx.play("menu")
	if p & InputRouter.M_BACK:
		_go(MAIN)
		Sfx.play("menu")
	elif p & InputRouter.M_OK:
		if sel == 0:
			Sfx.play("select")
			_start_host(true)
		else:
			var a: Dictionary = browser.list()[sel - 1]
			if not a.ok:
				status = "That arena is on a different version of the game."
				status_bad = true
				return
			Sfx.play("select")
			_start_join_screen()
			for i in NetSession.CODE_LEN:
				code_in[i] = a.code[i]
			_try_join()

func _start_host(pub: bool) -> void:
	hosting_public = pub
	_go(HOST)
	_new_net()
	net.host("", pub, Settings.player_name)
	if not pub:
		DisplayServer.clipboard_set(net.code)

func _start_join_screen() -> void:
	_go(JOIN)
	status = ""
	status_bad = false
	code_in = ["", "", "", ""]
	cur = 0
	# If the friend's code is already on the clipboard, fill it in.
	var clip := NetSession.clean_code(DisplayServer.clipboard_get())
	if clip.length() == NetSession.CODE_LEN:
		for i in NetSession.CODE_LEN:
			code_in[i] = clip[i]
		cur = NetSession.CODE_LEN - 1
		status = "Pasted the code from your clipboard. Press A / Enter to join."

func _new_net() -> void:
	if net:
		net.close()
		net.queue_free()
	net = NetSession.new()
	add_child(net)
	status = ""
	status_bad = false
	net.status_changed.connect(_on_status)
	net.failed.connect(_on_failed)
	net.connected.connect(_on_connected)

func _on_status(s: String) -> void:
	status = s
	status_bad = false
	if s == "Room ready" and net and not net.public:
		DisplayServer.clipboard_set(net.code)   # the code may have changed

func _on_failed(reason: String) -> void:
	status = reason
	status_bad = true
	Sfx.play("menu")

func _on_connected() -> void:
	Sfx.play("select")
	var n := net
	net = null
	remove_child(n)
	play_online.emit(n, 0 if n.is_host else 1)

func _back_from_net(to: int) -> void:
	if net:
		net.close()
		net.queue_free()
		net = null
	status = ""
	status_bad = false
	_go(to)
	Sfx.play("menu")

func _host_input(p: int) -> void:
	if p & InputRouter.M_BACK:
		_back_from_net(ARENAS if hosting_public else PRIVATE)
	elif (p & InputRouter.M_OK) and status_bad:
		_start_host(hosting_public)

func _join_input(p: int) -> void:
	if p & InputRouter.M_BACK:
		_back_from_net(PRIVATE)
		return
	var connecting := net != null and not status_bad
	if connecting:
		return
	if p & InputRouter.M_LEFT:
		cur = maxi(0, cur - 1)
	if p & InputRouter.M_RIGHT:
		cur = mini(NetSession.CODE_LEN - 1, cur + 1)
	if p & (InputRouter.M_UP | InputRouter.M_DOWN):
		var chars := NetSession.CODE_CHARS
		var i := chars.find(code_in[cur])
		if i < 0:
			i = 0 if p & InputRouter.M_UP else chars.length() - 1
		else:
			i = posmod(i + (1 if p & InputRouter.M_UP else -1), chars.length())
		code_in[cur] = chars[i]
		Sfx.play("menu")
	if p & InputRouter.M_OK:
		_try_join()

func _try_join() -> void:
	var c := "".join(code_in)
	if c.length() < NetSession.CODE_LEN:
		status = "The room code has %d letters." % NetSession.CODE_LEN
		status_bad = true
		return
	Sfx.play("select")
	_new_net()
	net.join(c)

# ---------------------------------------------------------------- settings
func _settings_pick(i: int) -> void:
	match i:
		0:
			name_edit = Settings.player_name
			_go(NAME)
		1:
			listening = false
			_go(CONTROLS)
		2:
			Settings.fullscreen = not Settings.fullscreen
			Settings.apply_display()
			Settings.save()
		3:
			Settings.rumble = not Settings.rumble
			Settings.save()
			if Settings.rumble:
				for j in Input.get_connected_joypads():
					Input.start_joy_vibration(j, 0.5, 0.5, 0.25)
		4: _go(MAIN)

func _name_input(p: int) -> void:
	if p & InputRouter.M_OK:
		var n := name_edit.strip_edges()
		if n != "":
			Settings.player_name = n
			Settings.save()
		Sfx.play("select")
		_go(SETTINGS)
	elif p & InputRouter.M_BACK:
		_go(SETTINGS)
	elif p & (InputRouter.M_UP | InputRouter.M_DOWN):
		# Controller players can't type: roll a random name instead.
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		name_edit = ["Courier", "Hooker", "Juggler", "Comboist", "Baller", "Spinner", "Tether", "Boomer"][rng.randi() % 8] + str(rng.randi_range(10, 99))
		Sfx.play("menu")

func _ctl_rows() -> Array:
	var rows: Array = []
	if ctl_dev < 2:
		rows.append_array(Settings.KB_MOVE)
	rows.append_array(Settings.ACTIONS)
	rows.append("_reset")
	rows.append("_back")
	return rows

func _controls_input(p: int) -> void:
	var rows := _ctl_rows()
	if p & (InputRouter.M_LEFT | InputRouter.M_RIGHT):
		ctl_dev = posmod(ctl_dev + (1 if p & InputRouter.M_RIGHT else -1), CTL_DEVS.size())
		sel = mini(sel, _ctl_rows().size() - 1)
		Sfx.play("menu")
		return
	if p & InputRouter.M_UP:
		sel = posmod(sel - 1, rows.size())
		Sfx.play("menu")
	if p & InputRouter.M_DOWN:
		sel = posmod(sel + 1, rows.size())
		Sfx.play("menu")
	if p & InputRouter.M_BACK:
		_go(SETTINGS)
		Sfx.play("menu")
	elif p & InputRouter.M_OK:
		Sfx.play("select")
		var row: String = rows[sel]
		if row == "_back":
			_go(SETTINGS)
		elif row == "_reset":
			Settings.reset(CTL_DEV_IDS[ctl_dev])
		else:
			listening = true
			listen_t = 0.0

func _input(ev: InputEvent) -> void:
	if not listening or listen_t < 0.25:
		return
	var row: String = _ctl_rows()[sel]
	if row.begins_with("_"):
		listening = false
		return
	var bind = null
	var is_pad := ctl_dev == 2
	if ev is InputEventKey and ev.pressed and not ev.echo:
		if ev.physical_keycode == KEY_ESCAPE and row != "start":
			listening = false
			get_viewport().set_input_as_handled()
			return
		if not is_pad:
			bind = ev.physical_keycode
	elif is_pad and ev is InputEventJoypadButton and ev.pressed:
		bind = ev.button_index
	elif is_pad and ev is InputEventJoypadMotion and absf(ev.axis_value) > 0.6 \
			and (ev.axis == JOY_AXIS_TRIGGER_LEFT or ev.axis == JOY_AXIS_TRIGGER_RIGHT):
		bind = "axis:%d" % ev.axis
	if bind == null:
		return
	var m: Dictionary = Settings.map_for(CTL_DEV_IDS[ctl_dev])
	# A button does one thing: take it off any other action first.
	for k in m:
		m[k] = m[k].filter(func(x): return typeof(x) != typeof(bind) or x != bind)
	m[row] = [bind]
	Settings.save()
	listening = false
	Sfx.play("select")
	get_viewport().set_input_as_handled()

func _unhandled_input(ev: InputEvent) -> void:
	if not (ev is InputEventKey) or not ev.pressed:
		return
	if screen == NAME:
		if ev.keycode == KEY_BACKSPACE:
			name_edit = name_edit.left(name_edit.length() - 1)
		elif ev.unicode >= 32 and name_edit.length() < 16:
			var ch := char(ev.unicode)
			if ch.is_valid_identifier() or ch in " -_." or ch.is_valid_int():
				name_edit += ch
		return
	if screen != JOIN:
		return
	if net != null and not status_bad:
		return
	if ev.keycode == KEY_V and (ev.ctrl_pressed or ev.meta_pressed):
		var clip := NetSession.clean_code(DisplayServer.clipboard_get())
		for i in mini(clip.length(), NetSession.CODE_LEN):
			code_in[i] = clip[i]
		if clip.length() >= NetSession.CODE_LEN:
			_try_join()
		return
	if ev.keycode == KEY_BACKSPACE:
		if code_in[cur] == "" and cur > 0:
			cur -= 1
		code_in[cur] = ""
		return
	var c := char(ev.unicode).to_upper() if ev.unicode > 0 else ""
	if c != "" and NetSession.CODE_CHARS.contains(c):
		code_in[cur] = c
		Sfx.play("menu")
		if cur < NetSession.CODE_LEN - 1:
			cur += 1
		elif "".join(code_in).length() == NetSession.CODE_LEN:
			_try_join()

# ---------------------------------------------------------------- drawing
const GOLD := Color("ffd166")
const SOFT := Color(1, 1, 1, 0.75)
const BAD := Color("ff8fa3")
const INFO := Color("b9f3ff")

func _text(f: Font, p: Vector2, s: String, sz: int, col: Color, outline: int = 0, w: float = -1, align := HORIZONTAL_ALIGNMENT_CENTER) -> void:
	var width := size.x if w < 0 else w
	if outline > 0:
		draw_string_outline(f, p, s, align, width, sz, outline, Color(FighterArt.OUTLINE, col.a))
	draw_string(f, p, s, align, width, sz, col)

func _hint(s: String) -> void:
	_text(font_ui, Vector2(0, size.y - 40), s, 22, Color(1, 1, 1, 0.45))

func _header(s: String) -> void:
	var pal0: Dictionary = FighterArt.PALETTES[0]
	_text(font_big, Vector2(0, 150), s, 88, pal0.main, 12)

func _draw() -> void:
	var vs := size
	draw_rect(Rect2(Vector2.ZERO, vs), Color("120d24"))
	for i in 7:
		var r := fmod(t * 60.0 + i * 180.0, 1260.0)
		draw_arc(vs * 0.5, r, 0, TAU, 96, Color(0.55, 0.4, 1.0, 0.09 * (1.0 - r / 1260.0)), 6.0)
	match screen:
		MAIN: _draw_main(vs)
		ARENAS: _draw_arenas(vs)
		PRIVATE: _draw_private(vs)
		HOST: _draw_host(vs)
		JOIN: _draw_join(vs)
		SETTINGS: _draw_settings(vs)
		CONTROLS: _draw_controls(vs)
		CSS: _draw_css(vs)
		SSS: _draw_sss(vs)
		NAME: _draw_name(vs)

func _draw_items(items: Array, y0: float, step: float) -> void:
	for i in items.size():
		var s := i == sel
		_text(font_ui, Vector2(0, y0 + i * step), ("> " if s else "") + items[i] + (" <" if s else ""), 46 if s else 38, GOLD if s else SOFT, 6)

func _draw_main(vs: Vector2) -> void:
	var pal0: Dictionary = FighterArt.PALETTES[0]
	var pal1: Dictionary = FighterArt.PALETTES[1]
	_text(font_big, Vector2(0, 200), "UNNAMED", 110, pal0.main, 14)
	_text(font_big, Vector2(0, 310), "BALL FIGHTER", 110, pal1.main, 14)
	_draw_items(MAIN_ITEMS, 440, 66)
	_text(font_ui, Vector2(0, 860), MAIN_HINTS[sel], 26, INFO, 4)
	if notice != "":
		_text(font_ui, Vector2(0, 910), notice, 26, BAD, 4)
	_text(font_ui, Vector2(0, 60), "Playing as %s" % Settings.player_name, 24, Color(1, 1, 1, 0.5), 0, vs.x - 40, HORIZONTAL_ALIGNMENT_RIGHT)
	_hint("A / Enter: select      B / Esc: back      Stick, D-pad or arrows: move")

func _draw_private(vs: Vector2) -> void:
	_header("PRIVATE MATCH")
	_draw_items(PRIVATE_ITEMS, 440, 70)
	_text(font_ui, Vector2(0, 760), "Private rooms aren't listed in Online Arenas. Share the 4-letter code with your friend.", 26, INFO, 4)
	_hint("A / Enter: select      B / Esc: back")

func _draw_arenas(vs: Vector2) -> void:
	_header("ONLINE ARENAS")
	var list: Array = browser.list() if browser else []
	var w := 900.0
	var x0 := (vs.x - w) * 0.5
	var y := 260.0
	var rows := ["+  Host a public arena"]
	for a in list:
		rows.append(a)
	for i in rows.size():
		if y > vs.y - 200:
			break
		var s := i == sel
		var r := Rect2(Vector2(x0, y), Vector2(w, 70))
		draw_rect(r, Color("2a2150") if s else Color("1c1636"))
		draw_rect(r, GOLD if s else Color(1, 1, 1, 0.15), false, 4.0 if s else 2.0)
		if i == 0:
			_text(font_ui, r.position + Vector2(30, 47), rows[0], 32, GOLD if s else Color.WHITE, 0, w - 60, HORIZONTAL_ALIGNMENT_LEFT)
		else:
			var a: Dictionary = rows[i]
			var col := Color.WHITE if a.ok else Color(1, 1, 1, 0.35)
			_text(font_ui, r.position + Vector2(30, 47), "%s's arena" % a.name, 32, col, 0, w - 60, HORIZONTAL_ALIGNMENT_LEFT)
			_text(font_ui, r.position + Vector2(30, 47), ("1 / 2 players" if a.ok else "different version"), 24, col, 0, w - 60, HORIZONTAL_ALIGNMENT_RIGHT)
		y += 84
	var msg := ""
	if browser and browser.status != "":
		msg = browser.status
	elif list.is_empty():
		msg = "No public arenas right now. Host one and friends will see it here."
	if msg != "":
		_text(font_ui, Vector2(0, y + 40), msg, 28, INFO, 4)
	if status_bad and status != "":
		_text(font_ui, Vector2(0, vs.y - 110), status, 28, BAD, 4)
	_hint("A / Enter: host or join      B / Esc: back      The list updates live")

func _draw_host(vs: Vector2) -> void:
	_header("PUBLIC ARENA" if hosting_public else "PRIVATE ROOM")
	if hosting_public:
		_text(font_ui, Vector2(0, 330), "Listed in Online Arenas as", 32, SOFT, 4)
		_text(font_big, Vector2(0, 450), "%s's arena" % Settings.player_name, 90, GOLD, 12)
		_text(font_ui, Vector2(0, 560), "Friends can also join with code %s" % (net.code if net else ""), 30, SOFT, 4)
	else:
		_text(font_ui, Vector2(0, 330), "YOUR ROOM CODE", 34, SOFT, 4)
		_text(font_big, Vector2(0, 520), net.code if net else "", 170, GOLD, 16)
		_text(font_ui, Vector2(0, 600), "Copied to your clipboard. Send it to your friend, then they pick Private Match > Join with a code.", 28, Color(1, 1, 1, 0.8), 4)
	var dots := ".".repeat(int(t * 2.0) % 4)
	var s := status if status_bad else ("Waiting for an opponent" + dots if status == "Room ready" or status == "" else status)
	_text(font_ui, Vector2(0, 760), s, 32, BAD if status_bad else INFO, 4)
	_draw_diag()
	_hint("B / Esc: back" + ("      A / Enter: try again" if status_bad else ""))

func _draw_join(vs: Vector2) -> void:
	_header("JOIN")
	_text(font_ui, Vector2(0, 340), "ENTER YOUR FRIEND'S ROOM CODE", 34, SOFT, 4)
	var bw := 130.0
	var gap := 30.0
	var total := NetSession.CODE_LEN * bw + (NetSession.CODE_LEN - 1) * gap
	var x0 := (vs.x - total) * 0.5
	var connecting := net != null and not status_bad
	for i in NetSession.CODE_LEN:
		var r := Rect2(Vector2(x0 + i * (bw + gap), 400), Vector2(bw, 160))
		var active := i == cur and not connecting
		draw_rect(r, Color("1f1838"))
		draw_rect(r, GOLD if active else Color(1, 1, 1, 0.3), false, 6.0 if active else 3.0)
		if active:
			draw_string(font_ui, r.position + Vector2(0, -12), "▲", HORIZONTAL_ALIGNMENT_CENTER, bw, 22, Color(1, 1, 1, 0.5))
			draw_string(font_ui, r.position + Vector2(0, 190), "▼", HORIZONTAL_ALIGNMENT_CENTER, bw, 22, Color(1, 1, 1, 0.5))
		draw_string_outline(font_big, r.position + Vector2(0, 125), code_in[i], HORIZONTAL_ALIGNMENT_CENTER, bw, 110, 10, Color(FighterArt.OUTLINE))
		draw_string(font_big, r.position + Vector2(0, 125), code_in[i], HORIZONTAL_ALIGNMENT_CENTER, bw, 110, Color.WHITE)
	var dots := ".".repeat(int(t * 2.0) % 4)
	_text(font_ui, Vector2(0, 700), status + (dots if connecting else ""), 32, BAD if status_bad else INFO, 4)
	_draw_diag()
	_hint("Type the letters or paste with Ctrl+V.   Controller: up/down picks a letter, left/right moves.   A / Enter: join   B / Esc: back")

func _draw_diag() -> void:
	if net and net.state == NetSession.CONNECTING:
		_text(font_ui, Vector2(0, 850), net.diag_text(), 20, Color(1, 1, 1, 0.4))

func _draw_settings(vs: Vector2) -> void:
	_header("SETTINGS")
	var items := ["Name:  %s" % Settings.player_name, "Controls", "Fullscreen:  %s" % ("On" if Settings.fullscreen else "Off"),
		"Rumble:  %s" % ("On" if Settings.rumble else "Off"), "Back"]
	_draw_items(items, 400, 76)
	_hint("A / Enter: change      B / Esc: back")

func _draw_name(vs: Vector2) -> void:
	_header("YOUR NAME")
	_text(font_ui, Vector2(0, 360), "Shown to other players in Online Arenas", 30, SOFT, 4)
	var r := Rect2(Vector2(vs.x * 0.5 - 420, 420), Vector2(840, 130))
	draw_rect(r, Color("1f1838"))
	draw_rect(r, GOLD, false, 5.0)
	var caret := "|" if int(t * 2.0) % 2 == 0 else " "
	_text(font_big, r.position + Vector2(0, 98), name_edit + caret, 80, Color.WHITE, 8, r.size.x)
	_hint("Type a name.   Controller: up/down for a random name.   A / Enter: save   B / Esc: cancel")

func _draw_controls(vs: Vector2) -> void:
	_header("CONTROLS")
	# Device tabs
	var tw := 420.0
	var x0 := (vs.x - tw * 3 - 40) * 0.5
	for i in 3:
		var r := Rect2(Vector2(x0 + i * (tw + 20), 200), Vector2(tw, 56))
		var on := i == ctl_dev
		draw_rect(r, Color("2a2150") if on else Color("1c1636"))
		draw_rect(r, GOLD if on else Color(1, 1, 1, 0.15), false, 3.0)
		_text(font_ui, r.position + Vector2(0, 38), CTL_DEVS[i], 24, GOLD if on else SOFT, 0, tw)
	var rows := _ctl_rows()
	var m: Dictionary = Settings.map_for(CTL_DEV_IDS[ctl_dev])
	var w := 900.0
	var lx := (vs.x - w) * 0.5
	var y := 300.0
	var step := minf(44.0, (vs.y - 400.0) / rows.size())
	for i in rows.size():
		var row: String = rows[i]
		var s := i == sel
		if s:
			draw_rect(Rect2(Vector2(lx - 16, y - step + 10), Vector2(w + 32, step)), Color(1, 0.82, 0.4, 0.12))
		var label: String = "Reset to defaults" if row == "_reset" else ("Back" if row == "_back" else Settings.LABELS[row])
		_text(font_ui, Vector2(lx, y), label, 28, GOLD if s else Color.WHITE, 0, w, HORIZONTAL_ALIGNMENT_LEFT)
		if m.has(row):
			var val: String = "Press a %s..." % ("button" if ctl_dev == 2 else "key") if (s and listening) else Settings.bindings_text(m[row], ctl_dev == 2)
			_text(font_ui, Vector2(lx, y), val, 28, GOLD if (s and listening) else SOFT, 0, w, HORIZONTAL_ALIGNMENT_RIGHT)
		y += step
	if ctl_dev == 2:
		_text(font_ui, Vector2(0, vs.y - 80), "Left stick moves (tilt = walk, flick = dash). Right stick does smash attacks / aerials. Menus always use A / B.", 22, INFO)
	else:
		_text(font_ui, Vector2(0, vs.y - 80), "Arrow keys also move P1 unless a second keyboard player has joined. Menus always use Enter / Esc.", 22, INFO)
	_hint("Left / right: switch device      A / Enter: rebind (then press the new key or button)      Esc: cancel")

func _draw_css(vs: Vector2) -> void:
	_header("CHOOSE YOUR FIGHTER")
	var cw := 330.0
	var x0 := (vs.x - cw * 4 - 60) * 0.5
	for i in CHARS.size():
		var c: Array = CHARS[i]
		var r := Rect2(Vector2(x0 + i * (cw + 20), 260), Vector2(cw, 480))
		var s := i == sel
		draw_rect(r, Color("2a2150") if c[2] else Color("17122c"))
		draw_rect(r, GOLD if s else Color(1, 1, 1, 0.15), false, 6.0 if s else 2.0)
		var pal: Dictionary = FighterArt.PALETTES[0]
		if c[2]:
			var ctr := r.position + Vector2(cw * 0.5, 210)
			draw_circle(ctr, 110, pal.dark)
			draw_circle(ctr, 92, pal.main)
			draw_colored_polygon(PackedVector2Array([ctr + Vector2(4, -30), ctr + Vector2(70, -24), ctr + Vector2(64, 12), ctr + Vector2(-8, 12)]), pal.visor)
		else:
			_text(font_big, r.position + Vector2(0, 260), "?", 200, Color(1, 1, 1, 0.12), 0, cw)
		_text(font_big, r.position + Vector2(0, 410), c[0], 56, Color.WHITE if c[2] else Color(1, 1, 1, 0.3), 8, cw)
		_text(font_ui, r.position + Vector2(0, 450), c[1] if c[2] else "Coming soon", 24, SOFT if c[2] else Color(1, 1, 1, 0.3), 0, cw)
	_text(font_ui, Vector2(0, 820), "TRAINING: you vs a sandbag (Back / F2 switches to the CPU)" if training else "VERSUS: you vs the CPU. A second controller can join in the match.", 28, INFO, 4)
	_hint("Left / right: choose      A / Enter: confirm      B / Esc: back")

func _draw_sss(vs: Vector2) -> void:
	_header("CHOOSE A STAGE")
	var cw := 380.0
	var x0 := (vs.x - cw * 4 - 60) * 0.5
	for i in STAGES.size():
		var st: Array = STAGES[i]
		var r := Rect2(Vector2(x0 + i * (cw + 20), 300), Vector2(cw, 300))
		var s := i == sel
		if st[1]:
			# Tiny preview: dusk sky, skyline, the platform.
			draw_rect(r, Color("3b2a6b"))
			draw_rect(Rect2(r.position + Vector2(0, 150), Vector2(cw, 150)), Color("7a3f7a"))
			for k in 9:
				var bh := 40.0 + float((k * 37) % 70)
				draw_rect(Rect2(r.position + Vector2(k * 44, 300 - bh), Vector2(36, bh)), Color("241a46"))
			draw_rect(Rect2(r.position + Vector2(60, 190), Vector2(cw - 120, 14)), Color("b8b2e8"))
			draw_rect(Rect2(r.position + Vector2(110, 130), Vector2(70, 8)), Color("b8b2e8"))
			draw_rect(Rect2(r.position + Vector2(cw - 180, 130), Vector2(70, 8)), Color("b8b2e8"))
		else:
			draw_rect(r, Color("17122c"))
			_text(font_big, r.position + Vector2(0, 210), "?", 160, Color(1, 1, 1, 0.12), 0, cw)
		draw_rect(r, GOLD if s else Color(1, 1, 1, 0.15), false, 6.0 if s else 2.0)
		_text(font_big, r.position + Vector2(0, 360), st[0], 40, Color.WHITE if st[1] else Color(1, 1, 1, 0.3), 6, cw)
	_hint("Left / right: choose      A / Enter: fight!      B / Esc: back")
