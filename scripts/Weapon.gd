class_name Weapon
extends Node2D
## The heavy head on the end of Arthur's arm — the ENTIRE stone he lifted because he
## could not draw the sword. This is the game's core feel, lifted from the reference
## main-character design: the head is a spring-damped pendulum that FOLLOWS the aim
## with weight and lag (never snapping), and DRAGGING the aim around the wielder whips
## it up to real angular speed. How hard a hit lands is read straight off the head's
## measured speed at contact — a slow drag only pushes, a fast whip launches.
##
## Three heads share this one body via a multiplier table:
##   STONE  — balanced, the default boulder.
##   HAMMER (錘) — huge knockback + damage, but heavy and laggy to swing.
##   SICKLE (鐮) — fast, long reach, low knockback, wins on sustained speed.
##
## Built entirely in code (its Area2D hitbox is spawned in _ready), so an entity is
## just "attach Weapon as a child of a Fighter" with no scene wiring.

enum Type { STONE, HAMMER, SICKLE }
enum State { IDLE, SWING, SLAM, SPIN }

# Per-type multipliers on the shared base feel. Keys: dmg, knock, reach, head,
# stiff (spring), damp, drag, avel (angular-speed cap).
const TYPES := {
	Type.STONE:  {"dmg": 1.0,  "knock": 1.0,  "reach": 1.0,  "head": 1.0,  "stiff": 1.0,  "damp": 1.0,  "drag": 1.0,  "avel": 1.0,  "name": "STONE"},
	Type.HAMMER: {"dmg": 1.55, "knock": 1.9,  "reach": 0.9,  "head": 1.25, "stiff": 0.8,  "damp": 1.2,  "drag": 0.9,  "avel": 0.78, "name": "HAMMER"},
	Type.SICKLE: {"dmg": 0.85, "knock": 0.62, "reach": 1.28, "head": 0.82, "stiff": 1.3,  "damp": 0.82, "drag": 1.35, "avel": 1.4,  "name": "SICKLE"},
}

# Shared base feel (before per-type + per-mass scaling).
const FOLLOW_STIFFNESS := 12.0
const REST_DAMPING := 4.6
const MAX_AVEL := 26.0
const DRAG_GAIN := 5.0
const PASSIVE_DRAG := 0.4      ## fraction of aim-drag applied even when not committed-swinging (point-and-flick still whips)
const INERTIA_GAIN := 1.0
const HEAD_RADIUS_BASE := 22.0
const SLAM_WINDUP := 0.32
const SLAM_RECOVER := 0.42
const SPIN_RATE := 16.0
const SPIN_ACCEL := 40.0
const SPIN_MIN_STAMINA := 30.0
const SPIN_HIT_INTERVAL := 0.45
const SPIN_SPEED_REF := 560.0  ## the whirl reads as this head speed for damage
const PICKUP_FLING := 2.4      ## impulse multiplier when the head bats a loose gem
const CLASH_SPEED := 620.0     ## combined head speed above which two swung stones CLASH and bounce apart

var type: int = Type.STONE
var state: int = State.IDLE
var aim_angle := 0.0           ## smoothed facing, for the owner's facing dot

var _target_aim := 0.0
var _prev_target := 0.0
var _aim_avel := 0.0           ## how fast the aim is being dragged around the owner (signed)
var _angle := 0.0             ## world angle of the head around the owner (the pendulum)
var _avel := 0.0             ## angular velocity of the head (rad/s)
var _head_dist := 0.0
var _lift := 0.0             ## 0..1 raised-overhead amount (slam telegraph)
var _state_time := 0.0
var _slam_struck := false
var _swinging := false
var _head_world := Vector2.ZERO
var _head_speed := 0.0        ## measured head speed (px/s) — the swing's "relative_speed"
var _prev_owner_vel := Vector2.ZERO
var _hit_ids := {}
var _hit_clear := 0.0
var _spin_clear := 0.0
var _clash_cd := 0.0
var _trail: Array = []

