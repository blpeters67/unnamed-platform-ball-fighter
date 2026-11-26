extends Control
## Screen-space UI: damage cards, the combo counter and style grade, combo
## summary cards, popups, the pause menu, and the results screen.

var m: Node
var font_ui: Font = load("res://assets/fonts/InterDisplay-ExtraBold.otf")
var font_big: Font = load("res://assets/fonts/InterDisplay-BlackItalic.otf")

const GRADE_COL := {"D": Color("9a93a8"), "C": Color("8fd3ff"), "B": Color("8dffb0"), "A": Color("ffe066"),
	"S": Color("ff9f43"), "SS": Color("ff5d73"), "SSS": Color("e67bff")}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _draw() -> void:
	var vs = size
	var sim: GameSim = m.sim
	# Screen flash
	if m.flash > 0.0:
		var fc: Color = m.flash_col
		fc.a = m.flash * 0.6
		draw_rect(Rect2(Vector2.ZERO, vs), fc)
	for i in 2:
		_draw_card(i, sim.st.f[i], vs)
		_draw_combo(i, vs)
	_draw_summaries(vs)
	_draw_screen_popups(vs)
	if m.p2_is_dummy():
		var mode: String = m.DUMMY_MODES[m.dummy_mode]
		var txt = "P2: %s      Back / Select / F2: toggle CPU and sandbag      2nd player: press any button on a controller to join" % mode
		_text(font_ui, Vector2(0, vs.y - 18), txt, HORIZONTAL_ALIGNMENT_CENTER, vs.x, 18, Color(1, 1, 1, 0.5))
	if m.online:
		var rb: Rollback = m.rb
		var txt = "ONLINE  room %s      you are %s      predicting %d frames      rollbacks %d" % [m.net.code, "P1" if m.my_slot == 0 else "P2", rb.unconfirmed(), rb.rollbacks]
		if rb.desync_frame >= 0:
			txt += "      DESYNC at frame %d (tell Claude!)" % rb.desync_frame
		_text(font_ui, Vector2(0, vs.y - 18), txt, HORIZONTAL_ALIGNMENT_CENTER, vs.x, 18, Color(1, 1, 1, 0.5))
	if m.paused:
		_draw_pause(vs)
	if sim.st.winner >= 0:
		_draw_game_over(vs)

func _text(f: Font, p: Vector2, s: String, align: int, width: float, sz: int, col: Color, outline: int = 0) -> void:
	if outline > 0:
		draw_string_outline(f, p, s, align, width, sz, outline, Color(FighterArt.OUTLINE, col.a))
	draw_string(f, p, s, align, width, sz, col)

func _pct_color(pct: float) -> Color:
	if pct < 40:
		return Color.WHITE.lerp(Color("ffe066"), pct / 40.0)
	if pct < 90:
		return Color("ffe066").lerp(Color("ff7a3d"), (pct - 40) / 50.0)
	if pct < 150:
		return Color("ff7a3d").lerp(Color("e0213d"), (pct - 90) / 60.0)
	return Color("e0213d").lerp(Color("8a0f2a"), clampf((pct - 150) / 80.0, 0, 1))

