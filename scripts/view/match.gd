extends Node2D
## Runs a local match: feeds input into the sim at a fixed 60 Hz, turns sim
## events into game feel (hitstop, sparks, shake, rumble, sound, popups),
## and draws the world. The HUD and background are separate nodes.

const U := FX.U
const STYLE_GRADES := [[0, "D"], [350, "C"], [800, "B"], [1500, "A"], [2500, "S"], [3800, "SS"], [5500, "SSS"]]
const DUMMY_MODES := ["DUMMY: STAND", "DUMMY: ESCAPE ARTIST", "DUMMY: SHIELD", "CPU OPPONENT"]

var sim = GameSim.new()
var cam = Camera2D.new()
var hud: Control
var bg: Control
var t = 0.0
var paused = false
var pause_sel = 0
var dummy_mode = 3
var cpu0 = Cpu.new()
var cpu1 = Cpu.new()
var dummy_rng = RandomNumberGenerator.new()
var dummy_mem = {"di": 0, "tech": true, "act": 0}

# Feel state (presentation only)
var particles: Array = []
var popups: Array = []
var trails = [[], []]
var ball_trails = [[], []]
var shake = 0.0
var punch = 0.0
var flash = 0.0
var flash_col = Color.WHITE
var impact = 0
var impact_pos = Vector2.ZERO
var focus_t = 0.0
var cam_pos = Vector2(0, -200)
var cam_zoom = 1.0
var last_move = ["", ""]
var combo_ui = [{}, {}]     # live combo display per attacker
var summaries: Array = []    # combo summary cards
var pct_shake = [0.0, 0.0]
var results_shown = false
var prev_menu_bits = [0, 0, 0]
var autoplay := false

func _ready() -> void:
	dummy_rng.randomize()
	add_child(cam)
	cam.make_current()
	cam.position_smoothing_enabled = false
	var bgl = CanvasLayer.new()
	bgl.layer = -10
	add_child(bgl)
	bg = preload("res://scripts/view/background.gd").new()
	bg.m = self
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bgl.add_child(bg)
	var hl = CanvasLayer.new()
	hl.layer = 10
	add_child(hl)
	hud = preload("res://scripts/view/hud.gd").new()
	hud.m = self
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hl.add_child(hud)
	InputRouter.toast.connect(func(s): popup_screen(s, Color("b9f3ff")))
	restart()

func restart() -> void:
	sim.reset(3)
	particles.clear()
	popups.clear()
	summaries.clear()
	combo_ui = [{}, {}]
	results_shown = false
	paused = false
	trails = [[], []]
	ball_trails = [[], []]

func p2_is_dummy() -> bool:
	return InputRouter.slots[1] == ""

# =====================================================================
# Fixed-rate simulation
# =====================================================================
func _physics_process(_dt: float) -> void:
	InputRouter.poll_joins(not paused)
	if InputRouter.slots[0] == "" and InputRouter.slots[1] != "":
		InputRouter.slots[0] = InputRouter.slots[1]
		InputRouter.slots[1] = ""
	var b0 = InputRouter.bits_for_slot(0)
	var b1 = InputRouter.bits_for_slot(1)
	if _menu_input(b0, b1):
		return
	if paused:
		return
	if sim.st.winner >= 0 and sim.st.over > 150:
		results_shown = true
		return
	if p2_is_dummy():
		b1 = _dummy_input()
	if autoplay:
		b0 = cpu0.think(sim, 0)
	sim.step([b0 & ~Inp.START, b1 & ~Inp.START])
	for e in sim.events:
		_on_event(e)
	_track_swings()

func _menu_input(b0: int, b1: int) -> bool:
	var press0: int = b0 & ~prev_menu_bits[0]
	var press1: int = b1 & ~prev_menu_bits[1]
	prev_menu_bits[0] = b0
	prev_menu_bits[1] = b1
	var press = press0 | press1
	if results_shown:
		if press & (Inp.ATTACK | Inp.START | Inp.JUMP):
			Sfx.play("select")
			restart()
		return true
	if press & Inp.START:
		paused = not paused
		pause_sel = 0
		Sfx.play("menu")
		return true
	if paused:
		if press & Inp.UP:
			pause_sel = posmod(pause_sel - 1, 4)
			Sfx.play("menu")
		if press & Inp.DOWN:
			pause_sel = posmod(pause_sel + 1, 4)
			Sfx.play("menu")
		if press & Inp.SPECIAL:
			paused = false
		if press & (Inp.ATTACK | Inp.JUMP) or ((press & (Inp.LEFT | Inp.RIGHT)) and pause_sel == 2):
			Sfx.play("select")
			match pause_sel:
				0: paused = false
				1: restart()
				2:
					var dirn = -1 if press & Inp.LEFT else 1
					dummy_mode = posmod(dummy_mode + dirn, DUMMY_MODES.size())
				3: get_tree().quit()
		return true
	return false

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo:
		if ev.physical_keycode == KEY_F11 or (ev.physical_keycode == KEY_ENTER and ev.alt_pressed):
			var w = get_window()
			w.mode = Window.MODE_WINDOWED if w.mode == Window.MODE_FULLSCREEN else Window.MODE_FULLSCREEN
		elif ev.physical_keycode == KEY_F2:
			dummy_mode = (dummy_mode + 1) % DUMMY_MODES.size()
			popup_screen("Dummy: " + DUMMY_MODES[dummy_mode], Color.WHITE)
		elif ev.physical_keycode == KEY_F5:
			restart()