# Cached derived (recomputed on mass change).
var _head_radius := HEAD_RADIUS_BASE
var _arm_length := 74.0
var _stiffness := FOLLOW_STIFFNESS
var _damping := REST_DAMPING
var _drag := DRAG_GAIN
var _max_avel := MAX_AVEL

var _owner: Fighter
var _hitbox: Area2D
var _hitshape: CollisionShape2D
var _circle: CircleShape2D

func _ready() -> void:
	_owner = get_parent() as Fighter
	_hitbox = Area2D.new()
	# The head lives on its OWN collision layer and is monitorable, so other weapons'
	# hitboxes can detect it — that's what makes two swung stones physically CLASH.
	_hitbox.collision_layer = Game.L_WEAPON
	_hitbox.collision_mask = Game.L_FIGHTER | Game.L_PICKUP | Game.L_WEAPON
	_hitbox.monitoring = true
	_hitbox.monitorable = true
	_circle = CircleShape2D.new()
	_circle.radius = _head_radius
	_hitshape = CollisionShape2D.new()
	_hitshape.shape = _circle
	_hitbox.add_child(_hitshape)
	add_child(_hitbox)
	refresh_scale(_owner.mass if _owner else 1.0)
	_head_dist = _arm_length
	_head_world = _head_at()

func set_type(t: int) -> void:
	type = t
	refresh_scale(_owner.mass if _owner else 1.0)

func type_name() -> String:
	return TYPES[type]["name"]

## Recompute head size, reach and swing feel for the owner's current mass. Bigger =
## a larger head with more reach, but a lower angular-speed cap and a softer spring
## (laggier) — the weight-vs-mobility trade the whole game turns on.
func refresh_scale(mass: float) -> void:
	var t: Dictionary = TYPES[type]
	var m := sqrt(maxf(mass, 0.001))
	var agility := Game.agility_for_mass(mass)
	_head_radius = HEAD_RADIUS_BASE * float(t["head"]) * m
	var body_r := Game.body_radius_for_mass(mass)
	_arm_length = (body_r * 1.1 + _head_radius + 22.0) * float(t["reach"])
	_stiffness = FOLLOW_STIFFNESS * float(t["stiff"]) * agility
	_damping = REST_DAMPING * float(t["damp"])
	_drag = DRAG_GAIN * float(t["drag"])
	_max_avel = MAX_AVEL * float(t["avel"]) * agility
	if _circle:
		_circle.radius = _head_radius * 0.98

# --- control API (shared by Player and Bot) ---------------------------------------

func aim_at(angle: float) -> void:
	_target_aim = angle

func set_swinging(on: bool) -> void:
	_swinging = on

func do_slam() -> void:
	if state == State.SLAM:
		return
	if not _owner.try_spend_stamina(Game.SLAM_STAMINA):
		_owner.on_too_tired()
		return
	_slam_struck = false
	_change_state(State.SLAM)

## Hold-to-whirl. Called every frame with the key's held state; idempotent.
func set_spin(on: bool) -> void:
	if on:
		if state == State.IDLE or state == State.SWING:
			if _owner.stamina >= SPIN_MIN_STAMINA:
				_hit_ids.clear()
				_spin_clear = 0.0
				_change_state(State.SPIN)
			else:
				_owner.on_too_tired()
	else:
		if state == State.SPIN:
			_change_state(State.IDLE)

func head_speed() -> float:
	return _head_speed

func reach() -> float:
	return _arm_length + _head_radius

## Settle the head back to a clean idle — used when a fighter (re)spawns. Critically,
## it re-seeds the head-position trackers to the CURRENT (post-teleport) position so the
## first frame after a respawn measures ~0 head speed, not a teleport-distance spike that
## would land a free full-power hit.
func reset() -> void:
	state = State.IDLE
	_avel = 0.0
	_head_dist = _arm_length
	_hit_ids.clear()
	_trail.clear()
	_swinging = false
	_head_speed = 0.0
	_head_world = _head_at()
	_prev_target = _target_aim
	_prev_owner_vel = _owner.velocity if _owner else Vector2.ZERO

