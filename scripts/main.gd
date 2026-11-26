extends Node
## Entry point: title menu -> local or online match -> back to the menu.
##
## Test flags (after `--`):
##   --shots=DIR --frames=N       screenshots of a CPU match (tests/shot.gd)
##   --nettest=host:CODE|join:CODE --frames=N [--signal=ws://...]
##                                CPU-vs-CPU online match, prints stats, quits

const MatchScript := preload("res://scripts/view/match.gd")
const LobbyScript := preload("res://scripts/view/lobby.gd")

var current: Node
var nettest := ""
var test_frames := 1200

func _ready() -> void:
	get_window().title = "Unnamed Ball Fighter"
	var shots := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			shots = true
		elif a.begins_with("--nettest="):
			nettest = a.substr(10)
		elif a.begins_with("--frames="):
			test_frames = int(a.substr(9))
	if shots:
		var m = _start_match()
		m.autoplay = true
		add_child(load("res://tests/shot.gd").new())
	elif nettest != "":
		_start_nettest()
	else:
		show_lobby("")
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--menushot="):
				# Dev: --menushot=FILE[:host|:join] saves the title menu.
				var bits := a.substr(11).split(":")
				var l = current.get_child(0)
				if bits.size() > 1:
					l.sel = 1 if bits[1] == "host" else 2
					l._main_input(InputRouter.M_OK)
				await get_tree().create_timer(1.5).timeout
				get_viewport().get_texture().get_image().save_png(bits[0])
				get_tree().quit()

func _swap(n: Node) -> void:
	if current:
		current.queue_free()
	current = n
	add_child(n)

func show_lobby(notice: String) -> void:
	var l = LobbyScript.new()
	l.notice = notice
	l.play_local.connect(func(): _start_match())
	l.play_online.connect(_start_online)
	l.quit_game.connect(func(): get_tree().quit())
	var layer := CanvasLayer.new()
	layer.add_child(l)
	_swap(layer)

func _start_match() -> Node:
	var m = MatchScript.new()
	m.left_match.connect(func(reason): show_lobby.call_deferred(reason))
	_swap(m)
	return m

func _start_online(net: NetSession, slot: int) -> Node:
	var m = MatchScript.new()
	m.setup_online(net, slot)
	m.left_match.connect(func(reason): show_lobby.call_deferred(reason))
	_swap(m)
	return m

# ------------------------------------------------------------ net test
func _start_nettest() -> void:
	var parts := nettest.split(":")
	var net := NetSession.new()
	add_child(net)
	net.status_changed.connect(func(s): print("[net] ", s))
	net.failed.connect(func(r): print("[net] FAILED: ", r); get_tree().quit(2))
	net.connected.connect(func():
		remove_child(net)
		var m = _start_online(net, 0 if net.is_host else 1)
		m.autoplay = true
		m.left_match.connect(func(r): print("[net] left: ", r); get_tree().quit(3))
		set_physics_process(true))
	if parts[0] == "host":
		net.host(parts[1])
	else:
		net.join(parts[1])
	set_physics_process(false)

func _physics_process(_dt: float) -> void:
	if nettest == "" or current == null or not current.get("online"):
		return
	var m = current
	if m.net_frames >= test_frames:
		var rb: Rollback = m.rb
		print("[nettest] frames=%d rollbacks=%d rb_frames=%d stalls=%d desync=%d hashes=%d hash@%d=%d pct=%d/%d" % [
			rb.frame, rb.rollbacks, rb.rb_frames, rb.stalls, rb.desync_frame, rb.my_hashes.size(),
			rb.last_hash_frame, rb.my_hashes.get(rb.last_hash_frame, 0), m.sim.st.f[0].pct, m.sim.st.f[1].pct])
		set_physics_process(false)
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--netshot="):
				get_viewport().get_texture().get_image().save_png(a.substr(10))
		get_tree().create_timer(1.0).timeout.connect(func(): get_tree().quit(0 if rb.desync_frame < 0 else 4))
