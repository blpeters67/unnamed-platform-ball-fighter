class_name FighterArt
## Procedural drawing for JUNO. Poses are built from the sim state every
## frame, using two-bone IK for the limbs. Pure presentation code: it only
## reads the sim and never changes it.

const OUTLINE := Color("120c1e")
const CENTER := Vector2(0, -46)

const PALETTES := [
	{"main": Color("ff6b4a"), "dark": Color("b8392a"), "accent": Color("ffd166"), "scarf": Color("ffe9a8"), "visor": Color("6ff7ff"), "glow": Color("ff9a5a")},
	{"main": Color("37c8d8"), "dark": Color("1f7d9a"), "accent": Color("c59bff"), "scarf": Color("e8dbff"), "visor": Color("ffe36e"), "glow": Color("6fe8ff")},
]

# Which limb strikes for each move, and a wind-up offset for it.
const STRIKE := {
	"jab": ["hand_f", Vector2(4, -56)], "jab2": ["hand_b", Vector2(0, -58)], "jab3": ["foot_f", Vector2(-10, -20)],
	"ftilt": ["foot_f", Vector2(-8, -18)], "utilt": ["hand_f", Vector2(14, -50)], "dtilt": ["foot_f", Vector2(0, -8)],
	"dash": ["foot_f", Vector2(-6, -30)], "fsmash": ["hand_f", Vector2(-30, -60)], "usmash": ["hand_f", Vector2(20, -30)],
	"dsmash": ["foot_f", Vector2(0, -16)], "nair": ["foot_f", Vector2(6, -30)], "fair": ["foot_f", Vector2(-10, -40)],
	"bair": ["foot_b", Vector2(4, -30)], "uair": ["foot_f", Vector2(10, -24)], "dair": ["foot_f", Vector2(8, -40)],
	"nspecial": ["hand_f", Vector2(10, -50)], "sspecial": ["hand_f", Vector2(-10, -56)], "uspecial": ["hand_f", Vector2(10, -40)],
	"dspecial": ["foot_f", Vector2(10, -40)], "dspecial_air": ["foot_f", Vector2(4, -12)], "dspecial_land": ["foot_f", Vector2(6, -6)],
	"grab": ["hand_f", Vector2(10, -52)], "pummel": ["hand_b", Vector2(10, -52)], "fthrow": ["hand_f", Vector2(30, -56)],
	"bthrow": ["hand_f", Vector2(30, -56)], "uthrow": ["hand_f", Vector2(30, -80)], "dthrow": ["hand_f", Vector2(30, -20)],
	"ball_throw": ["hand_f", Vector2(-24, -70)],
}

static func base_pose() -> Dictionary:
	return {"hip": Vector2(0, -42), "neck": Vector2(2, -70), "head": Vector2(4, -86),
		"hand_f": Vector2(20, -58), "hand_b": Vector2(-4, -60), "foot_f": Vector2(11, 0), "foot_b": Vector2(-11, 0),
		"rot": 0.0, "drop": 0.0, "alpha": 1.0, "strike": "", "scarf_lift": 0.0}

static func _ease(k: float) -> float:
	k = clampf(k, 0.0, 1.0)
	return 1.0 - (1.0 - k) * (1.0 - k)

static func _move_target(mv: Dictionary) -> Vector2:
	if mv.has("hb"):
		var h: Dictionary = mv.hb[mv.hb.size() - 1] if mv.type == "special" and mv.hb.size() > 3 else mv.hb[0]
		return Vector2(h.x, h.y)
	if mv.has("grabbox"):
		return Vector2(mv.grabbox.x, mv.grabbox.y)
	return Vector2(40, -60)