func _track_swings() -> void:
	for f in sim.st.f:
		var mv: String = f.move if f.state == GameSim.S_ATTACK else ""
		if mv != "" and (mv != last_move[f.id] or f.mf == 1):
			if f.mf <= 1:
				var ty: String = sim.moves[mv].type
				var pitch = 1.3 if ty == "jab" else (0.8 if ty == "smash" else 1.0)
				Sfx.play("swing", pitch + randf() * 0.1, -6.0)
		last_move[f.id] = mv

# =====================================================================
# Training dummy / sparring CPU (local only, never in netplay)
# =====================================================================
func _dummy_input() -> int:
	var d: Dictionary = sim.st.f[1]
	var me: Dictionary = sim.st.f[0]
	var s: int = d.state
	var bits = 0
	match dummy_mode:
		3:
			return cpu1.think(sim, 1)
		0:
			return 0
		2:
			return Inp.SHIELD if d.ground else 0
	# Escape behaviour (modes 1 & 3)
	if s == GameSim.S_HITSTUN or s == GameSim.S_HOOKED or s == GameSim.S_GRABBED:
		if d.sf == 1 or dummy_mem.di == 0:
			dummy_mem.di = [Inp.LEFT, Inp.RIGHT, Inp.UP, Inp.UP | Inp.LEFT, Inp.UP | Inp.RIGHT, 0][dummy_rng.randi() % 6]
			dummy_mem.tech = dummy_rng.randf() < 0.65
		bits |= dummy_mem.di
		if d.burst >= GameSim.BURST_MAX and d.combo >= 7 + dummy_rng.randi() % 6 and dummy_rng.randf() < 0.08:
			bits |= Inp.BURST
		if s == GameSim.S_GRABBED and sim.st.frame % 3 == 0:
			bits |= Inp.JUMP
		if dummy_mem.tech and d.tumble and d.vy > 0 and d.y > -90 * U:
			if sim.st.frame % 2 == 0:
				bits |= Inp.SHIELD
		return bits
	dummy_mem.di = 0
	if dummy_mode != 3:
		return 0
	# Sparring CPU: simple but keeps you honest.
	var dx: int = me.x - d.x
	var adx = absi(dx) / U
	var dir = Inp.RIGHT if dx > 0 else Inp.LEFT
	if not d.ground and d.y > 40 * U:
		bits |= Inp.UP | Inp.SPECIAL if dummy_rng.randf() < 0.3 else Inp.JUMP
		bits |= Inp.LEFT if d.x > 0 else Inp.RIGHT
		return bits
	if absi(d.x) > 560 * U:
		return Inp.LEFT if d.x > 0 else Inp.RIGHT
	var r = dummy_rng.randf()
	if me.state == GameSim.S_ATTACK and adx < 120 and r < 0.12:
		return Inp.SHIELD
	if adx > 320:
		if r < 0.03 and sim.st.b[1].st == GameSim.B_HELD:
			return Inp.BALL
		return dir
	if adx < 90:
		if r < 0.18:
			return [Inp.ATTACK, Inp.ATTACK | Inp.UP, Inp.ATTACK | Inp.DOWN, Inp.GRAB, Inp.ATTACK | dir][dummy_rng.randi() % 5]
		if r < 0.22:
			return Inp.JUMP
		return 0
	if r < 0.04:
		return Inp.JUMP
	if r < 0.06:
		return Inp.SPECIAL | dir
	return dir

# =====================================================================
# Events -> game feel
# =====================================================================
func w(x: int, y: int) -> Vector2:
	return Vector2(float(x) / U, float(y) / U)

func pal(id: int) -> Dictionary:
	return FighterArt.PALETTES[id]

