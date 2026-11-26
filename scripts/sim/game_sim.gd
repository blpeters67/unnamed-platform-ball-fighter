class_name GameSim
extends RefCounted
## The whole fight as a deterministic, integer-only simulation.
## All state lives in plain Dictionaries under `st`, so a rollback is just
## `load_state(save_state())`. Rendering reads `st` and `events`, never writes.

enum { S_IDLE, S_WALK, S_JUMPSQUAT, S_AIR, S_LAND, S_ATTACK, S_HITSTUN, S_HOOKED,
	S_GRABBED, S_GRAB_HOLD, S_KNOCKDOWN, S_GETUP, S_TECH, S_SHIELD, S_SHIELDSTUN,
	S_ROLL, S_SPOTDODGE, S_AIRDODGE, S_HELPLESS, S_BURST, S_SHIELDBREAK, S_DEAD, S_RESPAWN,
	S_DASH, S_RUN, S_SKID, S_LEDGE, S_LEDGE_GETUP, S_GRAPPLE }
enum { B_HELD, B_OUT, B_RETURN, B_HOOK, B_DEAD, B_GRAPPLE }

const U := FX.U

const BUF := 7                 # input buffer window (frames)
const TECH_WINDOW := 20
const PARRY_WINDOW := 5
const HURT_W := 26             # half width, px
const HURT_H := 92             # height, px
const COMBO_STATES := [S_HITSTUN, S_HOOKED, S_GRABBED, S_KNOCKDOWN]
const NO_ACT_STATES := [S_HITSTUN, S_HOOKED, S_GRABBED, S_DEAD, S_RESPAWN, S_SHIELDBREAK, S_KNOCKDOWN]
# Smash-style stale-move queue weights (per mille) for the last 9 moves that hit.
const STALE_W := [90, 80, 70, 60, 50, 40, 30, 20, 10]
const VARIETY_WINDOW := 8
const BURST_MAX := 1000
const BALL_R := 20
const BALL_CHARGES := 3
const CHARGE_FRAMES := 180   # one ball charge back every 3 seconds

var st: Dictionary
var events: Array = []
var moves: Dictionary = CharJuno.moves()

func _init(stocks: int = 3) -> void:
	reset(stocks)

func reset(stocks: int = 3) -> void:
	st = {"frame": 0, "f": [_new_fighter(0, stocks), _new_fighter(1, stocks)],
		"b": [_new_ball(0), _new_ball(1)], "winner": -1, "over": 0, "freeze": 0}
	for b in st.b:
		_ball_to_hand(b)

func save_state() -> Dictionary:
	return st.duplicate(true)

func load_state(s: Dictionary) -> void:
	st = s.duplicate(true)

func state_hash() -> int:
	return var_to_str(st).hash()

func _new_fighter(id: int, stocks: int) -> Dictionary:
	var sp: Array = StageHalo.SPAWN[id]
	var buf := []
	for i in Inp.BUFFERED.size():
		buf.append(99)
	return {"id": id, "x": sp[0] * U, "y": sp[1] * U, "vx": 0, "vy": 0, "face": 1 if id == 0 else -1,
		"ground": true, "jumps": CharJuno.EXTRA_JUMPS, "state": S_IDLE, "sf": 0, "move": "", "mf": 0,
		"charge": 0, "hit_mask": 0, "hitstun": 0, "hitlag": 0, "pct": 0, "stocks": stocks,
		"burst": 250, "combo": 0, "combo_dmg": 0, "combo_moves": [], "style": 0, "shield": 1000,
		"inv": 0, "tumble": false, "airdodged": false, "air_used": 0, "drop": 0, "prev": 0, "inp": 0,
		"buf": buf, "tech_age": 99, "landlag": 0, "partner": -1, "grab_t": 0, "mash": 0,
		"stale": [], "respawn": 0, "ff": false, "dir": 0, "kos": 0, "best_combo": 0,
		"ledge_cd": 0, "ledge_grabs": 0, "ledge_side": 0, "ledge_opt": 0,
		"charges": BALL_CHARGES, "charge_t": 0, "burst_safe": false, "coyote": 0, "ffb": 0}

func _new_ball(owner: int) -> Dictionary:
	return {"owner": owner, "st": B_HELD, "x": 0, "y": 0, "vx": 0, "vy": 0, "dx": 0, "dy": 0,
		"spd": 0, "cd": 0, "t": 0, "hit": false, "victim": -1, "hitlag": 0, "recall": false}

# =====================================================================
# Main step
# =====================================================================
func step(inputs: Array) -> void:
	events.clear()
	st.frame += 1
	var fs: Array = st.f
	for i in 2:
		_read_input(fs[i], int(inputs[i]))
	if st.freeze > 0:
		st.freeze -= 1
		return
	if st.winner >= 0:
		st.over += 1
	for f in fs:
		if f.hitlag > 0:
			f.hitlag -= 1
			_try_burst(f)
			continue
		_update_fighter(f)
	for b in st.b:
		_update_ball(b)
	_resolve_hits()
	_resolve_grabs()
	for f in fs:
		_check_blast(f)
	for f in fs:
		_check_combo_end(f)

func _read_input(f: Dictionary, inp: int) -> void:
	f.prev = f.inp
	f.inp = inp
	var buf: Array = f.buf
	for i in Inp.BUFFERED.size():
		var bit: int = Inp.BUFFERED[i]
		if (inp & bit) and not (f.prev & bit):
			buf[i] = 0
		elif buf[i] < 99:
			buf[i] += 1
	if (inp & Inp.SHIELD) and not (f.prev & Inp.SHIELD):
		f.tech_age = 0
	elif f.tech_age < 99:
		f.tech_age += 1

func _buffered(f: Dictionary, bit: int) -> bool:
	return f.buf[Inp.BUFFERED.find(bit)] <= BUF

func _consume(f: Dictionary, bit: int) -> void:
	f.buf[Inp.BUFFERED.find(bit)] = 99

func _pressed(f: Dictionary, bit: int) -> bool:
	return (f.inp & bit) != 0 and (f.prev & bit) == 0

func _held(f: Dictionary, bit: int) -> bool:
	return (f.inp & bit) != 0

func _other(f: Dictionary) -> Dictionary:
	return st.f[1 - f.id]

func _set_state(f: Dictionary, s: int) -> void:
	f.state = s
	f.sf = 0
	if s != S_ATTACK:
		f.move = ""

func is_invuln(f: Dictionary) -> bool:
	if f.inv > 0:
		return true
	var s: int = f.state
	var t: int = f.sf
	match s:
		S_ROLL: return t >= 3 and t <= 17
		S_SPOTDODGE: return t >= 2 and t <= 16
		S_AIRDODGE: return t >= 3 and t <= 18
		S_TECH: return t <= 20
		S_LEDGE_GETUP: return t <= 22
		S_GETUP: return t <= 20
		S_BURST: return t <= 22
		S_DEAD, S_RESPAWN: return true
	return false

# =====================================================================
# Fighter update
# =====================================================================
func _update_fighter(f: Dictionary) -> void:
	if f.inv > 0:
		f.inv -= 1
	if f.drop > 0:
		f.drop -= 1
	if st.frame % 3 == 0 and f.burst < BURST_MAX and f.state != S_DEAD:
		f.burst += 1
	if f.state != S_SHIELD and f.shield < 1000:
		f.shield = mini(1000, f.shield + 2)
	f.sf += 1
	if _try_burst(f):
		return
	_try_recall(f)
	match f.state:
		S_IDLE, S_WALK: _st_ground_neutral(f)
		S_DASH: _st_dash(f)
		S_RUN: _st_run(f)
		S_SKID: _st_skid(f)
		S_LEDGE: _st_ledge(f)
		S_LEDGE_GETUP: _st_ledge_getup(f)
		S_GRAPPLE: _st_grapple(f)
		S_JUMPSQUAT: _st_jumpsquat(f)
		S_AIR: _st_air(f)
		S_LAND: _st_land(f)
		S_ATTACK: _step_move(f)
		S_HITSTUN: _st_hitstun(f)
		S_HOOKED: _st_hooked(f)
		S_GRABBED: _st_grabbed(f)
		S_GRAB_HOLD: _st_grab_hold(f)
		S_KNOCKDOWN: _st_knockdown(f)
		S_GETUP: _st_getup(f)
		S_TECH: _st_tech(f)
		S_SHIELD: _st_shield(f)
		S_SHIELDSTUN: _st_shieldstun(f)
		S_ROLL: _st_roll(f)
		S_SPOTDODGE: _st_spotdodge(f)
		S_AIRDODGE: _st_airdodge(f)
		S_HELPLESS: _st_helpless(f)
		S_BURST: _st_burst(f)
		S_SHIELDBREAK: _st_shieldbreak(f)
		S_DEAD: _st_dead(f)
		S_RESPAWN: _st_respawn(f)
	if f.ledge_cd > 0:
		f.ledge_cd -= 1
	if f.charges < BALL_CHARGES:
		f.charge_t += 1
		if f.charge_t >= CHARGE_FRAMES:
			f.charge_t = 0
			f.charges += 1
			events.append({"t": "charge", "id": f.id, "x": f.x, "y": f.y})
	else:
		f.charge_t = 0
	if not (f.state in [S_HOOKED, S_GRABBED, S_DEAD, S_RESPAWN, S_LEDGE, S_LEDGE_GETUP, S_GRAPPLE]):
		_move_and_collide(f)
		_try_ledge_grab(f)