func is_busy() -> bool:
	return state == State.SLAM

# --- per-frame --------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	aim_angle = lerp_angle(aim_angle, _target_aim, clampf(10.0 * delta, 0.0, 1.0))
	_state_time += delta

	# Aim drag speed (signed) — the "how fast are you whipping the head around" input.
	_aim_avel = wrapf(_target_aim - _prev_target, -PI, PI) / maxf(delta, 0.0001)
	_prev_target = _target_aim

	# Owner acceleration this frame — what sloshes the heavy head around.
	var ov: Vector2 = _owner.velocity if _owner else Vector2.ZERO
	var accel: Vector2 = (ov - _prev_owner_vel) / maxf(delta, 0.0001)
	accel = accel.limit_length(3000.0)
	_prev_owner_vel = ov

	match state:
		State.IDLE, State.SWING:
			_update_pendulum(delta, accel)
			_apply_swing_hits(delta)
			var fast := _head_speed > Game.HIT_SPEED_MIN
			if fast and state == State.IDLE:
				_change_state(State.SWING)
			elif not fast and state == State.SWING:
				_change_state(State.IDLE)
		State.SLAM:
			_process_slam(delta)
		State.SPIN:
			_process_spin(delta)

	rotation = _angle
	if _hitbox:
		_hitbox.position = Vector2(_head_dist, 0.0)
	_update_trail(delta)
	_check_clash(delta)
	queue_redraw()

## Two swung stones colliding: if their combined head speed is high enough, both bounce
## off each other (reverse spin), the wielders are shoved apart, and a spark pops. Uses the
## weapon's own L_WEAPON collision layer via get_overlapping_areas().
func _check_clash(delta: float) -> void:
	_clash_cd -= delta
	if _clash_cd > 0.0:
		return
	for area in _hitbox.get_overlapping_areas():
		var ow := area.get_parent() as Weapon
		if ow == null or ow == self:
			continue
		if _head_speed + ow._head_speed < CLASH_SPEED:
			continue
		_avel = -_avel * 0.6
		_clash_cd = 0.28
		if _owner and ow._owner:
			var push := (_owner.global_position - ow._owner.global_position).normalized() * 170.0
			_owner.lunge(push)
			_owner.on_hit_feedback(14.0, push, false)
			# Both weapons run this each frame — emit the shared popup from just one side.
			if _owner.get_instance_id() < ow._owner.get_instance_id():
				var mid := (_head_at() + ow._head_at()) * 0.5
				Game.popup("CLASH!", mid + Vector2(0, -18), Color(1.0, 0.95, 0.7), 1.15)
		break

func _update_pendulum(delta: float, accel: Vector2) -> void:
	var diff := wrapf(_target_aim - _angle, -PI, PI)
	var torque := _stiffness * diff - _damping * _avel
	# The owner's movement sloshes the heavy head (pendulum pseudo-force).
	torque += (accel.x * sin(_angle) - accel.y * cos(_angle)) / maxf(_arm_length, 1.0) * INERTIA_GAIN
	# The aim-drag whip: rotating where you point spins the head that way, building
	# real speed. A committed swing (button held) applies it in full and costs stamina;
	# otherwise a weaker passive whip still lets a flick land.
	if absf(_aim_avel) > 0.2:
		if _swinging and _owner.try_spend_stamina(Game.SWING_STAMINA_RATE * delta):
			torque += _aim_avel * _drag
		else:
			torque += _aim_avel * _drag * PASSIVE_DRAG
	_avel = clampf(_avel + torque * delta, -_max_avel, _max_avel)
	_angle = wrapf(_angle + _avel * delta, -PI, PI)
	# A little stretch + lift under speed sells the whip.
	var target_dist := _arm_length + clampf(absf(_avel) * 0.7, 0.0, 16.0)
	_head_dist = lerpf(_head_dist, target_dist, clampf(10.0 * delta, 0.0, 1.0))
	_lift = lerpf(_lift, clampf(_head_speed / 1800.0, 0.0, 0.4), clampf(8.0 * delta, 0.0, 1.0))

