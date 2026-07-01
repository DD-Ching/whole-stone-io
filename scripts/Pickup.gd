class_name Pickup
extends RigidBody2D
## A loose object in the arena — the physics glue of the whole loop. GEMs are the food
## (absorb to grow); WEAPON crates swap your head to a Hammer or Sickle. Because they
## are real RigidBody2Ds, a swung head or a slam BATS them across the field, and death
## sprays a fan of them — the flung, bouncing loot is where the physics engine shows.

enum Kind { GEM, WEAPON }

var kind: int = Kind.GEM
var value := Game.GEM_MASS
var weapon_type: int = Weapon.Type.STONE
var tint := Color("d9c24a")
var consumed := false

var _t := 0.0
var _shape: CollisionShape2D
var _circle: CircleShape2D

func _ready() -> void:
	add_to_group("pickup")
	gravity_scale = 0.0
	linear_damp = 2.6
	angular_damp = 4.0
	lock_rotation = true
	collision_layer = Game.L_PICKUP
	collision_mask = Game.L_WALL | Game.L_PICKUP   # gems bounce off walls and each other (no stacking)
	_circle = CircleShape2D.new()
	_circle.radius = 9.0
	_shape = CollisionShape2D.new()
	_shape.shape = _circle
	add_child(_shape)

func setup(pos: Vector2, val: float, k: int, col: Color, wtype := Weapon.Type.STONE) -> void:
	position = pos
	kind = k
	value = val
	tint = col
	weapon_type = wtype
	if _circle:
		_circle.radius = 16.0 if kind == Kind.WEAPON else 9.0
	queue_redraw()

func fling(impulse: Vector2) -> void:
	apply_central_impulse(impulse)

## Force fields + terrain push gems around too (magnet vortex, currents, downhill drift).
func apply_env_force(accel: Vector2, _delta: float) -> void:
	apply_central_force(accel)

## A reversal/cushion zone bounces a gem's momentum back (clamped so it can't ratchet up).
func env_reflect(factor: float, outward: Vector2) -> void:
	linear_velocity = (-linear_velocity * factor + outward).limit_length(1400.0)

func consume() -> void:
	if consumed:
		return
	consumed = true
	queue_free()

func _process(delta: float) -> void:
	_t += delta
	queue_redraw()

func _draw() -> void:
	if kind == Kind.WEAPON:
		_draw_crate()
		return
	var pulse := 1.0 + 0.12 * sin(_t * 5.0)
	var r := _circle.radius * pulse
	draw_circle(Vector2.ZERO, r, tint)
	draw_circle(Vector2(-r * 0.3, -r * 0.3), r * 0.4, tint.lightened(0.4))
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 14, tint.darkened(0.35), 1.5)

func _draw_crate() -> void:
	var pulse := 1.0 + 0.08 * sin(_t * 4.0)
	var s := 16.0 * pulse
	var box := Rect2(Vector2(-s, -s), Vector2(s * 2.0, s * 2.0))
	var col := _crate_color()
	draw_rect(box, col.darkened(0.1))
	draw_rect(box, Color(0.1, 0.09, 0.08), false, 3.0)
	var font := ThemeDB.fallback_font
	if font:
		var label := _crate_letter()
		var fs := 20
		var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		draw_string(font, Vector2(-tw.x * 0.5, tw.y * 0.32), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.95))

func _crate_color() -> Color:
	match weapon_type:
		Weapon.Type.HAMMER:
			return Color("c56a3a")
		Weapon.Type.SICKLE:
			return Color("6aa8c5")
		Weapon.Type.STAFF:
			return Color("9a8a5a")
		_:
			return Color("8a8a92")

func _crate_letter() -> String:
	match weapon_type:
		Weapon.Type.HAMMER:
			return "H"
		Weapon.Type.SICKLE:
			return "S"
		Weapon.Type.STAFF:
			return "P"
		_:
			return "O"