# ---------------- Neutral ground ----------------
func _st_ground_neutral(f: Dictionary) -> void:
	if _ground_actions(f):
		return
	var sx := Inp.sx(f.inp)
	if sx != 0 and _buffered(f, Inp.DASH):
		_consume(f, Inp.DASH)
		_start_dash(f, sx)
		return
	if sx != 0:
		if f.state != S_WALK:
			f.state = S_WALK
			f.sf = 0
		f.face = sx
		var spd: int = CharJuno.WALK_SLOW if _held(f, Inp.WALK_SLOW) else CharJuno.WALK
		f.vx = FX.approach(f.vx, sx * spd, CharJuno.WALK_ACCEL)
	else:
		if f.state != S_IDLE:
			f.state = S_IDLE
			f.sf = 0
		f.vx = FX.approach0(f.vx, CharJuno.GROUND_FRICTION)

## Returns true if the fighter started an action.
func _ground_actions(f: Dictionary) -> bool:
	var ball: Dictionary = st.b[f.id]
	if _buffered(f, Inp.BALL) and ball.st == B_HELD and ball.cd == 0 and f.charges > 0:
		_consume(f, Inp.BALL)
		_start_move(f, "ball_throw")
		return true
	if _buffered(f, Inp.GRAB) or (_held(f, Inp.SHIELD) and _buffered(f, Inp.ATTACK)):
		_consume(f, Inp.GRAB)
		_consume(f, Inp.ATTACK)
		_start_move(f, "grab")
		return true
	if _buffered(f, Inp.JUMP):
		_consume(f, Inp.JUMP)
		_set_state(f, S_JUMPSQUAT)
		return true
	if _held(f, Inp.SHIELD):
		_set_state(f, S_SHIELD)
		return true
	if _buffered(f, Inp.SPECIAL):
		_consume(f, Inp.SPECIAL)
		_start_special(f)
		return true
	for cbit in [Inp.C_UP, Inp.C_DOWN, Inp.C_LEFT, Inp.C_RIGHT]:
		if _buffered(f, cbit):
			_consume(f, cbit)
			if cbit == Inp.C_UP:
				_start_move(f, "usmash")
			elif cbit == Inp.C_DOWN:
				_start_move(f, "dsmash")
			else:
				f.face = -1 if cbit == Inp.C_LEFT else 1
				_start_move(f, "fsmash")
			return true
	if _buffered(f, Inp.ATTACK):
		_consume(f, Inp.ATTACK)
		var sx := Inp.sx(f.inp)
		var sy := Inp.sy_up(f.inp)
		var smash := _held(f, Inp.SMASH)
		if sy > 0:
			_start_move(f, "usmash" if smash else "utilt")
		elif sy < 0:
			_start_move(f, "dsmash" if smash else "dtilt")
		elif sx != 0:
			f.face = sx
			if smash:
				_start_move(f, "fsmash")
			elif (f.state == S_DASH or f.state == S_RUN) and sx == f.face:
				_start_move(f, "dash")
			else:
				_start_move(f, "ftilt")
		else:
			_start_move(f, "fsmash" if smash else "jab")
		return true
	# Drop through a platform
	if _pressed(f, Inp.DOWN) and f.y < 0:
		f.drop = 12
		f.ground = false
		f.y += U
		_set_state(f, S_AIR)
		return true
	return false

func _start_special(f: Dictionary) -> void:
	var sx := Inp.sx(f.inp)
	var sy := Inp.sy_up(f.inp)
	if sy > 0:
		if not (f.air_used & 2):
			f.air_used |= 2
			_start_move(f, "uspecial")
		return
	if sy < 0:
		_start_move(f, "dspecial" if f.ground else "dspecial_air")
		return
	if sx != 0:
		f.face = sx
		if f.ground or not (f.air_used & 1):
			if not f.ground:
				f.air_used |= 1
			_start_move(f, "sspecial")
		return
	_start_move(f, "nspecial")

func _start_move(f: Dictionary, id: String) -> void:
	var mv: Dictionary = moves[id]
	f.state = S_ATTACK
	f.sf = 0
	f.move = id
	f.mf = 0
	f.charge = 0
	f.hit_mask = 0
	f.tumble = false
	var t: String = mv.type
	if f.ground and (t == "jab" or t == "tilt" or t == "smash" or t == "grab") and id != "dash":
		f.vx = f.vx / 3

# ---------------- Dash / run / dash dance ----------------
func _start_dash(f: Dictionary, dir: int) -> void:
	_set_state(f, S_DASH)
	f.face = dir
	f.vx = dir * CharJuno.DASH_SPEED
	events.append({"t": "dash", "id": f.id, "x": f.x, "y": f.y})

func _st_dash(f: Dictionary) -> void:
	var sx := Inp.sx(f.inp)
	# Dash dance: flick the other way during the initial dash
	if sx == -f.face and (_buffered(f, Inp.DASH) or not _held(f, Inp.WALK_SLOW)):
		_consume(f, Inp.DASH)
		_start_dash(f, sx)
		return
	if _ground_actions(f):
		return
	f.vx = f.face * CharJuno.DASH_SPEED
	if f.sf >= CharJuno.DASH_FRAMES:
		if sx == f.face:
			_set_state(f, S_RUN)
		else:
			_set_state(f, S_SKID)

func _st_run(f: Dictionary) -> void:
	var sx := Inp.sx(f.inp)
	# Flicking back out of a run turns around with a fresh dash.
	if sx == -f.face and _buffered(f, Inp.DASH):
		_consume(f, Inp.DASH)
		_start_dash(f, sx)
		return
	if _ground_actions(f):
		return
	if sx != f.face:
		_set_state(f, S_SKID)
		f.dir = sx
		return
	f.vx = FX.approach(f.vx, f.face * CharJuno.RUN_SPEED, 80)

func _st_skid(f: Dictionary) -> void:
	f.vx = FX.approach0(f.vx, CharJuno.GROUND_FRICTION + 30)
	var sx := Inp.sx(f.inp)
	if sx != 0 and _buffered(f, Inp.DASH):
		_consume(f, Inp.DASH)
		_start_dash(f, sx)
		return
	if _buffered(f, Inp.JUMP):
		_consume(f, Inp.JUMP)
		_set_state(f, S_JUMPSQUAT)
		return
	if f.sf >= CharJuno.SKID_FRAMES:
		if f.dir != 0 and Inp.sx(f.inp) == f.dir:
			f.face = f.dir
		f.dir = 0
		_set_state(f, S_IDLE)
		_ground_actions(f)

# ---------------- Ball grapple ----------------
## A thrown ball that touches a ledge corner while its owner is airborne
## latches on and reels the owner in to hang from that ledge.
func _ball_grapple_check(b: Dictionary) -> void:
	if b.st != B_OUT:
		return
	var o: Dictionary = st.f[b.owner]
	if o.ground or not (o.state in [S_AIR, S_HELPLESS, S_ATTACK, S_AIRDODGE]):
		return
	for side in [-1, 1]:
		var ex: int = (StageHalo.MAIN_X0 if side < 0 else StageHalo.MAIN_X1) * U
		var ey: int = StageHalo.MAIN_Y * U
		var dx: int = (b.x - ex) / U
		var dy: int = (b.y - ey) / U
		if dx * dx + dy * dy > 48 * 48:
			continue
		# Only when the owner is out past this edge (recovering), not on stage.
		if (o.x - ex) * side < -20 * U:
			continue
		var other := _other(o)
		if other.state == S_LEDGE and other.ledge_side == side:
			continue
		b.st = B_GRAPPLE
		b.x = ex
		b.y = ey
		b.t = 0
		_set_state(o, S_GRAPPLE)
		o.ledge_side = side
		o.vx = 0
		o.vy = 0
		events.append({"t": "grapple", "id": o.id, "x": ex, "y": ey})
		return

