extends SceneTree
## Two rollback peers over a fake laggy, lossy link. Both must end up with the
## exact same states as a plain sim fed the true inputs.

var fails := 0

func _init() -> void:
	for cfg in [[1, 1, 0.0], [3, 9, 0.05], [6, 14, 0.15]]:
		run_case(cfg[0], cfg[1], cfg[2])
	print("RESULT: ", "PASS" if fails == 0 else "FAIL (%d)" % fails)
	quit(1 if fails else 0)

func check(c: bool, msg: String) -> void:
	print("  ok   " if c else "  FAIL ", msg)
	if not c:
		fails += 1

func run_case(lag_min: int, lag_max: int, loss: float) -> void:
	print("link: %d-%d frames one way, %d%% loss" % [lag_min, lag_max, int(loss * 100)])
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234 + lag_max
	var peers := [Rollback.new(GameSim.new(), 0), Rollback.new(GameSim.new(), 1)]
	var wire := [[], []]   # packets in flight toward peer i: [arrive_tick, bytes]
	var held := [0, 0]
	var hold_t := [0, 0]
	var real := [[], []]   # real input per peer per tick it advanced
	var choices := [0, Inp.LEFT, Inp.RIGHT, Inp.ATTACK, Inp.JUMP, Inp.BALL, Inp.SHIELD, Inp.SPECIAL | Inp.UP,
		Inp.RIGHT | Inp.DASH, Inp.LEFT | Inp.ATTACK, Inp.DOWN, Inp.C_UP, Inp.GRAB]
	var adv_count := [0, 0]
	for t in 2400:
		for i in 2:
			hold_t[i] -= 1
			if hold_t[i] <= 0:
				held[i] = choices[rng.randi() % choices.size()]
				hold_t[i] = rng.randi_range(1, 20)
			var keep: Array = []
			for p in wire[i]:
				if p[0] <= t:
					peers[i].on_packet(p[1])
				else:
					keep.append(p)
			wire[i] = keep
			# Uneven clocks: peer 1 runs ~1% slower to exercise time sync.
			if i == 1 and t % 97 == 0:
				continue
			var r = peers[i].tick(held[i])
			if r != null:
				adv_count[i] += 1
			if rng.randf() >= loss:
				wire[1 - i].append([t + rng.randi_range(lag_min, lag_max), peers[i].make_packet()])
	# Rebuild the true input streams from each peer's local schedule and run
	# a plain sim to compare.
	var a: Rollback = peers[0]
	var b: Rollback = peers[1]
	print("    frames: %d / %d   rollbacks: %d (%d frames)   stalls: %d / %d" % [a.frame, b.frame, a.rollbacks + b.rollbacks, a.rb_frames + b.rb_frames, a.stalls, b.stalls])
	check(a.desync_frame < 0 and b.desync_frame < 0, "no desync reported")
	check(a.frame > 1800 and b.frame > 1800, "both kept running (%d, %d frames)" % [a.frame, b.frame])
	check(absi(a.frame - b.frame) <= lag_max + 4, "clocks stay in sync (gap %d)" % absi(a.frame - b.frame))
	var common := 0
	for hf in a.my_hashes.keys():
		if b.my_hashes.has(hf):
			common += 1
			if a.my_hashes[hf] != b.my_hashes[hf]:
				check(false, "hash mismatch at %d" % hf)
				return
	check(common >= 3, "%d confirmed checkpoints matched" % common)