func _on_event(e: Dictionary) -> void:
	var p = w(e.get("x", 0), e.get("y", 0))
	match e.t:
		"hit":
			_on_hit(e, p)
		"hook":
			_on_hit(e, p)
			Sfx.play("hook", 1.0 + mini(e.combo, 20) * 0.02)
			_ring(p, 26, 90, pal(e.a).visor, 16, 4)
			popup_world(p + Vector2(0, -40), "HOOKED!", pal(e.a).visor, 34)
			_chain_sparks(p, pal(e.a).visor)
		"release":
			Sfx.play("release")
			_ring(p + Vector2(0, -40), 10, 60, pal(e.a).visor, 12, 3)
		"toss":
			Sfx.play("toss")
		"recall":
			Sfx.play("recall")
		"catch":
			Sfx.play("catch", 1.0, -4.0)
			_ring(p, 8, 30, pal(e.id).accent, 8, 2)
		"bounce":
			Sfx.play("land", 1.6, -8.0)
		"parry":
			Sfx.play("parry")
			_ring(p, 20, 150, Color.WHITE, 22, 6)
			_flash(Color(1, 1, 1), 0.35)
			popup_world(p + Vector2(0, -50), "PARRY!", Color("fffbe0"), 46)
			_impact(p, 3)
			shake += 0.25
			InputRouter.rumble(e.id, 0.6, 0.2, 0.15)
		"shield":
			Sfx.play("shield", 1.0 + randf() * 0.1)
			_sparks(p, 6, Color("9fe7ff"), 0.0, PI, 6.0)
		"break":
			Sfx.play("break")
			popup_world(p + Vector2(0, -60), "SHIELD BREAK!", Color("ff5d73"), 44)
			_ring(p, 20, 140, Color("9fe7ff"), 24, 5)
			shake += 0.5
		"burst":
			Sfx.play("burst")
			var bc: Color = pal(e.id).glow
			_ring(p, 30, 200, bc, 26, 10)
			_ring(p, 10, 160, Color.WHITE, 18, 4)
			_sparks(p, 28, bc, 0.0, TAU, 18.0)
			_flash(bc, 0.45)
			_impact(p, 4)
			shake += 0.7
			popup_world(p + Vector2(0, -90), "BURST!", bc.lightened(0.4), 64)
			InputRouter.rumble(e.id, 0.8, 0.8, 0.35)
			if e.broke:
				combo_ui[1 - e.id]["broken"] = 1.0
		"bursthit":
			InputRouter.rumble(e.v, 0.5, 1.0, 0.3)
			_sparks(p, 16, pal(e.a).glow, 0.0, TAU, 14.0)
		"baited":
			Sfx.play("parry", 0.7)
			popup_world(p, "BAITED!", Color("fff275"), 52)
		"ko":
			_on_ko(e, p)
		"combo_end":
			_on_combo_end(e)
		"tech":
			Sfx.play("tech")
			popup_world(p + Vector2(0, -100), "TECH!", Color("b3ffcb"), 32)
			_ring(p + Vector2(0, -10), 10, 70, Color("b3ffcb"), 12, 3)
		"knockdown":
			Sfx.play("land", 0.7)
			_dust(p, 10)
			shake += 0.12
		"jump", "djump":
			Sfx.play("jump", 1.0 if e.t == "jump" else 1.3, -6.0)
			_dust(p, 4 if e.t == "jump" else 0)
			if e.t == "djump":
				_ring(p + Vector2(0, -6), 8, 46, Color(1, 1, 1, 0.8), 10, 3)
		"land":
			Sfx.play("land", 1.0, -10.0)
			_dust(p, 3)
		"stomp":
			Sfx.play("hit_heavy", 0.8)
			_dust(p, 14)
			_ring(p, 10, 120, pal(e.id).accent, 14, 5)
			shake += 0.3
		"grab":
			Sfx.play("grab")
		"pummel":
			Sfx.play("hit_light", 1.3, -6.0)
			_sparks(p, 4, Color.WHITE, 0.0, TAU, 5.0)
		"escape":
			popup_world(p, "ESCAPE", Color.WHITE, 30)

