class_name Bot
extends Fighter
## A rival knight. Same food-chain core as ever — HUNT smaller, FLEE bigger, WANDER
## toward loot — but every bot now has a TEMPERAMENT (two rolled scalars), pays real
## stamina like the player, reads the terrain, and knows when to slam. All of it rides
## the exact same physics path the player uses (aim_at / set_swinging / do_slam), so
## nothing here is a scripted cheat: bots win with the same tools you have.
##
## PERCEPTION WHITELIST (the anti-cheat contract — keep future tweaks inside it):
## a bot may read only what a player could see: positions, velocities, mass/size,
## weapon type + state (the whirl and slam telegraph are drawn on screen), its OWN
## stamina/health, terrain height/slope (the map is drawn), and is_pinned() (a wall
## behind someone is visible). NEVER an opponent's stamina — that bar isn't rendered.

enum Mode { WANDER, HUNT, FLEE }

const SIGHT := 640.0
const FEAR := 460.0
const GEM_SIGHT := 560.0
const CRATE_SIGHT := 900.0
const SEPARATION := 240.0     ## anti-clump radius (bias applied to wandering)

var p_agg := 1.0              ## aggression 0.7..1.4 — 1.0 reproduces the old thresholds exactly
var p_greed := 1.0            ## loot appetite 0.6..1.5
var preferred_weapon: int = Weapon.Type.STONE
var whirl_speed := 7.5        ## rad/s while attacking — randomized so attack rhythms differ

var _mode: int = Mode.WANDER
var _target: Fighter
var _think_cd := 0.0
var _wander_dir := Vector2.RIGHT
var _wander_pickup: Node2D = null   ## chosen at rethink — never re-scanned per frame
var _spin_sign := 1.0
var _aim := 0.0
var _winded := false          ## stamina hysteresis: back off under 25, re-engage over 65
var _slam_cd := 0.0
var _slam_roll_cd := 0.0
var _terrain: Terrain

func _ready() -> void:
	# Bots pay for slams, whirls and whip-work like everyone else — a free infinite
	# whirl was an UNCOUNTERABLE defense. The mild regen edge is their handicap for
	# managing the bar without a brain.
	uses_stamina = true
	stamina_regen_mult = 1.25
	var rng := Game.rng()
	p_agg = rng.randf_range(0.7, 1.4)
	p_greed = rng.randf_range(0.6, 1.5)
	preferred_weapon = [Weapon.Type.STONE, Weapon.Type.HAMMER, Weapon.Type.SICKLE, Weapon.Type.STAFF][rng.randi() % 4]
	whirl_speed = 7.5 * rng.randf_range(0.8, 1.2)
	super._ready()
	_aim = rng.randf() * TAU
	_spin_sign = 1.0 if rng.randf() < 0.5 else -1.0
	_wander_dir = Vector2.RIGHT.rotated(rng.randf() * TAU)

# --- temperament-derived thresholds (agg 1.0 == the old hardcoded numbers) ----------

func _prey_ratio() -> float:
	return clampf(0.60 + 0.32 * p_agg, 0.80, 1.02)    # bold bots take near-even fights

func _threat_ratio() -> float:
	return clampf(0.83 + 0.35 * p_agg, 1.05, 1.35)    # bold bots stand ground longer

func _fear_dist() -> float:
	return FEAR / p_agg                                # skittish bots break early

## How eagerly this loadout slams: the hammer IS a slam weapon, the sickle isn't.
func _slam_prop() -> float:
	match weapon.type:
		Weapon.Type.HAMMER:
			return 1.0
		Weapon.Type.STONE:
			return 0.7
		Weapon.Type.STAFF:
			return 0.5
		_:
			return 0.3

func _control(delta: float) -> void:
	_slam_cd = maxf(0.0, _slam_cd - delta)
	_slam_roll_cd = maxf(0.0, _slam_roll_cd - delta)
	_think_cd -= delta
	if _think_cd <= 0.0:
		_rethink()
		_think_cd = Game.rng().randf_range(0.25, 0.5)

	match _mode:
		Mode.HUNT:
			_do_hunt(delta)
		Mode.FLEE:
			_do_flee(delta)
		_:
			_do_wander(delta)