func _process_slam(delta: float) -> void:
	_angle = lerp_angle(_angle, _target_aim, clampf(14.0 * delta, 0.0, 1.0))
	_avel = 0.0
	if not _slam_struck:
		var t := clampf(_state_time / SLAM_WINDUP, 0.0, 1.0)
		_head_dist = lerpf(_arm_length, _arm_length * 0.55, t)   # rear back
		_lift = _ease_out(t)
		if t >= 1.0:
			_slam_struck = true
			_state_time = 0.0
			_do_slam_impact()
	else:
		var t := clampf(_state_time / SLAM_RECOVER, 0.0, 1.0)
		_head_dist = lerpf(_arm_length * 1.35, _arm_length, _ease_out(t))
		_lift = lerpf(_lift, 0.0, clampf(9.0 * delta, 0.0, 1.0))
		if t >= 1.0:
			_avel = 0.0
			_change_state(State.IDLE)

func _do_slam_impact() -> void:
	_head_dist = _arm_length * 1.35
	var point := _owner.global_position + Vector2(_arm_length * 1.35, 0.0).rotated(_target_aim)
	var t: Dictionary = TYPES[type]
	var radius := _arm_length * 1.5 + _head_radius
	var mass_factor := sqrt(maxf(_owner.mass, 0.001))
	var dmg := Game.BASE_DMG * float(t["dmg"]) * mass_factor * 1.7
	var knock := Game.BASE_KNOCK * float(t["knock"]) * 1.8
	# Radial burst — everything in range is damaged + launched outward from the point.
	for f in get_tree().get_nodes_in_group("fighter"):
		if f == _owner or not is_instance_valid(f):
			continue
		var d: float = f.global_position.distance_to(point)
		if d > radius + f.mass * 4.0:
			continue
		var dir: Vector2 = (f.global_position - point).normalized()
		if dir == Vector2.ZERO:
			dir = Vector2.RIGHT.rotated(_target_aim)
		var falloff := 1.0 - clampf(d / maxf(radius, 1.0), 0.0, 1.0) * 0.5
		if f.take_damage(dmg * falloff, dir, knock * falloff):
			_owner.on_scored_kill(f)
	for p in get_tree().get_nodes_in_group("pickup"):
		if not is_instance_valid(p):
			continue
		var pd: float = p.global_position.distance_to(point)
		if pd <= radius * 1.4 and p.has_method("fling"):
			var pdir: Vector2 = (p.global_position - point).normalized()
			p.fling(pdir * (radius - pd) * 3.0)
	Game.popup("SMASH!", point + Vector2(0, -30), Color(1.0, 0.82, 0.4), 1.3)
	_owner.on_hit_feedback(26.0, Vector2.RIGHT.rotated(_target_aim), true)

func _process_spin(delta: float) -> void:
	if not _owner.try_spend_stamina(Game.SPIN_STAMINA_RATE * delta):
		_owner.on_too_tired()
		_change_state(State.IDLE)
		return
	var target := SPIN_RATE * (1.0 if _avel >= 0.0 else -1.0)
	_avel = move_toward(_avel, target, SPIN_ACCEL * delta)
	_angle = wrapf(_angle + _avel * delta, -PI, PI)
	_head_dist = lerpf(_head_dist, _arm_length + 10.0, clampf(8.0 * delta, 0.0, 1.0))
	_lift = lerpf(_lift, 0.24, clampf(6.0 * delta, 0.0, 1.0))
	_apply_spin_hits()
	_spin_clear -= delta
	if _spin_clear <= 0.0:
		_hit_ids.clear()
		_spin_clear = SPIN_HIT_INTERVAL

# --- hit resolution ---------------------------------------------------------------

