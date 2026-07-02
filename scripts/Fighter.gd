class_name Fighter
extends CharacterBody2D
## A combatant body — the player and every rival bot share this. It owns Arthur's
## heavy, momentum-based movement (slow to start, keeps drifting), a health + stamina
## pool, the growth that drives the whole Snake.io hook (absorb gems / KO rivals to
## gain MASS, which makes you bigger, tankier and reach further, but slower and
## laggier to swing), and death that spills most of your mass back as loot.
##
## Subclasses only implement `_control(delta)`: set `move_dir` and drive `weapon`.
## Everything physical happens here so the two control schemes scale identically.

signal died(who: Fighter)

const ENV_DRAG := 3.6             ## proportional drag on environmental (field/terrain) velocity
const GHOST_SPEED := 235.0        ## speed above which a motion afterimage is shed (影像速度)
const GHOST_LIFE := 0.26
const PIERCE_KNOCK := 850.0       ## a hit harder than this PIERCES a cushion's protection (刺破/來不及緩衝)
const CUSHION_KNOCK_MULT := 0.3   ## fraction of knockback kept while buffered by an air cushion

var mass := Game.START_MASS
var health := 60.0
var max_health := 60.0
var stamina := Game.STAMINA_MAX
var color := Color("d9c24a")
var display_name := "Knight"
var is_player := false
var uses_stamina := true
var stamina_regen_mult := 1.0     ## bots run a mild 1.25 — they manage a real bar, just clumsily
var body_radius := Game.BASE_BODY_RADIUS
var is_king := false              ## wearing the crown (set by Main's leaderboard pass)
var wet := 1.0                    ## steering-speed multiplier from terrain water (1 = dry land)

var move_dir := Vector2.ZERO      ## set by the subclass each frame

var _steer := Vector2.ZERO        ## momentum-carrying input velocity
var _impulse := Vector2.ZERO      ## knockback + swing-lunge burst, decays on its own
var _env := Vector2.ZERO          ## velocity from force fields + terrain gradient (drag-damped)
var _invuln := 0.0
var _hurt := 0.0
var _cushion := 0.0               ## >0 while sheltered in an air cushion (soft armor)
var _stamina_delay := 0.0
var _dead := false
var _last_aim := 0.0
var _ghosts: Array = []           ## recent positions for the speed afterimage
var _wet_drawn := 1.0             ## wetness at last redraw (ripple appears/vanishes)
var _last_health_i := -1          ## quantized health at last redraw (drives the bar)
var _milestone := 0               ## last size-doubling celebrated (player fanfare)
var _name_line: TextLine          ## cached shaped nameplate — re-shaped only when the text changes
var _label_val := -1
var _chime_step := 0              ## the gem-vacuum pitch ladder
var _chime_time := 0.0

var weapon: Weapon
var _shape: CollisionShape2D
var _circle: CircleShape2D
var _collector: Area2D
var _collector_shape: CollisionShape2D
var _collector_circle: CircleShape2D

func _ready() -> void:
	add_to_group("fighter")
	collision_layer = Game.L_FIGHTER
	# Solid: collide with other fighters (no overlap), walls, and enemy weapon heads (which
	# physically shove us). Our OWN weapon adds a collision exception, so it never blocks us.
	collision_mask = Game.L_FIGHTER | Game.L_WALL | Game.L_WEAPON_SOLID

	_circle = CircleShape2D.new()
	_shape = CollisionShape2D.new()
	_shape.shape = _circle
	add_child(_shape)

	_collector_circle = CircleShape2D.new()
	_collector = Area2D.new()
	_collector.collision_layer = 0
	_collector.collision_mask = Game.L_PICKUP
	_collector.monitoring = true
	_collector_shape = CollisionShape2D.new()
	_collector_shape.shape = _collector_circle
	_collector.add_child(_collector_shape)
	add_child(_collector)
	_collector.body_entered.connect(_on_pickup_touched)

	weapon = Weapon.new()
	add_child(weapon)

	max_health = Game.health_for_mass(mass)
	health = max_health
	stamina = Game.STAMINA_MAX
	_apply_mass()

