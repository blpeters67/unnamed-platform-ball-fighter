extends SceneTree
## Finds how long a combo a "perfect" greedy player can do, using the sim's
## save/load (the same thing rollback uses) to try every option.
## godot --headless --script res://tests/combo_search.gd -- [di]

const MOVES := [
	["jab", Inp.ATTACK], ["ftilt", Inp.ATTACK | 2], ["utilt", Inp.ATTACK | Inp.UP], ["dtilt", Inp.ATTACK | Inp.DOWN],
	["fsmash", Inp.ATTACK | Inp.SMASH | 2], ["usmash", Inp.ATTACK | Inp.SMASH | Inp.UP], ["dsmash", Inp.ATTACK | Inp.SMASH | Inp.DOWN],
	["nair", Inp.ATTACK], ["fair", Inp.ATTACK | 2], ["bair", Inp.ATTACK | 1], ["uair", Inp.ATTACK | Inp.UP], ["dair", Inp.ATTACK | Inp.DOWN],
	["nspecial", Inp.SPECIAL], ["sspecial", Inp.SPECIAL | 2], ["uspecial", Inp.SPECIAL | Inp.UP], ["dspecial", Inp.SPECIAL | Inp.DOWN],
	["grab", Inp.GRAB], ["ball", Inp.BALL | 2], ["ballup", Inp.BALL | 2 | Inp.UP], ["recall", Inp.BALL],
]
var di := false
var rng := RandomNumberGenerator.new()

func _init() -> void:
	di = "di" in OS.get_cmdline_user_args()
	var best := 0
	for start_pct in [0, 40, 80, 120]:
		for trial in 5:
			rng.seed = trial * 7919 + start_pct
			var n := search(start_pct)
			best = maxi(best, n)
	print("BEST GREEDY COMBO: ", best)
	quit()

func victim_input(sim: GameSim) -> int:
	if not di:
		return 0
	return Inp.LEFT if sim.st.frame % 40 < 20 else Inp.UP

func dirbits(bits: int, toward: int) -> int:
	# 1 = away, 2 = toward
	var out := bits & ~3
	if bits & 2:
		out |= toward
	if bits & 1:
		out |= Inp.LEFT if toward == Inp.RIGHT else Inp.RIGHT
	return out

func try_seq(sim: GameSim, seq: Array) -> Dictionary:
	var s0 := sim.save_state()
	var c0: int = sim.st.f[1].combo
	var res := {"ok": false, "frames": 999}
	var i := 0
	for inp in seq:
		sim.step([inp, victim_input(sim)])
		i += 1
		if sim.st.f[1].combo > c0:
			res = {"ok": true, "frames": i}
			break
		if sim.st.f[1].combo == 0 or sim.st.f[1].state == GameSim.S_DEAD:
			break
	# require the combo to still be alive a moment later (it was a true hit)
	sim.load_state(s0)
	return res

func build(toward: int, dir_hold: int, wait: int, jump: int, mv: int) -> Array:
	var seq := []
	var dash := dir_hold == 4
	if dash:
		dir_hold = 2
	var hold := dirbits(dir_hold, toward)
	if jump > 0:
		for k in jump:
			seq.append(Inp.JUMP | hold)
	for k in wait:
		seq.append(hold | (Inp.DASH if dash and k == wait - 1 else 0))
	seq.append(dirbits(mv, toward))
	seq.append(hold)
	for k in 40:
		seq.append(hold)
	return seq

func search(start_pct: int) -> int:
	var sim := GameSim.new()
	sim.st.f[0].x = 0
	sim.st.f[1].x = 40 * FX.U
	sim.st.f[1].face = -1
	sim.st.f[1].pct = start_pct * 10
	sim.step([Inp.ATTACK, 0])
	for k in 8:
		sim.step([0, 0])
	var log := []
	while sim.st.f[1].combo > 0 and log.size() < 60:
		var a: Dictionary = sim.st.f[0]
		var v: Dictionary = sim.st.f[1]
		var toward := Inp.RIGHT if v.x > a.x else Inp.LEFT
		# fast-forward: how long until the attacker can act again?
		var pre := 0
		var s0 := sim.save_state()
		while pre < 60:
			var af: Dictionary = sim.st.f[0]
			if af.hitlag == 0 and af.state in [GameSim.S_IDLE, GameSim.S_WALK, GameSim.S_AIR, GameSim.S_LAND]:
				break
			sim.step([0, victim_input(sim)])
			pre += 1
		sim.load_state(s0)
		pre = maxi(0, pre - 3)
		var best = null
		for mv in MOVES:
			var fresh: bool = not (mv[0] in v.combo_moves) and mv[0] != "recall"
			for jump in [0, 1, 4]:
				for wait in [pre, pre + 3, pre + 6, pre + 10, pre + 16]:
					for dh in [0, 2, 4]:
						var seq := build(toward, dh, wait, jump, mv[1])
						var r := try_seq(sim, seq)
						if r.ok:
							var score: int = -r.frames + (30 if fresh else 0) + rng.randi() % 40
							if best == null or score > best.score:
								best = {"score": score, "seq": seq, "frames": r.frames, "name": mv[0]}
		if best == null:
			if OS.get_cmdline_user_args().has("v"):
				var aa = sim.st.f[0]; var vv = sim.st.f[1]; var bb = sim.st.b[0]
				print("   STUCK a.st=", aa.state, " a.mv=", aa.move, " a.mf=", aa.mf, " a.hl=", aa.hitlag, " v.st=", vv.state, " v.hs=", vv.hitstun, " v.hl=", vv.hitlag, " dx=", (vv.x-aa.x)/100, " dy=", (vv.y-aa.y)/100, " ball=", bb.st, " cd=", bb.cd)
			break
		for k in best.frames:
			sim.step([best.seq[k], victim_input(sim)])
		log.append(best.name)
		if OS.get_cmdline_user_args().has("v"):
			print("   ", best.name, " combo=", sim.st.f[1].combo, " pct=", sim.st.f[1].pct, " vstate=", sim.st.f[1].state, " hs=", sim.st.f[1].hitstun, " frames=", best.frames)
	print("start %d%%: %d hits  -> %s  (ended at %d%%)" % [start_pct, log.size() + 1, ", ".join(log), sim.st.f[1].pct / 10])
	return log.size() + 1