func _on_hit(e: Dictionary, p: Vector2) -> void:
	var dmg = float(e.d) / 10.0
	var a: int = e.a
	var v: int = e.v
	var combo: int = e.combo
	var col: Color = pal(a).glow
	var big: bool = e.big
	var heavy = dmg >= 10.0 or big
	# Sound: impact + a musical note that climbs with the combo
	if big:
		Sfx.play("hit_big")
	elif dmg >= 10.0:
		Sfx.play("hit_heavy", 1.0 + randf() * 0.05)
	elif dmg >= 5.0:
		Sfx.play("hit_mid", 1.0 + randf() * 0.08)
	else:
		Sfx.play("hit_light", 1.0 + randf() * 0.1)
	if combo >= 2:
		Sfx.play("note", Sfx.combo_pitch(combo), lerpf(-14.0, -2.0, clampf(combo / 20.0, 0, 1)))
	# Sparks along the launch direction
	var ang = -deg_to_rad(float(e.get("ang", 90)))
	var n = int(6 + dmg * 1.4 + mini(combo, 20) * 0.6)
	_sparks(p, n, col.lightened(0.3), ang, 0.9, 10.0 + dmg)
	_sparks(p, n / 2, Color.WHITE, ang, 0.5, 14.0 + dmg)
	_ring(p, 8, 30 + dmg * 5, Color.WHITE, 8 + int(dmg * 0.6), 3 + dmg * 0.3)
	_star(p, 30 + dmg * 3.5, col)
	# Screen feel
	shake += 0.08 + dmg * 0.022 + mini(combo, 30) * 0.004
	punch = minf(0.12, punch + 0.012 + dmg * 0.004)
	pct_shake[v] = 1.0
	if big:
		_flash(Color.WHITE, 0.4)
		_impact(p, 4)
		shake += 0.5
	elif combo in [10, 15, 20, 25, 30, 40, 50]:
		_impact(p, 3)
		_flash(col, 0.25)
		popup_world(p + Vector2(0, -70), "%d HITS!" % combo, col.lightened(0.5), 50)
	if heavy:
		focus_t = 0.18
		impact_pos = p
	# Rumble
	InputRouter.rumble(a, 0.15 + dmg * 0.02, 0.05 + dmg * 0.015, 0.08 + dmg * 0.006)
	InputRouter.rumble(v, 0.3 + dmg * 0.03, 0.3 + dmg * 0.05, 0.1 + dmg * 0.012)
	# Combo UI
	var mname: String = sim.moves[e.move].name if e.move != "ball" else "Comet Hook"
	var cu: Dictionary = combo_ui[a]
	cu["count"] = combo
	cu["pop"] = 1.0
	cu["dmg"] = sim.st.f[v].combo_dmg
	cu["style"] = sim.st.f[v].style
	cu["alive"] = true
	cu["broken"] = 0.0
	cu["fade"] = 1.0
	var feed: Array = cu.get("feed", [])
	if combo == 1:
		feed = []
	if e.fresh:
		feed.push_front({"text": "+ " + mname, "col": Color("8dffb0"), "t": 1.0, "tag": "NEW"})
		Sfx.play("new", 1.0 + mini(combo, 20) * 0.03, -10.0)
		popup_world(p + Vector2(0, -30), "NEW!", Color("8dffb0"), 26)
	elif e.rep > 0 and combo > 1:
		feed.push_front({"text": "%s  x%d" % [mname, e.rep + 1], "col": Color("9a93a8"), "t": 1.0, "tag": "STALE"})
		Sfx.play("stale", 1.0, -8.0)
		popup_world(p + Vector2(0, -30), "STALE", Color("9a93a8"), 22)
	elif combo > 1:
		feed.push_front({"text": mname, "col": Color.WHITE, "t": 1.0, "tag": ""})
	if feed.size() > 6:
		feed.resize(6)
	cu["feed"] = feed

func _on_ko(e: Dictionary, p: Vector2) -> void:
	Sfx.play("ko")
	var killer: int = 1 - e.id
	var col: Color = pal(killer).glow
	_flash(Color.WHITE, 0.8)
	_impact(p, 8)
	shake += 1.2
	var inward = (Vector2(0, -300) - p).normalized()
	for i in 40:
		var a = inward.angle() + randf_range(-0.6, 0.6)
		particles.append({"p": p, "v": Vector2.from_angle(a) * randf_range(12, 40), "life": 50.0, "max": 50.0,
			"col": col.lerp(Color.WHITE, randf() * 0.6), "size": randf_range(4, 10), "kind": 0})
	_ring(p, 40, 420, col, 40, 14)
	_ring(p, 20, 260, Color.WHITE, 30, 8)
	var txt = "K.O.!"
	if e.combo >= 5:
		txt = "%d-HIT KO!" % e.combo
	popup_screen(txt, col.lightened(0.5), 110)
	InputRouter.rumble(e.id, 1.0, 1.0, 0.6)
	InputRouter.rumble(killer, 0.8, 0.6, 0.4)

func _on_combo_end(e: Dictionary) -> void:
	var a: int = e.a
	var cu: Dictionary = combo_ui[a]
	cu["alive"] = false
	if e.combo >= 3:
		var grade = style_grade(e.style)
		summaries.append({"a": a, "combo": e.combo, "dmg": e.dmg, "grade": grade, "t": 0.0,
			"burst": e.burst, "ko": e.ko})
		if e.combo >= 6 and not e.burst:
			Sfx.play("finish", 0.85 + minf(e.combo, 30) * 0.012, -4.0)
		if e.burst:
			cu["broken"] = 1.0

func style_grade(style: int) -> String:
	var g = "D"
	for row in STYLE_GRADES:
		if style >= row[0]:
			g = row[1]
	return g