func _st_grapple(f: Dictionary) -> void:
	var side: int = f.ledge_side
	var ex: int = (StageHalo.MAIN_X0 if side < 0 else StageHalo.MAIN_X1) * U
	var tx: int = ex + side * 30 * U
	var ty: int = StageHalo.MAIN_Y * U + LEDGE_HANG_Y * U
	var dx: int = tx - f.x
	var dy: int = ty - f.y
	var dist := FX.isqrt(dx * dx + dy * dy)
	var spd := 2400
	if dist <= spd or f.sf > 60:
		f.x = tx
		f.y = ty
		var b: Dictionary = st.b[f.id]
		b.st = B_HELD
		b.cd = 10
		b.hit = false
		_ball_to_hand(b)
		_set_state(f, S_LEDGE)
		f.face = -side
		f.ground = false
		f.jumps = CharJuno.EXTRA_JUMPS
		f.air_used = 0
		f.airdodged = false
		f.inv = maxi(0, 34 - f.ledge_grabs * 14)
		f.ledge_grabs += 1
		events.append({"t": "ledge", "id": f.id, "x": ex, "y": StageHalo.MAIN_Y * U})
		return
	f.vx = dx * spd / dist
	f.vy = dy * spd / dist
	f.x += f.vx
	f.y += f.vy
	f.face = -side

# ---------------- Ledges ----------------
const LEDGE_REACH_X := 46   # px outside the stage edge the hands can reach
const LEDGE_HANG_Y := 86    # px below the ledge the feet hang
const LEDGE_MAX_HANG := 300

func _try_ledge_grab(f: Dictionary) -> void:
	if f.ground or f.ledge_cd > 0 or f.vy < 0:
		return
	var ok_state: bool = f.state == S_AIR or f.state == S_HELPLESS or f.state == S_AIRDODGE
	if f.state == S_ATTACK:
		var mv: Dictionary = moves[f.move]
		ok_state = mv.get("helpless", false) or mv.type == "special"
	if not ok_state or _held(f, Inp.DOWN):
		return
	for side in [-1, 1]:
		var ex: int = (StageHalo.MAIN_X0 if side < 0 else StageHalo.MAIN_X1) * U
		var dx: int = (f.x - ex) * side   # positive = outside the stage
		var dy: int = f.y - StageHalo.MAIN_Y * U
		if dx >= -10 * U and dx <= LEDGE_REACH_X * U and dy >= 20 * U and dy <= 125 * U:
			var o := _other(f)
			if o.state == S_LEDGE and o.ledge_side == side:
				return
			_set_state(f, S_LEDGE)
			f.ledge_side = side
			f.face = -side
			f.x = ex + side * 30 * U
			f.y = StageHalo.MAIN_Y * U + LEDGE_HANG_Y * U
			f.vx = 0
			f.vy = 0
			f.ff = false
			f.tumble = false
			f.jumps = CharJuno.EXTRA_JUMPS
			f.air_used = 0
			f.airdodged = false
			# Ledge invincibility shrinks each regrab without touching the stage.
			f.inv = maxi(0, 34 - f.ledge_grabs * 14)
			f.ledge_grabs += 1
			events.append({"t": "ledge", "id": f.id, "x": ex, "y": StageHalo.MAIN_Y * U})
			return

func _st_ledge(f: Dictionary) -> void:
	f.vx = 0
	f.vy = 0
	var side: int = f.ledge_side
	if f.sf < 8:
		return
	var sx := Inp.sx(f.inp)
	var toward := sx == -side
	var away := sx == side
	if f.sf >= LEDGE_MAX_HANG or _pressed(f, Inp.DOWN) or (away and _pressed(f, Inp.LEFT if side < 0 else Inp.RIGHT)):
		_ledge_release(f, false)
		return
	if _buffered(f, Inp.JUMP) or _pressed(f, Inp.UP):
		_consume(f, Inp.JUMP)
		_ledge_release(f, false)
		f.vy = -1600
		f.vx = -side * 250
		events.append({"t": "djump", "id": f.id, "x": f.x, "y": f.y})
		return
	if _buffered(f, Inp.ATTACK) or _buffered(f, Inp.SPECIAL):
		_consume(f, Inp.ATTACK)
		_consume(f, Inp.SPECIAL)
		f.ledge_opt = 2
	elif _buffered(f, Inp.SHIELD):
		_consume(f, Inp.SHIELD)
		f.ledge_opt = 1
	elif toward:
		f.ledge_opt = 0
	else:
		return
	_set_state(f, S_LEDGE_GETUP)

func _ledge_release(f: Dictionary, _stun: bool) -> void:
	_set_state(f, S_AIR)
	f.ledge_cd = 30
	f.x += f.ledge_side * 10 * U

func _st_ledge_getup(f: Dictionary) -> void:
	var side: int = f.ledge_side
	var ex: int = (StageHalo.MAIN_X0 if side < 0 else StageHalo.MAIN_X1) * U
	if f.sf <= 12:
		var k: int = f.sf
		f.x = ex + side * (30 - k * 5) * U
		f.y = StageHalo.MAIN_Y * U + (LEDGE_HANG_Y - k * LEDGE_HANG_Y / 12) * U
		return
	f.y = StageHalo.MAIN_Y * U
	f.ground = true
	f.x = ex - side * 30 * U
	var opt: int = f.ledge_opt
	if opt == 1:
		_set_state(f, S_ROLL)
		f.dir = -side
		f.inv = 10
	elif opt == 2:
		_start_move(f, "ledge_attack")
	else:
		_set_state(f, S_IDLE)
		f.inv = 6

# ---------------- Jumping & air ----------------
func _st_jumpsquat(f: Dictionary) -> void:
	f.vx = FX.approach0(f.vx, CharJuno.GROUND_FRICTION / 2)
	if f.sf >= CharJuno.JUMPSQUAT:
		f.vy = CharJuno.FULL_HOP if _held(f, Inp.JUMP) else CharJuno.SHORT_HOP
		f.vx = FX.approach(f.vx, Inp.sx(f.inp) * CharJuno.AIR_SPEED, 300)
		f.ground = false
		_set_state(f, S_AIR)
		events.append({"t": "jump", "id": f.id, "x": f.x, "y": f.y})

func _st_air(f: Dictionary) -> void:
	if f.coyote > 0:
		f.coyote -= 1
	if _air_actions(f):
		return
	_air_physics(f, 1000)

func _air_actions(f: Dictionary) -> bool:
	var ball: Dictionary = st.b[f.id]
	if _buffered(f, Inp.BALL) and ball.st == B_HELD and ball.cd == 0 and f.charges > 0:
		_consume(f, Inp.BALL)
		f.tumble = false
		_start_move(f, "ball_throw")
		return true
	if _buffered(f, Inp.SHIELD) and not f.airdodged:
		_consume(f, Inp.SHIELD)
		f.airdodged = true
		f.tumble = false
		_set_state(f, S_AIRDODGE)
		f.dir = (Inp.sx(f.inp) + 1) * 3 + (Inp.sy_up(f.inp) + 1)
		return true
	if _buffered(f, Inp.JUMP) and f.coyote > 0:
		# Coyote time: a jump just after walking off a ledge is a grounded jump
		# and keeps the double jump.
		_consume(f, Inp.JUMP)
		f.coyote = 0
		f.vy = CharJuno.FULL_HOP
		f.ff = false
		events.append({"t": "jump", "id": f.id, "x": f.x, "y": f.y})
		return true
	if _buffered(f, Inp.JUMP) and f.jumps > 0:
		_consume(f, Inp.JUMP)
		f.jumps -= 1
		f.coyote = 0
		f.vy = CharJuno.DOUBLE_JUMP
		f.vx = Inp.sx(f.inp) * CharJuno.AIR_SPEED
		f.ff = false
		f.tumble = false
		events.append({"t": "djump", "id": f.id, "x": f.x, "y": f.y})
		return true
	if _buffered(f, Inp.SPECIAL):
		_consume(f, Inp.SPECIAL)
		f.tumble = false
		_start_special(f)
		return true
	for cbit in [Inp.C_UP, Inp.C_DOWN, Inp.C_LEFT, Inp.C_RIGHT]:
		if _buffered(f, cbit):
			_consume(f, cbit)
			f.tumble = false
			if cbit == Inp.C_UP:
				_start_move(f, "uair")
			elif cbit == Inp.C_DOWN:
				_start_move(f, "dair")
			else:
				var cdir := -1 if cbit == Inp.C_LEFT else 1
				_start_move(f, "fair" if cdir == f.face else "bair")
			return true
	if _buffered(f, Inp.ATTACK):
		_consume(f, Inp.ATTACK)
		f.tumble = false
		var sx := Inp.sx(f.inp)
		var sy := Inp.sy_up(f.inp)
		if sy > 0:
			_start_move(f, "uair")
		elif sy < 0:
			_start_move(f, "dair")
		elif sx != 0:
			_start_move(f, "fair" if sx == f.face else "bair")
		else:
			_start_move(f, "nair")
		return true
	return false

