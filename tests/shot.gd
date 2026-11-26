extends Node
## Dev helper: captures screenshots of a CPU-vs-CPU match.
## godot -- --shots=/tmp/out --frames=120,300,600

var frames: Array = []
var outdir := "/tmp"
var n := 0

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			outdir = a.substr(8)
		if a.begins_with("--frames="):
			for s in a.substr(9).split(","):
				frames.append(int(s))

func _process(_dt: float) -> void:
	n += 1
	if frames.has(n):
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/shot_%04d.png" % [outdir, n])
	if n > frames.max() + 2:
		get_tree().quit()