func _physics_process(delta: float) -> void:
	if _dead:
		return
	_control(delta)
	_integrate(delta)
	_tick(delta)
	_update_ghosts(delta)
	# Redraw only when something VISIBLE changed. The aim epsilon is coarse on purpose
	# (0.045 rad ≈ the facing dot moving ~1px) — a whirling bot at 7.5 rad/s still
	# redraws, but a mouse micro-jitter doesn't; health is quantized to whole points.
	var health_i := int(health)
	if _hurt > 0.0 or _invuln > 0.0 or _ghosts.size() > 0 \
			or absf(weapon.aim_angle - _last_aim) > 0.045 \
			or health_i != _last_health_i or wet != _wet_drawn:
		_last_aim = weapon.aim_angle
		_last_health_i = health_i
		queue_redraw()

## Subclass hook: set `move_dir` (unit-ish) and drive `weapon`.
func _control(_delta: float) -> void:
	pass

func _integrate(delta: float) -> void:
	# Water drags at your LEGS only (steering) — knockback and terrain shove still carry
	# in full, so smashing a rival into a lake remains a legitimate setup.
	var spd := Game.speed_for_mass(mass) * _weapon_speed_mult() * wet
	if move_dir != Vector2.ZERO:
		_steer = _steer.move_toward(move_dir.limit_length(1.0) * spd, Game.ACCEL * delta)
	else:
		_steer = _steer.move_toward(Vector2.ZERO, Game.FRICTION * delta)
	_impulse = _impulse.move_toward(Vector2.ZERO, Game.KNOCK_FRICTION * delta)
	# Environmental velocity (fields + terrain) bleeds off with proportional drag, so a
	# steady force settles at a sane terminal speed instead of running away.
	_env *= maxf(0.0, 1.0 - ENV_DRAG * delta)
	velocity = _steer + _impulse + _env
	move_and_slide()

## Accumulate an environmental acceleration this frame (force fields, terrain gradient).
## Ignored while frozen (dead / picking a weapon) so it can't pile up and fling us on unfreeze.
func apply_env_force(accel: Vector2, delta: float) -> void:
	if _dead or not is_physics_processing():
		return
	_env += accel * delta

## A counter/cushion zone flings this body's momentum back (reflect), plus a shove out.
func env_reflect(factor: float, outward: Vector2) -> void:
	var v := velocity
	_steer *= -0.3
	_env = Vector2.ZERO
	_impulse = (-v * factor + outward).limit_length(2000.0)

## An air cushion is currently sheltering us — soft armor for a short window.
func mark_cushioned() -> void:
	_cushion = 0.15

## Terrain tells us how wet we are each physics frame. Entering water splashes.
func set_wetness(w: float) -> void:
	if w < 0.99 and wet >= 0.99 and not _dead:
		Sfx.play(&"splash", global_position, -6.0, Game.rng().randf_range(0.9, 1.1))
	wet = w

func _update_ghosts(delta: float) -> void:
	# Only a BOOSTED body sheds afterimages (knockback, lunge, downhill run) — plain
	# walking is below the bar, so a cruising fighter doesn't force redraws every frame.
	if velocity.length() > maxf(GHOST_SPEED, Game.speed_for_mass(mass) * 1.15):
		_ghosts.push_back({"pos": global_position, "age": 0.0})
	for g in _ghosts:
		g.age += delta
	while _ghosts.size() > 0 and _ghosts[0].age > GHOST_LIFE:
		_ghosts.pop_front()

## While the weapon is committed you are far less mobile — the cost of power.
func _weapon_speed_mult() -> float:
	match weapon.state:
		Weapon.State.SLAM:
			return 0.4
		Weapon.State.SPIN:
			return 0.78
		_:
			return 1.0

func _tick(delta: float) -> void:
	if _invuln > 0.0:
		_invuln = maxf(0.0, _invuln - delta)
	if _hurt > 0.0:
		_hurt = maxf(0.0, _hurt - delta)
	if _cushion > 0.0:
		_cushion = maxf(0.0, _cushion - delta)
	if health < max_health:
		health = minf(max_health, health + Game.HEALTH_REGEN * delta)
	if _stamina_delay > 0.0:
		_stamina_delay = maxf(0.0, _stamina_delay - delta)
	elif stamina < Game.STAMINA_MAX:
		stamina = minf(Game.STAMINA_MAX, stamina + Game.STAMINA_REGEN * stamina_regen_mult * delta)
	if _chime_time > 0.0:
		_chime_time = maxf(0.0, _chime_time - delta)
		if _chime_time == 0.0:
			_chime_step = 0   # the gem-vacuum combo ladder resets when you stop eating