func _air_physics(f: Dictionary, drift_pm: int) -> void:
	# Fast-fall forgiveness: a down press up to 6 frames early still counts,
	# and holding down right after leaving a ledge fast-falls too.
	if _pressed(f, Inp.DOWN):
		f.ffb = 6
	elif f.ffb > 0:
		f.ffb -= 1
	if f.vy > -200 and (f.ffb > 0 or (f.coyote > 0 and (f.inp & Inp.DOWN) != 0)):
		f.ff = true
		f.ffb = 0
	var maxf: int = CharJuno.FAST_FALL if f.ff else CharJuno.MAX_FALL
	if f.ff:
		f.vy = maxi(f.vy, CharJuno.FAST_FALL / 2)
	f.vy = mini(f.vy + CharJuno.GRAVITY, maxi(f.vy, maxf))
	var sx := Inp.sx(f.inp)
	if sx != 0:
		f.vx = FX.approach(f.vx, sx * CharJuno.AIR_SPEED * drift_pm / 1000, CharJuno.AIR_ACCEL * drift_pm / 1000)
	else:
		f.vx = FX.approach0(f.vx, CharJuno.AIR_FRICTION)

func _st_land(f: Dictionary) -> void:
	f.vx = FX.approach0(f.vx, CharJuno.GROUND_FRICTION)
	if f.sf >= f.landlag:
		_set_state(f, S_IDLE)
		_ground_actions(f)

# ---------------- Attacks ----------------
func _step_move(f: Dictionary) -> void:
	var mv: Dictionary = moves[f.move]
	# Smash charge: hold the button at the charge frame
	if mv.has("charge") and f.mf == mv.charge and f.charge < 60 and (f.inp & (Inp.ATTACK | Inp.C_ANY)):
		f.charge += 1
		f.vx = FX.approach0(f.vx, CharJuno.GROUND_FRICTION)
		if not f.ground:
			_air_physics(f, 0)
		return
	f.mf += 1
	var fr: int = f.mf
	var vel_set := false
	if mv.has("vel"):
		for v in mv.vel:
			if fr >= v[0] and fr <= v[1]:
				if v[2] != null:
					f.vx = int(v[2]) * f.face
				if v[3] != null:
					f.vy = int(v[3])
				vel_set = true
	if f.ground:
		if not vel_set:
			f.vx = FX.approach0(f.vx, CharJuno.GROUND_FRICTION)
	else:
		var nograv := false
		if mv.has("nograv") and fr >= mv.nograv[0] and fr <= mv.nograv[1]:
			nograv = true
		if mv.has("float") and fr >= mv.float[0] and fr <= mv.float[1]:
			f.vy = mini(f.vy + CharJuno.GRAVITY, 150)
			nograv = true
		if not nograv:
			f.vy = mini(f.vy + CharJuno.GRAVITY, CharJuno.FAST_FALL if f.ff else CharJuno.MAX_FALL)
			if mv.get("air", false) and _pressed(f, Inp.DOWN) and f.vy > -200:
				f.ff = true
				f.vy = maxi(f.vy, CharJuno.FAST_FALL / 2)
		if mv.has("drift"):
			f.vx = FX.approach(f.vx, Inp.sx(f.inp) * int(mv.drift), 60)
		elif not vel_set:
			var sx := Inp.sx(f.inp)
			if sx != 0:
				f.vx = FX.approach(f.vx, sx * CharJuno.AIR_SPEED, CharJuno.AIR_ACCEL)
			else:
				f.vx = FX.approach0(f.vx, CharJuno.AIR_FRICTION)
	if mv.has("chain"):
		var ch: Dictionary = mv.chain
		if fr >= ch.f0 and fr <= ch.f1 and _buffered(f, Inp.ATTACK) and Inp.sx(f.inp) == 0 and Inp.sy_up(f.inp) == 0:
			_consume(f, Inp.ATTACK)
			_start_move(f, ch.next)
			return
	if mv.has("ball_release") and fr == mv.ball_release:
		_throw_ball(f)
	if mv.has("throw") and fr == mv.throw.f:
		_apply_throw(f, mv)
	if mv.has("pummel") and fr == mv.pummel.f:
		var v := _other(f)
		if v.state == S_GRABBED:
			v.pct = mini(9999, v.pct + 10 * int(mv.pummel.d))
			f.hitlag = 3
			v.hitlag = 3
			events.append({"t": "pummel", "a": f.id, "v": v.id, "x": v.x, "y": v.y - 50 * U})
	if fr >= mv.len:
		_end_move(f)

func _end_move(f: Dictionary) -> void:
	var mv: Dictionary = moves[f.move]
	if mv.type == "pummel":
		_set_state(f, S_GRAB_HOLD)
		return
	if mv.get("helpless", false) and not f.ground:
		_set_state(f, S_HELPLESS)
	elif f.ground:
		_set_state(f, S_IDLE)
	else:
		_set_state(f, S_AIR)

# ---------------- Ball ----------------
func _throw_ball(f: Dictionary) -> void:
	var b: Dictionary = st.b[f.id]
	if b.st != B_HELD or f.charges <= 0:
		return
	f.charges -= 1
	var sx := Inp.sx(f.inp)
	var sy := Inp.sy_up(f.inp)
	if sx == 0 and sy == 0:
		sx = f.face
	if f.ground and sy < 0:
		sy = 0
		if sx == 0:
			sx = f.face
	var dx := sx * 1000
	var dy := -sy * 1000
	if sx != 0 and sy != 0:
		dx = sx * 707
		dy = -sy * 707
	if sx != 0:
		f.face = sx
	b.st = B_OUT
	b.dx = dx
	b.dy = dy
	b.spd = 2700
	b.t = 0
	b.hit = false
	b.recall = false
	_ball_to_hand(b)
	events.append({"t": "toss", "id": f.id, "x": b.x, "y": b.y})

func _try_recall(f: Dictionary) -> void:
	var b: Dictionary = st.b[f.id]
	if not _buffered(f, Inp.BALL):
		return
	if f.state in NO_ACT_STATES:
		return
	if b.st == B_OUT or (b.st == B_DEAD and b.t > 15):
		_consume(f, Inp.BALL)
		b.st = B_RETURN
		b.spd = maxi(b.spd, 2200)
		b.recall = true
		events.append({"t": "recall", "id": f.id, "x": b.x, "y": b.y})

func _ball_to_hand(b: Dictionary) -> void:
	var o: Dictionary = st.f[b.owner]
	b.x = o.x + o.face * 28 * U
	b.y = o.y - 58 * U

