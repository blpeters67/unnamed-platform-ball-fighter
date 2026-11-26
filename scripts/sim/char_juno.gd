class_name CharJuno
## JUNO, "the Courier". A fast rushdown fighter who throws a homing
## comet ball. Frame data lives here: positions in px (x is forward
## from facing, y is negative-up from the feet), knockback in px/frame*100,
## and angles in degrees (0 = forward, 90 = up, 180 = back, 270 = down).

const NAME := "JUNO"
const TITLE := "the Courier"

# Physics (sim units: px*100)
const WALK := 560
const WALK_SLOW := 280
const DASH_SPEED := 1050
const RUN_SPEED := 920
const DASH_FRAMES := 9
const SKID_FRAMES := 5
const WALK_ACCEL := 140
const GROUND_FRICTION := 90
const AIR_SPEED := 600
const AIR_ACCEL := 60
const AIR_FRICTION := 12
const GRAVITY := 62
const MAX_FALL := 1150
const FAST_FALL := 1750
const FULL_HOP := -1560
const SHORT_HOP := -1020
const DOUBLE_JUMP := -1620
const JUMPSQUAT := 3
const EXTRA_JUMPS := 1

static func hb(f0: int, f1: int, x: int, y: int, r: int, d: int, a: int, kb: int, kg: int, g: int = 0, fixed: bool = false) -> Dictionary:
	return {"f0": f0, "f1": f1, "x": x, "y": y, "r": r, "d": d, "a": a, "kb": kb, "kg": kg, "g": g, "fixed": fixed}

static var _moves: Dictionary = {}

static func moves() -> Dictionary:
	if _moves.is_empty():
		_moves = _build()
	return _moves