func _draw_card(i: int, f: Dictionary, vs: Vector2) -> void:
	var pal: Dictionary = FighterArt.PALETTES[i]
	var cx = vs.x * (0.36 if i == 0 else 0.64)
	var base = Vector2(cx - 150, vs.y - 200)
	var rect = Rect2(base, Vector2(300, 118))
	draw_rect(Rect2(base + Vector2(6, 6), rect.size), Color(0, 0, 0, 0.35))
	draw_rect(rect, Color("16122b", 0.88))
	draw_rect(Rect2(base, Vector2(8, 118)), pal.main)
	# Portrait disc
	draw_circle(base + Vector2(52, 52), 34, pal.dark)
	draw_circle(base + Vector2(52, 52), 28, pal.main)
	draw_colored_polygon(PackedVector2Array([base + Vector2(54, 44), base + Vector2(78, 46), base + Vector2(76, 58), base + Vector2(50, 58)]), pal.visor)
	var tag = m.player_tag(i)
	_text(font_ui, base + Vector2(16, 108), tag, HORIZONTAL_ALIGNMENT_LEFT, 80, 20, pal.accent)
	_text(font_ui, base + Vector2(96, 26), CharJuno.NAME, HORIZONTAL_ALIGNMENT_LEFT, 200, 20, Color(1, 1, 1, 0.85))
	# Damage percent
	var pct = float(f.pct) / 10.0
	var sh: float = m.pct_shake[i]
	var jitter = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * sh * 8.0
	var dead: bool = f.state == GameSim.S_DEAD
	var ptxt = "%d" % int(pct)
	var pc = _pct_color(pct)
	if dead:
		ptxt = "--"
		pc = Color(1, 1, 1, 0.3)
	var psz = int(64 + sh * 14)
	_text(font_big, base + Vector2(92, 92) + jitter, ptxt, HORIZONTAL_ALIGNMENT_LEFT, 160, psz, pc, 10)
	var dec = "%d%%" % (f.pct % 10) if false else "%"
	_text(font_big, base + Vector2(92 + font_big.get_string_size(ptxt, HORIZONTAL_ALIGNMENT_LEFT, -1, psz).x + 4, 92) + jitter, dec, HORIZONTAL_ALIGNMENT_LEFT, 60, 30, pc, 6)
	# Stocks
	for s in f.stocks:
		var sp = base + Vector2(210 + s * 24, 40)
		draw_circle(sp, 9, FighterArt.OUTLINE)
		draw_circle(sp, 7, pal.main)
	# Ball state icon
	var b: Dictionary = m.sim.st.b[i]
	# Ball charges: 3 pips, the next one fills up over 3 seconds
	for c in GameSim.BALL_CHARGES:
		var bp = base + Vector2(226 + c * 26, 82)
		draw_circle(bp, 11, FighterArt.OUTLINE)
		if c < f.charges:
			draw_circle(bp, 9, pal.visor)
		else:
			draw_circle(bp, 9, Color(pal.visor, 0.18))
			if c == f.charges:
				var k2 := float(f.charge_t) / GameSim.CHARGE_FRAMES
				draw_arc(bp, 9, -PI / 2, -PI / 2 + TAU * k2, 20, pal.visor, 3)
	# Burst meter
	var bw = 276.0
	var bx = base + Vector2(12, 128)
	var k = float(f.burst) / GameSim.BURST_MAX
	draw_rect(Rect2(bx, Vector2(bw, 12)), Color(0, 0, 0, 0.6))
	var full = f.burst >= GameSim.BURST_MAX
	var bc: Color = pal.glow
	if full:
		bc = bc.lerp(Color.WHITE, 0.4 + 0.4 * sin(m.t * 10.0))
	draw_rect(Rect2(bx + Vector2(2, 2), Vector2((bw - 4) * k, 8)), bc)
	_text(font_ui, bx + Vector2(0, 32), "BURST READY! (LB / O)" if full else "BURST", HORIZONTAL_ALIGNMENT_LEFT, bw, 15, Color(bc, 0.95 if full else 0.6))

