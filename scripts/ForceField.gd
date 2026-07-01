class_name ForceField
extends Area2D
## An environmental force zone (its own Area2D, on the L_FIELD collision layer, monitoring
## fighters + gems). Six flavours:
##   GRAVITY  — a well that pulls things in, stronger near the centre (重力場 梯度).
##   MAGNET   — MANA vortex: sucks loose gems inward hard (魔力/磁力場).
##   REPULSOR — a fan that shoves everything outward (力場彈開).
##   CURRENT  — a conveyor/wind that ADDS velocity along its direction (加); pair it with a
##              cushion (減) for the 加減法 push-and-drag interplay.
##   CUSHION  — a soft air layer (柔軟氣層/氣墊): slow bodies settle, MODERATE bodies bounce
##              elastically (airbag), but a FAST/hard body PIERCES through (刺破) and pops it,
##              so it can't buffer in time (來不及緩衝).
##   REVERSAL — counter terrain (關鍵逆轉/相剋): reflects a body's momentum back on entry.

enum Kind { GRAVITY, MAGNET, REPULSOR, CUSHION, CURRENT, REVERSAL }

const STRENGTH := {
	Kind.GRAVITY: 720.0, Kind.MAGNET: 1250.0, Kind.REPULSOR: 980.0,
	Kind.CUSHION: 0.0, Kind.CURRENT: 720.0, Kind.REVERSAL: 900.0,
}
const CUSHION_K := 5.2         ## damping coefficient inside a working cushion
const CUSHION_SOFT := 170.0    ## below this a body just settles softly
const CUSHION_PIERCE := 560.0  ## above this a body punches straight through (刺破)

var kind: int = Kind.GRAVITY
var radius := 230.0
var strength := 720.0
var field_dir := Vector2.RIGHT

var _t := 0.0
var _pierced := 0.0            ## >0 while a cushion is popped and cannot buffer
var _circle: CircleShape2D

func setup(k: int, pos: Vector2, r: float, dir := Vector2.RIGHT) -> void:
	kind = k
	position = pos
	radius = r
	field_dir = dir.normalized()
	strength = STRENGTH[k]
	if _circle:
		_circle.radius = radius

func _ready() -> void:
	add_to_group("field")
	z_index = -1
	collision_layer = Game.L_FIELD
	collision_mask = Game.L_FIGHTER | Game.L_PICKUP
	monitoring = true
	monitorable = false
	_circle = CircleShape2D.new()
	_circle.radius = radius
	var cs := CollisionShape2D.new()
	cs.shape = _circle
	add_child(cs)
	body_entered.connect(_on_entered)

func _physics_process(delta: float) -> void:
	_t += delta
	if _pierced > 0.0:
		_pierced = maxf(0.0, _pierced - delta)
	for body in get_overlapping_bodies():
		_apply(body, delta)
	queue_redraw()

func _apply(body, delta: float) -> void:
	var is_fighter := body is Fighter
	if is_fighter and (body as Fighter).is_dead():
		return
	var to: Vector2 = global_position - body.global_position
	var dist := to.length()
	var dir := (to / dist) if dist > 0.001 else Vector2.ZERO
	var falloff := clampf(1.0 - dist / radius, 0.0, 1.0)
	match kind:
		Kind.GRAVITY:
			body.apply_env_force(dir * strength * falloff, delta)
		Kind.MAGNET:
			# Mostly a gem vortex; barely tugs a (heavier) fighter.
			body.apply_env_force(dir * strength * falloff * (0.22 if is_fighter else 1.0), delta)
		Kind.REPULSOR:
			body.apply_env_force(-dir * strength * falloff, delta)
		Kind.CURRENT:
			body.apply_env_force(field_dir * strength, delta)
		Kind.CUSHION:
			_apply_cushion(body, is_fighter, delta)
		Kind.REVERSAL:
			pass   # entry-only (see _on_entered)

func _apply_cushion(body, is_fighter: bool, delta: float) -> void:
	if _pierced > 0.0:
		return   # popped — it can't buffer right now (來不及緩衝)
	var bvel: Vector2 = (body as Fighter).velocity if is_fighter else (body as Pickup).linear_velocity
	if bvel.length() > CUSHION_PIERCE:
		return   # too fast — it pierces straight through
	body.apply_env_force(-bvel * CUSHION_K, delta)   # soft catch
	if is_fighter:
		(body as Fighter).mark_cushioned()

