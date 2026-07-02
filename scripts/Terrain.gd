class_name Terrain
extends Node2D
## The battlefield's geography — a real-feeling HEIGHT FIELD, not an abstract force zone.
## Structure is built in layers, the way real land is: a few big Gaussian MASSIFS lay down
## mountain ranges and basins (the tectonic macro-shape), fractal (FBM) noise adds rolling
## relief, and a RIDGED noise layer carves sharp mountain ridges on top.
##
## Rendering is BAKED, not drawn live: at load the whole map is rendered once into a small
## hillshaded image (elevation palette × slope lighting, sampled 4× finer than the physics
## grid) and upscaled with bilinear filtering — so the entire ground costs the GPU ONE
## textured quad per frame instead of ~1,900 Gouraud polygons, which is what made phones
## stutter. Contour lines are precomputed into a single batched draw_multiline.
##
## The slope of the surface is the only "gravity" here: everything drifts DOWNHILL, and
## the water that collects in the basins is slow to wade through — high ground is power.

const BASE_AMP := 165.0
const RIDGE_AMP := 55.0         ## kept small — a hint of ridges, not busy detail
const TERRAIN_G := 300.0        ## downhill acceleration scale for fighters
const STEP := 92.0              ## coarse physics grid — big smooth landforms
const BAKE_SUB := 4             ## image supersampling vs the grid (23 px/pixel — crisp shading)
const SHADE_GAIN := 2.4         ## hillshade strength (slope × light dot product)

var _base := FastNoiseLite.new()
var _ridge := FastNoiseLite.new()
var _massifs: Array = []         ## {pos, amp, sigma} — the macro ranges & basins
var _grid := PackedFloat32Array()
var _cols := 0
var _rows := 0
var _origin := Vector2.ZERO
var _hmin := -1.0
var _hmax := 1.0
var _tex: ImageTexture
var _contours := PackedVector2Array()   ## all contour segments, batched into ONE draw call

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
	# Bilinear upscale of the baked image IS the smooth shading — set explicitly,
	# never trust the project default.
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
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
	_bake_image()
	_build_contours()
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
	# Fighters feel the downhill pull AND learn how wet they are — one loop, one grid
	# lookup each. Gems are deliberately NOT pushed every frame so their RigidBodies can
	# go to sleep once settled (a constant force would keep them awake = stutter).
	for f in get_tree().get_nodes_in_group("fighter"):
		var fi := f as Fighter
		if fi == null or fi.is_dead():
			continue
		fi.apply_env_force(-_grid_gradient(fi.global_position) * TERRAIN_G, delta)
		var t := norm_height(fi.global_position)
		if t < Game.WATER_T:
			fi.set_wetness(Game.WATER_SLOW)
		elif t < Game.COAST_T:
			fi.set_wetness(Game.COAST_SLOW)
		else:
			fi.set_wetness(1.0)

# --- public lookups (bots read the land the same way physics does) -----------------

## Downhill slope from the precomputed grid (cheap; no per-frame noise sampling).
func gradient_at(p: Vector2) -> Vector2:
	return _grid_gradient(p)

## Bilinear height from the physics grid.
func height_lookup(p: Vector2) -> float:
	var fx := clampf((p.x - _origin.x) / STEP, 0.0, float(_cols) - 0.001)
	var fy := clampf((p.y - _origin.y) / STEP, 0.0, float(_rows) - 0.001)
	var gx := int(fx)
	var gy := int(fy)
	var tx := fx - gx
	var ty := fy - gy
	var h0 := lerpf(_h(gx, gy), _h(gx + 1, gy), tx)
	var h1 := lerpf(_h(gx, gy + 1), _h(gx + 1, gy + 1), tx)
	return lerpf(h0, h1, ty)

## Normalized elevation 0..1 (0 = deepest basin, 1 = highest peak). Water below WATER_T.
func norm_height(p: Vector2) -> float:
	return clampf(inverse_lerp(_hmin, _hmax, height_lookup(p)), 0.0, 1.0)