# =====================================================================
# Effect helpers
# =====================================================================
func _sparks(p: Vector2, n: int, col: Color, ang: float, spread: float, spd: float) -> void:
	for i in n:
		var a = ang + randf_range(-spread, spread)
		particles.append({"p": p, "v": Vector2.from_angle(a) * spd * randf_range(0.4, 1.3), "life": randf_range(12, 26),
			"max": 26.0, "col": col, "size": randf_range(3, 7), "kind": 0})

func _ring(p: Vector2, r0: float, r1: float, col: Color, life: int, width: float) -> void:
	particles.append({"p": p, "r0": r0, "r1": r1, "life": float(life), "max": float(life), "col": col, "size": width, "kind": 1})

func _star(p: Vector2, r: float, col: Color) -> void:
	particles.append({"p": p, "r0": r, "life": 7.0, "max": 7.0, "col": col, "rot": randf() * TAU, "kind": 3})

func _dust(p: Vector2, n: int) -> void:
	for i in n + 3:
		var dir = -1.0 if i % 2 == 0 else 1.0
		particles.append({"p": p + Vector2(randf_range(-10, 10), -4), "v": Vector2(dir * randf_range(1.5, 5), -randf_range(0.2, 1.5)),
			"life": randf_range(16, 30), "max": 30.0, "col": Color(0.95, 0.9, 1.0, 0.55), "size": randf_range(6, 12), "kind": 2})

func _chain_sparks(p: Vector2, col: Color) -> void:
	_sparks(p, 14, col, 0.0, TAU, 9.0)

func _flash(col: Color, amount: float) -> void:
	flash = maxf(flash, amount)
	flash_col = col

func _impact(p: Vector2, frames: int) -> void:
	impact = maxi(impact, frames)
	impact_pos = p

func popup_world(p: Vector2, text: String, col: Color, size: int) -> void:
	popups.append({"p": p, "text": text, "col": col, "size": size, "t": 0.0, "world": true})

func popup_screen(text: String, col: Color, size: int = 30) -> void:
	popups.append({"p": Vector2.ZERO, "text": text, "col": col, "size": size, "t": 0.0, "world": false})

# =====================================================================
# Per-frame presentation update
# =====================================================================
func _process(dt: float) -> void:
	t += dt
	var k = dt * 60.0
	for pa in particles:
		pa.life -= k
		if pa.has("v"):
			pa.p += pa.v * k
			if pa.kind == 0:
				pa.v *= pow(0.86, k)
			elif pa.kind == 2:
				pa.v *= pow(0.92, k)
				pa.p.y -= 0.3 * k
	particles = particles.filter(func(pa): return pa.life > 0)
	for pp in popups:
		pp.t += dt
	popups = popups.filter(func(pp): return pp.t < (1.6 if pp.world else 2.2))
	for s in summaries:
		s.t += dt
	summaries = summaries.filter(func(s): return s.t < 3.2)
	for i in 2:
		var cu: Dictionary = combo_ui[i]
		if cu.has("pop"):
			cu.pop = maxf(0.0, cu.pop - dt * 5.0)
		if cu.get("alive", false) == false and cu.has("fade"):
			cu.fade = maxf(0.0, cu.fade - dt * 1.2)
		if cu.has("broken"):
			cu.broken = maxf(0.0, cu.broken - dt * 0.5)
		for fd in cu.get("feed", []):
			fd.t = maxf(0.0, fd.t - dt * 0.35)
		pct_shake[i] = maxf(0.0, pct_shake[i] - dt * 4.0)
	shake = minf(shake, 1.5)
	shake = maxf(0.0, shake - dt * 2.6)
	punch = maxf(0.0, punch - dt * 0.6)
	flash = maxf(0.0, flash - dt * 3.5)
	focus_t = maxf(0.0, focus_t - dt)
	if impact > 0 and Engine.get_physics_frames() % 1 == 0:
		impact -= 1
	_update_trails()
	_update_camera(dt)
	queue_redraw()
	hud.queue_redraw()
	bg.queue_redraw()

func _update_trails() -> void:
	for f in sim.st.f:
		var tr: Array = trails[f.id]
		if f.state == GameSim.S_ATTACK and f.has("_strike_pos"):
			tr.push_front(f["_strike_pos"])
		elif tr.size() > 0:
			tr.pop_back()
		if tr.size() > 7:
			tr.resize(7)
	for b in sim.st.b:
		var bt: Array = ball_trails[b.owner]
		if b.st != GameSim.B_HELD:
			bt.push_front(w(b.x, b.y))
		elif bt.size() > 0:
			bt.pop_back()
			if bt.size() > 0:
				bt.pop_back()
		if bt.size() > 14:
			bt.resize(14)