func _apply_swing_hits(delta: float) -> void:
	_hit_clear -= delta
	if _hit_clear <= 0.0:
		_hit_ids.clear()
		_hit_clear = Game.HIT_INTERVAL
	if _head_speed < Game.HIT_SPEED_MIN:
		return
	for body in _hitbox.get_overlapping_bodies():
		if body == _owner or not is_instance_valid(body):
			continue
		var id: int = body.get_instance_id()
		if _hit_ids.has(id):
			continue
		if body is Fighter:
			_hit_ids[id] = true
			_score_hit(body, _head_speed, false)
		elif body.has_method("fling"):
			_hit_ids[id] = true
			var dir: Vector2 = (body.global_position - _owner.global_position).normalized()
			body.fling(dir * _head_speed * PICKUP_FLING * 0.1)

func _apply_spin_hits() -> void:
	for body in _hitbox.get_overlapping_bodies():
		if body == _owner or not is_instance_valid(body):
			continue
		var id: int = body.get_instance_id()
		if _hit_ids.has(id):
			continue
		if body is Fighter:
			_hit_ids[id] = true
			_score_hit(body, maxf(_head_speed, SPIN_SPEED_REF), true)
		elif body.has_method("fling"):
			_hit_ids[id] = true
			var dir: Vector2 = (body.global_position - _owner.global_position).normalized()
			body.fling(dir * SPIN_SPEED_REF * PICKUP_FLING * 0.1)

func _score_hit(victim: Fighter, speed: float, is_spin: bool) -> void:
	var t: Dictionary = TYPES[type]
	var mass_factor := sqrt(maxf(_owner.mass, 0.001))
	var speed_factor := clampf(speed / Game.REF_HEAD_SPEED, 0.35, 2.4)
	var dmg := Game.BASE_DMG * float(t["dmg"]) * mass_factor * speed_factor
	var knock := (Game.BASE_KNOCK * float(t["knock"])) * speed_factor
	var dir: Vector2 = (victim.global_position - _owner.global_position).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT.rotated(_angle)
	var died := victim.take_damage(dmg, dir, knock)
	var shake := clampf(speed_factor * (18.0 if is_spin else 26.0), 6.0, 44.0)
	_owner.on_hit_feedback(shake * (0.5 if is_spin else 1.0), dir, false)
	# A scored hit commits the wielder's mass — a capped forward lunge along the blow.
	if not is_spin:
		var nudge := clampf(speed * 0.05, 0.0, 160.0)
		_owner.lunge(dir * nudge)
	if died:
		_owner.on_scored_kill(victim)
	elif not is_spin:
		Game.popup("BONK!", victim.global_position + Vector2(0, -victim.body_radius - 12.0), t["color"] if t.has("color") else Color(1, 0.95, 0.7), 0.9)

func _head_at() -> Vector2:
	return global_position + Vector2(_head_dist, 0.0).rotated(rotation)

func _update_trail(delta: float) -> void:
	var head := _head_at()
	_head_speed = minf(head.distance_to(_head_world) / maxf(delta, 0.0001), 3600.0)
	_head_world = head
	if _head_speed > Game.HIT_SPEED_MIN or state == State.SPIN or state == State.SLAM:
		_trail.push_back({"pos": head, "age": 0.0})
	for p in _trail:
		p.age += delta
	while _trail.size() > 0 and _trail[0].age > 0.2:
		_trail.pop_front()

func _change_state(s: int) -> void:
	state = s
	_state_time = 0.0

func _ease_out(t: float) -> float:
	return 1.0 - pow(1.0 - t, 3.0)

# --- drawing (all placeholder art, in code) ---------------------------------------