static func pose(f: Dictionary, sim: GameSim, t: float) -> Dictionary:
	var p = base_pose()
	var s: int = f.state
	var sf: int = f.sf
	var breath = sin(t * 3.0 + f.id) * 1.5
	match s:
		GameSim.S_IDLE:
			p.neck.y += breath
			p.head.y += breath
			p.hand_f.y += breath * 0.6
		GameSim.S_WALK:
			var ph = float(f.x) / (FX.U * 22.0) * f.face
			p.foot_f = Vector2(sin(ph) * 17, -maxf(0, cos(ph)) * 9)
			p.foot_b = Vector2(-sin(ph) * 17, -maxf(0, -cos(ph)) * 9)
			p.hand_f = Vector2(14 - sin(ph) * 10, -56)
			p.hand_b = Vector2(-6 + sin(ph) * 10, -56)
			p.neck.x += 5
			p.head.x += 7
			p.hip.y += absf(sin(ph)) * -2
		GameSim.S_DASH, GameSim.S_RUN:
			var ph = float(f.x) / (FX.U * 30.0) * f.face
			p.foot_f = Vector2(sin(ph) * 24 + 6, -maxf(0, cos(ph)) * 16)
			p.foot_b = Vector2(-sin(ph) * 24 + 6, -maxf(0, -cos(ph)) * 16)
			p.hand_f = Vector2(4 - sin(ph) * 14, -54)
			p.hand_b = Vector2(-20 + sin(ph) * 14, -60)
			p.neck.x += 14
			p.head.x += 18
			p.neck.y += 4
			p.head.y += 4
			p.scarf_lift = 0.6
			if f.state == GameSim.S_DASH and f.sf <= 3:
				p.neck.x += 6
				p.head.x += 6
		GameSim.S_LEDGE:
			p.hand_f = Vector2(30, -96)
			p.hand_b = Vector2(24, -98)
			p.foot_f = Vector2(6, 0 + sin(t * 3.0) * 2)
			p.foot_b = Vector2(-6, -4)
			p.neck.x += 4
			p.head.x += 2
		GameSim.S_GRAPPLE:
			p.hand_f = Vector2(40, -84)
			p.hand_b = Vector2(30, -80)
			p.foot_f = Vector2(0, -10)
			p.foot_b = Vector2(-14, -16)
			p.scarf_lift = -0.6
		GameSim.S_LEDGE_GETUP:
			_crouch(p, 1.0 - clampf(f.sf / 12.0, 0, 1))
			p.hand_f = Vector2(26, -60)
		GameSim.S_SKID:
			_crouch(p, 0.7)
			p.neck.x -= 12
			p.head.x -= 14
			p.foot_f = Vector2(20, 0)
			p.foot_b = Vector2(-10, 0)
		GameSim.S_JUMPSQUAT, GameSim.S_LAND:
			_crouch(p, 1.0 if s == GameSim.S_JUMPSQUAT else clampf(1.0 - float(sf) / maxf(1.0, f.landlag), 0, 1))
		GameSim.S_AIR, GameSim.S_HELPLESS:
			if f.vy < 0:
				p.foot_f = Vector2(10, -22)
				p.foot_b = Vector2(-8, -12)
				p.hand_f = Vector2(18, -72)
				p.hand_b = Vector2(-16, -68)
			else:
				p.foot_f = Vector2(9, -6)
				p.foot_b = Vector2(-10, -10)
				p.hand_f = Vector2(22, -62)
				p.hand_b = Vector2(-18, -64)
			p.scarf_lift = clampf(-float(f.vy) / 1500.0, -1, 1)
			if f.jumps == 0 and f.vy < 0 and f.vy < -700:
				p.rot = (1.0 - clampf(float(-f.vy) / 1350.0, 0, 1)) * TAU
			if s == GameSim.S_HELPLESS:
				p.hand_f = Vector2(12, -48)
				p.hand_b = Vector2(-12, -48)
				p.alpha = 0.85
		GameSim.S_ATTACK:
			_attack_pose(p, f, sim)
		GameSim.S_HITSTUN, GameSim.S_SHIELDBREAK:
			p.hand_f = Vector2(-6, -92)
			p.hand_b = Vector2(-28, -80)
			p.foot_f = Vector2(18, -6)
			p.foot_b = Vector2(-4, -2)
			p.neck.x -= 8
			p.head.x -= 12
			p.rot = -0.35
			if f.tumble and not f.ground:
				p.rot = t * 14.0
			if s == GameSim.S_SHIELDBREAK:
				p.rot = sin(t * 6.0) * 0.2
				p.head.x += sin(t * 9.0) * 4
		GameSim.S_HOOKED, GameSim.S_GRABBED:
			p.foot_f = Vector2(12, -26)
			p.foot_b = Vector2(-6, -20)
			p.hand_f = Vector2(20, -48 + sin(t * 30.0) * 8)
			p.hand_b = Vector2(-20, -50 - sin(t * 30.0) * 8)
			p.rot = sin(t * 18.0) * 0.25
		GameSim.S_KNOCKDOWN:
			p.rot = -PI / 2.0
			p.drop = 34.0
			p.hand_f = Vector2(10, -40)
			p.hand_b = Vector2(-10, -36)
		GameSim.S_GETUP, GameSim.S_TECH:
			var k = clampf(float(sf) / 18.0, 0, 1)
			if f.dir != 0:
				p.rot = k * TAU * f.dir * f.face
				_crouch(p, 1.0)
			else:
				p.rot = -PI / 2.0 * (1.0 - _ease(k))
				p.drop = 34.0 * (1.0 - _ease(k))
			if s == GameSim.S_TECH:
				p.alpha = 0.6 if sf <= 20 else 1.0
		GameSim.S_SHIELD, GameSim.S_SHIELDSTUN:
			_crouch(p, 0.5)
			p.hand_f = Vector2(16, -64)
			p.hand_b = Vector2(12, -54)
		GameSim.S_ROLL:
			_crouch(p, 1.0)
			p.rot = clampf(float(sf - 3) / 17.0, 0, 1) * TAU * f.dir * f.face
			p.alpha = 0.5 if sim.is_invuln(f) else 1.0
		GameSim.S_SPOTDODGE:
			_crouch(p, 0.6)
			p.alpha = 0.45 if sim.is_invuln(f) else 1.0
		GameSim.S_AIRDODGE:
			p.foot_f = Vector2(8, -20)
			p.foot_b = Vector2(-8, -18)
			p.hand_f = Vector2(10, -66)
			p.hand_b = Vector2(-10, -66)
			p.alpha = 0.45 if sim.is_invuln(f) else 1.0
		GameSim.S_BURST:
			p.hand_f = Vector2(36, -90)
			p.hand_b = Vector2(-36, -90)
			p.foot_f = Vector2(22, 0)
			p.foot_b = Vector2(-22, 0)
		GameSim.S_GRAB_HOLD:
			p.hand_f = Vector2(40, -54)
			p.hand_b = Vector2(36, -46)
			p.neck.x += 6
			p.head.x += 6
		GameSim.S_RESPAWN:
			p.neck.y += breath
			p.head.y += breath
	if sim.is_invuln(f) and f.inv > 0 and s != GameSim.S_RESPAWN:
		p.alpha = minf(p.alpha, 0.55 + 0.35 * sin(t * 30.0))
	return p

