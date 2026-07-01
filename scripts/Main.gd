class_name Main
extends Node2D
## The arena. Builds the walled play-field, seeds it with food, spawns the player and a
## roster of rival bots, and keeps the whole thing running .io-style: rivals are topped
## back up as they fall, gems are replenished, weapon crates drift in, and the
## leaderboard + your rank refresh a few times a second. On death you spill your loot
## and wait for a click to lift the stone again.

const CRATE_INTERVAL := 9.0
const CRATE_CAP := 4
const GEM_TOPUP_INTERVAL := 2.0
const GEM_HARD_CAP := 500     ## bound the loose-gem RigidBody count over very long sessions

var player: Player
var hud: Hud
var touch: TouchControls

var _half := Game.ARENA_SIZE * 0.5
var _board_cd := 0.0
var _crate_cd := CRATE_INTERVAL
var _gem_cd := GEM_TOPUP_INTERVAL
var _spawn_cd := 0.0
var _awaiting_respawn := false

func _ready() -> void:
	Game.reset_run()
	_build_walls()
	add_child(Terrain.new())          # contour heightfield + gravity gradient (draws under everything)
	_seed_gems(Game.AMBIENT_GEMS)

	player = Player.new()
	add_child(player)
	player.spawn_setup(Vector2.ZERO, Game.START_MASS, "You", Color("f4e6b4"))
	player.died.connect(_on_fighter_died)

	for i in range(Game.BOT_TARGET):
		_spawn_bot()

	_spawn_fields()

	# HUD in its own CanvasLayer so it's screen-space, independent of the camera zoom.
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Hud.new()
	layer.add_child(hud)
	hud.bind(player)
	# On-screen controls for phones (auto-shown only when a touchscreen is present).
	touch = TouchControls.new()
	layer.add_child(touch)

	queue_redraw()   # the static grid/border draws once and persists

func _process(delta: float) -> void:
	if _awaiting_respawn:
		if Input.is_action_just_pressed("respawn") or Input.is_action_just_pressed("attack") or (touch != null and touch.consume_tap()):
			_respawn_player()
		return

	_board_cd -= delta
	if _board_cd <= 0.0:
		_board_cd = 0.2
		_update_leaderboard()

	_crate_cd -= delta
	if _crate_cd <= 0.0:
		_crate_cd = CRATE_INTERVAL
		_spawn_crate()

	_gem_cd -= delta
	if _gem_cd <= 0.0:
		_gem_cd = GEM_TOPUP_INTERVAL
		_topup_gems()

	if _spawn_cd > 0.0:
		_spawn_cd -= delta
	_maintain_bots()

# --- spawning ---------------------------------------------------------------------

func _spawn_bot() -> void:
	var b := Bot.new()
	var start_mass: float = Game.START_MASS * Game.rng().randf_range(0.9, 1.6)
	b.mass = start_mass
	add_child(b)
	b.spawn_setup(_rand_pos(), start_mass, Game.random_name(), Game.random_color())
	b.weapon.set_type(_rand_weapon_type())
	b.died.connect(_on_fighter_died)

func _maintain_bots() -> void:
	if _spawn_cd > 0.0:
		return
	var count := 0
	for f in get_tree().get_nodes_in_group("fighter"):
		if f is Bot and is_instance_valid(f) and not (f as Fighter).is_dead():
			count += 1
	if count < Game.BOT_TARGET:
		_spawn_bot()
		_spawn_cd = 0.8   # stagger so a wipe refills gradually

func _spawn_crate() -> void:
	var crates := 0
	for p in get_tree().get_nodes_in_group("pickup"):
		if p is Pickup and (p as Pickup).kind == Pickup.Kind.WEAPON:
			crates += 1
	if crates >= CRATE_CAP:
		return
	var wt := _rand_weapon_type()
	var c := Pickup.new()
	add_child(c)
	c.setup(_rand_pos(), 0.0, Pickup.Kind.WEAPON, Color.WHITE, wt)

func _seed_gems(n: int) -> void:
	for i in range(n):
		var g := Pickup.new()
		add_child(g)
		g.setup(_rand_pos(), Game.GEM_MASS, Pickup.Kind.GEM, Game.random_color())

func _topup_gems() -> void:
	var gem_nodes: Array = []
	for p in get_tree().get_nodes_in_group("pickup"):
		if p is Pickup and (p as Pickup).kind == Pickup.Kind.GEM:
			gem_nodes.append(p)
	var gems := gem_nodes.size()
	if gems > GEM_HARD_CAP:
		for i in range(gems - GEM_HARD_CAP):
			(gem_nodes[i] as Pickup).consume()
		return
	var need := Game.AMBIENT_GEMS - gems
	for i in range(clampi(need, 0, 8)):
		var g := Pickup.new()
		add_child(g)
		g.setup(_rand_pos(), Game.GEM_MASS, Pickup.Kind.GEM, Game.random_color())