func _draw_combo(i: int, vs: Vector2) -> void:
	var cu: Dictionary = m.combo_ui[i]
	if not cu.has("count"):
		return
	var fade: float = cu.get("fade", 0.0)
	if fade <= 0.0 and cu.get("broken", 0.0) <= 0.0:
		return
	var left = i == 0
	var count: int = cu.count
	var x = 60.0 if left else vs.x - 60.0
	var align = HORIZONTAL_ALIGNMENT_LEFT if left else HORIZONTAL_ALIGNMENT_RIGHT
	var ox = 0.0 if left else -600.0
	var a = fade
	if count >= 2 and fade > 0.0:
		var pop: float = cu.get("pop", 0.0)
		var sz = int((96 + mini(count, 40) * 3) * (1.0 + pop * 0.45))
		var col = _combo_color(count)
		col.a = a
		var y = 210.0 + pop * 6
		_text(font_big, Vector2(x + ox, y), "%d" % count, align, 600, sz, col, 16)
		_text(font_big, Vector2(x + ox, y + 48), "HIT COMBO" if count >= 10 else "HITS", align, 600, 34, Color(1, 1, 1, a), 8)
		var dmg = float(cu.get("dmg", 0)) / 10.0
		_text(font_ui, Vector2(x + ox, y + 84), "%.1f%% damage" % dmg, align, 600, 24, Color(1, 1, 1, 0.8 * a), 6)
		var grade: String = m.style_grade(cu.get("style", 0))
		var gc: Color = GRADE_COL[grade]
		gc.a = a
		_text(font_big, Vector2(x + ox, y + 150), "STYLE  " + grade, align, 600, 50, gc, 10)
		# Move feed: green = new move, grey = stale repeat
		var fy = y + 196
		for fd in cu.get("feed", []):
			var fc: Color = fd.col
			fc.a = clampf(fd.t * 2.0, 0, 1) * a
			var label: String = fd.text
			if fd.tag != "":
				label = ("[%s] " % fd.tag) + label if left else label + (" [%s]" % fd.tag)
			_text(font_ui, Vector2(x + ox, fy), label, align, 600, 22, fc, 6)
			fy += 28
	if cu.get("broken", 0.0) > 0.0:
		var bk: float = cu.broken
		var bcol = Color("ff5d73")
		bcol.a = clampf(bk * 2.0, 0, 1)
		_text(font_big, Vector2(x + ox, 170), "COMBO BROKEN!", align, 600, 44, bcol, 10)

func _combo_color(n: int) -> Color:
	if n < 5:
		return Color.WHITE
	if n < 10:
		return Color("ffe066")
	if n < 15:
		return Color("ff9f43")
	if n < 20:
		return Color("ff5d73")
	if n < 30:
		return Color("e67bff")
	return Color.from_hsv(fmod(m.t * 0.8, 1.0), 0.6, 1.0)

func _draw_summaries(vs: Vector2) -> void:
	var y = 120.0
	for s in m.summaries:
		var tt: float = s.t
		var slide = 1.0 - pow(1.0 - clampf(tt * 4.0, 0, 1), 3)
		var a = 1.0 - clampf((tt - 2.4) / 0.8, 0, 1)
		var left: bool = s.a == 0
		var pal: Dictionary = FighterArt.PALETTES[s.a]
		var w = 520.0
		var x = vs.x * 0.5 - w * 0.5 + (1.0 - slide) * (-400.0 if left else 400.0)
		var r = Rect2(x, y, w, 92)
		draw_rect(r, Color("16122b", 0.85 * a))
		draw_rect(Rect2(x, y, w, 5), Color(pal.main, a))
		var head = "%d HIT COMBO" % s.combo
		if s.ko:
			head = "%d HIT KO COMBO" % s.combo
		elif s.burst:
			head = "%d HITS, BURST!" % s.combo
		_text(font_big, Vector2(x + 20, y + 50), head, HORIZONTAL_ALIGNMENT_LEFT, w, 38, Color(1, 1, 1, a), 8)
		_text(font_ui, Vector2(x + 22, y + 80), "%.1f%%" % (float(s.dmg) / 10.0), HORIZONTAL_ALIGNMENT_LEFT, w, 22, Color(1, 1, 1, 0.75 * a))
		var gc: Color = GRADE_COL[s.grade]
		gc.a = a
		_text(font_big, Vector2(x, y + 74), s.grade, HORIZONTAL_ALIGNMENT_RIGHT, w - 22, 64, gc, 10)
		y += 104

