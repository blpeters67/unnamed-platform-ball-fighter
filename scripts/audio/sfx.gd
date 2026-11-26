extends Node
## All sound effects are synthesized at startup (no audio files needed).
## Combo hits climb a pentatonic scale so long combos literally sound
## like they are building.

const RATE := 22050
const POOL := 20
const PENTA := [0, 2, 4, 7, 9, 12, 14, 16, 19, 21, 24, 26, 28, 31, 33, 36]

var _streams := {}
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.seed = 1234
	for i in POOL:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_players.append(p)
	_build()

func play(name: String, pitch: float = 1.0, vol_db: float = 0.0) -> void:
	if not _streams.has(name):
		return
	var p := _players[_next]
	_next = (_next + 1) % POOL
	p.stream = _streams[name]
	p.pitch_scale = clampf(pitch, 0.25, 4.0)
	p.volume_db = vol_db
	p.play()

## Musical note for the nth hit of a combo.
func combo_pitch(n: int) -> float:
	var i := clampi(n - 1, 0, PENTA.size() - 1)
	var extra := maxi(0, n - PENTA.size()) * 2
	return pow(2.0, float(PENTA[i] + extra) / 12.0)

func _build() -> void:
	_streams["hit_light"] = _make(0.16, func(t, i): return _noise() * _env(t, 0.002, 0.07) * 0.7 + sin(TAU * 180.0 * t * (1.0 - t * 2.0)) * _env(t, 0.001, 0.09) * 0.8)
	_streams["hit_mid"] = _make(0.24, func(t, i): return _noise() * _env(t, 0.002, 0.10) * 0.8 + sin(TAU * 120.0 * t * (1.0 - t * 1.5)) * _env(t, 0.001, 0.16) * 1.0)
	_streams["hit_heavy"] = _make(0.42, func(t, i): return _noise() * _env(t, 0.001, 0.16) * 0.9 + sin(TAU * 70.0 * t * (1.0 - t)) * _env(t, 0.001, 0.32) * 1.2 + sin(TAU * 1400.0 * t) * _env(t, 0.0, 0.03) * 0.3)
	_streams["hit_big"] = _make(0.9, func(t, i): return _noise() * _env(t, 0.001, 0.35) * 0.9 + sin(TAU * 52.0 * t * (1.0 - t * 0.5)) * _env(t, 0.001, 0.7) * 1.4 + sin(TAU * 2200.0 * t) * _env(t, 0.0, 0.05) * 0.4)
	_streams["note"] = _make(0.32, func(t, i): return (sin(TAU * 880.0 * t) * 0.6 + sin(TAU * 1760.0 * t) * 0.25 + sin(TAU * 2640.0 * t) * 0.1) * _env(t, 0.002, 0.25))
	_streams["swing"] = _make(0.14, func(t, i): return _noise() * _env(t, 0.03, 0.08) * 0.35 * (0.5 + 0.5 * sin(TAU * 40.0 * t)))
	_streams["toss"] = _make(0.22, func(t, i): return sin(TAU * (500.0 + 900.0 * t) * t) * _env(t, 0.005, 0.18) * 0.5 + _noise() * _env(t, 0.02, 0.15) * 0.2)
	_streams["recall"] = _make(0.25, func(t, i): return sin(TAU * (1300.0 - 1600.0 * t) * t) * _env(t, 0.005, 0.2) * 0.45)
	_streams["catch"] = _make(0.22, func(t, i): return (sin(TAU * 1320.0 * t) * (1.0 if t < 0.06 else 0.0) + sin(TAU * 1980.0 * t) * (1.0 if t >= 0.06 else 0.0)) * _env(t, 0.002, 0.2) * 0.35)
	_streams["hook"] = _make(0.4, func(t, i): return (sin(TAU * 220.0 * t + sin(TAU * 31.0 * t) * 6.0) * 0.7 + _noise() * 0.3) * _env(t, 0.002, 0.35) * 0.9)
	_streams["release"] = _make(0.3, func(t, i): return sin(TAU * (300.0 + 1200.0 * t) * t) * _env(t, 0.002, 0.25) * 0.6)
	_streams["parry"] = _make(0.7, func(t, i): return (sin(TAU * 1568.0 * t) + sin(TAU * 2093.0 * t) * 0.7 + sin(TAU * 3136.0 * t) * 0.3) * _env(t, 0.001, 0.6) * 0.45)
	_streams["shield"] = _make(0.18, func(t, i): return (sin(TAU * 600.0 * t) * 0.5 + _noise() * 0.4) * _env(t, 0.001, 0.12) * 0.6)
	_streams["break"] = _make(0.9, func(t, i): return (_noise() * 0.6 + sin(TAU * 400.0 * t * (1.0 - t * 0.6)) * 0.6) * _env(t, 0.001, 0.8) * 0.9)
	_streams["burst"] = _make(1.1, func(t, i): return (sin(TAU * (90.0 + 600.0 * t) * t) * 0.9 + _noise() * _env(t, 0.0, 0.4) * 0.7 + sin(TAU * 45.0 * t) * 0.8) * _env(t, 0.002, 1.0))
	_streams["ko"] = _make(1.6, func(t, i): return (_noise() * _env(t, 0.001, 0.9) * 0.9 + sin(TAU * 40.0 * t * (1.0 - t * 0.3)) * _env(t, 0.001, 1.4) * 1.4 + sin(TAU * 3000.0 * t) * _env(t, 0.0, 0.08) * 0.4))
	_streams["jump"] = _make(0.12, func(t, i): return sin(TAU * (260.0 + 500.0 * t) * t) * _env(t, 0.002, 0.1) * 0.3)
	_streams["land"] = _make(0.1, func(t, i): return (_noise() * 0.5 + sin(TAU * 90.0 * t)) * _env(t, 0.001, 0.08) * 0.35)
	_streams["tech"] = _make(0.3, func(t, i): return sin(TAU * 1046.0 * t) * _env(t, 0.001, 0.25) * 0.4 + sin(TAU * 1568.0 * t) * _env(t, 0.05, 0.25) * 0.3)
	_streams["grab"] = _make(0.15, func(t, i): return (_noise() * 0.4 + sin(TAU * 300.0 * t)) * _env(t, 0.001, 0.12) * 0.5)
	_streams["new"] = _make(0.45, func(t, i): return _arp(t, [1318.5, 1568.0, 2093.0], 0.06) * _env(t, 0.001, 0.4) * 0.35)
	_streams["stale"] = _make(0.25, func(t, i): return sin(TAU * (240.0 - 60.0 * t) * t) * _env(t, 0.002, 0.2) * 0.35)
	_streams["finish"] = _make(1.4, func(t, i): return _arp(t, [523.25, 659.25, 783.99, 1046.5, 1318.5, 1568.0], 0.07) * _env(t, 0.001, 1.2) * 0.4)
	_streams["menu"] = _make(0.08, func(t, i): return sin(TAU * 990.0 * t) * _env(t, 0.001, 0.06) * 0.3)
	_streams["select"] = _make(0.35, func(t, i): return _arp(t, [784.0, 1175.0], 0.08) * _env(t, 0.001, 0.3) * 0.4)
	_streams["charge"] = _make(0.5, func(t, i): return sin(TAU * (200.0 + 500.0 * t) * t) * _env(t, 0.05, 0.4) * 0.25)

func _arp(t: float, notes: Array, step: float) -> float:
	var idx := mini(int(t / step), notes.size() - 1)
	var f: float = notes[idx]
	return sin(TAU * f * t) * 0.7 + sin(TAU * f * 2.0 * t) * 0.2

func _noise() -> float:
	return _rng.randf_range(-1.0, 1.0)

func _env(t: float, attack: float, decay: float) -> float:
	if t < attack:
		return t / maxf(attack, 0.0001)
	return maxf(0.0, 1.0 - (t - attack) / decay) ** 2

func _make(dur: float, gen: Callable) -> AudioStreamWAV:
	var n := int(dur * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / RATE
		var s: float = clampf(gen.call(t, i), -1.0, 1.0)
		data.encode_s16(i * 2, int(s * 26000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w
