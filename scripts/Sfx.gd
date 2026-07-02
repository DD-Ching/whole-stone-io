extends Node
## Sfx — the game's entire soundscape, SYNTHESIZED at load (autoloaded as "Sfx").
## No audio assets: every effect is a small 16-bit mono 22.05 kHz buffer built
## sample-by-sample (sine partials, filtered noise, exponential decays) and played
## through a pool of positional AudioStreamPlayer2Ds — so a hammer landing two
## screens away is a faint, directional warning, and the big map sounds alive.
##
## Web notes (the traps, so nobody re-trips them):
##  - Playback uses the browser "sample" path: bus effects don't apply, so every
##    sound is designed dry (any ring/reverb is baked into the buffer itself).
##  - pitch_scale is set AFTER play() — defensive ordering for the web sample path.
##  - Anything played before the first user gesture is silently dropped by the
##    browser; that's fine, nothing audible matters before the first click/tap.

const RATE := 22050
const POOL := 8              ## mobile browsers get crackly past ~8 simultaneous voices
const MIN_GAP := 0.05        ## per-sound rate limit — a 24-gem death shower must not be white noise

var _streams := {}
var _players: Array[AudioStreamPlayer2D] = []
var _last := {}              ## sound name -> last play() time (sec)
var _rr := 0                 ## round-robin steal cursor when every voice is busy

func _ready() -> void:
	_streams = {
		&"thud": _make_thud(),
		&"clash": _make_clash(),
		&"chime": _make_chime(),
		&"gong": _make_gong(),
		&"boom": _make_boom(),
		&"whoosh": _make_whoosh(),
		&"splash": _make_splash(),
		&"fanfare": _make_fanfare(),
	}
	# Pre-register with the sample-playback path so the first play has no hitch (web).
	if AudioServer.has_method("register_stream_as_sample"):
		for s in _streams.values():
			AudioServer.call("register_stream_as_sample", s)
	for i in POOL:
		var p := AudioStreamPlayer2D.new()
		p.max_distance = 1500.0
		p.attenuation = 1.3
		add_child(p)
		_players.append(p)

## Play a named sound at a world position. Rate-limited per sound name.
func play(sound: StringName, pos: Vector2, vol_db := 0.0, pitch := 1.0) -> void:
	if not _streams.has(sound):
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - float(_last.get(sound, -10.0)) < MIN_GAP:
		return
	_last[sound] = now
	var pl: AudioStreamPlayer2D = null
	for p in _players:
		if not p.playing:
			pl = p
			break
	if pl == null:                       # every voice busy — steal one round-robin;
		pl = _players[_rr % POOL]        # a clipped tail is inaudible in a brawl
		_rr += 1
	pl.stream = _streams[sound]
	pl.global_position = pos
	pl.volume_db = vol_db
	pl.play()
	pl.pitch_scale = clampf(pitch, 0.5, 2.0)

# --- synthesis ---------------------------------------------------------------------
# Each builder returns a finished AudioStreamWAV. Shared idiom: a phase accumulator
# for swept tones, one-pole filters for shaped noise, exponential decay envelopes.

func _buf(dur: float) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(int(dur * RATE) * 2)
	return b

func _w(data: PackedByteArray, i: int, v: float) -> void:
	data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32000.0))

func _finish(data: PackedByteArray) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	return wav

## Stone meeting flesh: a fast low sine sweep plus a soft low-passed noise slap.
func _make_thud() -> AudioStreamWAV:
	var n := int(0.14 * RATE)
	var d := _buf(0.14)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var phase := 0.0
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		var env := exp(-26.0 * t)
		phase += TAU * lerpf(150.0, 55.0, clampf(t * 9.0, 0.0, 1.0)) / RATE
		lp += 0.18 * (rng.randf_range(-1.0, 1.0) - lp)
		_w(d, i, (0.8 * sin(phase) + 1.7 * lp) * env)
	return _finish(d)

