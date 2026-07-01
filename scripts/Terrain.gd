class_name Terrain
extends Node2D
## The battlefield's geography — a real-feeling HEIGHT FIELD, not an abstract force zone.
## Structure is built in layers, the way real land is: a few big Gaussian MASSIFS lay down
## mountain ranges and basins (the tectonic macro-shape), fractal (FBM) noise adds rolling
## relief, and a RIDGED noise layer carves sharp mountain ridges on top. It's drawn as a
## shaded topographic map — water in the basins, green lowlands, brown hills, grey rock,
## white snow on the peaks — with contour lines, so you can see high vs low at a glance.
## The slope of that surface is the only "gravity" here: everything drifts DOWNHILL.

const BASE_AMP := 165.0
const RIDGE_AMP := 55.0         ## kept small — a hint of ridges, not busy detail
const TERRAIN_G := 300.0        ## downhill acceleration scale for fighters
const STEP := 92.0              ## coarse grid — big smooth landforms, not fine detail

var _base := FastNoiseLite.new()
var _ridge := FastNoiseLite.new()
var _massifs: Array = []         ## {pos, amp, sigma} — the macro ranges & basins
var _grid := PackedFloat32Array()
var _cols := 0
var _rows := 0
var _origin := Vector2.ZERO
var _hmin := -1.0
var _hmax := 1.0

# Hypsometric palette, keyed by NORMALIZED elevation t in 0..1 (0 = lowest basin, 1 = highest
# peak) so the full range of colours is always used and high vs low reads at a glance.
const PALETTE := [
	[0.0, Color(0.10, 0.20, 0.42)],    # deep water
	[0.16, Color(0.15, 0.31, 0.54)],   # water
	[0.30, Color(0.20, 0.44, 0.50)],   # coast / shallows
	[0.42, Color(0.22, 0.44, 0.26)],   # lowland green
	[0.56, Color(0.42, 0.48, 0.24)],   # grass / foothills
	[0.68, Color(0.44, 0.34, 0.21)],   # hill brown
	[0.80, Color(0.45, 0.41, 0.40)],   # rock
	[0.90, Color(0.60, 0.58, 0.60)],   # high rock
	[1.0, Color(0.92, 0.94, 0.98)],    # snow
]

func _ready() -> void:
	add_to_group("terrain")
	z_index = -2
	var rng := Game.rng()
	_base.seed = rng.randi()
	_base.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_base.fractal_type = FastNoiseLite.FRACTAL_FBM
	_base.fractal_octaves = 3            # fewer octaves -> smoother, less busy
	_base.frequency = 0.0004            # low frequency -> big landforms (a valley, not a continent)
	_ridge.seed = rng.randi()
	_ridge.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_ridge.fractal_octaves = 3
	_ridge.frequency = 0.0011
	# Macro structure: a few big, wide ranges (+) and basins (-) — coarse, not fussy.
	var half := Game.ARENA_SIZE * 0.5
	for i in range(rng.randi_range(4, 6)):
		_massifs.append({
			"pos": Vector2(rng.randf_range(-half.x, half.x), rng.randf_range(-half.y, half.y)),
			"amp": rng.randf_range(-180.0, 250.0),
			"sigma": rng.randf_range(680.0, 1200.0),
		})
	_build_grid()
	set_physics_process(true)
	queue_redraw()

func height_at(p: Vector2) -> float:
	var h := 0.0
	for m in _massifs:
		var s: float = m["sigma"]
		h += float(m["amp"]) * exp(-p.distance_squared_to(m["pos"]) / (2.0 * s * s))
	h += _base.get_noise_2d(p.x, p.y) * BASE_AMP
	h += _ridge.get_noise_2d(p.x, p.y) * RIDGE_AMP
	return h

func _physics_process(delta: float) -> void:
	# Only fighters feel the downhill pull. Gems are deliberately NOT pushed every frame so the
	# RigidBodies can go to sleep once settled (a constant force would keep them awake = stutter).
	for f in get_tree().get_nodes_in_group("fighter"):
		var fi := f as Fighter
		if fi == null or fi.is_dead():
			continue
		fi.apply_env_force(-_grid_gradient(fi.global_position) * TERRAIN_G, delta)

