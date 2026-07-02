class_name Player
extends Fighter
## The human-controlled Arthur. WASD to haul yourself around (heavy, momentum-based);
## the mouse aims the stone, and DRAGGING the mouse around yourself whips it up to
## speed — a fast whip hits hard, a slow drag only shoves. Hold LMB to commit a swing,
## RMB to slam, Space to whirl.

const TOUCH_WHIRL_SPEED := 7.0   ## rad/s the aim advances while the right stick is held steady (auto-whirl)

var camera: GameCamera
var _tc: TouchControls
var _touch_aim := 0.0
var _prev_aim_active := false

func _ready() -> void:
	is_player = true
	uses_stamina = true
	display_name = "You"
	color = Color("f4e6b4")
	super._ready()
	camera = GameCamera.new()
	add_child(camera)

func spawn_setup(pos: Vector2, m: float, nm: String, col: Color) -> void:
	super.spawn_setup(pos, m, nm, col)
	if camera:
		camera.snap()   # don't let the smoothed camera glide across the map after a respawn teleport

func _control(delta: float) -> void:
	var tc := _touch()
	var on_touch: bool = tc != null and tc.enabled

	# Movement: keyboard/gamepad + the on-screen left stick (folded in, so both work).
	move_dir = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if on_touch:
		move_dir = (move_dir + tc.move_vec).limit_length(1.0)

	# Aim: on a phone the RIGHT stick drives the stone — flick it to strike where you point,
	# hold it steady to auto-whirl into the crowd (the aim keeps rotating, so the pendulum
	# whips like a bot's). On desktop the mouse points the stone; the mouse is never read on
	# touch (it would be a stale (0,0) with mouse-from-touch emulation off).
	if on_touch:
		if tc.aim_active:
			if not _prev_aim_active:
				_touch_aim = weapon.aim_angle   # continue from the current facing, no jump
			if tc.aim_moving and tc.aim_dir_set:
				_touch_aim = tc.aim_angle
			else:
				_touch_aim = wrapf(_touch_aim + TOUCH_WHIRL_SPEED * delta, -PI, PI)
			weapon.aim_at(_touch_aim)
		_prev_aim_active = tc.aim_active
	else:
		var to_mouse := get_global_mouse_position() - global_position
		if to_mouse.length() > 4.0:
			weapon.aim_at(to_mouse.angle())

	# Slam / whirl take priority over the swing (mirrors the reference ordering).
	if Input.is_action_just_pressed("slam") or (on_touch and tc.consume_slam()):
		weapon.do_slam()
	var whirling := Input.is_action_pressed("spin") or (on_touch and tc.whirl_held)
	weapon.set_spin(whirling)
	var swing := Input.is_action_pressed("attack") or (on_touch and tc.aim_active)
	weapon.set_swinging(swing and not whirling and not weapon.is_busy())

	# The spawn shield drops the moment you turn aggressor — an invulnerable attacker
	# would be uncounterable. (Post-hit i-frames are 0.18s, so >0.4s can only be a shield.)
	if (swing or whirling or weapon.state == Weapon.State.SLAM) and _invuln > 0.4 and not Game.picking:
		_invuln = 0.4

func _touch() -> TouchControls:
	if _tc == null or not is_instance_valid(_tc):
		_tc = get_tree().get_first_node_in_group("touch_controls") as TouchControls
	return _tc

func on_hit_feedback(shake: float, dir: Vector2, big: bool) -> void:
	if camera:
		camera.add_shake(shake, dir)
		if big:
			camera.kick(22.0)