# --- combat ------------------------------------------------------------------------

## Returns true if this hit KILLED the fighter (so the attacker can claim the kill).
func take_damage(amount: float, dir: Vector2, knockback: float) -> bool:
	if _dead or _invuln > 0.0:
		return false
	# Soft armor: an air cushion buffers the blow — UNLESS it's hard enough to pierce
	# (刺破 / 來不及緩衝), in which case the full impact lands.
	if _cushion > 0.0 and knockback < PIERCE_KNOCK:
		knockback *= CUSHION_KNOCK_MULT
		amount *= 0.65
	health -= amount
	_invuln = Game.INVULN
	_hurt = 0.32
	_impulse = (_impulse + dir * knockback).limit_length(1400.0)
	queue_redraw()
	if health <= 0.0:
		_die()
		return true
	return false

func lunge(v: Vector2) -> void:
	_impulse = (_impulse + v).limit_length(1400.0)

## Grant/extend i-frames (used to shield the player while the weapon picker is up).
func make_invulnerable(t: float) -> void:
	_invuln = maxf(_invuln, t)

## True if a wall is right behind us in the given direction — i.e. we can't be knocked back,
## so a hit lands with extra force (wall-pin). A real physics raycast, run during _physics_process.
func is_pinned(dir: Vector2) -> bool:
	if dir == Vector2.ZERO:
		return false
	var space := get_world_2d().direct_space_state
	if space == null:
		return false
	var q := PhysicsRayQueryParameters2D.create(global_position, global_position + dir.normalized() * (body_radius + 26.0))
	q.collision_mask = Game.L_WALL
	return not space.intersect_ray(q).is_empty()

func try_spend_stamina(cost: float) -> bool:
	if not uses_stamina:
		return true
	if stamina < cost:
		return false
	stamina -= cost
	_stamina_delay = 0.5
	return true

func on_too_tired() -> void:
	pass   # overridable feedback hook

## The collector Area2D touched a loose pickup — eat a gem to grow, or grab a crate
## to swap weapon head. Guarded so two fighters can't both claim the same gem.
func _on_pickup_touched(body: Node) -> void:
	if _dead:
		return
	var p := body as Pickup
	if p == null or p.consumed:
		return
	if p.kind == Pickup.Kind.GEM:
		grow(p.value)
		if is_player:
			# The vacuum combo: each gem within 0.8s rings one semitone higher.
			var pitch := pow(2.0, float(mini(_chime_step, 14)) / 12.0)
			_chime_step += 1
			_chime_time = 0.8
			Sfx.play(&"chime", global_position, -8.0, pitch)
	else:
		weapon.set_type(p.weapon_type)
		Sfx.play(&"chime", global_position, -4.0, 0.65)
		Game.popup(weapon.type_name() + "!", global_position + Vector2(0, -body_radius - 22.0), Color(1, 0.9, 0.5), 1.2)
	p.consume()

func on_hit_feedback(_shake: float, _dir: Vector2, _big: bool) -> void:
	pass   # player overrides to shake the camera

## The wielder just felled `victim` — claim a chunk of its mass outright.
## Felling the CROWN holder pays a bounty (0.5 of their mass instead of 0.4) — a soft
## comeback valve that keeps "kill the king" worth the risk.
func on_scored_kill(victim: Fighter) -> void:
	grow(victim.mass * (0.5 if victim.is_king else Game.KILL_ABSORB))
	Game.feed_event.emit("%s  >  %s" % [display_name, victim.display_name], is_player or victim.is_player)
	if is_player or victim.is_player:
		Sfx.play(&"gong", victim.global_position, 0.0, clampf(1.2 / sqrt(maxf(victim.mass, 0.5)), 0.5, 1.2))
	if is_player:
		Game.hitstop(0.05, 0.08)   # the payoff moment gets a real beat
		Game.popup("KO!", global_position + Vector2(0, -body_radius - 20.0), Color(1.0, 0.85, 0.3), 1.4)
		Game.add_kill()