static func _crouch(p: Dictionary, k: float) -> void:
	p.hip.y += 12 * k
	p.neck.y += 16 * k
	p.head.y += 16 * k
	p.neck.x += 6 * k
	p.head.x += 8 * k
	p.hand_f.y += 12 * k
	p.hand_b.y += 12 * k
	p.foot_f.x += 4 * k
	p.foot_b.x -= 4 * k

static func _attack_pose(p: Dictionary, f: Dictionary, sim: GameSim) -> void:
	var id: String = f.move
	var mv: Dictionary = sim.moves[id]
	var mf: int = f.mf
	var cfg: Array = STRIKE.get(id, ["hand_f", Vector2(0, -60)])
	var limb: String = cfg[0]
	p.strike = limb
	var target = _move_target(mv)
	var f0 = 4
	var f1 = 8
	if mv.has("hb"):
		f0 = int(mv.hb[0].f0)
		f1 = int(mv.hb[mv.hb.size() - 1].f1)
	elif mv.has("grabbox"):
		f0 = int(mv.grabbox.f0)
		f1 = int(mv.grabbox.f1)
	elif mv.has("ball_release"):
		f0 = int(mv.ball_release)
		f1 = f0 + 3
		var b: Dictionary = sim.st.b[f.id]
		target = Vector2(48, -66)
		if b.st != GameSim.B_HELD:
			target = Vector2(float(b.dx) / 1000.0 * 50.0 * f.face, float(b.dy) / 1000.0 * 50.0 - 60.0)
	elif mv.has("throw"):
		f0 = int(mv.throw.f) - 2
		f1 = int(mv.throw.f) + 2
		target = Vector2(40, -60)
		if id == "uthrow": target = Vector2(14, -110)
		if id == "dthrow": target = Vector2(36, -10)
		if id == "bthrow": target = Vector2(-50, -60)
	elif mv.has("pummel"):
		f0 = 3
		f1 = 5
		target = Vector2(42, -54)
	var base: Vector2 = p[limb]
	var wind: Vector2 = cfg[1]
	var pos: Vector2
	var len_total: int = mv.len
	if mf < f0:
		pos = base.lerp(wind, _ease(float(mf) / maxf(1.0, f0)))
	elif mf <= f1:
		pos = target
	else:
		pos = target.lerp(base, _ease(float(mf - f1) / maxf(1.0, len_total - f1)))
	# Body follows strong reaches
	var root: Vector2 = p.neck if limb.begins_with("hand") else p.hip
	var reach = 34.0 if limb.begins_with("hand") else 42.0
	var off = pos - root
	if off.length() > reach:
		var shift = off.normalized() * (off.length() - reach) * 0.7
		p.hip += shift * 0.6
		p.neck += shift
		p.head += shift
		if limb == "hand_f":
			p.hand_b += shift
		elif limb == "hand_b":
			p.hand_f += shift
	p[limb] = pos
	# Signature motions
	var prog = float(mf) / maxf(1.0, len_total)
	match id:
		"nair", "nspecial":
			if mf >= f0 and mf <= f1:
				p.rot = float(mf - f0) / maxf(1.0, f1 - f0) * TAU * (2.0 if id == "nspecial" else 1.0)
				p.hand_b = Vector2(-34, -54)
				p.foot_b = Vector2(-30, -20)
		"uspecial":
			p.rot = prog * TAU * 2.0 if mf >= 5 and mf <= 20 else 0.0
			p.foot_f = Vector2(6, -6)
			p.foot_b = Vector2(-6, -2)
		"bthrow":
			if mf >= 4 and mf <= mv.throw.f:
				p.rot = float(mf - 4) / maxf(1.0, mv.throw.f - 4) * -PI
		"fsmash", "usmash", "dsmash":
			if f.charge > 0 and mf == int(mv.charge):
				p.neck.x += sin(float(f.charge) * 1.7) * 2
		"dspecial_air":
			p.hand_f = Vector2(14, -96)
			p.hand_b = Vector2(-14, -96)
		"sspecial":
			if mf >= 6 and mf <= 16:
				p.neck.x += 10
				p.head.x += 14
				p.foot_b = Vector2(-30, -10)
		"jab3", "dash", "ftilt", "fair":
			if mf >= f0 and mf <= f1:
				p.foot_b = Vector2(-14, -4 if f.ground else -26)

