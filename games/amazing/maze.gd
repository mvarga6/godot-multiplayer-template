class_name Maze
extends Node2D

## A grid maze that both the server and every client generate from the same seed.
##
## Instance state, not static: from stage 9 a server runs one of these per lobby,
## and two games sharing one global grid would walk through each other's walls.
##
## Only the seed goes over the wire. That matters more than it looks: `Main.simulate()`
## consults this grid while replaying buffered inputs during reconciliation, so if two
## peers disagreed about one wall, every prediction would be wrong forever. Replicating
## a seed instead of a layout makes disagreement impossible by construction.

const COLS := 39      # odd, so the border and the carved cells line up
const ROWS := 23
## How much of the arena is walkable floor, as a share of every cell in the grid.
##
## A perfect maze comes out around 0.48 and is mean for a chase: corridors one
## cell wide, dead ends everywhere, and nowhere to dodge a freeze ray. Raising
## this knocks out extra interior walls until the target is met, which widens
## corridors and opens rooms without ever disconnecting anything — you only
## remove walls, so everything reachable before is still reachable.
##
## The ceiling is (COLS-2)*(ROWS-2)/(COLS*ROWS) ~= 0.87, because the border is
## always solid. Values above that are clamped to it.
const OPEN_FRACTION := 0.62

var grid := PackedByteArray()   # COLS*ROWS, 1 = wall, 0 = open
var current_seed := 0

var cell := Vector2.ZERO        # set by generate(), from AmazingWorld.ARENA

# --- generation --------------------------------------------------------------

func generate(maze_seed: int, arena: Vector2) -> void:
	current_seed = maze_seed
	cell = Vector2(arena.x / float(COLS), arena.y / float(ROWS))
	grid = PackedByteArray()
	grid.resize(COLS * ROWS)
	grid.fill(1)

	var rng := RandomNumberGenerator.new()
	rng.seed = maze_seed

	# Randomised depth-first carve over the odd-indexed cells, knocking out the
	# wall between a cell and the neighbour it moves to. Guarantees every open
	# cell is reachable from every other, so the dot can never strand itself.
	var stack: Array[Vector2i] = [Vector2i(1, 1)]
	_put(1, 1, 0)
	while not stack.is_empty():
		var c: Vector2i = stack[-1]
		var options: Array[Vector2i] = []
		for d in [Vector2i(2, 0), Vector2i(-2, 0), Vector2i(0, 2), Vector2i(0, -2)]:
			var n: Vector2i = c + d
			if n.x >= 1 and n.x <= COLS - 2 and n.y >= 1 and n.y <= ROWS - 2 and at(n.x, n.y) == 1:
				options.append(n)
		if options.is_empty():
			stack.pop_back()
			continue
		var n: Vector2i = options[rng.randi() % options.size()]
		_put((c.x + n.x) / 2, (c.y + n.y) / 2, 0)
		_put(n.x, n.y, 0)
		stack.append(n)

	_open_up_to(OPEN_FRACTION, rng)

## Knock out interior walls, in a seeded random order, until `fraction` of the
## grid is floor. Deterministic: same seed, same maze, which the whole
## prediction and projectile story depends on.
func _open_up_to(fraction: float, rng: RandomNumberGenerator) -> void:
	var total := COLS * ROWS
	var interior := (COLS - 2) * (ROWS - 2)
	var want := mini(int(round(clampf(fraction, 0.0, 1.0) * float(total))), interior)

	var closed: Array[Vector2i] = []
	var open_now := 0
	for y in ROWS:
		for x in COLS:
			if at(x, y) == 0:
				open_now += 1
			elif x > 0 and y > 0 and x < COLS - 1 and y < ROWS - 1:
				closed.append(Vector2i(x, y))

	# Fisher-Yates on the seeded rng, so the choice is random but reproducible.
	for i in range(closed.size() - 1, 0, -1):
		var j := rng.randi() % (i + 1)
		var swap := closed[i]
		closed[i] = closed[j]
		closed[j] = swap

	# Only ever open a cell that already touches floor. Opening an isolated one
	# would create a pocket nothing can walk to -- and `random_open_point` would
	# cheerfully drop a gem in it. Repeat passes, because a cell that was not
	# eligible early becomes eligible once a neighbour opens.
	var progress := true
	while open_now < want and progress:
		progress = false
		for c in closed:
			if open_now >= want:
				break
			if at(c.x, c.y) == 0:
				continue
			if not _touches_open(c.x, c.y):
				continue
			_put(c.x, c.y, 0)
			open_now += 1
			progress = true

func _touches_open(x: int, y: int) -> bool:
	return _is_open(x + 1, y) or _is_open(x - 1, y) or _is_open(x, y + 1) or _is_open(x, y - 1)

## Share of the grid that is walkable. Handy for tuning OPEN_FRACTION.
func open_fraction() -> float:
	if grid.is_empty():
		return 0.0
	var open := 0
	for i in grid.size():
		if grid[i] == 0:
			open += 1
	return float(open) / float(grid.size())