func _update_camera(dt: float) -> void:
	var pts = []
	for f in sim.st.f:
		if f.state != GameSim.S_DEAD:
			pts.append(w(f.x, f.y - 46 * U))
	for b in sim.st.b:
		if b.st == GameSim.B_OUT or b.st == GameSim.B_RETURN:
			pts.append(w(b.x, b.y))
	if pts.is_empty():
		pts.append(Vector2(0, -150))
	var mn: Vector2 = pts[0]
	var mx: Vector2 = pts[0]
	for q in pts:
		mn = Vector2(minf(mn.x, q.x), minf(mn.y, q.y))
		mx = Vector2(maxf(mx.x, q.x), maxf(mx.y, q.y))
	var center = (mn + mx) * 0.5 + Vector2(0, -40)
	var vs = get_viewport_rect().size
	var need_w = maxf(mx.x - mn.x + 700.0, 1000.0)
	var need_h = maxf(mx.y - mn.y + 520.0, 560.0)
	var z = clampf(minf(vs.x / need_w, vs.y / need_h), 0.62, 1.55)
	center.x = clampf(center.x, -900, 900)
	center.y = clampf(center.y, -650, 150)
	var lerpk = 1.0 - pow(0.004, dt)
	cam_pos = cam_pos.lerp(center, lerpk)
	cam_zoom = lerpf(cam_zoom, z, lerpk * 0.8)
	var zz = cam_zoom * (1.0 + punch)
	var cp = cam_pos
	if focus_t > 0.0:
		cp = cp.lerp(impact_pos, 0.18)
		zz *= 1.0 + focus_t * 0.5
	var sh = shake * shake
	cam.offset = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * sh * 26.0
	cam.position = cp
	cam.zoom = Vector2(zz, zz)

# =====================================================================
# World drawing
# =====================================================================
func _draw() -> void:
	var impacting = impact > 0
	if impacting:
		# Anime-style impact frame: black world, white silhouettes.
		draw_rect(Rect2(cam.position - Vector2(6000, 6000), Vector2(12000, 12000)), Color("07050c"))
	_draw_stage(impacting)
	for b in sim.st.b:
		_draw_ball_tether(b)
	for f in sim.st.f:
		_draw_fighter(f, impacting)
	for b in sim.st.b:
		_draw_ball(b, impacting)
	_draw_particles()
	_draw_world_popups()

func _draw_stage(sil: bool) -> void:
	var x0 = float(StageHalo.MAIN_X0)
	var x1 = float(StageHalo.MAIN_X1)
	var bot = float(StageHalo.MAIN_BOTTOM)
	if sil:
		draw_line(Vector2(x0, 0), Vector2(x1, 0), Color(1, 1, 1, 0.9), 4)
		for pl in StageHalo.PLATFORMS:
			draw_line(Vector2(pl[0], pl[2]), Vector2(pl[1], pl[2]), Color(1, 1, 1, 0.6), 3)
		return
	# Underside: tapered crystal hull
	var hull = PackedVector2Array([Vector2(x0 - 20, 0), Vector2(x1 + 20, 0), Vector2(x1 - 40, 70), Vector2(x1 - 180, bot - 40),
		Vector2(140, bot + 60), Vector2(-140, bot + 60), Vector2(x0 + 180, bot - 40), Vector2(x0 + 40, 70)])
	draw_colored_polygon(hull, Color("1b1533"))
	var inner = PackedVector2Array([Vector2(x0 + 30, 18), Vector2(x1 - 30, 18), Vector2(x1 - 70, 70), Vector2(x1 - 200, bot - 50),
		Vector2(120, bot + 36), Vector2(-120, bot + 36), Vector2(x0 + 200, bot - 50), Vector2(x0 + 70, 70)])
	draw_colored_polygon(inner, Color("2a2150"))
	# Glowing seams
	var glow = Color(0.55, 0.85, 1.0, 0.35 + 0.1 * sin(t * 2.0))
	for i in 7:
		var xx = lerpf(x0 + 120, x1 - 120, i / 6.0)
		draw_line(Vector2(xx, 24), Vector2(xx * 0.3, bot + 20), glow, 2)
	draw_circle(Vector2(0, bot + 10), 26, Color("6ff7ff", 0.25 + 0.1 * sin(t * 3)))
	draw_circle(Vector2(0, bot + 10), 12, Color("dffcff"))
	# Halo ring under the stage
	var ring_c = Color("ffd166", 0.55)
	draw_arc(Vector2(0, bot + 30), 260, 0.15, PI - 0.15, 48, ring_c, 5)
	# Deck
	draw_rect(Rect2(x0 - 20, -4, x1 - x0 + 40, 24), Color("3a2f6b"))
	draw_rect(Rect2(x0 - 20, -6, x1 - x0 + 40, 8), Color("cfc4ff"))
	draw_line(Vector2(x0 - 20, -6), Vector2(x1 + 20, -6), Color("ffffff"), 2)
	for i in 21:
		var xx = lerpf(x0, x1, i / 20.0)
		draw_line(Vector2(xx, 4), Vector2(xx, 18), Color("251d47"), 2)
	# Edge lights
	for xx in [x0 - 14, x1 + 14]:
		draw_circle(Vector2(xx, 6), 7, Color("ff6b9d"))
		draw_circle(Vector2(xx, 6), 14, Color("ff6b9d", 0.25))
	# Platforms
	for pl in StageHalo.PLATFORMS:
		var a = Vector2(pl[0], pl[2])
		var b = Vector2(pl[1], pl[2])
		draw_line(a + Vector2(0, 6), b + Vector2(0, 6), Color("6ff7ff", 0.18), 18)
		draw_line(a, b, Color("6ff7ff", 0.9), 5)
		draw_line(a + Vector2(6, 6), b + Vector2(-6, 6), Color("2a2150"), 6)
		draw_circle(a, 5, Color("dffcff"))
		draw_circle(b, 5, Color("dffcff"))