## The 2-4 Hz brain: one scan of the fighter group feeds threat pick, prey pick,
## anti-clump separation AND the loot claim check; the per-frame handlers only steer.
func _rethink() -> void:
	# Stamina hysteresis — the winded back-off window is the player's designed opening.
	if stamina < 25.0:
		_winded = true
	elif stamina > 65.0:
		_winded = false

	_target = null
	var threat: Fighter = null
	var threat_d := _fear_dist()
	var prey_cands: Array = []          # up to 3 of {f, d}
	var crowd_push := Vector2.ZERO
	var fighters := get_tree().get_nodes_in_group("fighter")
	var my_h := _height(global_position)
	for other in fighters:
		if other == self or not is_instance_valid(other):
			continue
		var f := other as Fighter
		if f == null or f._dead:
			continue
		var d := global_position.distance_to(f.global_position)
		if d < SEPARATION:
			crowd_push += (global_position - f.global_position) / maxf(d, 1.0)
		if f.mass > mass * _threat_ratio() and d < threat_d:
			threat = f
			threat_d = d
		elif f.mass < mass * _prey_ratio() and d < SIGHT:
			# Timid bots don't start fights they'd have to climb into.
			if p_agg < 1.0 and _height(f.global_position) > my_h + 45.0:
				continue
			prey_cands.append({"f": f, "d": d})

	if threat != null:
		_mode = Mode.FLEE
		_target = threat
		return

	var prey := _pick_prey(prey_cands, fighters)
	if prey != null:
		_mode = Mode.HUNT
		_target = prey
		return

	_mode = Mode.WANDER
	_wander_pickup = _pick_pickup(fighters)
	if crowd_push != Vector2.ZERO:
		# Drift away from the pack — spreads 13 bots over the map instead of one pile.
		_wander_dir = (_wander_dir + crowd_push.normalized() * 1.2).normalized()
	elif Game.rng().randf() < 0.5:
		_wander_dir = Vector2.RIGHT.rotated(Game.rng().randf() * TAU)

## Weighted-random over the 3 nearest prey, discounting anyone already engaged —
## probabilistic choice spreads hunters across targets instead of dog-piling one.
func _pick_prey(cands: Array, fighters: Array) -> Fighter:
	if cands.is_empty():
		return null
	cands.sort_custom(func(a, b): return a["d"] < b["d"])
	var total := 0.0
	var weights: Array = []
	for i in range(mini(cands.size(), 3)):
		var c: Dictionary = cands[i]
		var w: float = 1.0 / (float(c["d"]) + 150.0)
		for other in fighters:
			var f := other as Fighter
			if f != null and f != self and f != c["f"] and not f._dead \
					and f.global_position.distance_to((c["f"] as Fighter).global_position) < 220.0:
				w *= 0.4   # someone is already on them
				break
		weights.append(w)
		total += w
	var roll := Game.rng().randf() * total
	for i in range(weights.size()):
		roll -= weights[i]
		if roll <= 0.0:
			return cands[i]["f"] as Fighter
	return cands[0]["f"] as Fighter

## Choose ONE pickup at rethink (never per frame): gems value-weighted by distance,
## crates only if they'd change our loadout toward what we want — with a claim check
## so 13 bots don't converge on the same shiny thing.
func _pick_pickup(fighters: Array) -> Node2D:
	var best: Node2D = null
	var best_score := 0.0
	var best_d := 0.0
	var gem_sight := GEM_SIGHT * p_greed
	var crate_sight := CRATE_SIGHT * p_greed
	for p in get_tree().get_nodes_in_group("pickup"):
		var pk := p as Pickup
		if pk == null or pk.consumed:
			continue
		var d := global_position.distance_to(pk.global_position)
		var score := 0.0
		if pk.kind == Pickup.Kind.GEM:
			if d > gem_sight:
				continue
			score = pk.value / (d + 200.0)
		else:
			if d > crate_sight or pk.weapon_type == weapon.type:
				continue
			if pk.weapon_type != preferred_weapon and weapon.type != Weapon.Type.STONE:
				continue
			score = 1.2 / (d + 200.0)
		if score > best_score:
			best_score = score
			best = pk
			best_d = d
	if best != null:
		for other in fighters:   # claim check on the winner only — 13 checks, not 220×13
			var f := other as Fighter
			if f != null and f != self and not f._dead \
					and f.global_position.distance_to(best.global_position) < best_d * 0.8:
				return null
	return best

func _target_gone() -> bool:
	return _target == null or not is_instance_valid(_target) or _target._dead

func _do_hunt(delta: float) -> void:
	weapon.set_spin(false)   # hunting whips via aim-rotation, never the whirl — clear any leftover SPIN
	if _target_gone():
		_mode = Mode.WANDER
		weapon.set_swinging(false)
		return
	var to := _target.global_position - global_position
	var d := to.length()

	# Winded: give ground and guard with the passive whip until the bar recovers —
	# the visible opening IS the counterplay against bot pressure.
	if _winded:
		weapon.set_swinging(false)
		weapon.aim_at(to.angle())
		move_dir = -to.normalized() * 0.7
		return

	var strike := weapon.reach() + _target.body_radius + 44.0
	if d <= strike:
		_try_slam(to, d)
		# In range: whirl the head by rotating the aim, and shove in.
		_aim += _spin_sign * whirl_speed * delta
		weapon.aim_at(_aim)
		weapon.set_swinging(true)
		move_dir = to.normalized() * 0.5
	else:
		weapon.set_swinging(false)
		weapon.aim_at(to.angle())
		_aim = to.angle()
		move_dir = _approach_dir(to)

