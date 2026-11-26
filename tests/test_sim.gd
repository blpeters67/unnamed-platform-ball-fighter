extends SceneTree
## Headless checks: run with
##   godot --headless --script res://tests/test_sim.gd

var fails := 0

func _init() -> void:
	test_compiles_and_idles()
	test_determinism()
	test_ball_hook_drags_back()
	test_staling_pushes_away()
	test_long_combo()
	test_burst_breaks_combo()
	test_dash_dance()
	test_recovery()
	test_ledge()
	test_charges_grapple_burst()
	print("RESULT: ", "PASS" if fails == 0 else "FAIL (%d)" % fails)
	quit(1 if fails else 0)

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		fails += 1

func run(sim: GameSim, a: int, b: int, n: int) -> Array:
	var evs := []
	for i in n:
		sim.step([a, b])
		evs.append_array(sim.events)
	return evs

func test_compiles_and_idles() -> void:
	print("idle")
	var sim := GameSim.new()
	run(sim, 0, 0, 120)
	check(sim.st.f[0].ground and sim.st.f[0].state == GameSim.S_IDLE, "P1 stands idle on stage")

func scripted_inputs(n: int, seed: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var out := []
	var held := [0, 0]
	for i in n:
		for p in 2:
			if rng.randi() % 6 == 0:
				held[p] = rng.randi() & 0xFFFF
		out.append([held[0], held[1]])
	return out

func test_determinism() -> void:
	print("determinism / rollback")
	var ins := scripted_inputs(1800, 7)
	var a := GameSim.new()
	_close(a)
	for i in 600:
		a.step(ins[i])
	var snap := a.save_state()
	for i in range(600, 1800):
		a.step(ins[i])
	var h1 := a.state_hash()
	var b := GameSim.new()
	b.load_state(snap)
	for i in range(600, 1800):
		b.step(ins[i])
	check(h1 == b.state_hash(), "restore + resimulate gives identical state")
	var c := GameSim.new()
	_close(c)
	for i in 1800:
		c.step(ins[i])
	check(h1 == c.state_hash(), "two fresh runs match")
	print("   frame ", a.st.frame, " p1 %", a.st.f[0].pct / 10, " p2 %", a.st.f[1].pct / 10)

func test_ball_hook_drags_back() -> void:
	print("ball hook")
	var sim := GameSim.new()
	sim.st.f[0].x = 0
	sim.st.f[1].x = 250 * FX.U
	run(sim, 0, 0, 5)
	var evs := run(sim, Inp.BALL, 0, 1)
	evs.append_array(run(sim, 0, 0, 100))
	var hooked := false
	for e in evs:
		if e.t == "hook":
			hooked = true
	check(hooked, "thrown ball hooks enemy")
	var released := false
	for e in evs:
		if e.t == "release":
			released = true
	var dist: int = absi(sim.st.f[1].x - sim.st.f[0].x) / FX.U
	check(released, "ball releases enemy at owner")
	check(dist < 160, "enemy dragged close to owner (dist %d px)" % dist)

func test_staling_pushes_away() -> void:
	print("variety vs spam")
	# Same move three times in a combo should launch farther and stun less.
	var sim := GameSim.new()
	var a: Dictionary = sim.st.f[0]
	var v: Dictionary = sim.st.f[1]
	v.pct = 300
	var h: Dictionary = sim.moves["ftilt"].hb[0]
	sim._apply_hit(a, v, h, "ftilt", false)
	var kb1 := absi(v.vx)
	var hs1: int = v.hitstun
	a.hitlag = 0
	sim._apply_hit(a, v, h, "ftilt", false)
	a.hitlag = 0
	sim._apply_hit(a, v, h, "ftilt", false)
	check(absi(v.vx) > kb1 * 13 / 10, "spammed move launches farther (%d -> %d)" % [kb1, absi(v.vx)])
	check(v.hitstun < hs1, "spammed move gives less hitstun (%d -> %d)" % [hs1, v.hitstun])
	# Alternating two moves must also decay.
	var sim2 := GameSim.new()
	var a2: Dictionary = sim2.st.f[0]
	var v2: Dictionary = sim2.st.f[1]
	v2.pct = 300
	var h2: Dictionary = sim2.moves["utilt"].hb[0]
	sim2._apply_hit(a2, v2, h, "ftilt", false)
	sim2._apply_hit(a2, v2, h2, "utilt", false)
	sim2._apply_hit(a2, v2, h, "ftilt", false)
	sim2._apply_hit(a2, v2, h2, "utilt", false)
	sim2._apply_hit(a2, v2, h, "ftilt", false)
	check(v2.combo_moves.size() == 5 and absi(v2.vx) > kb1 * 13 / 10, "A-B-A-B-A alternation also decays")
	# Fresh moves reward
	var sim3 := GameSim.new()
	var v3: Dictionary = sim3.st.f[1]
	v3.pct = 300
	sim3._apply_hit(sim3.st.f[0], v3, h, "ftilt", false)
	sim3._apply_hit(sim3.st.f[0], v3, h, "jab", false)
	check(v3.hitstun > hs1, "a fresh move in a combo gets bonus hitstun")

func test_long_combo() -> void:
	print("long combo is possible")
	# Direct sequence of fresh hits while in hitstun keeps the combo alive.
	var sim := GameSim.new()
	var a: Dictionary = sim.st.f[0]
	var v: Dictionary = sim.st.f[1]
	var ids := ["jab", "jab2", "dtilt", "utilt", "ftilt", "nair", "uair", "fair", "bair", "dair", "nspecial", "sspecial", "usmash", "dsmash", "fsmash", "dash"]
	var ok := true
	for id in ids:
		a.hitlag = 0
		var h: Dictionary = sim.moves[id].hb[0]
		sim._apply_hit(a, v, h, id, false)
		if v.state != GameSim.S_HITSTUN:
			ok = false
	check(ok and v.combo == ids.size(), "%d-hit varied combo counted (style %d, burst %d)" % [v.combo, v.style, v.burst])

func test_burst_breaks_combo() -> void:
	print("burst")
	var sim := GameSim.new()
	var a: Dictionary = sim.st.f[0]
	var v: Dictionary = sim.st.f[1]
	v.x = a.x + 40 * FX.U
	v.burst = 1000
	sim._apply_hit(a, v, sim.moves["ftilt"].hb[0], "ftilt", false)
	var evs := run(sim, 0, Inp.BURST, 1)
	evs.append_array(run(sim, 0, 0, 12))
	var burst := false
	var flew := false
	var ended := false
	for e in evs:
		if e.t == "burst": burst = true
		if e.t == "bursthit": flew = true
		if e.t == "combo_end": ended = true
	check(burst and ended, "burst during hitstun ends the combo")
	check(flew, "burst knocks the attacker away")

func _close(sim: GameSim) -> void:
	sim.st.f[0].x = -60 * FX.U
	sim.st.f[1].x = 60 * FX.U

func test_dash_dance() -> void:
	print("dash / dash dance / walk")
	var sim := GameSim.new()
	run(sim, Inp.RIGHT | Inp.DASH, 0, 1)
	check(sim.st.f[0].state == GameSim.S_DASH and sim.st.f[0].vx > 0, "flick starts a dash")
	run(sim, Inp.RIGHT, 0, 4)
	run(sim, Inp.LEFT | Inp.DASH, 0, 1)
	check(sim.st.f[0].state == GameSim.S_DASH and sim.st.f[0].vx < 0 and sim.st.f[0].face == -1, "flicking back mid-dash dash-dances")
	run(sim, Inp.LEFT, 0, 20)
	check(sim.st.f[0].state == GameSim.S_RUN, "holding after the dash runs")
	var sim2 := GameSim.new()
	run(sim2, Inp.RIGHT | Inp.WALK_SLOW, 0, 20)
	check(sim2.st.f[0].state == GameSim.S_WALK and sim2.st.f[0].vx == CharJuno.WALK_SLOW, "a light tilt walks slowly")

func test_recovery() -> void:
	print("recovery")
	var sim := GameSim.new()
	var f: Dictionary = sim.st.f[0]
	f.x = 800 * FX.U
	f.y = 150 * FX.U
	f.ground = false
	f.state = GameSim.S_AIR
	f.face = -1
	run(sim, Inp.LEFT | Inp.JUMP, 0, 1)
	run(sim, Inp.LEFT, 0, 14)
	run(sim, Inp.LEFT | Inp.UP | Inp.SPECIAL, 0, 1)
	run(sim, Inp.LEFT, 0, 160)
	check(f.ground or sim.st.f[0].ground, "double jump + up-B gets back from 800px out, 150px below")
	var sim3 := GameSim.new()
	var a: Dictionary = sim3.st.f[0]
	var v: Dictionary = sim3.st.f[1]
	v.pct = 1200
	sim3._apply_hit(a, v, sim3.moves["fsmash"].hb[0], "fsmash", false)
	check(v.hitstun <= 56, "big launches cap hitstun (%d frames)" % v.hitstun)

func test_ledge() -> void:
	print("ledge")
	var sim := GameSim.new()
	var f: Dictionary = sim.st.f[0]
	f.x = 670 * FX.U
	f.y = -40 * FX.U
	f.ground = false
	f.state = GameSim.S_AIR
	run(sim, 0, 0, 30)
	f = sim.st.f[0]
	check(f.state == GameSim.S_LEDGE, "falling next to the edge grabs the ledge")
	run(sim, Inp.LEFT, 0, 30)
	f = sim.st.f[0]
	check(f.ground and f.x < StageHalo.MAIN_X1 * FX.U, "holding toward the stage climbs up")

func test_charges_grapple_burst() -> void:
	print("ball charges / grapple / burst")
	var sim := GameSim.new()
	var f: Dictionary = sim.st.f[0]
	sim.st.f[1].x = 600 * FX.U
	var throws := 0
	for i in 4:
		var evs := run(sim, Inp.BALL, 0, 1)
		evs.append_array(run(sim, 0, 0, 8))
		for e in evs:
			if e.t == "toss": throws += 1
		run(sim, Inp.BALL, 0, 1)  # recall
		run(sim, 0, 0, 45)
	f = sim.st.f[0]
	check(throws == 3, "only 3 ball throws in a row (%d thrown)" % throws)
	var before: int = sim.st.f[0].charges
	run(sim, 0, 0, GameSim.CHARGE_FRAMES + 2)
	check(sim.st.f[0].charges == before + 1, "a charge comes back after 3 seconds")
	# grapple
	var g := GameSim.new()
	var o: Dictionary = g.st.f[0]
	o.x = 820 * FX.U
	o.y = 160 * FX.U
	o.ground = false
	o.state = GameSim.S_AIR
	o.face = -1
	var evs2 := run(g, Inp.BALL | Inp.LEFT | Inp.UP, 0, 1)
	evs2.append_array(run(g, Inp.LEFT | Inp.UP, 0, 6))
	evs2.append_array(run(g, 0, 0, 20))
	var grappled := false
	for e in evs2:
		if e.t == "grapple": grappled = true
	check(grappled and g.st.f[0].state == GameSim.S_LEDGE, "ball thrown at the ledge grapples onto it")
	# burst can't kill
	var b := GameSim.new()
	var a2: Dictionary = b.st.f[0]
	var v2: Dictionary = b.st.f[1]
	a2.x = 600 * FX.U
	a2.pct = 9000
	v2.x = 560 * FX.U
	v2.burst = 1000
	b._apply_hit(a2, v2, b.moves["jab"].hb[0], "jab", false)
	b.st.f[0].x = 600 * FX.U
	run(b, 0, Inp.BURST, 1)
	var kos := 0
	for i in 40:
		b.step([0, 0])
		for e in b.events:
			if e.t == "ko": kos += 1
	check(kos == 0, "burst at 900 percent near the edge does not KO (pushed to x=%d)" % (b.st.f[0].x / FX.U))