## Converts a local pose point into world pixels.
static func to_world(local: Vector2, origin: Vector2, face: int, rot: float, drop: float) -> Vector2:
	var q = local - CENTER
	q = q.rotated(rot)
	q += CENTER
	q.y += drop
	q.x *= face
	return origin + q

static func ik(root: Vector2, target: Vector2, l1: float, l2: float, bend: float) -> Vector2:
	var d = root.distance_to(target)
	d = clampf(d, 0.01, l1 + l2 - 0.01)
	var cosv = clampf((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0)
	var a = acos(cosv)
	var dir = (target - root).angle()
	return root + Vector2.from_angle(dir + a * bend) * l1

static func draw(ci: CanvasItem, f: Dictionary, p: Dictionary, origin: Vector2, pal: Dictionary, t: float, silhouette: Color = Color(0, 0, 0, 0)) -> Dictionary:
	var face: int = f.face
	var rot: float = p.rot
	var drop: float = p.drop
	var W := func(v: Vector2) -> Vector2: return to_world(v, origin, face, rot, drop)
	var alpha: float = p.alpha
	var sil = silhouette.a > 0.0
	var c_out = OUTLINE if not sil else silhouette
	c_out.a *= alpha
	var c_main: Color = pal.main if not sil else silhouette
	var c_dark: Color = pal.dark if not sil else silhouette
	var c_acc: Color = pal.accent if not sil else silhouette
	var c_scarf: Color = pal.scarf if not sil else silhouette
	var c_visor: Color = pal.visor if not sil else silhouette
	c_main.a = alpha; c_dark.a = alpha; c_acc.a = alpha; c_scarf.a = alpha; c_visor.a = alpha
	var hip: Vector2 = W.call(p.hip)
	var neck: Vector2 = W.call(p.neck)
	var head: Vector2 = W.call(p.head)
	var shoulder = neck.lerp(hip, 0.12)
	var hf: Vector2 = W.call(p.hand_f)
	var hb: Vector2 = W.call(p.hand_b)
	var ff: Vector2 = W.call(p.foot_f)
	var fb: Vector2 = W.call(p.foot_b)
	var bend_arm = -1.0 * face
	var bend_leg = 1.0 * face
	# Back limbs (darker)
	_limb(ci, shoulder, hb, ik(shoulder, hb, 18, 18, bend_arm), 8.0, c_dark, c_out, c_acc, 6.5)
	_limb(ci, hip, fb, ik(hip, fb, 22, 22, bend_leg), 10.0, c_dark, c_out, c_dark.darkened(0.2), 7.0)
	# Scarf (flows behind)
	var back = Vector2(-face, 0)
	var sway = sin(t * 7.0 + f.id) * 6.0
	var s0 = neck + Vector2(0, 2)
	var s1 = s0 + back * 22 + Vector2(0, 6 + sway - p.scarf_lift * 14.0)
	var s2 = s1 + back * 20 + Vector2(0, 10 - sway - p.scarf_lift * 18.0)
	ci.draw_polyline(PackedVector2Array([s0, s1, s2]), c_out, 13.0, true)
	ci.draw_polyline(PackedVector2Array([s0, s1, s2]), c_scarf, 8.0, true)
	# Torso
	var tdir = (neck - hip)
	var perp = Vector2(-tdir.y, tdir.x).normalized()
	var torso = PackedVector2Array([hip + perp * 11, neck + perp * 15, neck - perp * 15, hip - perp * 11])
	var torso_out = PackedVector2Array([hip + perp * 15, neck + perp * 19, neck - perp * 19, hip - perp * 15])
	ci.draw_colored_polygon(torso_out, c_out)
	ci.draw_circle(hip, 15, c_out)
	ci.draw_colored_polygon(torso, c_main)
	ci.draw_circle(hip, 11, c_dark)
	# Chest stripe
	ci.draw_line(neck.lerp(hip, 0.2) + perp * 10, neck.lerp(hip, 0.55) - perp * 10, c_acc, 4.0)
	# Front leg
	_limb(ci, hip, ff, ik(hip, ff, 22, 22, bend_leg), 10.0, c_main, c_out, c_dark.darkened(0.1), 7.0)
	# Head: helmet + visor
	ci.draw_circle(head, 19, c_out)
	ci.draw_circle(head, 15, c_main)
	var fwd = Vector2(1, 0).rotated(rot) * Vector2(face, 1)
	var vis_c = head + fwd * 6 + Vector2(0, -1)
	var vp = PackedVector2Array([vis_c + fwd * 9 + Vector2(0, -5), vis_c + fwd * 10 + Vector2(0, 4), vis_c - fwd * 6 + Vector2(0, 5), vis_c - fwd * 7 + Vector2(0, -4)])
	ci.draw_colored_polygon(vp, c_visor)
	# Helmet fin
	var fin = PackedVector2Array([head + Vector2(-face * 4, -14), head + Vector2(-face * 22, -22), head + Vector2(-face * 12, -8)])
	ci.draw_colored_polygon(fin, c_acc)
	# Front arm
	_limb(ci, shoulder, hf, ik(shoulder, hf, 18, 18, bend_arm), 8.0, c_main, c_out, c_acc, 7.0)
	return {"hand_f": hf, "hand_b": hb, "foot_f": ff, "foot_b": fb, "head": head, "neck": neck, "hip": hip}

static func _limb(ci: CanvasItem, a: Vector2, b: Vector2, mid: Vector2, w: float, col: Color, out: Color, tip: Color, tip_r: float) -> void:
	ci.draw_line(a, mid, out, w + 6.0)
	ci.draw_line(mid, b, out, w + 6.0)
	ci.draw_circle(mid, (w + 6.0) * 0.5, out)
	ci.draw_circle(b, tip_r + 3.0, out)
	ci.draw_line(a, mid, col, w)
	ci.draw_line(mid, b, col, w)
	ci.draw_circle(mid, w * 0.5, col)
	ci.draw_circle(b, tip_r, tip)
