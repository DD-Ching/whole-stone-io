class_name Hud
extends Control
## Screen-space HUD (lives under a CanvasLayer): score/best/kills top-left, the live
## leaderboard + kill feed top-right, the player's stamina + health along the bottom,
## off-screen THREAT ARROWS at the screen edge, and the death overlay. It only ever
## reads state from the Game autoload's signals (+ a bound player for the live bars),
## so it never reaches into the arena.
##
## Every string is shaped ONCE into a cached TextLine and re-shaped only when its text
## changes — draw_string re-shapes through HarfBuzz every call, which on the single
## wasm thread was one of the biggest per-frame CPU costs in the whole game.

const FEED_LIFE := 5.0
const THREAT_RANGE := 1600.0

var player: Fighter

var _score := 0
var _best := 0
var _kills := 0
var _rank := 1
var _total := 1
var _board: Array = []
var _feed: Array = []       ## {text, gold, t} — newest first, capped
var _dead := false
var _final_score := 0
var _final_rank := 1

var _font: Font
var _lines := {}            ## slot -> {text, size, tl} — the TextLine cache

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
	Game.feed_event.connect(_on_feed)

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

func _on_feed(text: String, gold: bool) -> void:
	_feed.push_front({"text": text, "gold": gold, "t": FEED_LIFE})
	while _feed.size() > 3:
		_feed.pop_back()

func _process(delta: float) -> void:
	for e in _feed:
		e["t"] -= delta
	while _feed.size() > 0 and float(_feed.back()["t"]) <= 0.0:
		_feed.pop_back()
	queue_redraw()

# --- cached text ------------------------------------------------------------------

## Fetch the shaped line for a slot, re-shaping only when its text/size changed.
func _slot(slot: String, s: String, size: int) -> TextLine:
	var e: Dictionary = _lines.get(slot, {})
	if e.get("text", "") != s or int(e.get("size", 0)) != size:
		var tl := TextLine.new()
		tl.add_string(s, _font, size)
		e = {"text": s, "size": size, "tl": tl}
		_lines[slot] = e
	return e["tl"]

## Draw at the same BASELINE position the old draw_string used (TextLine anchors at
## its top-left, so we lift by the ascent to keep the layout identical).
func _text(slot: String, s: String, pos: Vector2, size: int, col: Color) -> void:
	var tl := _slot(slot, s, size)
	var p := pos - Vector2(0.0, tl.get_line_ascent())
	tl.draw(get_canvas_item(), p + Vector2(1.5, 1.5), Color(0, 0, 0, 0.55))
	tl.draw(get_canvas_item(), p, col)

func _center(slot: String, s: String, vp: Vector2, dy: float, size: int, col: Color) -> void:
	var tl := _slot(slot, s, size)
	_text(slot, s, Vector2(vp.x * 0.5 - tl.get_size().x * 0.5, vp.y * 0.5 + dy), size, col)

# --- drawing ------------------------------------------------------------------------