func grow(amount: float) -> void:
	mass = clampf(mass + amount, Game.START_MASS, Game.MAX_MASS)
	_apply_mass()
	if is_player:
		Game.player_mass = mass
		Game.set_player_score(int(round(mass * 100.0)))
		# Size-doubling fanfare: growth costs double each time, so celebrate each doubling —
		# frequent hooks early, rare punctuation late, can never spam.
		var lvl := int(floor(log(maxf(mass, 1.0)) / log(2.0)))
		if lvl > _milestone:
			_milestone = lvl
			Game.popup("SIZE %d!" % int(round(mass * 100.0)), global_position + Vector2(0, -body_radius - 34.0), Color(1.0, 0.9, 0.4), 1.5)
			Sfx.play(&"fanfare", global_position, -2.0)
			if Game.fx:
				Game.fx.ring(global_position, Color(1.0, 0.88, 0.45))

## Re-derive body size, reach, health cap and collector range from the current mass.
func _apply_mass() -> void:
	body_radius = Game.body_radius_for_mass(mass)
	_circle.radius = body_radius
	_collector_circle.radius = body_radius + 34.0
	var ratio := 1.0 if max_health <= 0.0 else clampf(health / max_health, 0.0, 1.0)
	max_health = Game.health_for_mass(mass)
	health = max_health * ratio if not is_equal_approx(ratio, 1.0) else max_health
	if weapon:
		weapon.refresh_scale(mass)
	queue_redraw()

## Place + (re)initialise this fighter for a fresh life. Used at spawn and respawn.
func spawn_setup(pos: Vector2, m: float, nm: String, col: Color) -> void:
	position = pos
	display_name = nm
	color = col
	mass = m
	_dead = false
	_steer = Vector2.ZERO
	_impulse = Vector2.ZERO
	_env = Vector2.ZERO
	# Spawn shield: a fresh life can't be smashed the instant it appears in a whirling
	# pile. The player's shield cancels early on their first attack input (an
	# invulnerable aggressor would be uncounterable).
	_invuln = 1.5 if is_player else 1.0
	_hurt = 0.0
	_cushion = 0.0
	wet = 1.0
	is_king = false
	_ghosts.clear()
	_name_line = null
	_label_val = -1
	_milestone = int(floor(log(maxf(m, 1.0)) / log(2.0)))
	_apply_mass()
	health = max_health
	stamina = Game.STAMINA_MAX
	if is_player:
		Game.player_mass = m
	if weapon:
		if is_player:
			weapon.set_type(Weapon.Type.STONE)   # every life starts fresh with the boulder
		weapon.reset()
		weapon.set_solid_active(true)
		weapon.set_physics_process(true)          # _die() paused it; bring it back
	show()
	set_physics_process(true)
	if is_player:
		Game.set_player_score(int(round(mass * 100.0)))
	queue_redraw()

func is_dead() -> bool:
	return _dead

## Main's leaderboard pass crowns / uncrowns the arena's #1.
func set_king(k: bool) -> void:
	if is_king != k:
		is_king = k
		queue_redraw()

func _die() -> void:
	if _dead:
		return
	_dead = true
	if weapon:
		weapon.reset()                   # settle it out of SPIN/SWING so it can't hit while dead
		weapon.set_solid_active(false)   # a corpse's stone shouldn't keep blocking the living
		weapon.set_physics_process(false)
	# The death reads as THIS fighter shattering — a burst in their own color.
	if Game.fx:
		Game.fx.burst(global_position, color, 26, 420.0, 4.0)
	if is_player:
		Sfx.play(&"gong", global_position, 0.0, 0.7)
		Game.hitstop(0.05, 0.12)         # let the death land
	_spill_loot()
	died.emit(self)

func _spill_loot() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var spill := mass * Game.SPILL_FRACTION
	# Fewer, RICHER gems (each worth ~2 baseline) — and scattered on a ring around the
	# corpse rather than stacked at one point, so the physics solver never sees the
	# N²/2-pair contact island that a same-point pile of RigidBodies creates.
	var count := clampi(int(spill / (Game.GEM_MASS * 2.0)), 3, 24)
	var per := spill / float(count)
	var r := Game.rng()
	for i in range(count):
		var g := Pickup.new()
		scene.add_child(g)
		var a := r.randf() * TAU
		var off := Vector2(cos(a), sin(a)) * (body_radius * 0.6 + r.randf_range(0.0, body_radius * 0.8))
		g.setup(global_position + off, per, Pickup.Kind.GEM, color)
		g.fling(Vector2(cos(a), sin(a)) * r.randf_range(120.0, 340.0))

