class_name Cpu
extends RefCounted
## A sparring CPU that plays the real game: it combos with fresh moves,
## throws and recalls the ball, DIs, techs, bursts out of long combos and
## recovers to the stage. It only produces input bits, like a player would.

const U := FX.U
var rng := RandomNumberGenerator.new()
var queue: Array = []
var level := 0.7   # 0..1, how sharp it plays
var _di := 0
var _tech := false
var _scratch: GameSim = null
var _look_cd := 0

func _init(seed_v: int = 0) -> void:
	if seed_v == 0:
		rng.randomize()
	else:
		rng.seed = seed_v

func think(sim: GameSim, id: int) -> int:
	_sim_ref = sim
	var me: Dictionary = sim.st.f[id]
	var op: Dictionary = sim.st.f[1 - id]
	var s: int = me.state
	# ---- Defense always overrides queued plans ----
	if s in [GameSim.S_HITSTUN, GameSim.S_HOOKED, GameSim.S_GRABBED, GameSim.S_KNOCKDOWN]:
		queue.clear()
		return _defend(sim, me)
	_di = 0
	if s == GameSim.S_DEAD:
		queue.clear()
		return 0
	if s == GameSim.S_RESPAWN:
		return Inp.DOWN if me.sf > 40 and rng.randf() < 0.1 else 0
	if s == GameSim.S_LEDGE:
		queue.clear()
		if me.sf < 10 + rng.randi() % 30:
			return 0
		var toward_c := Inp.LEFT if me.ledge_side > 0 else Inp.RIGHT
		return [toward_c, Inp.JUMP, Inp.ATTACK, Inp.SHIELD][rng.randi() % 4]
	if not queue.is_empty():
		return queue.pop_front()
	# ---- Recovery ----
	var off_x: bool = absi(me.x) > (StageHalo.MAIN_X1 - 10) * U
	if not me.ground and (off_x or me.y > 10 * U):
		return _recover(me)
	if op.state == GameSim.S_DEAD or op.state == GameSim.S_RESPAWN:
		return _toward_center(me)
	var dx: int = op.x - me.x
	var dy: int = op.y - me.y
	var adx := absi(dx) / U
	var toward := Inp.RIGHT if dx > 0 else Inp.LEFT
	var away := Inp.LEFT if dx > 0 else Inp.RIGHT
	var ball: Dictionary = sim.st.b[id]
	var ball_ready: bool = ball.st == GameSim.B_HELD and ball.cd == 0 and me.charges > 0
	var actionable: bool = s in [GameSim.S_IDLE, GameSim.S_WALK, GameSim.S_AIR, GameSim.S_LAND]
	# ---- Offense: the opponent is in a combo state, extend it ----
	if _look_cd > 0:
		_look_cd -= 1
	if op.state in [GameSim.S_HITSTUN, GameSim.S_KNOCKDOWN] and actionable:
		if _look_cd == 0 and rng.randf() < level:
			var plan := _lookahead(sim, id, toward)
			if not plan.is_empty():
				queue = plan
				return queue.pop_front()
			_look_cd = 6
		return _extend_combo(sim, me, op, dx, dy, adx, toward, ball_ready)
	if op.state == GameSim.S_HOOKED:
		# Ball is dragging them in: get ready to punish where they land.
		if adx < 140 and me.ground and rng.randf() < 0.4:
			return 0
		return toward if adx > 160 else 0
	# Recall the ball when it is behind the opponent (yank it through them)
	if ball.st == GameSim.B_OUT and rng.randf() < 0.25:
		var bx: int = ball.x - me.x
		if signi(bx) == signi(dx) and absi(bx) > absi(dx) + 30 * U:
			return _press(Inp.BALL)
	if not actionable:
		if s == GameSim.S_GRAB_HOLD:
			var throws := [Inp.UP, Inp.DOWN, toward, away]
			var pick: int = throws[rng.randi() % throws.size()]
			if _fresh(op, "dthrow") and rng.randf() < 0.5:
				pick = Inp.DOWN
			return pick
		if s == GameSim.S_SHIELD:
			if op.state == GameSim.S_ATTACK and adx < 80 and rng.randf() < 0.3:
				return _press(Inp.GRAB)
			return Inp.SHIELD if rng.randf() < 0.8 else 0
		return 0
	# ---- Defense in neutral: react to incoming attacks / balls ----
	var ob: Dictionary = sim.st.b[1 - id]
	if me.ground and (ob.st == GameSim.B_OUT or ob.st == GameSim.B_RETURN):
		var bdx: int = absi(ob.x - me.x) / U
		var bdy: int = absi(ob.y - (me.y - 46 * U)) / U
		if bdx < 120 and bdy < 90 and rng.randf() < 0.35 * level:
			queue = [Inp.SHIELD, Inp.SHIELD, Inp.SHIELD, 0]
			return Inp.SHIELD
	if op.state == GameSim.S_ATTACK and adx < 110 and me.ground and rng.randf() < 0.22 * level:
		if rng.randf() < 0.5:
			queue = [Inp.SHIELD, Inp.SHIELD, Inp.SHIELD, Inp.SHIELD, Inp.SHIELD, 0]
			return Inp.SHIELD
		queue = [Inp.SHIELD | away, Inp.SHIELD | away, 0]
		return Inp.SHIELD
	if op.state in [GameSim.S_SHIELD, GameSim.S_SHIELDSTUN] and adx < 80 and rng.randf() < 0.3:
		return _press(Inp.GRAB)
	# ---- Neutral ----
	if me.ground and absi(me.x) > (StageHalo.MAIN_X1 - 90) * U:
		return _toward_center(me)
	var r := rng.randf()
	if adx > 260:
		if ball_ready and adx < 620 and r < 0.06:
			var up := Inp.UP if dy < -120 * U else 0
			return _press(Inp.BALL | toward | up, toward)
		if r < 0.03:
			return _jump_aerial(toward, Inp.ATTACK | toward)
		if s == GameSim.S_IDLE or s == GameSim.S_WALK:
			return toward | Inp.DASH
		return toward
	if adx > 110:
		if r < 0.05:
			return _jump_aerial(toward, [Inp.ATTACK, Inp.ATTACK | toward][rng.randi() % 2])
		if r < 0.08:
			return _press(Inp.SPECIAL | toward, toward)
		if r < 0.11 and ball_ready:
			return _press(Inp.BALL | toward, toward)
		return toward if r < 0.85 else 0
	# Close range mixups
	if r < 0.10:
		return _press(Inp.ATTACK)
	if r < 0.16:
		return _press(Inp.ATTACK | toward, toward)
	if r < 0.20:
		return _press(Inp.ATTACK | Inp.DOWN, Inp.DOWN)
	if r < 0.24:
		return _press(Inp.GRAB)
	if r < 0.27:
		return _press(Inp.ATTACK | toward | Inp.SMASH, toward)
	if r < 0.30:
		return _jump_aerial(0, Inp.ATTACK)
	if r < 0.32:
		queue = [Inp.SHIELD | away, 0]
		return Inp.SHIELD
	return 0

