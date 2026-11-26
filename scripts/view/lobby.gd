extends Control
## Title menu: local play, host online, join online. Hosting shows a 4-letter
## room code (already copied to the clipboard); joining takes the code by
## typing, pasting, or picking letters with a controller.

signal play_local
signal play_online(net: NetSession, slot: int)
signal quit_game

enum { MAIN, HOST, JOIN }

var font_ui: Font = load("res://assets/fonts/InterDisplay-ExtraBold.otf")
var font_big: Font = load("res://assets/fonts/InterDisplay-BlackItalic.otf")
var screen := MAIN
var sel := 0
var net: NetSession
var status := ""
var status_bad := false
var code_in := ["", "", "", ""]
var cur := 0
var t := 0.0
var copied := false
var notice := ""   # shown on the main screen (e.g. why the last match ended)

const ITEMS := ["Play local  (vs CPU or couch)", "Host online game", "Join online game", "Quit"]

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(dt: float) -> void:
	t += dt
	size = get_viewport_rect().size
	var p := InputRouter.menu_pressed(screen == JOIN)
	match screen:
		MAIN: _main_input(p)
		HOST: _host_input(p)
		JOIN: _join_input(p)
	queue_redraw()

func _main_input(p: int) -> void:
	if p & InputRouter.M_UP:
		sel = posmod(sel - 1, ITEMS.size())
		Sfx.play("menu")
	if p & InputRouter.M_DOWN:
		sel = posmod(sel + 1, ITEMS.size())
		Sfx.play("menu")
	if p & InputRouter.M_OK:
		Sfx.play("select")
		notice = ""
		match sel:
			0: play_local.emit()
			1: _start_host()
			2: _start_join_screen()
			3: quit_game.emit()

func _start_host() -> void:
	screen = HOST
	_new_net()
	net.host()
	DisplayServer.clipboard_set(net.code)
	copied = true

func _start_join_screen() -> void:
	screen = JOIN
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
	net.status_changed.connect(func(s): status = s; status_bad = false)
	net.failed.connect(_on_failed)
	net.connected.connect(_on_connected)

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

func _back() -> void:
	if net:
		net.close()
		net.queue_free()
		net = null
	screen = MAIN
	Sfx.play("menu")

func _host_input(p: int) -> void:
	if p & InputRouter.M_BACK:
		_back()
	elif (p & InputRouter.M_OK) and status_bad:
		_start_host()

func _join_input(p: int) -> void:
	if p & InputRouter.M_BACK:
		_back()
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

func _unhandled_input(ev: InputEvent) -> void:
	if screen != JOIN or not (ev is InputEventKey) or not ev.pressed:
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
	var ch := char(ev.unicode).to_upper() if ev.unicode > 0 else ""
	if ch != "" and NetSession.CODE_CHARS.contains(ch):
		code_in[cur] = ch
		Sfx.play("menu")
		if cur < NetSession.CODE_LEN - 1:
			cur += 1
		elif "".join(code_in).length() == NetSession.CODE_LEN:
			_try_join()

# ---------------------------------------------------------------- drawing
func _text(f: Font, p: Vector2, s: String, sz: int, col: Color, outline: int = 0, w: float = -1) -> void:
	var width := size.x if w < 0 else w
	if outline > 0:
		draw_string_outline(f, p, s, HORIZONTAL_ALIGNMENT_CENTER, width, sz, outline, Color(FighterArt.OUTLINE, col.a))
	draw_string(f, p, s, HORIZONTAL_ALIGNMENT_CENTER, width, sz, col)

func _draw() -> void:
	var vs := size
	# Background: deep gradient with drifting rings.
	draw_rect(Rect2(Vector2.ZERO, vs), Color("120d24"))
	for i in 7:
		var r := fmod(t * 60.0 + i * 180.0, 1260.0)
		draw_arc(vs * 0.5, r, 0, TAU, 96, Color(0.55, 0.4, 1.0, 0.09 * (1.0 - r / 1260.0)), 6.0)
	var pal0: Dictionary = FighterArt.PALETTES[0]
	var pal1: Dictionary = FighterArt.PALETTES[1]
	_text(font_big, Vector2(0, 220), "UNNAMED", 120, pal0.main, 14)
	_text(font_big, Vector2(0, 340), "BALL FIGHTER", 120, pal1.main, 14)
	match screen:
		MAIN: _draw_main(vs)
		HOST: _draw_host(vs)
		JOIN: _draw_join(vs)