func _draw() -> void:
	if _font == null:
		return
	var vp := get_viewport_rect().size
	var touch := _touch_on()

	# --- top-left: score block ---
	_text("score", "SIZE  %d" % _score, Vector2(24, 40), 30, Color(1, 0.95, 0.75))
	_text("best", "Best  %d" % _best, Vector2(26, 66), 16, Color(0.8, 0.8, 0.85))
	_text("kos", "KOs   %d" % _kills, Vector2(26, 88), 16, Color(0.8, 0.8, 0.85))
	_text("rank", "Rank  #%d / %d" % [_rank, _total], Vector2(26, 110), 16, Color(0.85, 0.85, 0.9))

	# --- top-right: leaderboard ---
	var lx := vp.x - 240.0
	_text("lbt", "LEADERBOARD", Vector2(lx, 40), 18, Color(1, 0.9, 0.55))
	var y := 66.0
	for i in range(min(_board.size(), 6)):
		var e: Dictionary = _board[i]
		var col: Color = Color(1, 0.92, 0.5) if e.get("is_player", false) else Color(0.82, 0.82, 0.88)
		if e.get("is_king", false):
			col = Color(1.0, 0.85, 0.3)   # the crown holder glows gold in the standings too
		_text("lb%d" % i, "%d. %s" % [i + 1, e.get("name", "?")], Vector2(lx, y), 15, col)
		var sc := str(int(e.get("score", 0)))
		var stl := _slot("lbs%d" % i, sc, 15)
		_text("lbs%d" % i, sc, Vector2(vp.x - 24.0 - stl.get_size().x, y), 15, col)
		y += 22.0

	# --- kill feed under the leaderboard (hidden on small phone screens) ---
	if not (touch and vp.x < 900.0):
		y += 8.0
		for i in range(_feed.size()):
			var f: Dictionary = _feed[i]
			var a := clampf(float(f["t"]), 0.0, 1.0)   # last second fades out
			var fcol := Color(1, 0.9, 0.55, 0.95 * a) if f["gold"] else Color(0.75, 0.75, 0.8, 0.6 * a)
			_text("feed%d" % i, str(f["text"]), Vector2(lx, y), 13, fcol)
			y += 18.0

	# --- off-screen threat arrows: is something huge about to enter my screen? ---
	if not _dead and player != null and is_instance_valid(player) and not player.is_dead():
		_draw_threat_arrows(vp)

	# --- bottom: bars ---
	if player != null and is_instance_valid(player):
		var bw := 260.0
		var bx := vp.x * 0.5 - bw * 0.5
		var by := vp.y - 64.0
		draw_rect(Rect2(bx, by, bw, 12), Color(0, 0, 0, 0.5))
		var sf := clampf(player.stamina / Game.STAMINA_MAX, 0.0, 1.0)
		draw_rect(Rect2(bx, by, bw * sf, 12), Color(0.35, 0.7, 1.0))
		_text("stam", "STAMINA", Vector2(bx, by - 4), 12, Color(0.7, 0.85, 1.0))
		draw_rect(Rect2(bx, by + 18, bw, 12), Color(0, 0, 0, 0.5))
		var hf := clampf(player.health / player.max_health, 0.0, 1.0)
		draw_rect(Rect2(bx, by + 18, bw * hf, 12), Color(0.4, 0.85, 0.45).lerp(Color(0.9, 0.35, 0.3), 1.0 - hf))

	var hint := "LEFT stick move   •   RIGHT stick to whip the stone   •   SLAM / WHIRL buttons" if touch \
		else "WASD move   •   drag MOUSE to whip the stone   •   LMB swing   •   RMB slam   •   SPACE whirl"
	var htl := _slot("hint", hint, 14)
	var hint_y := (vp.y - 150.0) if touch else (vp.y - 14.0)
	_text("hint", hint, Vector2(vp.x * 0.5 - htl.get_size().x * 0.5, hint_y), 14, Color(0.75, 0.75, 0.8))

	# --- death overlay ---
	if _dead:
		draw_rect(Rect2(Vector2.ZERO, vp), Color(0, 0, 0, 0.55))
		_center("d1", "YOU GOT SMASHED", vp, -70, 46, Color(1, 0.5, 0.45))
		_center("d2", "Final size %d   •   You finished #%d" % [_final_score, _final_rank], vp, -8, 22, Color(1, 0.95, 0.8))
		var rehint := "TAP to lift the stone again" if touch else "Press  R  or  CLICK  to lift the stone again"
		_center("d3", rehint, vp, 44, 20, Color(0.85, 0.9, 1.0))

	# --- portrait nudge (phones): the game is landscape-first ---
	if touch and vp.x < vp.y:
		draw_rect(Rect2(Vector2.ZERO, vp), Color(0.055, 0.055, 0.08, 0.96))
		_center("r1", "ROTATE YOUR DEVICE", vp, -20, 30, Color(1, 0.95, 0.75))
		_center("r2", "to landscape to play", vp, 20, 22, Color(0.85, 0.85, 0.92))

	# --- start weapon picker (desktop dev) ---
	if Game.picking:
		draw_rect(Rect2(Vector2.ZERO, vp), Color(0, 0, 0, 0.6))
		_center("p1", "WHOLE STONE .io", vp, -120, 40, Color(1, 0.9, 0.55))
		_center("p2", "Choose your weapon", vp, -68, 24, Color(1, 0.95, 0.85))
		_center("p3", "[1] STONE     [2] HAMMER     [3] SICKLE     [4] STAFF", vp, -16, 22, Color(0.85, 0.9, 1.0))
		_center("p4", "press 1-4   (you can switch anytime — dev)", vp, 24, 15, Color(0.7, 0.72, 0.82))

## Edge chevrons for fighters that OUTWEIGH the player, close but off-screen — answers
## the one question that causes unfair-feeling deaths ("is something huge coming?")
## while every fight at or below your weight class stays a genuine ambush.
func _draw_threat_arrows(vp: Vector2) -> void:
	var xform := get_viewport().get_canvas_transform()
	var vp_rect := Rect2(Vector2.ZERO, vp).grow(-8.0)
	for f in get_tree().get_nodes_in_group("fighter"):
		var fi := f as Fighter
		if fi == null or fi == player or fi.is_dead():
			continue
		if fi.mass <= Game.player_mass * 1.18:
			continue
		var wd := fi.global_position.distance_to(player.global_position)
		if wd > THREAT_RANGE:
			continue
		var sp: Vector2 = xform * fi.global_position
		if vp_rect.has_point(sp):
			continue                       # already on screen — the body is its own warning
		var edge := sp.clamp(Vector2(28, 28), vp - Vector2(28, 28))
		var dir := sp - edge
		dir = dir.normalized() if dir.length() > 0.5 else Vector2.RIGHT
		var ratio := clampf(fi.mass / maxf(Game.player_mass, 0.01) / 1.18, 1.0, 2.0)
		var size := 10.0 * ratio
		var alpha := clampf(1.4 - wd / THREAT_RANGE, 0.25, 0.9)
		var perp := dir.orthogonal()
		var pts := PackedVector2Array([
			edge + dir * size,
			edge - dir * size * 0.4 + perp * size * 0.7,
			edge - dir * size * 0.4 - perp * size * 0.7,
		])
		draw_colored_polygon(pts, Color(fi.color.r, fi.color.g, fi.color.b, alpha))
		draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[0]]), Color(0, 0, 0, alpha * 0.6), 1.5)