func _fresh(op: Dictionary, mv: String) -> bool:
	return not (mv in op.combo_moves)

func _press(bits: int, hold: int = 0) -> int:
	queue = [hold, hold & (Inp.LEFT | Inp.RIGHT | Inp.UP | Inp.DOWN)]
	return bits

func _jump_aerial(dir: int, atk: int) -> int:
	queue = [Inp.JUMP | dir, Inp.JUMP | dir, Inp.JUMP | dir, dir, dir, dir, atk | dir, dir, dir]
	return Inp.JUMP | dir

func _toward_center(me: Dictionary) -> int:
	return Inp.LEFT if me.x > 0 else Inp.RIGHT

var _sim_ref: GameSim = null

func _recover(me: Dictionary) -> int:
	var dir := _toward_center(me)
	# Grapple: toss the ball at the ledge when far below/out
	if _sim_ref != null and me.charges > 0 and me.y > 60 * U and _sim_ref.st.b[me.id].st == GameSim.B_HELD and rng.randf() < 0.25:
		queue = [dir | Inp.UP, dir | Inp.UP, dir | Inp.UP, dir | Inp.UP, dir | Inp.UP, dir | Inp.UP]
		return Inp.BALL | dir | Inp.UP
	if me.vy > 0 and me.jumps > 0 and me.y > -60 * U:
		queue = [dir, dir]
		return Inp.JUMP | dir
	if me.vy > 200 and me.y > 30 * U and not (me.air_used & 2):
		queue = [dir, dir]
		return Inp.SPECIAL | Inp.UP | dir
	if me.y > -20 * U and not (me.air_used & 1) and absi(me.x) > (StageHalo.MAIN_X1 + 60) * U and me.y < 60 * U:
		queue = [dir]
		return Inp.SPECIAL | dir
	return dir