# --- drawing (placeholder art, in code) --------------------------------------------

func _draw() -> void:
	_wet_drawn = wet
	var col := color
	if _hurt > 0.0:
		col = col.lerp(Color(1, 0.3, 0.3), clampf(_hurt / 0.32, 0.0, 1.0))
	if _invuln > 0.0 and int(_invuln * 30.0) % 2 == 0:
		col = col.darkened(0.25)
	# Wading ripple — the visual half of the water slow (the feel half is the splash).
	if wet < 0.99:
		draw_arc(Vector2.ZERO, body_radius + 5.0, 0.0, TAU, 24, Color(0.7, 0.85, 1.0, 0.4), 2.0)
		draw_arc(Vector2.ZERO, body_radius + 10.0, 0.0, TAU, 24, Color(0.7, 0.85, 1.0, 0.18), 2.0)
	# Speed afterimage (影像速度) — fading ghosts trailing a fast mover.
	for g in _ghosts:
		var ga: float = (1.0 - float(g.age) / GHOST_LIFE) * 0.32
		draw_circle(to_local(g.pos), body_radius * 0.92, Color(color.r, color.g, color.b, ga))
	draw_circle(Vector2.ZERO, body_radius, col)
	draw_arc(Vector2.ZERO, body_radius, 0.0, TAU, 26, col.darkened(0.4), 3.0)
	# Facing dot toward the aim.
	var face := Vector2.RIGHT.rotated(weapon.aim_angle) * body_radius * 0.55 if weapon else Vector2.ZERO
	draw_circle(face, body_radius * 0.28, Color(0.15, 0.13, 0.12))

	# Health bar (only when hurt) — a thin bar above the body.
	if health < max_health - 0.5:
		var w := body_radius * 1.8
		var y := -body_radius - 12.0
		draw_rect(Rect2(-w * 0.5, y, w, 5.0), Color(0, 0, 0, 0.5))
		var frac := clampf(health / max_health, 0.0, 1.0)
		draw_rect(Rect2(-w * 0.5, y, w * frac, 5.0), Color(0.4, 0.85, 0.4).lerp(Color(0.9, 0.4, 0.3), 1.0 - frac))

	# The crown — the arena's #1 wears it, everyone hunts it.
	if is_king:
		var cy := -body_radius - 26.0
		var cw := 11.0
		draw_colored_polygon(PackedVector2Array([
			Vector2(-cw, cy), Vector2(-cw, cy - 9.0), Vector2(-cw * 0.5, cy - 4.0),
			Vector2(0, cy - 11.0), Vector2(cw * 0.5, cy - 4.0), Vector2(cw, cy - 9.0),
			Vector2(cw, cy),
		]), Color(1.0, 0.85, 0.25))

	# Nameplate: shaped ONCE per label change (TextLine cache), tinted by the food chain —
	# red will hunt you, green will flee you, white is an even fight. The tint uses the
	# bots' own decision thresholds, so the color IS their intent.
	var val := int(round(mass * 100.0))
	if _name_line == null or val != _label_val:
		_label_val = val
		_name_line = TextLine.new()
		_name_line.add_string("%s  %d" % [display_name, val], ThemeDB.fallback_font, 15)
	var tint := Color(1, 1, 1, 0.9)
	if is_player:
		tint = Color(1, 0.92, 0.6, 0.95)
	else:
		var ratio := mass / maxf(Game.player_mass, 0.01)
		if ratio > 1.18:
			tint = Color(1.0, 0.55, 0.5, 0.95)
		elif ratio < 0.92:
			tint = Color(0.6, 0.95, 0.6, 0.9)
	var ts := _name_line.get_size()
	var tpos := Vector2(-ts.x * 0.5, body_radius + 8.0)
	_name_line.draw(get_canvas_item(), tpos + Vector2(1.5, 1.5), Color(0, 0, 0, 0.6))
	_name_line.draw(get_canvas_item(), tpos, tint)
