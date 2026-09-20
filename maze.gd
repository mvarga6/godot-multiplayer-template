class_name Maze
extends Node2D

## A grid maze that both the server and every client generate from the same seed.
##
## Only the seed goes over the wire. That matters more than it looks: `Main.simulate()`
## consults this grid while replaying buffered inputs during reconciliation, so if two
## peers disagreed about one wall, every prediction would be wrong forever. Replicating
## a seed instead of a layout makes disagreement impossible by construction.

const COLS := 19      # odd, so the border and the carved cells line up
const ROWS := 11
const EXTRA_OPENINGS := 6    # a perfect maze is mean for a chase; punch some loops in it

static var grid := PackedByteArray()   # COLS*ROWS, 1 = wall, 0 = open
static var current_seed := 0

static var cell := Vector2.ZERO        # set by generate(), from Main.ARENA

# --- generation --------------------------------------------------------------

static func generate(maze_seed: int, arena: Vector2) -> void:
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

	for _i in EXTRA_OPENINGS:
		var x := 1 + rng.randi() % (COLS - 2)
		var y := 1 + rng.randi() % (ROWS - 2)
		_put(x, y, 0)

static func _put(x: int, y: int, v: int) -> void:
	grid[y * COLS + x] = v

static func at(x: int, y: int) -> int:
	return grid[y * COLS + x]

# --- queries -----------------------------------------------------------------

## True when a `half`-radius square centred on `centre` overlaps any wall cell.
static func is_blocked(centre: Vector2, half: float) -> bool:
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
static func random_open_point(rng: RandomNumberGenerator) -> Vector2:
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

func _draw() -> void:
	if grid.is_empty():
		return
	# Clearly darker than the default background, which is about #4d4d4d.
	var wall := Color(0.13, 0.14, 0.19, 1.0)
	for y in ROWS:
		for x in COLS:
			if at(x, y) == 1:
				draw_rect(Rect2(Vector2(x, y) * cell, cell), wall)