func _defend(sim: GameSim, me: Dictionary) -> int:
	var bits := 0
	if me.sf <= 1 or _di == 0:
		var opts := [Inp.LEFT, Inp.RIGHT, Inp.UP, Inp.UP | Inp.LEFT, Inp.UP | Inp.RIGHT, Inp.DOWN, 0]
		_di = opts[rng.randi() % opts.size()]
		_tech = rng.randf() < 0.3 + 0.5 * level
	bits |= _di
	# Survival DI: push toward the stage when far out
	if absi(me.x) > 500 * U:
		bits = (bits & ~(Inp.LEFT | Inp.RIGHT)) | (Inp.LEFT if me.x > 0 else Inp.RIGHT)
	if me.burst >= GameSim.BURST_MAX:
		var want := 6 + int((1.0 - level) * 8.0)
		if me.combo >= want and rng.randf() < 0.07:
			bits |= Inp.BURST
		if me.pct > 1100 and me.combo >= 3 and rng.randf() < 0.05:
			bits |= Inp.BURST
	if me.state == GameSim.S_GRABBED and sim.st.frame % 3 == 0:
		bits |= Inp.JUMP
	if me.state == GameSim.S_KNOCKDOWN and me.sf > 14 and rng.randf() < 0.2:
		bits |= [Inp.LEFT, Inp.RIGHT, Inp.UP][rng.randi() % 3]
	if _tech and me.tumble and me.vy > 0 and me.y > -80 * U and sim.st.frame % 2 == 0:
		bits |= Inp.SHIELD
	return bits

