extends Control
## Parallax dusk sky for HALO TERRACE: gradient, stars, a giant halo,
## and layered city silhouettes that drift with the camera.

var m: Node
var _stars: Array = []
var _towers: Array = []

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rng = RandomNumberGenerator.new()
	rng.seed = 42
	for i in 140:
		_stars.append([rng.randf(), rng.randf() * 0.6, rng.randf_range(1.0, 2.6), rng.randf() * TAU])
	for layer in 3:
		var row = []
		var x = -0.2
		while x < 1.4:
			var wdt = rng.randf_range(0.02, 0.06)
			row.append([x, wdt, rng.randf_range(0.08, 0.28) * (1.0 - layer * 0.25), rng.randi() % 3])
			x += wdt + rng.randf_range(0.0, 0.02)
		_towers.append(row)

func _draw() -> void:
	var vs = size
	if m.impact > 0:
		draw_rect(Rect2(Vector2.ZERO, vs), Color("07050c"))
		return
	var top = Color("1a1040")
	var mid = Color("6a2c70")
	var low = Color("f08a5d")
	var steps = 24
	for i in steps:
		var k0 = float(i) / steps
		var c = top.lerp(mid, k0 * 2.0) if k0 < 0.5 else mid.lerp(low, (k0 - 0.5) * 2.0)
		draw_rect(Rect2(0, vs.y * k0, vs.x, vs.y / steps + 1), c)
	var cam: Vector2 = m.cam_pos
	var tt: float = m.t
	for s in _stars:
		var a = 0.4 + 0.4 * sin(tt * 1.5 + s[3])
		var p = Vector2(fposmod(s[0] * vs.x - cam.x * 0.02, vs.x), s[1] * vs.y - cam.y * 0.01)
		draw_circle(p, s[2], Color(1, 1, 1, a))
	# Sun + halo
	var sun = Vector2(vs.x * 0.5 - cam.x * 0.05, vs.y * 0.62 - cam.y * 0.04)
	draw_circle(sun, 210, Color("ffb36b", 0.25))
	draw_circle(sun, 150, Color("ffd08a", 0.45))
	draw_circle(sun, 105, Color("ffe7b0"))
	draw_arc(sun, 330, PI * 1.05, PI * 1.95, 64, Color("ffe7b0", 0.35), 6)
	draw_arc(sun, 360, PI * 1.1, PI * 1.9, 64, Color("ffe7b0", 0.15), 3)
	# Cloud bands
	for i in 4:
		var y = vs.y * (0.55 + i * 0.07) - cam.y * (0.05 + i * 0.02)
		var off = fposmod(tt * (8.0 + i * 5) - cam.x * (0.06 + i * 0.03), vs.x * 1.4)
		for j in 4:
			var cx = fposmod(j * vs.x * 0.42 + off, vs.x * 1.4) - vs.x * 0.2
			draw_circle(Vector2(cx, y), 70 + i * 16, Color("ffcfa0", 0.06 + i * 0.015))
			draw_circle(Vector2(cx + 80, y + 10), 60 + i * 12, Color("ffcfa0", 0.06 + i * 0.015))
	# City silhouettes (3 parallax layers)
	var cols = [Color("5b2a6e", 0.8), Color("3d1f55", 0.9), Color("24143d")]
	for layer in 3:
		var par = 0.08 + layer * 0.08
		var base_y = vs.y * (0.78 + layer * 0.06) - cam.y * par * 0.5
		for tw in _towers[layer]:
			var x0: float = tw[0] * vs.x - cam.x * par
			x0 = fposmod(x0 + vs.x * 0.2, vs.x * 1.6) - vs.x * 0.2
			var wdt: float = tw[1] * vs.x
			var h: float = tw[2] * vs.y
			draw_rect(Rect2(x0, base_y - h, wdt, h + vs.y), cols[layer])
			if tw[3] == 0:
				draw_rect(Rect2(x0 + wdt * 0.4, base_y - h - 30, 3, 30), cols[layer])
				draw_circle(Vector2(x0 + wdt * 0.4 + 1.5, base_y - h - 30), 3, Color("ff6b9d", 0.5 + 0.5 * sin(tt * 3 + x0)))
			if layer == 2:
				for wy in range(int(base_y - h + 14), int(base_y), 22):
					if int(wy + x0) % 3 == 0:
						draw_rect(Rect2(x0 + 6, wy, wdt - 12, 4), Color("ffd166", 0.18))