func _draw_screen_popups(vs: Vector2) -> void:
	var y = vs.y * 0.36
	for pp in m.popups:
		if pp.world:
			continue
		var tt: float = pp.t
		var sc = 1.0 + 0.5 * maxf(0.0, 1.0 - tt * 6.0)
		var a = 1.0 - clampf((tt - 1.6) / 0.6, 0, 1)
		var c: Color = pp.col
		c.a = a
		var sz = int(pp.size * sc)
		_text(font_big, Vector2(0, y), pp.text, HORIZONTAL_ALIGNMENT_CENTER, vs.x, sz, c, 12 if pp.size > 60 else 6)
		y += pp.size + 16

func _draw_pause(vs: Vector2) -> void:
	draw_rect(Rect2(Vector2.ZERO, vs), Color(0.03, 0.02, 0.07, 0.82))
	_text(font_big, Vector2(0, 150), "PAUSED", HORIZONTAL_ALIGNMENT_CENTER, vs.x, 84, Color.WHITE, 12)
	var items = ["Resume", "Restart match", "P2 when empty:  < %s >" % m.DUMMY_MODES[m.dummy_mode], "Main menu"]
	if m.online:
		items = ["Resume  (the match keeps going!)", "Leave match"]
	for i in items.size():
		var sel: bool = i == m.pause_sel
		var c = Color("ffd166") if sel else Color(1, 1, 1, 0.7)
		_text(font_ui, Vector2(0, 250 + i * 52), ("> " if sel else "") + items[i], HORIZONTAL_ALIGNMENT_CENTER, vs.x, 36 if sel else 30, c, 6)
	var P = Settings.pad
	var K = Settings.kb1
	var pb = func(k): return Settings.bindings_text(P[k], true)
	var kb = func(k): return Settings.bindings_text(K[k], false)
	var col1 = [
		"CONTROLLER (Xbox / PlayStation / Switch)",
		"Left stick: walk (tilt) / dash (flick)",
		"%s: attack    %s: special" % [pb.call("attack"), pb.call("special")],
		"%s: jump" % pb.call("jump"),
		"Right stick: smash attacks (air: aerials)",
		"Flick stick + attack: smash attack",
		"%s: throw ball / recall ball" % pb.call("ball"),
		"%s: shield (tap = parry)   %s: grab" % [pb.call("shield"), pb.call("grab")],
		"%s: BURST when the meter is full" % pb.call("burst"),
		"%s: pause    %s: CPU / sandbag" % [pb.call("start"), pb.call("back")],
	]
	var col2 = [
		"KEYBOARD   (change any of these in Settings > Controls)",
		"%s %s %s %s or arrows: move (tap = dash)" % [kb.call("up"), kb.call("left"), kb.call("down"), kb.call("right")],
		"%s: attack    %s: special" % [kb.call("attack"), kb.call("special")],
		"%s: jump" % kb.call("jump"),
		"%s + direction + attack: smash attack" % kb.call("smash"),
		"%s: throw ball / recall ball" % kb.call("ball"),
		"%s: shield (tap = parry)    %s: grab" % [kb.call("shield"), kb.call("grab")],
		"%s: BURST" % kb.call("burst"),
		"%s: pause  %s: CPU/sandbag  F11: fullscreen" % [kb.call("start"), kb.call("back")],
		"2nd keyboard player: press numpad 1 to join",
	]
	var tips = [
		"THE BALL: throw it past or at your opponent. It hooks them and drags them back to you.",
		"Recall it mid-flight to yank it back through them. Use different moves in a combo for more hitstun;",
		"repeating moves makes them fly farther away. Getting comboed? Burst, DI with the stick, tech by shielding as you land.",
	]
	for i in col1.size():
		_text(font_ui, Vector2(vs.x * 0.5 - 620, 520 + i * 32), col1[i], HORIZONTAL_ALIGNMENT_LEFT, 600, 24 if i == 0 else 21, Color("8fd3ff") if i == 0 else Color(1, 1, 1, 0.85))
		_text(font_ui, Vector2(vs.x * 0.5 + 60, 520 + i * 32), col2[i], HORIZONTAL_ALIGNMENT_LEFT, 600, 24 if i == 0 else 21, Color("8fd3ff") if i == 0 else Color(1, 1, 1, 0.85))
	for i in tips.size():
		_text(font_ui, Vector2(0, 880 + i * 30), tips[i], HORIZONTAL_ALIGNMENT_CENTER, vs.x, 20, Color("ffd166", 0.9))
	# Controller status, so it's obvious whether the game sees your pad
	var pads := Input.get_connected_joypads()
	var line := "Controllers detected: none"
	if not pads.is_empty():
		var names := []
		for j in pads:
			var nm := Input.get_joy_name(j)
			var slot := InputRouter.slots.find("joy%d" % j)
			names.append("%s%s" % [nm if nm != "" else "Gamepad", " (P%d)" % (slot + 1) if slot >= 0 else ""])
		line = "Controllers detected: " + ", ".join(names)
	_text(font_ui, Vector2(0, 990), line, HORIZONTAL_ALIGNMENT_CENTER, vs.x, 22, Color("8fd3ff"))
	if pads.is_empty():
		_text(font_ui, Vector2(0, 1022), "Steam Controller? Launch the game through Steam (Add a Non-Steam Game) so Steam turns it into a gamepad.", HORIZONTAL_ALIGNMENT_CENTER, vs.x, 20, Color(1, 1, 1, 0.7))

