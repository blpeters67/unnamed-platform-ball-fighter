extends Node
## Entry point. Step 1 boots straight into a match.

func _ready() -> void:
	get_window().title = "Unnamed Ball Fighter"
	var m := preload("res://scripts/view/match.gd").new()
	add_child(m)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			m.autoplay = true
			add_child(load("res://tests/shot.gd").new())
