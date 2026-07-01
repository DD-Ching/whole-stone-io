class_name Terrain
extends Node2D
## The battlefield's shape — a topographic HEIGHT FIELD drawn as contour lines (等高線),
## generated from a handful of mutated Gaussian bumps (高斯隨機 變異) plus smooth noise.
## The slope of that field is a GRAVITY GRADIENT (重力場 梯度): every fighter and loose gem
## is nudged DOWNHILL, so valleys pull things in and ridges shed them. Peaks are high ground
## you slide off; basins are traps that gather the crowd (and the loot).

const NOISE_AMP := 190.0        ## height contribution from the smooth noise layer
const TERRAIN_G := 340.0        ## downhill acceleration scale for fighters
const PICKUP_G := 260.0         ## gentler downhill pull for loose gems
const STEP := 92.0              ## contour sampling grid resolution (px)
const LEVELS := [-190.0, -120.0, -55.0, 0.0, 55.0, 120.0, 190.0, 250.0]

var _noise := FastNoiseLite.new()
var _bumps: Array = []          ## {pos, amp, sigma} — the mutated Gaussian features
var _grid := PackedFloat32Array()
var _cols := 0
var _rows := 0
var _origin := Vector2.ZERO

func _ready() -> void:
	add_to_group("terrain")
	z_index = -2   # under the fighters/gems, over the clear colour
	var rng := Game.rng()
	_noise.seed = rng.randi()
	_noise.frequency = 0.0011
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	var half := Game.ARENA_SIZE * 0.5
	# Mutated Gaussian terrain: random peaks (+) and pits (-) of varied width.
	for i in range(rng.randi_range(7, 11)):
		_bumps.append({
			"pos": Vector2(rng.randf_range(-half.x, half.x), rng.randf_range(-half.y, half.y)),
			"amp": rng.randf_range(-230.0, 270.0),
			"sigma": rng.randf_range(300.0, 640.0),
		})
	_build_grid()
	set_physics_process(true)
	queue_redraw()

## Height of the field at a world point (analytic: noise + Gaussian bumps).
func height_at(p: Vector2) -> float:
	var h := _noise.get_noise_2d(p.x, p.y) * NOISE_AMP
	for b in _bumps:
		var s: float = b["sigma"]
		h += float(b["amp"]) * exp(-p.distance_squared_to(b["pos"]) / (2.0 * s * s))
	return h

## Uphill gradient (finite difference). Downhill force = -gradient_at(p).
func gradient_at(p: Vector2) -> Vector2:
	var e := 7.0
	var gx := (height_at(p + Vector2(e, 0)) - height_at(p - Vector2(e, 0))) / (2.0 * e)
	var gy := (height_at(p + Vector2(0, e)) - height_at(p - Vector2(0, e))) / (2.0 * e)
	return Vector2(gx, gy)

func _physics_process(delta: float) -> void:
	# Slide fighters and gems downhill — the gravity gradient.
	for f in get_tree().get_nodes_in_group("fighter"):
		var fi := f as Fighter
		if fi == null or fi.is_dead():
			continue
		fi.apply_env_force(-_grid_gradient(fi.global_position) * TERRAIN_G, delta)
	for p in get_tree().get_nodes_in_group("pickup"):
		if p is Pickup and is_instance_valid(p):
			p.apply_env_force(-_grid_gradient((p as Pickup).global_position) * PICKUP_G, delta)

## Cheap downhill slope from the PRECOMPUTED grid (central differences) — used for the
## per-frame physics pull so we don't re-evaluate the analytic multi-Gaussian field for
## every gem every frame.
func _grid_gradient(p: Vector2) -> Vector2:
	var gx := clampi(int(floor((p.x - _origin.x) / STEP)), 1, _cols - 1)
	var gy := clampi(int(floor((p.y - _origin.y) / STEP)), 1, _rows - 1)
	var dhdx := (_h(gx + 1, gy) - _h(gx - 1, gy)) / (2.0 * STEP)
	var dhdy := (_h(gx, gy + 1) - _h(gx, gy - 1)) / (2.0 * STEP)
	return Vector2(dhdx, dhdy)

# --- contour rendering (marching squares) -----------------------------------------

func _build_grid() -> void:
	var half := Game.ARENA_SIZE * 0.5
	var margin := Game.WALL_THICK
	_origin = -half - Vector2(margin, margin)
	var span := Game.ARENA_SIZE + Vector2(margin, margin) * 2.0
	_cols = int(ceil(span.x / STEP))
	_rows = int(ceil(span.y / STEP))
	_grid.resize((_cols + 1) * (_rows + 1))
	for gy in range(_rows + 1):
		for gx in range(_cols + 1):
			_grid[gy * (_cols + 1) + gx] = height_at(_origin + Vector2(gx, gy) * STEP)

func _h(gx: int, gy: int) -> float:
	return _grid[gy * (_cols + 1) + gx]

func _draw() -> void:
	for li in range(LEVELS.size()):
		var level: float = LEVELS[li]
		var col := _level_color(level)
		var width := 2.0 if is_equal_approx(level, 0.0) else 1.4
		for gy in range(_rows):
			for gx in range(_cols):
				_draw_cell(gx, gy, level, col, width)

func _draw_cell(gx: int, gy: int, level: float, col: Color, width: float) -> void:
	var x0 := _origin.x + gx * STEP
	var y0 := _origin.y + gy * STEP
	var ha := _h(gx, gy)          # top-left
	var hb := _h(gx + 1, gy)      # top-right
	var hc := _h(gx + 1, gy + 1)  # bottom-right
	var hd := _h(gx, gy + 1)      # bottom-left
	var pts: Array = []
	if (ha < level) != (hb < level):   # top edge
		pts.append(Vector2(x0 + STEP * (level - ha) / (hb - ha), y0))
	if (hb < level) != (hc < level):   # right edge
		pts.append(Vector2(x0 + STEP, y0 + STEP * (level - hb) / (hc - hb)))
	if (hd < level) != (hc < level):   # bottom edge
		pts.append(Vector2(x0 + STEP * (level - hd) / (hc - hd), y0 + STEP))
	if (ha < level) != (hd < level):   # left edge
		pts.append(Vector2(x0, y0 + STEP * (level - ha) / (hd - ha)))
	if pts.size() == 2:
		draw_line(pts[0], pts[1], col, width)
	elif pts.size() == 4:   # saddle — two segments
		draw_line(pts[0], pts[1], col, width)
		draw_line(pts[2], pts[3], col, width)

func _level_color(level: float) -> Color:
	# Valleys cool/blue, ridges warm — a faint topographic wash.
	var t := clampf(level / 250.0, -1.0, 1.0)
	var base: Color
	if t < -0.01:
		base = Color(0.4, 0.55, 0.9)    # valley blue
	elif t > 0.01:
		base = Color(0.88, 0.62, 0.4)   # ridge warm
	else:
		base = Color(0.65, 0.7, 0.8)    # sea level
	base.a = 0.16 + 0.12 * absf(t)
	return base