static func _build() -> Dictionary:
	var m := {}
	# ---------------- Jab chain ----------------
	m["jab"] = {"name": "Jab", "type": "jab", "len": 16,
		"hb": [hb(3, 4, 36, -52, 26, 3, 70, 420, 120)],
		"chain": {"next": "jab2", "f0": 5, "f1": 14}}
	m["jab2"] = {"name": "Jab 2", "type": "jab", "len": 17,
		"hb": [hb(3, 4, 40, -50, 26, 3, 65, 440, 120)],
		"chain": {"next": "jab3", "f0": 5, "f1": 15}}
	m["jab3"] = {"name": "Spinning Heel", "type": "jab", "len": 32,
		"hb": [hb(5, 7, 50, -50, 32, 5, 40, 720, 650)]}
	# ---------------- Tilts ----------------
	m["ftilt"] = {"name": "Forward Tilt", "type": "tilt", "len": 27,
		"hb": [hb(6, 8, 60, -48, 30, 8, 35, 700, 780)]}
	# Flip kick: one quick foot arc from in front, over the head, to behind.
	m["utilt"] = {"name": "Up Tilt", "type": "tilt", "len": 22,
		"hb": [hb(4, 5, 34, -40, 30, 6, 84, 720, 380), hb(6, 7, 20, -96, 34, 6, 90, 740, 380),
			hb(8, 10, -24, -88, 32, 6, 98, 720, 380)]}
	m["dtilt"] = {"name": "Down Tilt", "type": "tilt", "len": 19,
		"hb": [hb(5, 7, 54, -12, 26, 5, 78, 660, 300)]}
	m["dash"] = {"name": "Dash Attack", "type": "tilt", "len": 34,
		"hb": [hb(6, 12, 40, -42, 34, 9, 66, 760, 480)],
		"vel": [[1, 12, 900, null], [13, 34, 200, null]]}
	# ---------------- Smash attacks (chargeable) ----------------
	m["fsmash"] = {"name": "Forward Smash", "type": "smash", "len": 46, "charge": 9,
		"hb": [hb(12, 14, 70, -50, 36, 16, 38, 900, 1550)]}
	m["usmash"] = {"name": "Up Smash", "type": "smash", "len": 44, "charge": 7,
		"hb": [hb(10, 15, 0, -120, 44, 14, 90, 950, 1420)]}
	m["dsmash"] = {"name": "Down Smash", "type": "smash", "len": 44, "charge": 6,
		"hb": [hb(9, 11, 58, -14, 32, 13, 30, 850, 1380), hb(9, 11, -58, -14, 32, 13, 150, 850, 1380)]}
	# ---------------- Aerials ----------------
	m["nair"] = {"name": "Neutral Air", "type": "aerial", "air": true, "len": 34, "landlag": 7,
		"hb": [hb(4, 7, 0, -48, 46, 8, 50, 560, 600), hb(8, 18, 0, -48, 42, 4, 60, 460, 300)]}
	# Quick overhead chop: fast, tiny landing lag, low knockback. A combo tool.
	m["fair"] = {"name": "Forward Air", "type": "aerial", "air": true, "len": 25, "landlag": 5,
		"hb": [hb(5, 7, 46, -50, 32, 5, 48, 520, 420)]}
	m["bair"] = {"name": "Back Air", "type": "aerial", "air": true, "len": 34, "landlag": 12,
		"hb": [hb(6, 9, -54, -50, 32, 12, 140, 850, 1280)]}
	m["uair"] = {"name": "Up Air", "type": "aerial", "air": true, "len": 30, "landlag": 8,
		"hb": [hb(5, 10, 2, -112, 38, 7, 88, 680, 600)]}
	m["dair"] = {"name": "Down Air", "type": "aerial", "air": true, "len": 44, "landlag": 18,
		"hb": [hb(11, 15, 0, -4, 34, 12, 270, 640, 880)]}
	# ---------------- Specials ----------------
	m["nspecial"] = {"name": "Orbit Spin", "type": "special", "len": 50, "float": [6, 32],
		"hb": [hb(8, 9, 0, -48, 52, 2, 95, 430, 0, 0, true), hb(13, 14, 0, -48, 52, 2, 95, 430, 0, 1, true),
			hb(18, 19, 0, -48, 52, 2, 95, 430, 0, 2, true), hb(23, 24, 0, -48, 52, 2, 95, 430, 0, 3, true),
			hb(30, 32, 0, -48, 58, 5, 45, 820, 720, 4)]}
	m["sspecial"] = {"name": "Dash Strike", "type": "special", "len": 38, "air_once": true,
		"nograv": [3, 16], "vel": [[1, 5, 0, 0], [6, 16, 1600, 0], [17, 38, 300, null]],
		"hb": [hb(6, 16, 34, -48, 32, 9, 32, 760, 640)]}
	m["uspecial"] = {"name": "Comet Rise", "type": "special", "len": 36, "helpless": true, "landlag": 14,
		"drift": 560, "air_once": true, "nograv": [5, 14], "vel": [[1, 4, null, 0], [5, 14, null, -1550]],
		"hb": [hb(5, 6, 0, -60, 38, 3, 90, 470, 0, 0, true), hb(9, 10, 0, -60, 38, 3, 90, 470, 0, 1, true),
			hb(13, 14, 0, -62, 38, 3, 90, 470, 0, 2, true), hb(18, 20, 0, -70, 42, 6, 80, 820, 780, 3)]}
	m["dspecial"] = {"name": "Meteor Stomp", "type": "special", "len": 36,
		"hb": [hb(8, 11, 56, -12, 34, 8, 80, 860, 480), hb(8, 11, -56, -12, 34, 8, 100, 860, 480)]}
	m["dspecial_air"] = {"name": "Meteor Plunge", "type": "special", "air": true, "len": 70, "landlag": 0,
		"on_land": "dspecial_land", "nograv": [1, 70], "vel": [[1, 6, 0, 0], [7, 70, 0, 1900]],
		"hb": [hb(7, 70, 0, -10, 32, 9, 275, 620, 680)]}
	m["dspecial_land"] = {"name": "Meteor Shockwave", "type": "special", "len": 24,
		"hb": [hb(1, 3, 52, -12, 36, 6, 70, 720, 420), hb(1, 3, -52, -12, 36, 6, 110, 720, 420)]}
	# ---------------- Grab & throws ----------------
	m["grab"] = {"name": "Grab", "type": "grab", "len": 32, "grabbox": {"f0": 7, "f1": 8, "x": 46, "y": -46, "r": 30}}
	m["pummel"] = {"name": "Pummel", "type": "pummel", "len": 14, "pummel": {"f": 4, "d": 1}}
	m["fthrow"] = {"name": "Forward Throw", "type": "throw", "len": 26, "throw": {"f": 8, "d": 8, "a": 40, "kb": 720, "kg": 640}}
	m["bthrow"] = {"name": "Back Throw", "type": "throw", "len": 30, "throw": {"f": 11, "d": 10, "a": 140, "kb": 820, "kg": 880, "swap": true}}
	m["uthrow"] = {"name": "Up Throw", "type": "throw", "len": 28, "throw": {"f": 9, "d": 7, "a": 90, "kb": 760, "kg": 440}}
	m["dthrow"] = {"name": "Down Throw", "type": "throw", "len": 30, "throw": {"f": 12, "d": 6, "a": 74, "kb": 560, "kg": 330}}
	m["ledge_attack"] = {"name": "Ledge Attack", "type": "tilt", "len": 30,
		"hb": [hb(6, 9, 50, -30, 36, 7, 40, 750, 400)]}
	# ---------------- The ball ----------------
	m["ball_throw"] = {"name": "Comet Toss", "type": "ball", "len": 18, "landlag": 4, "ball_release": 5}
	return m