func _grid_gradient(p: Vector2) -> Vector2:
	var gx := clampi(int(floor((p.x - _origin.x) / STEP)), 1, _cols - 1)
	var gy := clampi(int(floor((p.y - _origin.y) / STEP)), 1, _rows - 1)
	var dhdx := (_h(gx + 1, gy) - _h(gx - 1, gy)) / (2.0 * STEP)
	var dhdy := (_h(gx, gy + 1) - _h(gx, gy - 1)) / (2.0 * STEP)
	return Vector2(dhdx, dhdy)

# --- grid ---------------------------------------------------------------------------

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

# --- the one-time bake ----------------------------------------------------------------

## Render the whole map into a small image: elevation palette × slope hillshading,
## sampled 4× finer than the physics grid so ridge lighting survives the upscale.
func _bake_image() -> void:
	var iw := _cols * BAKE_SUB + 1
	var ih := _rows * BAKE_SUB + 1
	var px := STEP / float(BAKE_SUB)
	# Sample the true (noise) heightfield once per pixel...
	var hs := PackedFloat32Array()
	hs.resize(iw * ih)
	for y in range(ih):
		for x in range(iw):
			hs[y * iw + x] = height_at(_origin + Vector2(x, y) * px)
	# ...then light it: sun from the north-west, slopes facing it brighten, slopes
	# facing away darken. Water is flattened toward glassy (no relief under the surface).
	var img := Image.create(iw, ih, false, Image.FORMAT_RGB8)
	var light := Vector2(-0.7071, -0.7071)
	for y in range(ih):
		for x in range(iw):
			var h := hs[y * iw + x]
			var xm := hs[y * iw + maxi(x - 1, 0)]
			var xp := hs[y * iw + mini(x + 1, iw - 1)]
			var ym := hs[maxi(y - 1, 0) * iw + x]
			var yp := hs[mini(y + 1, ih - 1) * iw + x]
			var slope := Vector2((xp - xm) / (2.0 * px), (yp - ym) / (2.0 * px))
			var shade := clampf(1.0 + (slope.x * light.x + slope.y * light.y) * SHADE_GAIN, 0.72, 1.22)
			var t := clampf(inverse_lerp(_hmin, _hmax, h), 0.0, 1.0)
			if t < Game.COAST_T:
				shade = lerpf(shade, 1.0, 0.7)
			var c := _elev_color(h)
			img.set_pixel(x, y, Color(c.r * shade, c.g * shade, c.b * shade))
	_tex = ImageTexture.create_from_image(img)

## Precompute every contour segment (marching squares over the physics grid) into one
## flat point array — the whole overlay is then a single draw_multiline call.
func _build_contours() -> void:
	_contours.clear()
	var steps := 7
	for s in range(1, steps):
		var level := lerpf(_hmin, _hmax, float(s) / float(steps))
		for gy in range(_rows):
			for gx in range(_cols):
				_contour_cell(gx, gy, level)

func _contour_cell(gx: int, gy: int, level: float) -> void:
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
		_contours.push_back(pts[0])
		_contours.push_back(pts[1])
	elif pts.size() == 4:
		_contours.push_back(pts[0])
		_contours.push_back(pts[1])
		_contours.push_back(pts[2])
		_contours.push_back(pts[3])

func _draw() -> void:
	# The entire ground: ONE textured quad. The rect is nudged half a texel so image
	# sample centers land exactly on the world positions they were sampled at.
	if _tex != null:
		var px := STEP / float(BAKE_SUB)
		var span := Vector2(_cols, _rows) * STEP
		draw_texture_rect(_tex, Rect2(_origin - Vector2(px, px) * 0.5, span + Vector2(px, px)), false)
	# All contour lines: ONE batched call (explicit width — WebGL hairlines are 1 physical
	# pixel and vanish on hiDPI phones).
	if _contours.size() >= 2:
		draw_multiline(_contours, Color(0.0, 0.0, 0.0, 0.26), 2.0)
	# Arena boundary.
	draw_rect(Rect2(-Game.ARENA_SIZE * 0.5, Game.ARENA_SIZE), Color(0.6, 0.55, 0.8, 0.9), false, 6.0)