func _update_ball(b: Dictionary) -> void:
	var o: Dictionary = st.f[b.owner]
	if o.state == S_DEAD or o.state == S_RESPAWN:
		if b.st == B_HOOK:
			_release_hook(b, false)
		b.st = B_HELD
	if b.hitlag > 0:
		b.hitlag -= 1
		return
	match b.st:
		B_HELD:
			_ball_to_hand(b)
			if b.cd > 0:
				b.cd -= 1
		B_OUT:
			b.t += 1
			b.spd -= 115
			b.vx = b.dx * b.spd / 1000
			b.vy = b.dy * b.spd / 1000
			var ny: int = b.y + b.vy
			if b.vy > 0 and b.y <= -BALL_R * U and ny > -BALL_R * U and b.x > StageHalo.MAIN_X0 * U and b.x < StageHalo.MAIN_X1 * U:
				b.dy = -b.dy
				b.vy = -b.vy
				events.append({"t": "bounce", "x": b.x, "y": b.y})
			b.x += b.vx
			b.y += b.vy
			var ddx: int = (b.x - o.x) / U
			var ddy: int = (b.y - o.y) / U
			if b.spd <= 300 or ddx * ddx + ddy * ddy > 850 * 850:
				b.st = B_RETURN
				b.spd = 300
			_ball_hit_check(b)
			_ball_grapple_check(b)
		B_GRAPPLE:
			b.t += 1
			if o.state != S_GRAPPLE:
				b.st = B_RETURN
				b.spd = 1500
		B_RETURN:
			b.t += 1
			var tx: int = o.x + o.face * 28 * U
			var ty: int = o.y - 58 * U
			var dx: int = tx - b.x
			var dy: int = ty - b.y
			var dist := FX.isqrt(dx * dx + dy * dy)
			var maxs := 3600 if b.recall else 2600
			b.spd = mini(maxs, b.spd + (260 if b.recall else 170))
			if dist <= 46 * U or dist <= b.spd:
				b.st = B_HELD
				b.cd = 12
				b.recall = false
				b.hit = false
				_ball_to_hand(b)
				events.append({"t": "catch", "id": b.owner, "x": b.x, "y": b.y})
			else:
				b.vx = dx * b.spd / dist
				b.vy = dy * b.spd / dist
				b.x += b.vx
				b.y += b.vy
				_ball_hit_check(b)
		B_HOOK:
			b.t += 1
			var v: Dictionary = st.f[b.victim]
			if v.state != S_HOOKED:
				b.st = B_RETURN
				b.spd = 1500
				return
			var tx: int = o.x + o.face * 88 * U
			var ty: int = o.y - 50 * U
			var dx: int = tx - b.x
			var dy: int = ty - b.y
			var dist := FX.isqrt(dx * dx + dy * dy)
			b.spd = mini(2600, b.spd + 120)
			if dist <= b.spd or b.t >= 80:
				b.x = tx
				b.y = ty
				_release_hook(b, true)
			else:
				b.vx = dx * b.spd / dist
				b.vy = dy * b.spd / dist
				b.x += b.vx
				b.y += b.vy
				v.x = b.x
				v.y = b.y + 42 * U
		B_DEAD:
			b.t += 1
			b.vy = mini(b.vy + 55, 1400)
			b.vx = FX.approach0(b.vx, 8)
			if b.vy > 0 and b.y + b.vy > -BALL_R * U and b.y <= -BALL_R * U and b.x > StageHalo.MAIN_X0 * U and b.x < StageHalo.MAIN_X1 * U:
				b.vy = -b.vy * 55 / 100
			b.x += b.vx
			b.y += b.vy
			if b.t >= 50:
				b.st = B_RETURN
				b.spd = 900
				b.recall = false

func _ball_hit_check(b: Dictionary) -> void:
	if b.hit:
		return
	var v: Dictionary = st.f[1 - b.owner]
	if is_invuln(v) or v.state == S_GRABBED or v.state == S_HOOKED:
		return
	if not FX.circle_rect(b.x, b.y, BALL_R * U, v.x - HURT_W * U, v.y - HURT_H * U, v.x + HURT_W * U, v.y):
		return
	b.hit = true
	if v.state == S_SHIELD and v.sf <= PARRY_WINDOW:
		b.st = B_DEAD
		b.t = 0
		b.vx = -b.vx / 3
		b.vy = -900
		v.inv = 6
		_set_state(v, S_IDLE if v.ground else S_AIR)
		events.append({"t": "parry", "id": v.id, "x": b.x, "y": b.y, "ball": true})
		return
	if v.state == S_SHIELD or v.state == S_SHIELDSTUN:
		v.shield -= 130
		_set_state(v, S_SHIELDSTUN)
		v.hitstun = 7
		v.vx = signi(b.vx) * 350
		b.st = B_RETURN
		b.spd = 1200
		events.append({"t": "shield", "id": v.id, "x": b.x, "y": b.y, "d": 3})
		_check_shield_break(v)
		return
	# Hook! The ball grabs the enemy and drags them back to its owner.
	var a: Dictionary = st.f[b.owner]
	var info := _combo_hit(a, v, "ball", 30, "ball")
	_release_own_hook(v)
	_set_state(v, S_HOOKED)
	v.hitstun = 0
	v.tumble = false
	v.vx = 0
	v.vy = 0
	v.ground = false
	v.ff = false
	v.hitlag = 7
	v.airdodged = false
	v.air_used = 0
	b.st = B_HOOK
	b.victim = v.id
	b.t = 0
	b.spd = 900
	b.hitlag = 7
	events.append({"t": "hook", "a": a.id, "v": v.id, "x": b.x, "y": b.y, "combo": v.combo,
		"fresh": info.fresh, "rep": info.rep, "d": info.d, "move": "ball", "kb": 0, "big": false})

func _release_hook(b: Dictionary, with_stun: bool) -> void:
	var v: Dictionary = st.f[b.victim]
	var o: Dictionary = st.f[b.owner]
	if v.state == S_HOOKED:
		if with_stun:
			# Each extra hook in the same combo gives a little less stun.
			var hooks := 0
			for m in v.combo_moves:
				if m == "ball":
					hooks += 1
			# Hooking the same victim over and over in one combo stales hard.
			var stun := 46
			for i in maxi(0, hooks - 1):
				stun = stun * 82 / 100
			stun = stun * maxi(600, 1000 - 12 * v.combo) / 1000
			_set_state(v, S_HITSTUN)
			v.hitstun = maxi(14, stun)
			v.vx = o.face * 120
			v.vy = -560
			v.face = -o.face
			v.tumble = false
			events.append({"t": "release", "a": o.id, "v": v.id, "x": v.x, "y": v.y})
		else:
			_set_state(v, S_AIR)
	b.st = B_HELD
	b.cd = 26
	b.hit = false
	b.victim = -1
	_ball_to_hand(b)

## If `f` was dragging someone with its ball, drop them (owner got hit / burst).
func _release_own_hook(f: Dictionary) -> void:
	var b: Dictionary = st.b[f.id]
	if b.st == B_HOOK:
		var v: Dictionary = st.f[b.victim]
		if v.state == S_HOOKED:
			_set_state(v, S_AIR)
		b.st = B_RETURN
		b.spd = 1500
		b.victim = -1

# ---------------- Hitstun & tech ----------------
func _st_hitstun(f: Dictionary) -> void:
	f.hitstun -= 1
	if f.ground:
		f.vx = FX.approach0(f.vx, 55)
	else:
		f.vy = mini(f.vy + CharJuno.GRAVITY, CharJuno.MAX_FALL)
		if f.vy < 0:
			f.vy += 22
		f.vx = FX.approach0(f.vx, 36)
	if f.hitstun <= 0:
		_set_state(f, S_IDLE if f.ground else S_AIR)

func _st_hooked(f: Dictionary) -> void:
	var b: Dictionary = st.b[1 - f.id]
	if b.st != B_HOOK or b.victim != f.id:
		_set_state(f, S_AIR)

func _st_knockdown(f: Dictionary) -> void:
	f.vx = FX.approach0(f.vx, 70)
	var any: bool = (f.inp & (Inp.ATTACK | Inp.JUMP | Inp.SHIELD | Inp.SPECIAL | Inp.LEFT | Inp.RIGHT | Inp.UP)) != 0
	if f.sf >= 50 or (f.sf >= 12 and any):
		_set_state(f, S_GETUP)
		f.dir = Inp.sx(f.inp)

func _st_getup(f: Dictionary) -> void:
	f.vx = f.dir * 700 if (f.sf >= 4 and f.sf <= 18) else 0
	if f.sf >= 24:
		_set_state(f, S_IDLE)

func _st_tech(f: Dictionary) -> void:
	f.vx = f.dir * 800 if (f.sf >= 2 and f.sf <= 18) else 0
	if f.sf >= 24:
		_set_state(f, S_IDLE)

# ---------------- Shield & dodges ----------------
func _st_shield(f: Dictionary) -> void:
	f.vx = FX.approach0(f.vx, CharJuno.GROUND_FRICTION)
	f.shield -= 2
	if _check_shield_break(f):
		return
	if _buffered(f, Inp.JUMP):
		_consume(f, Inp.JUMP)
		_set_state(f, S_JUMPSQUAT)
		return
	if _buffered(f, Inp.ATTACK) or _buffered(f, Inp.GRAB):
		_consume(f, Inp.ATTACK)
		_consume(f, Inp.GRAB)
		_start_move(f, "grab")
		return
	if _pressed(f, Inp.LEFT) or _pressed(f, Inp.RIGHT):
		f.dir = Inp.sx(f.inp)
		_set_state(f, S_ROLL)
		return
	if _pressed(f, Inp.DOWN):
		_set_state(f, S_SPOTDODGE)
		return
	if not _held(f, Inp.SHIELD):
		_set_state(f, S_LAND)
		f.landlag = 6