func _draw_fighter(f: Dictionary, sil: bool) -> void:
	if f.state == GameSim.S_DEAD:
		return
	var p = FighterArt.pose(f, sim, t)
	var origin = w(f.x, f.y)
	var pl = pal(f.id)
	if f.hitlag > 0 and f.state in [GameSim.S_HITSTUN, GameSim.S_HOOKED]:
		origin.x += sin(t * 90.0) * minf(f.hitlag, 10) * 0.9
	# Respawn halo platform
	if f.state == GameSim.S_RESPAWN:
		draw_line(origin + Vector2(-50, 4), origin + Vector2(50, 4), Color(pl.accent, 0.9), 6)
		draw_arc(origin + Vector2(0, 4), 52, PI + 0.3, TAU - 0.3, 20, Color(pl.accent, 0.4), 3)
	# Shield bubble
	if f.state == GameSim.S_SHIELD or f.state == GameSim.S_SHIELDSTUN:
		var r = 30.0 + 34.0 * float(f.shield) / 1000.0
		var sc: Color = pl.visor
		sc.a = 0.32
		var parry: bool = f.state == GameSim.S_SHIELD and f.sf <= GameSim.PARRY_WINDOW
		if parry:
			sc = Color(1, 1, 1, 0.65)
		draw_circle(origin + Vector2(0, -46), r, sc)
		draw_arc(origin + Vector2(0, -46), r, 0, TAU, 40, Color(sc, 0.9), 3)
	# Burst aura
	if f.state == GameSim.S_BURST:
		var k = clampf(f.sf / 10.0, 0, 1)
		draw_circle(origin + Vector2(0, -46), 175 * k, Color(pl.glow, 0.18 * (1.0 - k) + 0.05))
	# Full burst meter shimmer
	if f.burst >= GameSim.BURST_MAX and not sil:
		draw_arc(origin + Vector2(0, -46), 62, t * 3.0, t * 3.0 + 1.2, 16, Color(pl.glow, 0.6), 3)
		draw_arc(origin + Vector2(0, -46), 62, t * 3.0 + PI, t * 3.0 + PI + 1.2, 16, Color(pl.glow, 0.6), 3)
	# Smash charge glow
	if f.state == GameSim.S_ATTACK and f.charge > 0 and sim.moves[f.move].has("charge") and f.mf == sim.moves[f.move].charge:
		var ck = f.charge / 60.0
		draw_circle(origin + Vector2(0, -46), 50 + 20 * ck, Color(1, 1, 0.7, 0.12 + 0.12 * sin(t * 40.0)))
	# Hooked victim glow
	if f.state == GameSim.S_HOOKED:
		draw_circle(origin + Vector2(0, -46), 58, Color(pal(1 - f.id).visor, 0.22))
	# Attack trail (motion smear)
	var tr: Array = trails[f.id]
	if tr.size() >= 2 and not sil:
		for i in tr.size() - 1:
			var a = 1.0 - float(i) / tr.size()
			draw_line(tr[i], tr[i + 1], Color(pl.accent, 0.55 * a), 22.0 * a + 4.0)
	var silc = Color(1, 1, 1, 1) if sil else Color(0, 0, 0, 0)
	var joints = FighterArt.draw(self, f, p, origin, pl, t, silc)
	if p.strike != "" and joints.has(p.strike):
		f["_strike_pos"] = joints[p.strike]
	# Player tag
	if not sil:
		var tag = "P%d" % (f.id + 1)
		if f.id == 1 and p2_is_dummy():
			tag = "CPU"
		var tp = origin + Vector2(0, -132 if f.state != GameSim.S_KNOCKDOWN else -70)
		draw_colored_polygon(PackedVector2Array([tp + Vector2(-8, 8), tp + Vector2(8, 8), tp + Vector2(0, 16)]), pl.main)
		draw_string(hud.font_ui, tp + Vector2(-30, 4), tag, HORIZONTAL_ALIGNMENT_CENTER, 60, 22, pl.main)