func _put(x: int, y: int, v: int) -> void:
	grid[y * COLS + x] = v

func at(x: int, y: int) -> int:
	return grid[y * COLS + x]

# --- queries -----------------------------------------------------------------

## True when a `half`-radius square centred on `centre` overlaps any wall cell.
func is_blocked(centre: Vector2, half: float) -> bool:
	if grid.is_empty():
		return false                      # no maze yet: everything is open
	var x0 := int(floor((centre.x - half) / cell.x))
	var x1 := int(floor((centre.x + half - 0.001) / cell.x))
	var y0 := int(floor((centre.y - half) / cell.y))
	var y1 := int(floor((centre.y + half - 0.001) / cell.y))
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if x < 0 or y < 0 or x >= COLS or y >= ROWS:
				return true               # outside the grid is solid
			if at(x, y) == 1:
				return true
	return false

## Centre of a random open cell. Server-side only — the result is sent explicitly,
## so it does not need to match anything a client would compute.
func random_open_point(rng: RandomNumberGenerator) -> Vector2:
	if grid.is_empty():
		return Vector2.ZERO           # no maze generated yet
	var open: Array[Vector2i] = []
	for y in ROWS:
		for x in COLS:
			if at(x, y) == 0:
				open.append(Vector2i(x, y))
	if open.is_empty():
		return Vector2(cell.x * 1.5, cell.y * 1.5)
	var c: Vector2i = open[rng.randi() % open.size()]
	return (Vector2(c) + Vector2(0.5, 0.5)) * cell

# --- drawing -----------------------------------------------------------------

const FLOOR := Color(0.13, 0.13, 0.15, 1.0)    # cooled basalt you can walk on
const CRUST := Color(0.11, 0.04, 0.04, 1.0)    # the dark skin on top of the lava
const EMBER := Color(0.62, 0.13, 0.03, 1.0)    # what glows through the cracks
const MOLTEN := Color(1.0, 0.52, 0.10, 1.0)    # the exposed edge facing open ground

const SEAM := 3.0            # thickness of the molten rim, in pixels
const PULSE_HZ := 0.22       # how fast a cell breathes

func _ready() -> void:
	# The shimmer needs a redraw per frame, which is pointless without a screen.
	set_process(DisplayServer.get_name() != "headless")

func _process(_delta: float) -> void:
	queue_redraw()

## Stable per-cell value in 0..1. Folded with the seed so a new maze gets a new
## pattern rather than the same blotches in the same places.
func _hash01(x: int, y: int) -> float:
	var n: int = (x * 73856093) ^ (y * 19349663) ^ (current_seed * 83492791)
	return float(absi(n) % 1024) / 1024.0

## How much of this wall cell is exposed to walkable ground, 0..1.
func _exposure(x: int, y: int) -> float:
	var open := 0
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nx: int = x + d.x
		var ny: int = y + d.y
		if nx < 0 or ny < 0 or nx >= COLS or ny >= ROWS:
			continue
		if at(nx, ny) == 0:
			open += 1
	return float(open) / 4.0

func _draw() -> void:
	if grid.is_empty():
		return
	var t := float(Time.get_ticks_msec()) / 1000.0
	for y in ROWS:
		for x in COLS:
			var rect := Rect2(Vector2(x, y) * cell, cell)
			if at(x, y) == 0:
				draw_rect(rect, FLOOR)
				continue
			var h := _hash01(x, y)
			var exposure := _exposure(x, y)
			# Each cell breathes on its own phase, so the field ripples instead
			# of blinking in unison.
			var pulse := 0.5 + 0.5 * sin(t * TAU * PULSE_HZ + h * TAU)
			var heat := clampf(0.10 + 0.30 * h + 0.22 * pulse + 0.30 * exposure, 0.0, 1.0)
			draw_rect(rect, CRUST.lerp(EMBER, heat))
			_draw_seams(x, y, rect, pulse)

## A bright molten lip on each face that touches walkable ground — the edge is
## where lava actually reads as lava.
func _draw_seams(x: int, y: int, rect: Rect2, pulse: float) -> void:
	var glow := MOLTEN
	glow.a = 0.55 + 0.45 * pulse
	if _is_open(x, y - 1):
		draw_rect(Rect2(rect.position, Vector2(cell.x, SEAM)), glow)
	if _is_open(x, y + 1):
		draw_rect(Rect2(rect.position + Vector2(0, cell.y - SEAM), Vector2(cell.x, SEAM)), glow)
	if _is_open(x - 1, y):
		draw_rect(Rect2(rect.position, Vector2(SEAM, cell.y)), glow)
	if _is_open(x + 1, y):
		draw_rect(Rect2(rect.position + Vector2(cell.x - SEAM, 0), Vector2(SEAM, cell.y)), glow)

func _is_open(x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= COLS or y >= ROWS:
		return false
	return at(x, y) == 0