func _st_shieldstun(f: Dictionary) -> void:
	f.vx = FX.approach0(f.vx, 40)
	f.hitstun -= 1
	if f.hitstun <= 0:
		if _held(f, Inp.SHIELD):
			_set_state(f, S_SHIELD)
			f.sf = PARRY_WINDOW + 1
		else:
			_set_state(f, S_LAND)
			f.landlag = 6

func _check_shield_break(f: Dictionary) -> bool:
	if f.shield > 0:
		return false
	f.shield = 450
	_set_state(f, S_SHIELDBREAK)
	f.hitstun = 160
	f.vy = -1300
	f.ground = false
	events.append({"t": "break", "id": f.id, "x": f.x, "y": f.y - 50 * U})
	return true

func _st_roll(f: Dictionary) -> void:
	f.vx = f.dir * 760 if (f.sf >= 3 and f.sf <= 20) else FX.approach0(f.vx, 120)
	if f.sf >= 28:
		_set_state(f, S_IDLE)

func _st_spotdodge(f: Dictionary) -> void:
	f.vx = 0
	if f.sf >= 22:
		_set_state(f, S_IDLE)

func _st_airdodge(f: Dictionary) -> void:
	if f.sf == 1:
		var sx: int = f.dir / 3 - 1
		var sy: int = f.dir % 3 - 1
		var sp := 1600 if (sx == 0 or sy == 0) else 1131
		f.vx = sx * sp
		f.vy = -sy * sp
		f.ff = false
	if f.sf <= 18:
		f.vx = f.vx * 91 / 100
		f.vy = f.vy * 91 / 100
	else:
		_air_physics(f, 500)
	if f.sf >= 28:
		_set_state(f, S_AIR)

func _st_helpless(f: Dictionary) -> void:
	_air_physics(f, 450)

# ---------------- Burst ----------------
func _try_burst(f: Dictionary) -> bool:
	if not _buffered(f, Inp.BURST) or f.burst < BURST_MAX:
		return false
	if f.state in [S_DEAD, S_RESPAWN, S_BURST, S_SHIELDBREAK]:
		return false
	_consume(f, Inp.BURST)
	f.burst = 0
	var was_combo: bool = f.state in COMBO_STATES
	if f.state == S_GRABBED:
		var p: Dictionary = st.f[f.partner]
		if p.state == S_GRAB_HOLD or (p.state == S_ATTACK and moves[p.move].type in ["pummel", "throw"]):
			_set_state(p, S_IDLE if p.ground else S_AIR)
	var hb: Dictionary = st.b[1 - f.id]
	if hb.st == B_HOOK and hb.victim == f.id:
		hb.st = B_RETURN
		hb.spd = 1500
		hb.victim = -1
	_release_own_hook(f)
	_set_state(f, S_BURST)
	f.hitlag = 0
	f.hitstun = 0
	f.tumble = false
	f.vx = 0
	f.vy = 0
	f.hit_mask = 0
	f.airdodged = false
	f.air_used = 0
	f.jumps = CharJuno.EXTRA_JUMPS
	events.append({"t": "burst", "id": f.id, "x": f.x, "y": f.y - 46 * U, "broke": was_combo, "combo": f.combo})
	return true

func _st_burst(f: Dictionary) -> void:
	f.vx = 0
	f.vy = 0
	if f.sf >= 40:
		_set_state(f, S_IDLE if f.ground else S_AIR)

func _st_shieldbreak(f: Dictionary) -> void:
	f.hitstun -= 1
	if not f.ground:
		f.vy = mini(f.vy + CharJuno.GRAVITY, CharJuno.MAX_FALL)
	else:
		f.vx = FX.approach0(f.vx, CharJuno.GROUND_FRICTION)
	if f.hitstun <= 0:
		_set_state(f, S_IDLE if f.ground else S_AIR)

# ---------------- Grab ----------------
func _st_grab_hold(f: Dictionary) -> void:
	f.vx = 0
	f.grab_t += 1
	var v := _other(f)
	if v.state != S_GRABBED:
		_set_state(f, S_IDLE)
		return
	if f.grab_t < 4:
		return
	var sx := Inp.sx(f.inp) + Inp.cx(f.inp)
	var sy := Inp.sy_up(f.inp) + Inp.cy_up(f.inp)
	if sy > 0:
		_start_move(f, "uthrow")
	elif sy < 0:
		_start_move(f, "dthrow")
	elif sx != 0 and signi(sx) == f.face:
		_start_move(f, "fthrow")
	elif sx != 0:
		_start_move(f, "bthrow")
	elif _buffered(f, Inp.ATTACK):
		_consume(f, Inp.ATTACK)
		_start_move(f, "pummel")
	elif f.grab_t >= 60:
		_start_move(f, "fthrow")

func _st_grabbed(f: Dictionary) -> void:
	var p: Dictionary = st.f[f.partner]
	var holding: bool = p.state == S_GRAB_HOLD or (p.state == S_ATTACK and moves[p.move].type in ["pummel", "throw"])
	if not holding:
		_set_state(f, S_IDLE if f.ground else S_AIR)
		return
	var behind: bool = p.state == S_ATTACK and p.move == "bthrow" and p.mf >= 5
	f.x = p.x + p.face * (-44 if behind else 48) * U
	f.y = p.y
	f.face = -p.face
	f.vx = 0
	f.vy = 0
	var mash_bits := Inp.ATTACK | Inp.SPECIAL | Inp.JUMP | Inp.SHIELD | Inp.LEFT | Inp.RIGHT | Inp.UP | Inp.DOWN
	if (f.inp & mash_bits) & ~(f.prev & mash_bits):
		f.mash += 1
	if p.state == S_GRAB_HOLD and f.mash >= 7 + f.pct / 250:
		_set_state(f, S_IDLE)
		f.vx = p.face * 900
		f.inv = 4
		_set_state(p, S_IDLE)
		p.vx = -p.face * 900
		events.append({"t": "escape", "id": f.id, "x": f.x, "y": f.y - 50 * U})

func _apply_throw(f: Dictionary, mv: Dictionary) -> void:
	var v := _other(f)
	if v.state != S_GRABBED:
		return
	var th: Dictionary = mv.throw
	if th.get("swap", false):
		v.x = f.x - f.face * 44 * U
	var h := {"d": th.d, "a": th.a, "kb": th.kb, "kg": th.kg, "fixed": false, "g": 0}
	_apply_hit(f, v, h, f.move, true)

func _resolve_grabs() -> void:
	for a in st.f:
		if a.state != S_ATTACK or a.move != "grab" or a.hitlag > 0:
			continue
		var gb: Dictionary = moves["grab"].grabbox
		if a.mf < gb.f0 or a.mf > gb.f1:
			continue
		var v := _other(a)
		if is_invuln(v) or not v.ground or v.state in [S_GRABBED, S_HOOKED, S_DEAD]:
			continue
		var cx: int = a.x + a.face * int(gb.x) * U
		var cy: int = a.y + int(gb.y) * U
		if FX.circle_rect(cx, cy, int(gb.r) * U, v.x - HURT_W * U, v.y - HURT_H * U, v.x + HURT_W * U, v.y):
			var in_combo: bool = v.state in COMBO_STATES
			if not in_combo:
				_reset_combo(v)
			_release_own_hook(v)
			_set_state(a, S_GRAB_HOLD)
			a.grab_t = 0
			a.partner = v.id
			_set_state(v, S_GRABBED)
			v.partner = a.id
			v.mash = 0
			v.hitstun = 0
			events.append({"t": "grab", "a": a.id, "v": v.id, "x": cx, "y": cy})

# ---------------- Dead / respawn ----------------
func _st_dead(f: Dictionary) -> void:
	f.respawn -= 1
	if f.respawn <= 0 and f.stocks > 0:
		_set_state(f, S_RESPAWN)
		f.x = (-1 if f.id == 0 else 1) * 120 * U
		f.y = StageHalo.RESPAWN_Y * U
		f.vx = 0
		f.vy = 0
		f.pct = 0
		f.ground = false
		f.jumps = CharJuno.EXTRA_JUMPS
		f.airdodged = false
		f.air_used = 0
		f.shield = 1000

func _st_respawn(f: Dictionary) -> void:
	f.vx = 0
	f.vy = 0
	var any: bool = (f.inp & ~f.prev) != 0
	if f.sf >= 150 or (f.sf >= 20 and any):
		_set_state(f, S_AIR)
		f.inv = 100

