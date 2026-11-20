class_name BattleSfx
extends Node3D
## Battle sounds, synthesised at start-up (no audio files): swing whoosh, steel on steel, a blow on a
## shield, hits, bow release, arrows striking, hooves. A small pool of 3D players; far-away sounds are
## skipped and only a few may start per frame, so a 300-man melee doesn't turn into noise.

const RATE := 22050
const VOICES := 20
const MAX_DIST := 75.0
const PER_FRAME := 5

var clips := {}                     # kind -> Array[AudioStreamWAV] (a few variants each)
var _pool: Array[AudioStreamPlayer3D] = []
var _next := 0
var _started_this_frame := 0
var _rng := RandomNumberGenerator.new()
var volume_db := 0.0


func _ready() -> void:
	_rng.seed = 12345
	clips["whoosh"] = [_whoosh(0.26, 900.0), _whoosh(0.32, 650.0), _whoosh(0.22, 1200.0)]
	clips["clash"] = [_clash(1.0), _clash(1.13), _clash(0.9)]
	clips["shield"] = [_wood(1.0), _wood(0.85)]
	clips["hit"] = [_hit(0.6), _hit(0.75), _hit(0.5)]
	clips["thud"] = [_thud(1.0), _thud(0.8)]
	clips["twang"] = [_twang(170.0), _twang(205.0)]
	clips["crossbow"] = [_twang(120.0, 0.18)]
	clips["arrow_hit"] = [_arrow_hit()]
	clips["hoof"] = [_hoof(1.0), _hoof(0.85)]
	for i in VOICES:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 9.0
		p.max_distance = MAX_DIST
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.panning_strength = 0.8
		add_child(p)
		_pool.append(p)


func _process(_dt: float) -> void:
	_started_this_frame = 0


## Play `kind` at world position `pos`. vol in dB; pitch is randomised a little.
func play(kind: String, pos: Vector3, vol := 0.0, pitch := 1.0) -> void:
	if not clips.has(kind) or _started_this_frame >= PER_FRAME or not visible:
		return
	var cam := get_viewport().get_camera_3d()
	if cam and cam.global_position.distance_to(pos) > MAX_DIST:
		return
	_started_this_frame += 1
	var p := _pool[_next]
	_next = (_next + 1) % _pool.size()
	var variants: Array = clips[kind]
	p.stream = variants[_rng.randi() % variants.size()]
	p.global_position = pos
	p.volume_db = vol + volume_db
	p.pitch_scale = pitch * _rng.randf_range(0.92, 1.08)
	p.play()


# ------------------------------------------------------------------ synthesis
func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	# normalise to a common peak (no clipping), with a 3 ms fade-out so nothing clicks at the end
	var peak := 0.0001
	for v in samples:
		peak = maxf(peak, absf(v))
	var g := 0.8 / peak
	var fade := int(0.003 * RATE)
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		var f := clampf(float(samples.size() - 1 - i) / fade, 0.0, 1.0)
		data.encode_s16(i * 2, int(clampf(samples[i] * g * f, -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w


func _buf(seconds: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(int(seconds * RATE))
	return b


func _noise() -> float:
	return _rng.randf_range(-1.0, 1.0)


## Air torn by a blade: band-passed noise swelling and fading, the band sweeping up.
func _whoosh(dur: float, freq: float) -> AudioStreamWAV:
	var b := _buf(dur)
	var lp := 0.0
	var lp2 := 0.0
	for i in b.size():
		var t := float(i) / b.size()
		var f := freq * (0.6 + 0.8 * t)
		var a := clampf(TAU * f / RATE, 0.0, 1.0)
		lp += (_noise() - lp) * a
		lp2 += (lp - lp2) * a * 0.5
		var env := pow(sin(PI * pow(t, 0.7)), 2.0)
		b[i] = (lp - lp2) * env * 1.6
	return _wav(b)


## Steel on steel: inharmonic partials ringing out after a sharp click.
func _clash(k: float) -> AudioStreamWAV:
	var b := _buf(0.7)
	var parts := [[1240.0, 9.0, 0.5], [1785.0, 11.0, 0.35], [2710.0, 14.0, 0.3], [3520.0, 18.0, 0.22], [4380.0, 24.0, 0.15]]
	for i in b.size():
		var t := float(i) / RATE
		var s := 0.0
		for p in parts:
			s += sin(TAU * p[0] * k * t) * exp(-p[1] * t) * p[2]
		if t < 0.006:
			s += _noise() * (1.0 - t / 0.006) * 0.9
		b[i] = s * 0.55
	return _wav(b)


## A blow landing on a wooden shield: dull knock.
func _wood(k: float) -> AudioStreamWAV:
	var b := _buf(0.25)
	var lp := 0.0
	for i in b.size():
		var t := float(i) / RATE
		lp += (_noise() - lp) * 0.12
		b[i] = (lp * 2.2 * exp(-28.0 * t) + sin(TAU * 135.0 * k * t) * exp(-22.0 * t) * 0.7
			+ sin(TAU * 310.0 * k * t) * exp(-35.0 * t) * 0.3)
	return _wav(b)


## A cut or a stab landing: a short wet slap over a thump.
func _hit(noise_amt: float) -> AudioStreamWAV:
	var b := _buf(0.22)
	var lp := 0.0
	for i in b.size():
		var t := float(i) / RATE
		lp += (_noise() - lp) * 0.35
		var f := 95.0 * (1.0 + 1.5 * exp(-30.0 * t))
		b[i] = sin(TAU * f * t) * exp(-18.0 * t) * 0.8 + lp * noise_amt * exp(-40.0 * t) * 1.6
	return _wav(b)


## A blunt blow / a horse barging into a man.
func _thud(k: float) -> AudioStreamWAV:
	var b := _buf(0.3)
	var lp := 0.0
	for i in b.size():
		var t := float(i) / RATE
		lp += (_noise() - lp) * 0.06
		var f := 70.0 * k * (1.0 + exp(-25.0 * t))
		b[i] = sin(TAU * f * t) * exp(-12.0 * t) + lp * 3.0 * exp(-25.0 * t)
	return _wav(b)


## Bow string: Karplus-Strong plucked string.
func _twang(freq: float, dur := 0.35) -> AudioStreamWAV:
	var b := _buf(dur)
	var n := int(RATE / freq)
	var ring := PackedFloat32Array()
	ring.resize(n)
	for i in n:
		ring[i] = _noise()
	var idx := 0
	for i in b.size():
		var nxt := (idx + 1) % n
		var v := (ring[idx] + ring[nxt]) * 0.497
		ring[idx] = v
		idx = nxt
		var t := float(i) / RATE
		b[i] = v * 0.8 + (_noise() * 0.4 * exp(-90.0 * t))
	return _wav(b)


func _arrow_hit() -> AudioStreamWAV:
	var b := _buf(0.12)
	var lp := 0.0
	for i in b.size():
		var t := float(i) / RATE
		lp += (_noise() - lp) * 0.25
		b[i] = lp * 2.0 * exp(-55.0 * t) + sin(TAU * 260.0 * t) * exp(-45.0 * t) * 0.5
	return _wav(b)


func _hoof(k: float) -> AudioStreamWAV:
	var b := _buf(0.12)
	var lp := 0.0
	for i in b.size():
		var t := float(i) / RATE
		lp += (_noise() - lp) * 0.18
		b[i] = lp * 1.8 * exp(-60.0 * t) + sin(TAU * 85.0 * k * t) * exp(-35.0 * t) * 0.6
	return _wav(b)
