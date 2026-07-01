class_name Hud
extends Control
## Screen-space HUD (lives under a CanvasLayer): score/best/kills top-left, the live
## leaderboard top-right, the player's stamina + health and the controls hint along
## the bottom, and the death overlay. It only ever reads state from the Game autoload's
## signals (+ a bound player for the live bars), so it never reaches into the arena.

var player: Fighter

var _score := 0
var _best := 0
var _kills := 0
var _rank := 1
var _total := 1
var _board: Array = []
var _dead := false
var _final_score := 0
var _final_rank := 1

var _font: Font

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font
	Game.score_changed.connect(_on_score)
	Game.kills_changed.connect(func(k): _kills = k)
	Game.rank_changed.connect(func(r, t): _rank = r; _total = t)
	Game.leaderboard_changed.connect(func(b): _board = b)
	Game.player_died.connect(_on_died)
	Game.player_spawned.connect(func(): _dead = false)

var _tc: Node = null

func bind(p: Fighter) -> void:
	player = p
	# Seed from the autoload: the player's first score was emitted before we connected.
	_score = Game.score
	_best = Game.best
	_kills = Game.kills

func _touch_on() -> bool:
	if _tc == null or not is_instance_valid(_tc):
		_tc = get_tree().get_first_node_in_group("touch_controls")
	return _tc != null and _tc.enabled

func _on_score(s: int, b: int) -> void:
	_score = s
	_best = b

func _on_died(final_score: int, rank: int) -> void:
	_dead = true
	_final_score = final_score
	_final_rank = rank

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	if _font == null:
		return
	var vp := get_viewport_rect().size

	# --- top-left: score block ---
	_text("SIZE  %d" % _score, Vector2(24, 40), 30, Color(1, 0.95, 0.75))
	_text("Best  %d" % _best, Vector2(26, 66), 16, Color(0.8, 0.8, 0.85))
	_text("KOs   %d" % _kills, Vector2(26, 88), 16, Color(0.8, 0.8, 0.85))
	_text("Rank  #%d / %d" % [_rank, _total], Vector2(26, 110), 16, Color(0.85, 0.85, 0.9))

	# --- top-right: leaderboard ---
	var lx := vp.x - 240.0
	_text("LEADERBOARD", Vector2(lx, 40), 18, Color(1, 0.9, 0.55))
	var y := 66.0
	for i in range(min(_board.size(), 6)):
		var e: Dictionary = _board[i]
		var col: Color = Color(1, 0.92, 0.5) if e.get("is_player", false) else Color(0.82, 0.82, 0.88)
		_text("%d. %s" % [i + 1, e.get("name", "?")], Vector2(lx, y), 15, col)
		var sc := str(int(e.get("score", 0)))
		var sw := _font.get_string_size(sc, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
		_text(sc, Vector2(vp.x - 24.0 - sw, y), 15, col)
		y += 22.0

	# --- bottom: bars + controls ---
	if player != null and is_instance_valid(player):
		var bw := 260.0
		var bx := vp.x * 0.5 - bw * 0.5
		var by := vp.y - 64.0
		# stamina
		draw_rect(Rect2(bx, by, bw, 12), Color(0, 0, 0, 0.5))
		var sf := clampf(player.stamina / Game.STAMINA_MAX, 0.0, 1.0)
		draw_rect(Rect2(bx, by, bw * sf, 12), Color(0.35, 0.7, 1.0))
		_text("STAMINA", Vector2(bx, by - 4), 12, Color(0.7, 0.85, 1.0))
		# health
		draw_rect(Rect2(bx, by + 18, bw, 12), Color(0, 0, 0, 0.5))
		var hf := clampf(player.health / player.max_health, 0.0, 1.0)
		draw_rect(Rect2(bx, by + 18, bw * hf, 12), Color(0.4, 0.85, 0.45).lerp(Color(0.9, 0.35, 0.3), 1.0 - hf))

	var touch := _touch_on()
	var hint := "LEFT stick move   •   RIGHT stick to whip the stone   •   SLAM / WHIRL buttons" if touch \
		else "WASD move   •   drag MOUSE to whip the stone   •   LMB swing   •   RMB slam   •   SPACE whirl"
	var hw := _font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	# Keep the hint clear of the on-screen sticks/buttons on phones.
	var hint_y := (vp.y - 150.0) if touch else (vp.y - 14.0)
	_text(hint, Vector2(vp.x * 0.5 - hw * 0.5, hint_y), 14, Color(0.75, 0.75, 0.8))

	# --- death overlay ---
	if _dead:
		draw_rect(Rect2(Vector2.ZERO, vp), Color(0, 0, 0, 0.55))
		_center("YOU GOT SMASHED", vp, -70, 46, Color(1, 0.5, 0.45))
		_center("Final size %d   •   You finished #%d" % [_final_score, _final_rank], vp, -8, 22, Color(1, 0.95, 0.8))
		var rehint := "TAP to lift the stone again" if touch else "Press  R  or  CLICK  to lift the stone again"
		_center(rehint, vp, 44, 20, Color(0.85, 0.9, 1.0))

	# --- portrait nudge (phones): the game is landscape-first ---
	if touch and vp.x < vp.y:
		draw_rect(Rect2(Vector2.ZERO, vp), Color(0.055, 0.055, 0.08, 0.96))
		_center("ROTATE YOUR DEVICE", vp, -20, 30, Color(1, 0.95, 0.75))
		_center("to landscape to play", vp, 20, 22, Color(0.85, 0.85, 0.92))

func _text(s: String, pos: Vector2, size: int, col: Color) -> void:
	draw_string(_font, pos + Vector2(1.5, 1.5), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.55))
	draw_string(_font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)

func _center(s: String, vp: Vector2, dy: float, size: int, col: Color) -> void:
	var w := _font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	_text(s, Vector2(vp.x * 0.5 - w * 0.5, vp.y * 0.5 + dy), size, col)