# ---------------- Movement & stage collision ----------------
func _on_surface(x: int, y: int) -> bool:
	if y == StageHalo.MAIN_Y * U and x >= StageHalo.MAIN_X0 * U and x <= StageHalo.MAIN_X1 * U:
		return true
	for p in StageHalo.PLATFORMS:
		if y == int(p[2]) * U and x >= int(p[0]) * U and x <= int(p[1]) * U:
			return true
	return false

func _move_and_collide(f: Dictionary) -> void:
	var oy: int = f.y
	f.x += f.vx
	if f.ground:
		if f.vy < 0:
			f.ground = false
			_on_leave_ground(f)
		elif not _on_surface(f.x, f.y):
			f.ground = false
			_on_leave_ground(f)
		else:
			f.vy = 0
			return
	f.y += f.vy
	# Main stage solid block sides / underside
	var in_x: bool = f.x >= StageHalo.MAIN_X0 * U and f.x <= StageHalo.MAIN_X1 * U
	if f.vy >= 0:
		if oy <= StageHalo.MAIN_Y * U and f.y >= StageHalo.MAIN_Y * U and in_x:
			f.y = StageHalo.MAIN_Y * U
			_on_land(f)
			return
		if f.drop == 0 and not (f.state == S_ATTACK and f.move == "dspecial_air" and _held(f, Inp.DOWN)):
			for p in StageHalo.PLATFORMS:
				var py: int = int(p[2]) * U
				if oy <= py and f.y >= py and f.x >= int(p[0]) * U and f.x <= int(p[1]) * U:
					f.y = py
					_on_land(f)
					return
	if f.y > StageHalo.MAIN_Y * U and f.y - HURT_H * U < StageHalo.MAIN_BOTTOM * U and f.x > (StageHalo.MAIN_X0 - HURT_W) * U and f.x < (StageHalo.MAIN_X1 + HURT_W) * U:
		# Inside the stage block: push out the shortest way
		var to_left: int = f.x - (StageHalo.MAIN_X0 - HURT_W) * U
		var to_right: int = (StageHalo.MAIN_X1 + HURT_W) * U - f.x
		var to_bottom: int = StageHalo.MAIN_BOTTOM * U - (f.y - HURT_H * U)
		if to_bottom < mini(to_left, to_right) and f.vy < 0:
			f.y = (StageHalo.MAIN_BOTTOM + HURT_H) * U
			f.vy = 0
		elif to_left < to_right:
			f.x = (StageHalo.MAIN_X0 - HURT_W) * U
			f.vx = -absi(f.vx) / 2 if f.state == S_HITSTUN else mini(f.vx, 0)
		else:
			f.x = (StageHalo.MAIN_X1 + HURT_W) * U
			f.vx = absi(f.vx) / 2 if f.state == S_HITSTUN else maxi(f.vx, 0)

func _on_leave_ground(f: Dictionary) -> void:
	match f.state:
		S_IDLE, S_WALK, S_LAND, S_SHIELD, S_SHIELDSTUN, S_ROLL, S_SPOTDODGE, S_KNOCKDOWN, S_GETUP, S_TECH, S_JUMPSQUAT, S_DASH, S_RUN, S_SKID:
			_set_state(f, S_AIR)
			f.tumble = false
			f.coyote = 5

func _on_land(f: Dictionary) -> void:
	f.ground = true
	f.vy = 0
	f.ledge_grabs = 0
	f.jumps = CharJuno.EXTRA_JUMPS
	f.airdodged = false
	f.air_used = 0
	f.ff = false
	match f.state:
		S_AIR:
			if f.tumble:
				_tumble_land(f)
			else:
				_set_state(f, S_LAND)
				f.landlag = 3
				events.append({"t": "land", "id": f.id, "x": f.x, "y": f.y})
		S_ATTACK:
			var mv: Dictionary = moves[f.move]
			if mv.has("on_land"):
				_start_move(f, mv.on_land)
				events.append({"t": "stomp", "id": f.id, "x": f.x, "y": f.y})
			elif mv.get("helpless", false) or mv.get("air", false) or mv.type == "ball":
				var ll: int = mv.get("landlag", 4)
				_set_state(f, S_LAND)
				f.landlag = ll
		S_HELPLESS:
			_set_state(f, S_LAND)
			f.landlag = 14
		S_AIRDODGE:
			_set_state(f, S_LAND)
			f.landlag = 9
		S_HITSTUN:
			if f.tumble:
				_tumble_land(f)

func _tumble_land(f: Dictionary) -> void:
	f.tumble = false
	if f.tech_age <= TECH_WINDOW:
		f.tech_age = 99
		_set_state(f, S_TECH)
		f.dir = Inp.sx(f.inp)
		f.vx = 0
		events.append({"t": "tech", "id": f.id, "x": f.x, "y": f.y})
	else:
		_set_state(f, S_KNOCKDOWN)
		f.hitstun = 0
		f.vx = f.vx / 3
		events.append({"t": "knockdown", "id": f.id, "x": f.x, "y": f.y})

func _check_blast(f: Dictionary) -> void:
	if f.state == S_DEAD or f.state == S_RESPAWN:
		return
	if f.burst_safe and f.state == S_HITSTUN:
		return
	f.burst_safe = false
	var out: bool = absi(f.x) > StageHalo.BLAST_X * U or f.y > StageHalo.BLAST_BOTTOM * U
	if f.y < StageHalo.BLAST_TOP * U and (f.state == S_HITSTUN or f.y < (StageHalo.BLAST_TOP - 200) * U):
		out = true
	if not out:
		return
	var killer := _other(f)
	if f.combo > 0:
		killer.best_combo = maxi(killer.best_combo, f.combo)
	events.append({"t": "ko", "id": f.id, "x": clampi(f.x, -StageHalo.BLAST_X * U, StageHalo.BLAST_X * U),
		"y": clampi(f.y, StageHalo.BLAST_TOP * U, StageHalo.BLAST_BOTTOM * U), "combo": f.combo, "style": f.style, "dmg": f.combo_dmg})
	killer.kos += 1
	f.stocks -= 1
	var hb: Dictionary = st.b[1 - f.id]
	if hb.st == B_HOOK and hb.victim == f.id:
		hb.st = B_RETURN
		hb.victim = -1
	_set_state(f, S_DEAD)
	f.respawn = 80
	f.vx = 0
	f.vy = 0
	f.hitstun = 0
	f.hitlag = 0
	st.freeze = 18
	if f.stocks <= 0 and st.winner < 0:
		st.winner = killer.id

func _check_combo_end(v: Dictionary) -> void:
	if v.combo <= 0:
		return
	if v.state in COMBO_STATES or v.hitlag > 0:
		return
	var a := _other(v)
	a.best_combo = maxi(a.best_combo, v.combo)
	events.append({"t": "combo_end", "a": a.id, "v": v.id, "combo": v.combo, "dmg": v.combo_dmg,
		"style": v.style, "burst": v.state == S_BURST, "ko": v.state == S_DEAD})
	_reset_combo(v)

func _reset_combo(v: Dictionary) -> void:
	v.combo = 0
	v.combo_dmg = 0
	v.combo_moves = []
	v.style = 0

# =====================================================================
# Hits
# =====================================================================
func hitbox_world(f: Dictionary, h: Dictionary) -> Vector2i:
	return Vector2i(f.x + f.face * int(h.x) * U, f.y + int(h.y) * U)

func _resolve_hits() -> void:
	var hits := []
	for a in st.f:
		if a.hitlag > 0:
			continue
		var v := _other(a)
		if is_invuln(v) or v.state == S_GRABBED or v.state == S_DEAD:
			continue
		var rx0: int = v.x - HURT_W * U
		var ry0: int = v.y - HURT_H * U
		var rx1: int = v.x + HURT_W * U
		var ry1: int = v.y
		if a.state == S_BURST:
			if a.sf >= 3 and a.sf <= 8 and not (a.hit_mask & 1):
				if FX.circle_rect(a.x, a.y - 46 * U, 175 * U, rx0, ry0, rx1, ry1):
					hits.append([a, v, null, ""])
			continue
		if a.state != S_ATTACK:
			continue
		var mv: Dictionary = moves[a.move]
		if not mv.has("hb"):
			continue
		for h in mv.hb:
			if a.mf < h.f0 or a.mf > h.f1 or (a.hit_mask & (1 << int(h.g))):
				continue
			var c := hitbox_world(a, h)
			if FX.circle_rect(c.x, c.y, int(h.r) * U, rx0, ry0, rx1, ry1):
				hits.append([a, v, h, a.move])
				break
	for hit in hits:
		if hit[2] == null:
			_apply_burst_hit(hit[0], hit[1])
		else:
			_apply_hit(hit[0], hit[1], hit[2], hit[3], false)