func _on_entered(body) -> void:
	var is_fighter := body is Fighter
	if is_fighter and (body as Fighter).is_dead():
		return
	if kind == Kind.REVERSAL:
		var outward: Vector2 = (body.global_position - global_position).normalized() * strength * 0.55
		_reflect(body, is_fighter, 1.0, outward)   # pure reflect (no energy added) + an outward shove
		if is_fighter:
			Game.popup("COUNTER!", body.global_position + Vector2(0, -28), Color(1, 0.5, 0.5), 1.2)
	elif kind == Kind.CUSHION:
		var bvel: Vector2 = (body as Fighter).velocity if is_fighter else (body as Pickup).linear_velocity
		var speed := bvel.length()
		var outward: Vector2 = (body.global_position - global_position).normalized()
		if speed > CUSHION_PIERCE:
			# Only a heavy body (fighter) can burst the air layer; a gem just slips through.
			if is_fighter:
				_pierced = 0.7
				Game.popup("PIERCED!", global_position + Vector2(0, -24), Color(1, 0.55, 0.4), 1.15)
		elif speed > CUSHION_SOFT:
			_reflect(body, is_fighter, 0.55, outward * 30.0)   # elastic airbag bounce

func _reflect(body, is_fighter: bool, factor: float, outward: Vector2) -> void:
	if is_fighter:
		(body as Fighter).env_reflect(factor, outward)
	elif body is Pickup:
		(body as Pickup).env_reflect(factor, outward)

# --- drawing ----------------------------------------------------------------------

func _draw() -> void:
	var col := _color()
	var pulse := 0.5 + 0.5 * sin(_t * 3.0)
	var popped := kind == Kind.CUSHION and _pierced > 0.0
	var fill_a := 0.05 + 0.05 * pulse
	if popped:
		fill_a = 0.02
	draw_circle(Vector2.ZERO, radius, Color(col.r, col.g, col.b, fill_a))
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, Color(col.r, col.g, col.b, 0.15 + 0.35 * pulse), 3.0)
	match kind:
		Kind.GRAVITY, Kind.MAGNET:
			_radial_arrows(col, true)
		Kind.REPULSOR:
			_radial_arrows(col, false)
		Kind.CURRENT:
			_flow_arrows(col)
		Kind.REVERSAL:
			draw_arc(Vector2.ZERO, radius * 0.5, 0.4, 0.4 + PI * 1.4, 24, col, 3.0)
			draw_arc(Vector2.ZERO, radius * 0.5, 0.4 + PI, 0.4 + PI + PI * 1.4, 24, col, 3.0)
		Kind.CUSHION:
			for k in range(3):
				draw_arc(Vector2.ZERO, radius * (0.4 + 0.25 * k), 0.0, TAU, 32, Color(col.r, col.g, col.b, 0.12), 2.0)
	var font := ThemeDB.fallback_font
	if font:
		var label := ("PIERCED" if popped else _name())
		var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15)
		draw_string(font, Vector2(-tw.x * 0.5, 5.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(col.r, col.g, col.b, 0.7))

func _radial_arrows(col: Color, inward: bool) -> void:
	for i in range(8):
		var a := TAU * i / 8.0
		var d := Vector2.RIGHT.rotated(a)
		var outer := d * radius * 0.82
		var inner := d * radius * 0.5
		if inward:
			_arrow(outer, inner, col)
		else:
			_arrow(inner, outer, col)

func _flow_arrows(col: Color) -> void:
	var n := field_dir
	var perp := n.orthogonal()
	for i in range(-1, 2):
		var base := perp * i * radius * 0.5 - n * radius * 0.6
		_arrow(base, base + n * radius * 1.2, col)

func _arrow(from: Vector2, to: Vector2, col: Color) -> void:
	draw_line(from, to, Color(col.r, col.g, col.b, 0.75), 2.5)
	var d := (to - from).normalized()
	var p := d.orthogonal()
	draw_line(to, to - d * 10.0 + p * 6.0, Color(col.r, col.g, col.b, 0.75), 2.5)
	draw_line(to, to - d * 10.0 - p * 6.0, Color(col.r, col.g, col.b, 0.75), 2.5)

func _color() -> Color:
	match kind:
		Kind.GRAVITY: return Color(0.5, 0.55, 1.0)
		Kind.MAGNET: return Color(0.82, 0.42, 0.98)
		Kind.REPULSOR: return Color(1.0, 0.55, 0.25)
		Kind.CUSHION: return Color(0.5, 0.9, 1.0)
		Kind.CURRENT: return Color(0.4, 0.92, 0.5)
		_: return Color(1.0, 0.42, 0.42)

func _name() -> String:
	match kind:
		Kind.GRAVITY: return "GRAVITY"
		Kind.MAGNET: return "MANA"
		Kind.REPULSOR: return "REPEL"
		Kind.CUSHION: return "AIR"
		Kind.CURRENT: return "CURRENT"
		_: return "REVERSAL"
