class_name FxLayer
extends Node2D
## Every spark and burst in the game lives in THIS one node: a fixed ring buffer of
## particles and a single _draw() — never a node per effect (per-effect node churn is
## exactly the mobile cost the terrain bake removed). Callers just ask for a burst;
## requests outside the camera's view are dropped, since nobody would see them.

const MAX := 256

var _pos := PackedVector2Array()
var _vel := PackedVector2Array()
var _col := PackedColorArray()
var _age := PackedFloat32Array()
var _life := PackedFloat32Array()
var _size := PackedFloat32Array()
var _head := 0

func _ready() -> void:
	z_index = 40
	_pos.resize(MAX)
	_vel.resize(MAX)
	_col.resize(MAX)
	_age.resize(MAX)
	_life.resize(MAX)
	_size.resize(MAX)
	for i in MAX:
		_life[i] = 0.0
		_age[i] = 1.0
	set_process(false)

## A radial spray of sparks — hits, clashes, deaths (pass the victim's color).
func burst(at: Vector2, color: Color, count: int, speed: float, spark_size := 3.0) -> void:
	if not _on_screen(at):
		return
	var rng := Game.rng()
	for i in count:
		var a := rng.randf() * TAU
		var s := speed * rng.randf_range(0.35, 1.0)
		_spawn(at, Vector2(cos(a), sin(a)) * s, color, rng.randf_range(0.18, 0.42), spark_size)
	set_process(true)

## A clean expanding ring — milestone fanfares, big punctuation.
func ring(at: Vector2, color: Color, count := 26, speed := 340.0) -> void:
	if not _on_screen(at):
		return
	for i in count:
		var a := TAU * float(i) / float(count)
		_spawn(at, Vector2(cos(a), sin(a)) * speed, color, 0.5, 3.5)
	set_process(true)

func _spawn(p: Vector2, v: Vector2, c: Color, life: float, sz: float) -> void:
	_pos[_head] = p
	_vel[_head] = v
	_col[_head] = c
	_age[_head] = 0.0
	_life[_head] = life
	_size[_head] = sz
	_head = (_head + 1) % MAX    # on overflow the oldest spark is silently recycled

func _on_screen(at: Vector2) -> bool:
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		return true
	var half := get_viewport_rect().size * 0.5 / cam.zoom
	return absf(at.x - cam.global_position.x) < half.x + 120.0 \
		and absf(at.y - cam.global_position.y) < half.y + 120.0

func _process(delta: float) -> void:
	var any := false
	for i in MAX:
		if _age[i] >= _life[i]:
			continue
		_age[i] += delta
		_pos[i] += _vel[i] * delta
		_vel[i] *= maxf(0.0, 1.0 - 6.0 * delta)
		any = true
	queue_redraw()               # one final redraw after the last spark dies clears the canvas
	if not any:
		set_process(false)

func _draw() -> void:
	for i in MAX:
		if _age[i] >= _life[i]:
			continue
		var k: float = 1.0 - _age[i] / _life[i]
		var c := _col[i]
		c.a = k
		var s: float = _size[i] * (0.5 + 0.5 * k)
		draw_rect(Rect2(_pos[i] - Vector2(s, s) * 0.5, Vector2(s, s)), c)