## Shared combo bookkeeping for every kind of hit. Returns variety info.
func _combo_hit(a: Dictionary, v: Dictionary, move_id: String, base_d10: int, mtype: String) -> Dictionary:
	var in_combo: bool = v.state in COMBO_STATES
	if not in_combo:
		_reset_combo(v)
	var cm: Array = v.combo_moves
	var rep := 0
	for i in range(maxi(0, cm.size() - VARIETY_WINDOW), cm.size()):
		if cm[i] == move_id:
			rep += 1
	var fresh: bool = not (move_id in cm)
	# Match-wide stale queue (like Smash): overused moves do less damage.
	var stale_pm := 1000
	var sq: Array = a.stale
	for i in sq.size():
		if sq[i] == move_id:
			stale_pm -= STALE_W[i]
	if stale_pm == 1000:
		stale_pm = 1050
	var d10: int = base_d10 * stale_pm / 1000
	d10 = d10 * (1000 + a.charge * 7) / 1000
	d10 = maxi(5, d10 * maxi(550, 1000 - 22 * v.combo) / 1000)
	v.pct = mini(9999, v.pct + d10)
	v.combo += 1
	v.combo_dmg += d10
	cm.append(move_id)
	# Style: variety is king
	var pts := 15
	if fresh:
		pts = 120
	elif rep == 0:
		pts = 60
	if mtype == "smash":
		pts += 40
	elif mtype == "throw":
		pts += 25
	v.style += pts * (100 + v.combo * 10) / 100
	# Burst meter: varied combos fill it slowly, spam fills it fast.
	var gain: int = 30 + 8 * v.combo
	var mult := 1000 + 650 * rep
	if fresh:
		mult = 550
	v.burst = mini(BURST_MAX, v.burst + gain * mult / 1000)
	sq.push_front(move_id)
	if sq.size() > 9:
		sq.pop_back()
	return {"fresh": fresh and v.combo > 1, "rep": rep, "d": d10, "in_combo": in_combo}

func _apply_hit(a: Dictionary, v: Dictionary, h: Dictionary, move_id: String, is_throw: bool) -> void:
	var mtype: String = moves[move_id].type
	a.hit_mask |= 1 << int(h.g)
	var d: int = int(h.d)
	# ---- Shield / parry ----
	if not is_throw and (v.state == S_SHIELD or v.state == S_SHIELDSTUN):
		var c := hitbox_world(a, h)
		if v.state == S_SHIELD and v.sf <= PARRY_WINDOW:
			a.hitlag = 20
			v.hitlag = 2
			_set_state(v, S_IDLE)
			v.inv = 5
			events.append({"t": "parry", "id": v.id, "x": c.x, "y": c.y, "ball": false})
			return
		var dmg_shield := d * 13 + 20
		if mtype == "smash":
			dmg_shield = dmg_shield * (1000 + a.charge * 7) / 1000
		v.shield -= dmg_shield
		_set_state(v, S_SHIELDSTUN)
		v.hitstun = 3 + d * 6 / 10
		var push: int = signi(v.x - a.x)
		if push == 0:
			push = a.face
		v.vx = push * (220 + d * 45)
		var hl := 3 + d / 3
		a.hitlag = hl
		v.hitlag = hl
		events.append({"t": "shield", "id": v.id, "x": c.x, "y": c.y, "d": d})
		_check_shield_break(v)
		return
	# ---- Real hit ----
	var info := _combo_hit(a, v, move_id, d * 10, mtype)
	v.burst_safe = false
	var p: int = v.pct / 10
	var kb: int = int(h.kb)
	if not h.fixed:
		kb += int(h.kg) * p / 100
		kb = kb * (1000 + a.charge * 5) / 1000
	if info.rep > 0 and info.in_combo:
		# Repeating a move in a combo launches them farther: harder to follow up.
		kb = kb * (1000 + 320 * info.rep) / 1000
	var ang: int = int(h.a)
	var world_a: int = ang if a.face == 1 else 180 - ang
	if v.ground and posmod(world_a, 360) > 190 and posmod(world_a, 360) < 350:
		world_a = 80 if a.face == 1 else 100
		kb = kb * 6 / 10
	# Directional influence
	var sx := Inp.sx(v.inp)
	var sy := Inp.sy_up(v.inp)
	if not h.fixed and (sx != 0 or sy != 0):
		var lx := FX.cos_d(world_a)
		var ly := FX.sin_d(world_a)
		var cross: int = lx * sy - ly * sx
		if cross > 0:
			world_a += 14
		elif cross < 0:
			world_a -= 14
	# Hitstun with combo decay and variety reward/penalty
	# Generous hitstun for combo hits, but big launches don't lock you out
	# of recovering: above ~12 px/f the curve flattens and caps.
	var hs: int = 16 + kb * 28 / 1000
	if kb > 1200:
		hs = 45 + (kb - 1200) * 9 / 1000
	hs = mini(hs, 56)
	var stun_pm: int = maxi(600, 1000 - 12 * v.combo)
	if info.in_combo:
		if info.fresh:
			stun_pm = stun_pm * 1150 / 1000
		elif info.rep > 0:
			stun_pm = stun_pm * maxi(350, 1000 - 260 * info.rep) / 1000
	hs = maxi(6, hs * stun_pm / 1000)
	# Hitlag: the "crunch" of a hit
	var hl := 4 + d * 4 / 10 + mini(v.combo / 5, 4)
	if mtype == "smash":
		hl += 3 + a.charge / 20
	var big := kb >= 2500
	if big:
		hl += 7
	hl = mini(hl, 24)
	a.hitlag = hl
	v.hitlag = hl
	# Victim reaction
	if v.state == S_HOOKED:
		var hb: Dictionary = st.b[a.id]
		if hb.st == B_HOOK and hb.victim == v.id:
			hb.st = B_RETURN
			hb.spd = 1500
			hb.victim = -1
	_release_own_hook(v)
	_set_state(v, S_HITSTUN)
	v.hitstun = hs
	v.vx = FX.cos_d(world_a) * kb / 1000
	v.vy = -FX.sin_d(world_a) * kb / 1000
	v.tumble = kb >= 1150
	if v.vy < 0:
		v.ground = false
	v.ff = false
	v.airdodged = false
	v.air_used = 0
	if not is_throw:
		v.face = -a.face
	var c2 := Vector2i(v.x, v.y - 46 * U) if is_throw else hitbox_world(a, h)
	events.append({"t": "hit", "a": a.id, "v": v.id, "x": c2.x, "y": c2.y, "d": info.d, "kb": kb,
		"combo": v.combo, "fresh": info.fresh, "rep": info.rep, "big": big, "move": move_id,
		"type": mtype, "hl": hl, "ang": world_a})

func _apply_burst_hit(a: Dictionary, v: Dictionary) -> void:
	a.hit_mask |= 1
	var dx: int = v.x - a.x
	var dy: int = (v.y - 46 * U) - (a.y - 46 * U)
	if dx == 0 and dy == 0:
		dx = a.face
	var dist := maxi(1, FX.isqrt(dx * dx + dy * dy))
	if v.state == S_SHIELD or v.state == S_SHIELDSTUN:
		# Baited! Shielding a burst is the counter-play.
		v.shield -= 250
		_set_state(v, S_SHIELDSTUN)
		v.hitstun = 14
		v.vx = dx * 1400 / dist
		a.hitlag = 10
		v.hitlag = 10
		events.append({"t": "shield", "id": v.id, "x": v.x, "y": v.y - 46 * U, "d": 20})
		events.append({"t": "baited", "id": v.id, "x": v.x, "y": v.y - 80 * U})
		_check_shield_break(v)
		return
	_release_own_hook(v)
	# Fixed push, no percent scaling: burst gets them off you, it never kills.
	var kb := 1500
	_set_state(v, S_HITSTUN)
	v.hitstun = 30
	v.vx = dx * kb / dist
	v.vy = mini(-700, dy * kb / dist)
	v.ground = false
	v.tumble = false
	v.burst_safe = true
	a.hitlag = 9
	v.hitlag = 9
	events.append({"t": "bursthit", "a": a.id, "v": v.id, "x": v.x, "y": v.y - 46 * U})
