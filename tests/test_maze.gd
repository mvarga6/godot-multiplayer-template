extends GameTest

var maze := Maze.new()

func after_each() -> void:
	maze.free()

const ARENA := Vector2(2304, 1296)

func _open_cells() -> Array:
	var out := []
	for y in Maze.ROWS:
		for x in Maze.COLS:
			if maze.at(x, y) == 0:
				out.append(Vector2i(x, y))
	return out

func test_same_seed_gives_an_identical_grid() -> void:
	maze.generate(4242, ARENA)
	var a := maze.grid.duplicate()
	maze.generate(999, ARENA)
	maze.generate(4242, ARENA)
	eq(maze.grid, a, "regenerating from the same seed reproduces the grid")

func test_different_seeds_give_different_grids() -> void:
	maze.generate(1, ARENA)
	var a := maze.grid.duplicate()
	maze.generate(2, ARENA)
	ne(maze.grid, a, "a different seed produces a different maze")

func test_grid_has_the_configured_shape() -> void:
	maze.generate(7, ARENA)
	eq(maze.grid.size(), Maze.COLS * Maze.ROWS, "grid cell count")
	almost(maze.cell.x, ARENA.x / float(Maze.COLS), 0.001, "cell width")
	almost(maze.cell.y, ARENA.y / float(Maze.ROWS), 0.001, "cell height")

func test_the_border_is_always_solid() -> void:
	for seed_value in [0, 5, 77, 1234, 999999]:
		maze.generate(seed_value, ARENA)
		for x in Maze.COLS:
			eq(maze.at(x, 0), 1, "top border solid at x=%d seed=%d" % [x, seed_value])
			eq(maze.at(x, Maze.ROWS - 1), 1, "bottom border solid at x=%d" % x)
		for y in Maze.ROWS:
			eq(maze.at(0, y), 1, "left border solid at y=%d" % y)
			eq(maze.at(Maze.COLS - 1, y), 1, "right border solid at y=%d" % y)

func test_every_open_cell_is_reachable() -> void:
	# The carve is a spanning tree plus extra openings, so the whole floor must
	# be one connected region. If it were not, the dot could strand itself.
	for seed_value in [3, 31, 314, 3141, 31415]:
		maze.generate(seed_value, ARENA)
		var open := _open_cells()
		ok(open.size() > 0, "seed %d carved something" % seed_value)
		var seen := {}
		var stack := [open[0]]
		seen[open[0]] = true
		while not stack.is_empty():
			var c: Vector2i = stack.pop_back()
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = c + d
				if n.x < 0 or n.y < 0 or n.x >= Maze.COLS or n.y >= Maze.ROWS:
					continue
				if maze.at(n.x, n.y) != 0 or seen.has(n):
					continue
				seen[n] = true
				stack.append(n)
		eq(seen.size(), open.size(), "seed %d: all %d open cells reachable" % [seed_value, open.size()])

func test_the_maze_hits_its_open_fraction() -> void:
	# OPEN_FRACTION is the tuning knob; generation must actually honour it.
	for seed_value in [1, 17, 404, 90210, 31415]:
		maze.generate(seed_value, ARENA)
		almost(maze.open_fraction(), Maze.OPEN_FRACTION, 0.002,
			"seed %d lands on the target openness" % seed_value)

func test_the_open_fraction_is_reachable() -> void:
	# The border is always solid, so the target can never exceed the interior.
	var ceiling := float((Maze.COLS - 2) * (Maze.ROWS - 2)) / float(Maze.COLS * Maze.ROWS)
	ok(Maze.OPEN_FRACTION <= ceiling,
		"OPEN_FRACTION (%.2f) is within the %.2f ceiling" % [Maze.OPEN_FRACTION, ceiling])
	ok(Maze.OPEN_FRACTION > 0.0, "and leaves somewhere to walk")

func test_opening_up_never_disconnects_anything() -> void:
	# Widening only ever removes walls, so connectivity cannot regress -- but it
	# is the property the dot depends on, so prove it at the tuned value.
	maze.generate(2718, ARENA)
	var open := _open_cells()
	var seen := {}
	var stack := [open[0]]
	seen[open[0]] = true
	while not stack.is_empty():
		var c: Vector2i = stack.pop_back()
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if n.x < 0 or n.y < 0 or n.x >= Maze.COLS or n.y >= Maze.ROWS:
				continue
			if maze.at(n.x, n.y) != 0 or seen.has(n):
				continue
			seen[n] = true
			stack.append(n)
	eq(seen.size(), open.size(), "every one of the %d open cells is reachable" % open.size())

func test_is_blocked_reads_the_grid() -> void:
	maze.generate(11, ARENA)
	for c in _open_cells():
		var centre := (Vector2(c) + Vector2(0.5, 0.5)) * maze.cell
		not_ok(maze.is_blocked(centre, 1.0), "open cell %s is walkable" % c)
		break
	for y in Maze.ROWS:
		for x in Maze.COLS:
			if maze.at(x, y) == 1:
				var centre := (Vector2(x, y) + Vector2(0.5, 0.5)) * maze.cell
				ok(maze.is_blocked(centre, 1.0), "wall cell (%d,%d) blocks" % [x, y])
				return

func test_outside_the_grid_is_solid() -> void:
	maze.generate(11, ARENA)
	ok(maze.is_blocked(Vector2(-50, 100), 16.0), "left of the arena is solid")
	ok(maze.is_blocked(Vector2(100, -50), 16.0), "above the arena is solid")
	ok(maze.is_blocked(ARENA + Vector2(50, 50), 16.0), "past the far corner is solid")

func test_an_ungenerated_maze_blocks_nothing() -> void:
	maze.grid = PackedByteArray()
	not_ok(maze.is_blocked(Vector2(500, 500), 16.0), "empty grid is all open")
	eq(maze.random_open_point(RandomNumberGenerator.new()), Vector2.ZERO,
		"empty grid yields no spawn point")

func test_random_open_point_lands_on_floor() -> void:
	maze.generate(2024, ARENA)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	for i in 60:
		var p := maze.random_open_point(rng)
		not_ok(maze.is_blocked(p, 16.0), "spawn point %s clears a 32px body" % p)