## Metal on stone: inharmonic partials (bell-like, deliberately NOT a harmonic series)
## with fast staggered decays, plus a tiny click of noise at the attack.
func _make_clash() -> AudioStreamWAV:
	var n := int(0.22 * RATE)
	var d := _buf(0.22)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var freqs := [740.0, 1213.0, 1876.0, 2451.0]
	var amps := [1.0, 0.7, 0.5, 0.32]
	var decs := [-14.0, -17.0, -21.0, -26.0]
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		for k in 4:
			v += sin(TAU * freqs[k] * t) * amps[k] * exp(decs[k] * t)
		v *= 0.30
		if t < 0.008:
			v += rng.randf_range(-0.5, 0.5) * (1.0 - t / 0.008)
		_w(d, i, v)
	return _finish(d)

## A bright little pickup blip — callers ladder the pitch for the vacuum-combo feel.
func _make_chime() -> AudioStreamWAV:
	var n := int(0.10 * RATE)
	var d := _buf(0.10)
	for i in n:
		var t := float(i) / RATE
		var v := sin(TAU * 880.0 * t) * exp(-30.0 * t) + 0.35 * sin(TAU * 1760.0 * t) * exp(-38.0 * t)
		_w(d, i, v * 0.55)
	return _finish(d)

## The KO gong — low inharmonic partials with a long ring. Pitched down for big kills.
func _make_gong() -> AudioStreamWAV:
	var n := int(0.7 * RATE)
	var d := _buf(0.7)
	var freqs := [80.0, 121.0, 163.0, 242.0, 334.0]
	var amps := [1.0, 0.6, 0.45, 0.3, 0.2]
	var decs := [-3.2, -4.0, -4.8, -5.8, -7.0]
	for i in n:
		var t := float(i) / RATE
		var attack := minf(t * 90.0, 1.0)     # soft mallet, not a click
		var v := 0.0
		for k in 5:
			v += sin(TAU * freqs[k] * t) * amps[k] * exp(decs[k] * t)
		_w(d, i, v * 0.38 * attack)
	return _finish(d)

## Slam detonation: heavy low-passed noise over a sub-bass sine.
func _make_boom() -> AudioStreamWAV:
	var n := int(0.4 * RATE)
	var d := _buf(0.4)
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		var env := exp(-9.0 * t)
		lp += 0.06 * (rng.randf_range(-1.0, 1.0) - lp)
		_w(d, i, (3.4 * lp + 0.7 * sin(TAU * 52.0 * t)) * env)
	return _finish(d)

## Air torn by a fast head: band-passed noise with a swell-and-die envelope.
func _make_whoosh() -> AudioStreamWAV:
	var n := int(0.22 * RATE)
	var d := _buf(0.22)
	var rng := RandomNumberGenerator.new()
	rng.seed = 31
	var lp_hi := 0.0
	var lp_lo := 0.0
	for i in n:
		var t := float(i) / RATE
		var env := pow(sin(PI * t / 0.22), 2.0)
		var w := rng.randf_range(-1.0, 1.0)
		lp_hi += 0.35 * (w - lp_hi)
		lp_lo += 0.05 * (w - lp_lo)
		_w(d, i, (lp_hi - lp_lo) * env * 1.6)   # band = smooth minus rumble
	return _finish(d)

## Body hitting water: a bright splash of high-passed noise, fast decay.
func _make_splash() -> AudioStreamWAV:
	var n := int(0.18 * RATE)
	var d := _buf(0.18)
	var rng := RandomNumberGenerator.new()
	rng.seed = 43
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		var env := minf(t * 200.0, 1.0) * exp(-15.0 * t)
		var w := rng.randf_range(-1.0, 1.0)
		lp += 0.1 * (w - lp)
		_w(d, i, (w - lp) * env * 0.8)          # white minus rumble = the fizz
	return _finish(d)

## Milestone fanfare: two rising notes with a shimmer of octave harmonics.
func _make_fanfare() -> AudioStreamWAV:
	var n := int(0.38 * RATE)
	var d := _buf(0.38)
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		if t < 0.2:
			v += (sin(TAU * 660.0 * t) + 0.4 * sin(TAU * 1320.0 * t)) * exp(-9.0 * t)
		if t >= 0.1:
			var t2 := t - 0.1
			v += (sin(TAU * 990.0 * t2) + 0.4 * sin(TAU * 1980.0 * t2)) * exp(-7.0 * t2)
		_w(d, i, v * 0.4)
	return _finish(d)