func _spawn_fields() -> void:
	var kinds := [
		ForceField.Kind.GRAVITY, ForceField.Kind.MAGNET, ForceField.Kind.REPULSOR,
		ForceField.Kind.CUSHION, ForceField.Kind.CURRENT, ForceField.Kind.REVERSAL,
	]
	for k in kinds:            # one of every kind…
		_add_field(k)
	for i in range(3):         # …plus a few extra at random
		_add_field(kinds[Game.rng().randi() % kinds.size()])

func _add_field(kind: int) -> void:
	var pos := _rand_pos()
	var tries := 0
	while pos.length() < 380.0 and tries < 8:   # keep clear of the centre player spawn
		pos = _rand_pos()
		tries += 1
	var f := ForceField.new()
	add_child(f)
	f.setup(kind, pos, Game.rng().randf_range(190.0, 300.0), Vector2.RIGHT.rotated(Game.rng().randf() * TAU))

func _rand_weapon_type() -> int:
	var pool := [Weapon.Type.STONE, Weapon.Type.HAMMER, Weapon.Type.SICKLE]
	return pool[Game.rng().randi() % pool.size()]

func _rand_pos() -> Vector2:
	var m := 220.0
	return Vector2(
		Game.rng().randf_range(-_half.x + m, _half.x - m),
		Game.rng().randf_range(-_half.y + m, _half.y - m))

# --- death / respawn --------------------------------------------------------------

func _on_fighter_died(who: Fighter) -> void:
	if who == player:
		var rank := _player_rank()   # compute BEFORE the board scan drops the dead player
		_update_leaderboard()
		# _update_leaderboard just emitted rank #1 (the dead player isn't in the list),
		# so re-emit the true finishing rank for the HUD.
		Game.rank_changed.emit(rank, _alive_count())
		Game.player_died.emit(int(round(player.mass * 100.0)), rank)
		player.hide()
		player.set_physics_process(false)
		_awaiting_respawn = true
		if touch != null:
			touch.consume_tap()   # flush any taps from before death so we don't insta-respawn
	else:
		who.queue_free()

func _alive_count() -> int:
	var n := 0
	for f in get_tree().get_nodes_in_group("fighter"):
		var fi := f as Fighter
		if fi != null and not fi.is_dead():
			n += 1
	return n

func _respawn_player() -> void:
	_awaiting_respawn = false
	Game.reset_run()
	player.spawn_setup(_rand_pos(), Game.START_MASS, "You", Color("f4e6b4"))
	Game.player_spawned.emit()

# --- leaderboard ------------------------------------------------------------------

func _update_leaderboard() -> void:
	var list: Array = []
	for f in get_tree().get_nodes_in_group("fighter"):
		if not is_instance_valid(f):
			continue
		var fi := f as Fighter
		if fi == null or fi.is_dead():
			continue
		list.append({"name": fi.display_name, "score": int(round(fi.mass * 100.0)), "is_player": fi.is_player})
	list.sort_custom(func(a, b): return a["score"] > b["score"])
	Game.leaderboard_changed.emit(list)
	var rank := 1
	for i in range(list.size()):
		if list[i]["is_player"]:
			rank = i + 1
			break
	Game.rank_changed.emit(rank, list.size())

func _player_rank() -> int:
	var rank := 1
	for f in get_tree().get_nodes_in_group("fighter"):
		var fi := f as Fighter
		if fi != null and fi != player and not fi.is_dead() and fi.mass > player.mass:
			rank += 1
	return rank

# --- walls + background -----------------------------------------------------------

func _build_walls() -> void:
	var t := Game.WALL_THICK
	_add_wall(Vector2(0, -_half.y - t * 0.5), Vector2(Game.ARENA_SIZE.x + t * 2.0, t))
	_add_wall(Vector2(0, _half.y + t * 0.5), Vector2(Game.ARENA_SIZE.x + t * 2.0, t))
	_add_wall(Vector2(-_half.x - t * 0.5, 0), Vector2(t, Game.ARENA_SIZE.y + t * 2.0))
	_add_wall(Vector2(_half.x + t * 0.5, 0), Vector2(t, Game.ARENA_SIZE.y + t * 2.0))

func _add_wall(pos: Vector2, size: Vector2) -> void:
	var body := StaticBody2D.new()
	body.collision_layer = Game.L_WALL
	body.collision_mask = 0
	body.position = pos
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	shape.shape = rect
	body.add_child(shape)
	add_child(body)

func _draw() -> void:
	# A faint grid + a bright border so the big arena reads and you feel your speed.
	var step := 160.0
	var grid := Color(1, 1, 1, 0.045)
	var x := -_half.x
	while x <= _half.x:
		draw_line(Vector2(x, -_half.y), Vector2(x, _half.y), grid, 1.0)
		x += step
	var y := -_half.y
	while y <= _half.y:
		draw_line(Vector2(-_half.x, y), Vector2(_half.x, y), grid, 1.0)
		y += step
	draw_rect(Rect2(-_half, Game.ARENA_SIZE), Color(0.5, 0.45, 0.7, 0.8), false, 6.0)