## Downhill slope from the precomputed grid (cheap; no per-frame noise sampling).
func _grid_gradient(p: Vector2) -> Vector2:
	var gx := clampi(int(floor((p.x - _origin.x) / STEP)), 1, _cols - 1)
	var gy := clampi(int(floor((p.y - _origin.y) / STEP)), 1, _rows - 1)
	var dhdx := (_h(gx + 1, gy) - _h(gx - 1, gy)) / (2.0 * STEP)
	var dhdy := (_h(gx, gy + 1) - _h(gx, gy - 1)) / (2.0 * STEP)
	return Vector2(dhdx, dhdy)

# --- grid + rendering -------------------------------------------------------------

func _build_grid() -> void:
	var half := Game.ARENA_SIZE * 0.5
	var margin := Game.WALL_THICK
	_origin = -half - Vector2(margin, margin)
	var span := Game.ARENA_SIZE + Vector2(margin, margin) * 2.0
	_cols = int(ceil(span.x / STEP))
	_rows = int(ceil(span.y / STEP))
	_grid.resize((_cols + 1) * (_rows + 1))
	_hmin = INF
	_hmax = -INF
	for gy in range(_rows + 1):
		for gx in range(_cols + 1):
			var h := height_at(_origin + Vector2(gx, gy) * STEP)
			_grid[gy * (_cols + 1) + gx] = h
			_hmin = minf(_hmin, h)
			_hmax = maxf(_hmax, h)

func _h(gx: int, gy: int) -> float:
	return _grid[gy * (_cols + 1) + gx]

func _elev_color(h: float) -> Color:
	var t := clampf(inverse_lerp(_hmin, _hmax, h), 0.0, 1.0)
	for i in range(PALETTE.size() - 1):
		var a: Array = PALETTE[i]
		var b: Array = PALETTE[i + 1]
		if t <= float(b[0]):
			var span: float = float(b[0]) - float(a[0])
			var k: float = 0.0 if span <= 0.0 else clampf((t - float(a[0])) / span, 0.0, 1.0)
			return (a[1] as Color).lerp(b[1] as Color, k)
	return PALETTE[PALETTE.size() - 1][1]

func _draw() -> void:
	# Shaded elevation fill — each cell a Gouraud quad coloured by its corner heights.
	for gy in range(_rows):
		for gx in range(_cols):
			var x0 := _origin.x + gx * STEP
			var y0 := _origin.y + gy * STEP
			var pts := PackedVector2Array([
				Vector2(x0, y0), Vector2(x0 + STEP, y0),
				Vector2(x0 + STEP, y0 + STEP), Vector2(x0, y0 + STEP)])
			var cols := PackedColorArray([
				_elev_color(_h(gx, gy)), _elev_color(_h(gx + 1, gy)),
				_elev_color(_h(gx + 1, gy + 1)), _elev_color(_h(gx, gy + 1))])
			draw_polygon(pts, cols)
	# Contour lines on top for readability — evenly spaced across the real height range.
	var steps := 7
	for s in range(1, steps):
		var level := lerpf(_hmin, _hmax, float(s) / float(steps))
		for gy in range(_rows):
			for gx in range(_cols):
				_contour_cell(gx, gy, level, Color(0.0, 0.0, 0.0, 0.28), 1.3)
	# Arena boundary.
	draw_rect(Rect2(-Game.ARENA_SIZE * 0.5, Game.ARENA_SIZE), Color(0.6, 0.55, 0.8, 0.9), false, 6.0)

func _contour_cell(gx: int, gy: int, level: float, col: Color, w: float) -> void:
	var x0 := _origin.x + gx * STEP
	var y0 := _origin.y + gy * STEP
	var ha := _h(gx, gy)
	var hb := _h(gx + 1, gy)
	var hc := _h(gx + 1, gy + 1)
	var hd := _h(gx, gy + 1)
	var pts: Array = []
	if (ha < level) != (hb < level):
		pts.append(Vector2(x0 + STEP * (level - ha) / (hb - ha), y0))
	if (hb < level) != (hc < level):
		pts.append(Vector2(x0 + STEP, y0 + STEP * (level - hb) / (hc - hb)))
	if (hd < level) != (hc < level):
		pts.append(Vector2(x0 + STEP * (level - hd) / (hc - hd), y0 + STEP))
	if (ha < level) != (hd < level):
		pts.append(Vector2(x0, y0 + STEP * (level - ha) / (hd - ha)))
	if pts.size() == 2:
		draw_line(pts[0], pts[1], col, w)
	elif pts.size() == 4:
		draw_line(pts[0], pts[1], col, w)
		draw_line(pts[2], pts[3], col, w)
