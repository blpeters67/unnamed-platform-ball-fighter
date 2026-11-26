extends SceneTree
## CPU vs CPU soak test: checks the game never breaks and reports combo stats.
## godot --headless --script res://tests/cpu_stats.gd

func _init() -> void:
	var sim := GameSim.new(99)
	var c0 := Cpu.new(11)
	var c1 := Cpu.new(22)
	var combos := {}
	var kos := 0
	var bursts := 0
	var hooks := 0
	var events := {}
	var maxc := 0
	var techs := 0
	var frames := 60 * 60 * 6
	for i in frames:
		sim.step([c0.think(sim, 0), c1.think(sim, 1)])
		for e in sim.events:
			events[e.t] = events.get(e.t, 0) + 1
			if e.t == "combo_end":
				combos[e.combo] = combos.get(e.combo, 0) + 1
				maxc = maxi(maxc, e.combo)
	var keys := combos.keys()
	keys.sort()
	var line := ""
	for k in keys:
		line += "%d:%d " % [k, combos[k]]
	print("minutes: ", frames / 3600.0)
	print("combo length histogram: ", line)
	print("longest: ", maxc)
	print("events: ", events)
	print("pct: ", sim.st.f[0].pct / 10, " ", sim.st.f[1].pct / 10, "  stocks ", sim.st.f[0].stocks, " ", sim.st.f[1].stocks)
	quit()
