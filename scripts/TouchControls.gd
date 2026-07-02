class_name TouchControls
extends Control
## On-screen controls so the game is fully playable on a phone (landscape). A twin-stick
## layout: a dynamic LEFT stick to move, a dynamic RIGHT stick to aim + swing (holding it
## whirls the stone via the weapon's touch swing-assist), plus SLAM and WHIRL buttons in
## the bottom-right corner. Multi-touch is tracked by finger index so both thumbs work at
## once. Hidden on desktop; shown when a touchscreen is present (or with ?touch=1 for testing).

const STICK_RADIUS := 96.0
const BTN_R := 54.0

var enabled := false
var move_vec := Vector2.ZERO
var aim_active := false
var aim_angle := 0.0
var aim_dir_set := false      ## true once the aim thumb has established a real direction (dragged past the dead zone)
var aim_moving := false       ## true while the aim thumb is actively dragging (brief decay)
var whirl_held := false

var _aim_move_cd := 0.0

var _slam_queued := false
var _tapped := false

var _move_touch := -1
var _move_origin := Vector2.ZERO
var _move_pos := Vector2.ZERO
var _aim_touch := -1
var _aim_origin := Vector2.ZERO
var _aim_pos := Vector2.ZERO
var _slam_touch := -1
var _whirl_touch := -1

var _font: Font
var _labels := {}        ## button label -> cached TextLine (shaped once, drawn forever)
var _redraw_once := true ## one redraw queued by a press/release while both thumbs are idle

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_to_group("touch_controls")
	_font = ThemeDB.fallback_font
	enabled = _detect_touch()
	visible = enabled
	set_process_input(enabled)
	set_process(enabled)

## Show the on-screen controls only on genuine TOUCH-FIRST devices (phones/tablets), never
## on a desktop that merely has a touchscreen + mouse. On the web that's the `(pointer: coarse)`
## media query (true for phones, false for a mouse-driven laptop) plus a `?touch=1` override
## for testing; on native we require an actual mobile OS.
func _detect_touch() -> bool:
	if OS.has_feature("web"):
		var force = JavaScriptBridge.eval("(new URLSearchParams(location.search).get('touch')==='1')?1:0", true)
		if force != null and int(force) == 1:
			return true
		var coarse = JavaScriptBridge.eval("(window.matchMedia && matchMedia('(pointer: coarse)').matches)?1:0", true)
		return coarse != null and int(coarse) == 1
	return DisplayServer.is_touchscreen_available() and (OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios"))

func consume_slam() -> bool:
	var s := _slam_queued
	_slam_queued = false
	return s

## One-shot "screen was tapped" — used by the respawn prompt. Flushed on death.
func consume_tap() -> bool:
	var t := _tapped
	_tapped = false
	return t

func _process(delta: float) -> void:
	if _aim_move_cd > 0.0:
		_aim_move_cd -= delta
		aim_moving = _aim_move_cd > 0.0
	# Redraw while a thumb is down (the sticks track it); when idle the buttons are a
	# static image — one final redraw after the last release, then nothing.
	if _move_touch != -1 or _aim_touch != -1 or _slam_touch != -1 or _whirl_touch != -1 or _redraw_once:
		_redraw_once = false
		queue_redraw()

func _btn_slam(vp: Vector2) -> Vector2:
	return Vector2(vp.x - 90.0, vp.y - 90.0)

func _btn_whirl(vp: Vector2) -> Vector2:
	return Vector2(vp.x - 210.0, vp.y - 110.0)

func _input(event: InputEvent) -> void:
	if not enabled:
		return
	var vp := get_viewport_rect().size
	if event is InputEventScreenTouch:
		_redraw_once = true   # a press/release always repaints once (button highlight)
		var pos: Vector2 = event.position
		if event.pressed:
			_tapped = true
			# Buttons take priority over the sticks.
			if _slam_touch == -1 and pos.distance_to(_btn_slam(vp)) <= BTN_R:
				_slam_touch = event.index
				_slam_queued = true
				return
			if _whirl_touch == -1 and pos.distance_to(_btn_whirl(vp)) <= BTN_R:
				_whirl_touch = event.index
				whirl_held = true
				return
			if pos.x < vp.x * 0.5 and _move_touch == -1:
				_move_touch = event.index
				_move_origin = pos
				_move_pos = pos
			elif pos.x >= vp.x * 0.5 and _aim_touch == -1:
				_aim_touch = event.index
				_aim_origin = pos
				_aim_pos = pos
				aim_active = true
				aim_dir_set = false   # no real direction yet — don't aim at a stale angle
				aim_moving = false
				_aim_move_cd = 0.0
		else:
			if event.index == _move_touch:
				_move_touch = -1
				move_vec = Vector2.ZERO
			elif event.index == _aim_touch:
				_aim_touch = -1
				aim_active = false
				aim_dir_set = false
				aim_moving = false
				_aim_move_cd = 0.0
			elif event.index == _slam_touch:
				_slam_touch = -1
			elif event.index == _whirl_touch:
				_whirl_touch = -1
				whirl_held = false
	elif event is InputEventScreenDrag:
		var pos: Vector2 = event.position
		if event.index == _move_touch:
			_move_pos = pos
			move_vec = ((pos - _move_origin) / STICK_RADIUS).limit_length(1.0)
		elif event.index == _aim_touch:
			_aim_pos = pos
			var d := pos - _aim_origin
			if d.length() > 8.0:
				aim_angle = d.angle()
				aim_dir_set = true
				aim_moving = true
				_aim_move_cd = 0.12   # "actively steering" window; decays to a whirl when the thumb rests

func _draw() -> void:
	if not enabled:
		return
	var vp := get_viewport_rect().size
	# Sticks (only while held).
	if _move_touch != -1:
		_draw_stick(_move_origin, _move_pos, Color(0.6, 0.8, 1.0))
	if _aim_touch != -1:
		_draw_stick(_aim_origin, _aim_pos, Color(1.0, 0.7, 0.4))
	# Buttons (always visible while touch UI is on).
	_draw_button(_btn_whirl(vp), "WHIRL", whirl_held, Color(1.0, 0.7, 0.3))
	_draw_button(_btn_slam(vp), "SLAM", _slam_touch != -1, Color(1.0, 0.5, 0.4))

func _draw_stick(origin: Vector2, pos: Vector2, col: Color) -> void:
	draw_arc(origin, STICK_RADIUS, 0.0, TAU, 40, Color(col.r, col.g, col.b, 0.35), 4.0)
	draw_circle(origin, STICK_RADIUS, Color(1, 1, 1, 0.04))
	var knob := origin + (pos - origin).limit_length(STICK_RADIUS)
	draw_circle(knob, 34.0, Color(col.r, col.g, col.b, 0.5))
	draw_arc(knob, 34.0, 0.0, TAU, 24, Color(col.r, col.g, col.b, 0.9), 3.0)

func _draw_button(center: Vector2, label: String, held: bool, col: Color) -> void:
	var a := 0.85 if held else 0.4
	draw_circle(center, BTN_R, Color(col.r, col.g, col.b, 0.18 if not held else 0.4))
	draw_arc(center, BTN_R, 0.0, TAU, 32, Color(col.r, col.g, col.b, a), 4.0)
	if _font:
		var tl: TextLine = _labels.get(label)
		if tl == null:
			tl = TextLine.new()
			tl.add_string(label, _font, 16)
			_labels[label] = tl
		var s := tl.get_size()
		tl.draw(get_canvas_item(), center - s * 0.5, Color(1, 1, 1, 0.9))