## Slam when it will actually LAND: target too slow to dodge the windup, turtled in a
## whirl (the slam's radial burst is the designed whirl-counter), or pinned. Every
## trigger is observable — no stamina peeking.
func _try_slam(to: Vector2, d: float) -> void:
	if _slam_cd > 0.0 or _slam_roll_cd > 0.0 or weapon.is_busy():
		return
	_slam_roll_cd = 0.35
	if stamina < 55.0 or health <= max_health * 0.35:
		return
	if d > weapon.reach() * 1.15 + _target.body_radius:
		return
	var landable: bool = _target.velocity.length() < 130.0 \
		or _target.weapon.state == Weapon.State.SPIN \
		or _target.is_pinned(to.normalized())
	if not landable:
		return
	if Game.rng().randf() < 0.55 * _slam_prop() * p_agg:
		weapon.aim_at(to.angle())
		weapon.do_slam()
		_slam_cd = Game.rng().randf_range(2.5, 4.5) / p_agg

## Approach with the land in mind: when the shortest path is a steep climb, switchback
## along the contour and take the high ground first — knocked prey then tumbles
## DOWNHILL into our free chase speed. Pure positioning; the physics does the rest.
func _approach_dir(to: Vector2) -> Vector2:
	var t := _terrain_node()
	if t == null:
		return to.normalized()
	var grad := t.gradient_at(global_position)
	var to_n := to.normalized()
	if grad.length() > 0.12 and to_n.dot(grad.normalized()) > 0.55:   # heading hard uphill
		var along := grad.orthogonal().normalized()
		if along.dot(to_n) < 0.0:
			along = -along
		return (to_n * 0.5 + along * 0.6).normalized()
	return to_n

func _do_flee(delta: float) -> void:
	if _target_gone():
		_mode = Mode.WANDER
		weapon.set_spin(false)   # don't leave the whirl running when the threat vanishes at close range
		return
	var away := global_position - _target.global_position
	var flee := away.normalized()

	# Borrow the downhill boost — it decides chases between near-equal speeds, and it
	# LOOKS like the bot knows the map. But never flee into a wall (that gifts the
	# wall-pin execution) or into water (the slow pool is where fleers go to die).
	var t := _terrain_node()
	if t != null:
		var grad: Vector2 = t.gradient_at(global_position)
		if grad.length() > 0.12:
			flee = (flee + (-grad).normalized() * 0.45).normalized()
		if t.norm_height(global_position + flee * 200.0) < Game.COAST_T:
			var along := grad.orthogonal().normalized()
			if along.dot(flee) < 0.0:
				along = -along
			flee = (along * 0.8 + flee * 0.3).normalized()
	if is_pinned(flee):
		# Rotate along the wall, toward the arena centre (corners are execution zones).
		var toward_centre := -global_position
		var cw := flee.orthogonal()
		flee = cw if cw.dot(toward_centre) > 0.0 else -cw
		# Cornered AND in reach? Desperation slam to blast free.
		if away.length() < weapon.reach() + 40.0 and _slam_cd <= 0.0 \
				and stamina >= 55.0 and not weapon.is_busy():
			weapon.aim_at((-away).angle())
			weapon.do_slam()
			_slam_cd = Game.rng().randf_range(2.5, 4.5)
	move_dir = flee

	# Whirl defensively if the bigger fighter is right on top of us — but only with the
	# stamina to sustain it; a winded bot must run on legs alone (counterable pressure).
	if away.length() < weapon.reach() + _target.body_radius + 30.0 \
			and stamina >= 35.0 and not _winded:
		_aim += _spin_sign * whirl_speed * delta
		weapon.aim_at(_aim)
		weapon.set_spin(true)
	else:
		weapon.set_spin(false)
		weapon.aim_at(away.angle())

func _do_wander(delta: float) -> void:
	weapon.set_swinging(false)
	weapon.set_spin(false)
	# Steer at the pickup chosen at rethink; if it got eaten meanwhile, drift until the
	# next think tick rather than re-scanning the whole group mid-frame.
	if _wander_pickup != null and (not is_instance_valid(_wander_pickup) or (_wander_pickup as Pickup).consumed):
		_wander_pickup = null
	if _wander_pickup != null:
		var to: Vector2 = _wander_pickup.global_position - global_position
		move_dir = to.normalized()
		weapon.aim_at(to.angle())
	else:
		move_dir = _wander_dir
		_aim += delta * 0.6
		weapon.aim_at(_aim)

func _height(p: Vector2) -> float:
	var t := _terrain_node()
	return t.height_lookup(p) if t != null else 0.0

func _terrain_node() -> Terrain:
	if _terrain == null or not is_instance_valid(_terrain):
		_terrain = get_tree().get_first_node_in_group("terrain") as Terrain
	return _terrain
