class_name FloatingText
extends Node2D
## A tiny self-drawing, self-freeing pop label ("SMASH!", "+3", "KO!") that floats
## up and fades. Built entirely in code so the project runs from a clean checkout
## with no font/scene imports.

var _text := ""
var _color := Color.WHITE
var _scale := 1.0
var _age := 0.0
var _life := 0.9
var _vel := Vector2(0.0, -46.0)
var _line: TextLine   ## shaped ONCE here — the per-frame draw just repaints cached glyphs

func setup(text: String, color: Color, scale := 1.0) -> void:
	_text = text
	_color = color
	_scale = scale
	z_index = 100
	_line = TextLine.new()
	_line.add_string(text, ThemeDB.fallback_font, int(round(22.0 * scale)))
	queue_redraw()

func _process(delta: float) -> void:
	_age += delta
	position += _vel * delta
	_vel.y += 40.0 * delta   # ease the rise
	if _age >= _life:
		queue_free()
	else:
		queue_redraw()

func _draw() -> void:
	if _line == null:
		return
	var t := clampf(_age / _life, 0.0, 1.0)
	var a := 1.0 - t * t
	var origin := Vector2(-_line.get_size().x * 0.5, -_line.get_line_ascent())
	# Cheap outline for readability over any background.
	_line.draw(get_canvas_item(), origin + Vector2(1.5, 1.5), Color(0, 0, 0, 0.6 * a))
	_line.draw(get_canvas_item(), origin, Color(_color.r, _color.g, _color.b, a))