func _draw_main(vs: Vector2) -> void:
	for i in ITEMS.size():
		var s := i == sel
		var c := Color("ffd166") if s else Color(1, 1, 1, 0.75)
		_text(font_ui, Vector2(0, 500 + i * 70), ("> " if s else "") + ITEMS[i] + (" <" if s else ""), 46 if s else 38, c, 6)
	if notice != "":
		_text(font_ui, Vector2(0, 820), notice, 28, Color("ff8fa3"), 4)
	_text(font_ui, Vector2(0, vs.y - 40), "A / Enter: select      Stick, D-pad or arrows: move", 22, Color(1, 1, 1, 0.45))

func _draw_host(vs: Vector2) -> void:
	_text(font_ui, Vector2(0, 470), "YOUR ROOM CODE", 34, Color(1, 1, 1, 0.75), 4)
	var code := net.code if net else ""
	_text(font_big, Vector2(0, 640), code, 170, Color("ffd166"), 16)
	if copied:
		_text(font_ui, Vector2(0, 710), "Copied to your clipboard. Send it to your friend, then they pick Join online game.", 28, Color(1, 1, 1, 0.8), 4)
	var dots := ".".repeat(int(t * 2.0) % 4)
	var s := status if status_bad else ("Waiting for your friend" + dots if status == "Room ready" or status == "" else status)
	_text(font_ui, Vector2(0, 800), s, 32, Color("ff8fa3") if status_bad else Color("b9f3ff"), 4)
	_draw_diag()
	_text(font_ui, Vector2(0, vs.y - 40), "B / Esc: back" + ("      A / Enter: try again" if status_bad else ""), 22, Color(1, 1, 1, 0.45))

func _draw_join(vs: Vector2) -> void:
	_text(font_ui, Vector2(0, 470), "ENTER YOUR FRIEND'S ROOM CODE", 34, Color(1, 1, 1, 0.75), 4)
	var bw := 130.0
	var gap := 30.0
	var total := NetSession.CODE_LEN * bw + (NetSession.CODE_LEN - 1) * gap
	var x0 := (vs.x - total) * 0.5
	var connecting := net != null and not status_bad
	for i in NetSession.CODE_LEN:
		var r := Rect2(Vector2(x0 + i * (bw + gap), 520), Vector2(bw, 160))
		var active := i == cur and not connecting
		draw_rect(r, Color("1f1838"))
		draw_rect(r, Color("ffd166") if active else Color(1, 1, 1, 0.3), false, 6.0 if active else 3.0)
		if active:
			draw_string(font_ui, r.position + Vector2(0, -12), "▲", HORIZONTAL_ALIGNMENT_CENTER, bw, 22, Color(1, 1, 1, 0.5))
			draw_string(font_ui, r.position + Vector2(0, 190), "▼", HORIZONTAL_ALIGNMENT_CENTER, bw, 22, Color(1, 1, 1, 0.5))
		draw_string_outline(font_big, r.position + Vector2(0, 125), code_in[i], HORIZONTAL_ALIGNMENT_CENTER, bw, 110, 10, Color(FighterArt.OUTLINE))
		draw_string(font_big, r.position + Vector2(0, 125), code_in[i], HORIZONTAL_ALIGNMENT_CENTER, bw, 110, Color.WHITE)
	var dots := ".".repeat(int(t * 2.0) % 4)
	var s := status + (dots if connecting else "")
	_text(font_ui, Vector2(0, 800), s, 32, Color("ff8fa3") if status_bad else Color("b9f3ff"), 4)
	_draw_diag()
	_text(font_ui, Vector2(0, vs.y - 40), "Type the letters or paste with Ctrl+V.   Controller: up/down picks a letter, left/right moves.   A / Enter: join   B / Esc: back", 22, Color(1, 1, 1, 0.45))

func _draw_diag() -> void:
	if net and net.state == NetSession.CONNECTING:
		_text(font_ui, Vector2(0, 850), net.diag_text(), 20, Color(1, 1, 1, 0.4))