func _draw() -> void:
	_draw_trail()
	var head := Vector2(_head_dist, 0.0)
	var r := _head_radius * (1.0 + 0.4 * _lift)
	var speed_t := clampf(_head_speed / 1400.0, 0.0, 1.0)
	var base_col: Color = _owner.color if _owner else Color("cfd0d8")

	# Overhead shadow while lifted.
	if _lift > 0.01:
		draw_circle(head - Vector2(16.0 * _lift, 0.0), r * 0.9, Color(0, 0, 0, 0.26 * _lift))

	# The haft: a grip line from the wielder out to the head.
	draw_line(Vector2(6.0, 0.0), head, Color(0.32, 0.25, 0.19), 7.0)
	draw_line(Vector2(6.0, 0.0), head, Color(0.55, 0.44, 0.32), 3.0)

	if state == State.SPIN:
		draw_arc(Vector2.ZERO, _head_dist, 0.0, TAU, 40, Color(1.0, 0.7, 0.3, 0.3), 4.0)

	match type:
		Type.HAMMER:
			_draw_hammer(head, r, speed_t)
		Type.SICKLE:
			_draw_sickle(head, r, speed_t)
		_:
			_draw_stone(head, r, speed_t, base_col)

	# A heat ring when the head is really moving — reads momentum at a glance.
	if speed_t > 0.25 and (state == State.SWING or state == State.SPIN):
		draw_arc(head, r + 6.0, 0.0, TAU, 32, Color(1.0, 0.7, 0.25, speed_t * 0.9), 3.0)

func _draw_stone(head: Vector2, r: float, speed_t: float, base_col: Color) -> void:
	var stone := Color(0.46, 0.44, 0.5).lerp(Color(1.0, 0.5, 0.2), speed_t * 0.7)
	draw_circle(head, r, stone)
	draw_circle(head - Vector2(r * 0.3, r * 0.3), r * 0.42, stone.lightened(0.12))
	draw_circle(head + Vector2(r * 0.32, r * 0.24), r * 0.24, stone.darkened(0.22))
	draw_arc(head, r, 0.0, TAU, 28, Color(0.16, 0.15, 0.18), 3.0)
	# The sword, buried hilt-deep in the stone — the whole joke, drawn.
	draw_line(head - Vector2(r * 0.2, 0), head + Vector2(r + 12.0, 0), Color(0.85, 0.87, 0.95), 4.0)
	draw_line(head + Vector2(r * 0.1, -6), head + Vector2(r * 0.1, 6), Color(0.85, 0.8, 0.5), 4.0)

func _draw_hammer(head: Vector2, r: float, speed_t: float) -> void:
	var col := Color(0.4, 0.42, 0.48).lerp(Color(1.0, 0.5, 0.2), speed_t * 0.7)
	var w := r * 1.7
	var h := r * 1.25
	var rect := Rect2(head - Vector2(w * 0.5, h * 0.5), Vector2(w, h))
	draw_rect(rect, col)
	draw_rect(rect, Color(0.15, 0.14, 0.16), false, 3.0)
	draw_rect(Rect2(head - Vector2(w * 0.5, h * 0.5), Vector2(w * 0.28, h)), col.darkened(0.2))

func _draw_sickle(head: Vector2, r: float, speed_t: float) -> void:
	var col := Color(0.78, 0.8, 0.88).lerp(Color(1.0, 0.6, 0.3), speed_t * 0.7)
	# A curved blade sweeping off the haft.
	var pts := PackedVector2Array()
	var n := 12
	for i in range(n + 1):
		var a := lerpf(-1.2, 1.2, float(i) / float(n))
		pts.push_back(head + Vector2(cos(a), sin(a)) * r * 1.1)
	draw_polyline(pts, col, 5.0)
	draw_circle(head, r * 0.35, Color(0.3, 0.24, 0.18))   # the pivot knob

func _draw_trail() -> void:
	if _trail.size() < 2:
		return
	for i in range(_trail.size() - 1):
		var a: float = 1.0 - _trail[i].age / 0.2
		var p0: Vector2 = to_local(_trail[i].pos)
		var p1: Vector2 = to_local(_trail[i + 1].pos)
		draw_line(p0, p1, Color(0.95, 0.85, 0.6, clampf(a, 0.0, 1.0) * 0.45), 9.0 * clampf(a, 0.2, 1.0))
