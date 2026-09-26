extends GameTest

var maze := Maze.new()

func after_each() -> void:
	maze.free()

const TICK := 1.0 / 60.0
const ARENA := Vector2(2304, 1296)

const Main = preload("res://games/amazing/amazing_world.gd")

func before_each() -> void:
	# An empty grid means "no walls", which isolates the movement rule from the maze.
	maze.grid = PackedByteArray()

func test_speed_is_pixels_per_second() -> void:
	var p := Vector2(500, 500)
	for i in 60:
		p = Main.simulate(maze, p, Vector2.RIGHT, TICK)
	almost(p.x - 500.0, Main.SPEED, 0.01, "one second of input travels SPEED pixels")
	almost(p.y, 500.0, 0.0001, "no drift on the other axis")

func test_delta_scales_the_step() -> void:
	# Start well inside the arena: from the origin the edge clamp would hide the effect.
	var start := Vector2(500, 500)
	var slow := Main.simulate(maze, start, Vector2.RIGHT, 0.01).x - start.x
	var fast := Main.simulate(maze, start, Vector2.RIGHT, 0.02).x - start.x
	almost(fast, slow * 2.0, 0.001, "twice the delta is twice the distance")

func test_diagonal_is_not_faster_than_straight() -> void:
	var start := Vector2(500, 500)
	var straight := Main.simulate(maze, start, Vector2.RIGHT, TICK).distance_to(start)
	var diagonal := Main.simulate(maze, start, Vector2(1, 1).normalized(), TICK).distance_to(start)
	almost(diagonal, straight, 0.001, "diagonal distance matches straight")

func test_an_oversized_input_vector_is_clamped() -> void:
	var honest := Main.simulate(maze, Vector2(500, 500), Vector2.RIGHT, TICK)
	var cheating := Main.simulate(maze, Vector2(500, 500), Vector2(9999, 0), TICK)
	vec_almost(cheating, honest, 0.0001, "a huge vector moves exactly as fast as a unit one")

func test_movement_is_a_pure_function() -> void:
	# Reconciliation replays this; if it depended on hidden state, replay would drift.
	var a := Main.simulate(maze, Vector2(123, 456), Vector2(0.3, -0.7), TICK)
	for i in 50:
		eq(Main.simulate(maze, Vector2(123, 456), Vector2(0.3, -0.7), TICK), a,
			"same inputs always give the same output")

func test_the_arena_edges_hold() -> void:
	var p := Vector2(100, 100)
	for i in 600:
		p = Main.simulate(maze, p, Vector2(-1, -1).normalized(), TICK)
	vec_almost(p, Main.HALF, 0.001, "cannot walk out through the top-left")
	p = Vector2(2000, 1000)
	for i in 600:
		p = Main.simulate(maze, p, Vector2(1, 1).normalized(), TICK)
	vec_almost(p, ARENA - Main.HALF, 0.001, "cannot walk out through the bottom-right")

func test_walls_block_movement() -> void:
	maze.generate(31337, ARENA)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	var start := maze.random_open_point(rng)
	var p := start
	for i in 2000:
		p = Main.simulate(maze, p, Vector2(1, 0.35).normalized(), TICK)
		not_ok(maze.is_blocked(p, Main.HALF.x), "never ends a step inside a wall")

func test_you_slide_along_a_wall_instead_of_stopping() -> void:
	maze.generate(31337, ARENA)
	# Find an open cell whose right neighbour is solid, then push right-and-down.
	for y in range(1, Maze.ROWS - 1):
		for x in range(1, Maze.COLS - 2):
			if maze.at(x, y) != 0 or maze.at(x + 1, y) != 1 or maze.at(x, y + 1) != 0:
				continue
			var p := (Vector2(x, y) + Vector2(0.5, 0.5)) * maze.cell
			var before := p
			for i in 20:
				p = Main.simulate(maze, p, Vector2(1, 1).normalized(), TICK)
			ok(p.y > before.y + 1.0, "blocked on x, still moving on y (slide)")
			not_ok(maze.is_blocked(p, Main.HALF.x), "and still out of the wall")
			return
	ok(false, "no suitable wall found to test sliding against")

func test_a_body_inside_a_wall_can_always_escape() -> void:
	# Regeneration can drop a wall on someone. If every direction were blocked
	# they would be stuck there forever, so being stuck must not be sticky.
	maze.generate(31337, ARENA)
	for y in range(1, Maze.ROWS - 1):
		for x in range(1, Maze.COLS - 1):
			if maze.at(x, y) != 1:
				continue
			var inside := (Vector2(x, y) + Vector2(0.5, 0.5)) * maze.cell
			ok(maze.is_blocked(inside, Main.HALF.x), "precondition: standing in a wall")
			var moved := Main.simulate(maze, inside, Vector2.RIGHT, TICK)
			ne(moved, inside, "a trapped body is allowed to move")
			return
	ok(false, "no wall cell found")