func _draw_game_over(vs: Vector2) -> void:
	var sim: GameSim = m.sim
	var over: int = sim.st.over
	var win: int = sim.st.winner
	var pal: Dictionary = FighterArt.PALETTES[win]
	if over < 150:
		var k = clampf(over / 12.0, 0, 1)
		var sz = int(lerpf(260, 170, k))
		_text(font_big, Vector2(0, vs.y * 0.5 + 60), "GAME!", HORIZONTAL_ALIGNMENT_CENTER, vs.x, sz, Color.WHITE, 18)
		return
	draw_rect(Rect2(Vector2.ZERO, vs), Color(0.03, 0.02, 0.07, 0.86))
	var who = m.player_tag(win)
	_text(font_big, Vector2(0, 260), ("YOU WIN!" if who == "YOU" else "%s WINS" % who), HORIZONTAL_ALIGNMENT_CENTER, vs.x, 130, pal.main, 16)
	_text(font_ui, Vector2(0, 330), "JUNO, the Courier", HORIZONTAL_ALIGNMENT_CENTER, vs.x, 30, Color(1, 1, 1, 0.7))
	for i in 2:
		var f: Dictionary = sim.st.f[i]
		var x = vs.x * (0.3 if i == 0 else 0.55)
		var tag = m.player_tag(i)
		var pc: Dictionary = FighterArt.PALETTES[i]
		_text(font_big, Vector2(x, 460), tag, HORIZONTAL_ALIGNMENT_LEFT, 400, 56, pc.main, 8)
		_text(font_ui, Vector2(x, 520), "KOs: %d" % f.kos, HORIZONTAL_ALIGNMENT_LEFT, 400, 32, Color.WHITE)
		_text(font_ui, Vector2(x, 562), "Longest combo: %d hits" % f.best_combo, HORIZONTAL_ALIGNMENT_LEFT, 400, 32, Color.WHITE)
		_text(font_ui, Vector2(x, 604), "Stocks left: %d" % maxi(0, f.stocks), HORIZONTAL_ALIGNMENT_LEFT, 400, 32, Color.WHITE)
	var blink = 0.6 + 0.4 * sin(m.t * 4.0)
	if m.online:
		var left = maxi(0, (sim.auto_rematch - over) / 60 + 1)
		_text(font_ui, Vector2(0, 760), "Rematch in %d..." % left, HORIZONTAL_ALIGNMENT_CENTER, vs.x, 34, Color(1, 1, 1, blink))
	else:
		_text(font_ui, Vector2(0, 760), "Press B / K to play again", HORIZONTAL_ALIGNMENT_CENTER, vs.x, 34, Color(1, 1, 1, blink))