func _extend_combo(sim: GameSim, me: Dictionary, op: Dictionary, dx: int, dy: int, adx: int, toward: int, ball_ready: bool) -> int:
	var above: bool = dy < -90 * U
	var far_above: bool = dy < -220 * U
	# Far away: the ball is the combo extender
	if adx > 230 and ball_ready:
		var updir := Inp.UP if dy < -140 * U else 0
		return _press(Inp.BALL | toward | updir, toward)
	if adx > 150:
		if me.ground and adx > 200 and _fresh(op, "sspecial") and rng.randf() < 0.3 and absi(dy) < 60 * U:
			return _press(Inp.SPECIAL | toward, toward)
		if far_above or above:
			return _jump_aerial(toward, Inp.ATTACK | Inp.UP)
		return toward
	var choices := []
	if me.ground:
		if above and not far_above:
			choices = [["utilt", Inp.ATTACK | Inp.UP], ["usmash", Inp.ATTACK | Inp.UP | Inp.SMASH]]
		elif far_above:
			choices = [["uair", -1]]
		else:
			choices = [["jab", Inp.ATTACK], ["ftilt", Inp.ATTACK | toward], ["dtilt", Inp.ATTACK | Inp.DOWN],
				["dsmash", Inp.ATTACK | Inp.DOWN | Inp.SMASH], ["fsmash", Inp.ATTACK | toward | Inp.SMASH],
				["dspecial", Inp.SPECIAL | Inp.DOWN], ["nspecial", Inp.SPECIAL], ["grab", Inp.GRAB],
				["nair", -2], ["fair", -3]]
	else:
		if above:
			choices = [["uair", Inp.ATTACK | Inp.UP], ["uspecial", Inp.SPECIAL | Inp.UP]]
		elif dy > 60 * U:
			choices = [["dair", Inp.ATTACK | Inp.DOWN]]
		else:
			var front: bool = signi(dx) == me.face
			choices = [["nair", Inp.ATTACK], ["fair" if front else "bair", Inp.ATTACK | toward], ["nspecial", Inp.SPECIAL]]
	# Prefer moves the opponent hasn't eaten yet this combo (variety pays off)
	var fresh := []
	for c in choices:
		if _fresh(op, c[0]):
			fresh.append(c)
	var pool := fresh if not fresh.is_empty() and rng.randf() < 0.55 + 0.45 * level else choices
	if pool.is_empty():
		return toward
	var pick: Array = pool[rng.randi() % pool.size()]
	var b: int = pick[1]
	if b == -1:
		return _jump_aerial(toward, Inp.ATTACK | Inp.UP)
	if b == -2:
		return _jump_aerial(0, Inp.ATTACK)
	if b == -3:
		return _jump_aerial(toward, Inp.ATTACK | toward)
	return _press(b, b & (Inp.LEFT | Inp.RIGHT | Inp.UP | Inp.DOWN))

## Tries a handful of real options in a scratch copy of the match and picks
## one that actually continues the combo (preferring moves not used yet).
func _lookahead(sim: GameSim, id: int, toward: int) -> Array:
	if _scratch == null:
		_scratch = GameSim.new()
	var op: Dictionary = sim.st.f[1 - id]
	var cands := [
		["jab", [Inp.ATTACK]], ["ftilt", [Inp.ATTACK | toward]], ["utilt", [Inp.ATTACK | Inp.UP]],
		["dtilt", [Inp.ATTACK | Inp.DOWN]], ["usmash", [Inp.ATTACK | Inp.UP | Inp.SMASH]],
		["fsmash", [Inp.ATTACK | toward | Inp.SMASH]], ["nspecial", [Inp.SPECIAL]], ["sspecial", [Inp.SPECIAL | toward]],
		["ball", [Inp.BALL | toward]], ["ball", [Inp.BALL | toward | Inp.UP]],
		["nair", [Inp.JUMP, Inp.JUMP, 0, 0, Inp.ATTACK]], ["uair", [Inp.JUMP | toward, Inp.JUMP | toward, Inp.JUMP | toward, toward, toward, Inp.ATTACK | Inp.UP]],
		["fair", [Inp.JUMP | toward, Inp.JUMP | toward, toward, toward, Inp.ATTACK | toward]],
		["dash", [toward, toward, toward, toward, toward, toward, toward, toward, toward, toward, toward, toward, Inp.ATTACK | toward]],
	]
	var base := sim.save_state()
	var best: Array = []
	var best_score := -9999
	for c in cands:
		var name: String = c[0]
		var seq: Array = c[1].duplicate()
		var hold: int = seq[seq.size() - 1] & (Inp.LEFT | Inp.RIGHT)
		_scratch.load_state(base)
		var c0: int = op.combo
		for k in 30:
			var inp: int = seq[k] if k < seq.size() else hold
			var ins := [0, 0]
			ins[id] = inp
			_scratch.step(ins)
			var v: Dictionary = _scratch.st.f[1 - id]
			if v.combo > c0:
				var score := -k + (25 if not (name in op.combo_moves) else 0) + rng.randi() % 6
				if score > best_score:
					best_score = score
					best = []
					for j in k + 1:
						best.append(seq[j] if j < seq.size() else hold)
					best.append(hold)
				break
			if v.combo == 0:
				break
	return best