func _draw_ball_tether(b: Dictionary) -> void:
	if b.st != GameSim.B_HOOK:
		return
	var o: Dictionary = sim.st.f[b.owner]
	var a = w(o.x, o.y - 50 * U)
	var c = w(b.x, b.y)
	var col: Color = pal(b.owner).visor
	var pts = PackedVector2Array()
	for i in 13:
		var k = i / 12.0
		var q = a.lerp(c, k)
		q += Vector2(0, sin(k * PI * 3.0 + t * 30.0) * 8.0 * sin(k * PI))
		pts.append(q)
	draw_polyline(pts, Color(col, 0.35), 12.0, true)
	draw_polyline(pts, Color(col.lightened(0.5), 0.95), 3.0, true)

func _draw_ball(b: Dictionary, sil: bool) -> void:
	var o: Dictionary = sim.st.f[b.owner]
	if o.state == GameSim.S_DEAD:
		return
	var p = w(b.x, b.y)
	var pl = pal(b.owner)
	var col: Color = pl.visor
	if sil:
		draw_circle(p, GameSim.BALL_R, Color.WHITE)
		return
	var bt: Array = ball_trails[b.owner]
	for i in bt.size() - 1:
		var a = 1.0 - float(i) / bt.size()
		draw_line(bt[i], bt[i + 1], Color(col, 0.5 * a), GameSim.BALL_R * 1.6 * a + 2.0)
	var held: bool = b.st == GameSim.B_HELD
	var cd: bool = held and b.cd > 0
	var r = float(GameSim.BALL_R) * (0.7 if held else 1.0)
	var pulse = 0.5 + 0.5 * sin(t * 10.0)
	draw_circle(p, r * 2.0, Color(col, (0.10 if cd else 0.18) + 0.06 * pulse))
	draw_circle(p, r + 3.0, FighterArt.OUTLINE)
	draw_circle(p, r, col.darkened(0.45) if cd else col)
	draw_circle(p + Vector2(-r * 0.3, -r * 0.3), r * 0.45, Color(1, 1, 1, 0.85))
	if not held:
		var spin = t * 18.0
		draw_arc(p, r + 7, spin, spin + 2.2, 12, Color(pl.accent, 0.9), 3)
	if b.st == GameSim.B_DEAD:
		draw_arc(p, r + 10, 0, TAU, 20, Color(1, 1, 1, 0.4), 2)

func _draw_particles() -> void:
	for pa in particles:
		var k: float = pa.life / pa.max
		var c: Color = pa.col
		match int(pa.kind):
			0:
				c.a *= k
				var v: Vector2 = pa.v
				draw_line(pa.p, pa.p - v * 1.6, c, pa.size * k + 1.0)
			1:
				var r: float = lerpf(pa.r0, pa.r1, 1.0 - k * k)
				c.a *= k
				draw_arc(pa.p, r, 0, TAU, 48, c, pa.size * k + 1.0)
			2:
				c.a *= k
				draw_circle(pa.p, pa.size * (1.4 - k * 0.6), c)
			3:
				c.a = k
				var pts = PackedVector2Array()
				for i in 8:
					var rr: float = pa.r0 * (1.0 if i % 2 == 0 else 0.35) * (1.2 - k * 0.4)
					pts.append(pa.p + Vector2.from_angle(pa.rot + i * TAU / 8.0) * rr)
				draw_colored_polygon(pts, c)
				draw_circle(pa.p, pa.r0 * 0.3 * k, Color(1, 1, 1, k))

func _draw_world_popups() -> void:
	for pp in popups:
		if not pp.world:
			continue
		var k: float = pp.t / 1.6
		var rise = -60.0 * _out(k)
		var sc = 1.0 + 0.6 * maxf(0.0, 1.0 - pp.t * 8.0)
		var a = 1.0 - maxf(0.0, (k - 0.6) / 0.4)
		var size = int(pp.size * sc)
		var pos: Vector2 = pp.p + Vector2(-200, rise)
		var c: Color = pp.col
		c.a = a
		draw_string_outline(hud.font_big, pos, pp.text, HORIZONTAL_ALIGNMENT_CENTER, 400, size, 10, Color(FighterArt.OUTLINE, a))
		draw_string(hud.font_big, pos, pp.text, HORIZONTAL_ALIGNMENT_CENTER, 400, size, c)

func _out(k: float) -> float:
	return 1.0 - pow(1.0 - clampf(k, 0, 1), 3)
