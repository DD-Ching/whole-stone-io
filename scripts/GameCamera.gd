class_name GameCamera
extends Camera2D
## Follows the player (it's parented to them), shakes on impact, and — the .io touch —
## zooms OUT as the player grows, so your ever-bigger stone always stays on screen.

const KICK_MAX := 42.0   ## hard cap on the directional kick offset, so a bad caller can't fling the view off-screen

var _shake := 0.0
var _kick := Vector2.ZERO
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	make_current()
	position_smoothing_enabled = true
	position_smoothing_speed = 9.0
	var half := Game.ARENA_SIZE * 0.5
	var pad := Game.WALL_THICK
	limit_left = int(-half.x - pad)
	limit_right = int(half.x + pad)
	limit_top = int(-half.y - pad)
	limit_bottom = int(half.y + pad)
	_rng.randomize()

func add_shake(amount: float, dir := Vector2.ZERO) -> void:
	_shake = minf(_shake + amount, 60.0)
	if dir != Vector2.ZERO:
		# Normalize the direction (callers may pass a full impulse vector) and clamp the
		# accumulated kick, so the view can never be flung far off the player.
		_kick = (_kick + dir.normalized() * amount * 0.35).limit_length(KICK_MAX)

func kick(amount: float) -> void:
	_shake = minf(_shake + amount, 80.0)

## Snap the camera onto the player instantly (no smoothing slide, no leftover shake/kick).
## Used on (re)spawn so a teleport doesn't make the view glide across the whole map.
func snap() -> void:
	_kick = Vector2.ZERO
	_shake = 0.0
	offset = Vector2.ZERO
	reset_smoothing()

func _process(delta: float) -> void:
	var f := get_parent() as Fighter
	if f:
		# Zoomed out a bit (0.82 base) so the player reads as SMALL in a BIG map, then eases
		# further out as they grow so the ever-bigger stone still fits.
		var z := clampf(pow(f.mass, -0.12) * 0.82, 0.2, 0.86)   # low floor so a limitless giant still fits on screen
		zoom = zoom.lerp(Vector2(z, z), clampf(3.0 * delta, 0.0, 1.0))
	_shake = maxf(0.0, _shake - 70.0 * delta)
	_kick = _kick.move_toward(Vector2.ZERO, 420.0 * delta)
	var off := _kick
	if _shake > 0.5:
		off += Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)) * _shake
	offset = off
