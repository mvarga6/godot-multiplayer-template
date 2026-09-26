extends GameTest

## Ashamed: a 2.5D floor you walk around on, drawn side-on.
##
## The state is deliberately three numbers that are easy to confuse:
## `ground.x` along the level, `ground.y` *depth* into the screen, and `height`
## off the floor. Screen position is derived from all three and stored nowhere.

const TICK := 1.0 / 60.0

var main: Node2D
var world: GameWorld

func before_each() -> void:
	main = make_main()
	main.in_session = true
	var id: int = main._next_lobby_id
	main._next_lobby_id += 1
	main.lobbies[id] = {"name": "side quest", "type": "ashamed", "members": []}
	main._create_world(id, "ashamed")
	main.my_lobby_id = id
	world = main.worlds[id]

func after_each() -> void:
	drop_main(main)

func _standing(x: float = 600.0, depth: float = 100.0) -> Dictionary:
	return {"ground": Vector2(x, depth), "height": 0.0, "v_height": 0.0, "grounded": true}

func _step(s: Dictionary, move: Vector2, jump: bool) -> Dictionary:
	return AshamedWorld.simulate(s["ground"], float(s["height"]), float(s["v_height"]),
		bool(s["grounded"]), move, jump, TICK)

# --- the projection -----------------------------------------------------------

func test_depth_is_drawn_higher_up_the_screen() -> void:
	# On the camera's own axis, so there is no sideways distance to foreshorten.
	var near := AshamedWorld.project(Vector2(500.0, 0.0), 0.0, 500.0)
	var far := AshamedWorld.project(Vector2(500.0, AshamedWorld.DEPTH_RANGE), 0.0, 500.0)
	ok(far.y < near.y, "further away sits higher on screen")
	eq(far.x, near.x, "the body the camera follows never slides sideways")

func test_horizontal_distance_foreshortens() -> void:
	# Two bodies at the same world x, one deep. The far one is drawn nearer the
	# camera's axis: that convergence is what makes the floor read as a plane.
	var eye := 1000.0
	var near := AshamedWorld.project(Vector2(1400.0, 0.0), 0.0, eye)
	var far := AshamedWorld.project(Vector2(1400.0, AshamedWorld.DEPTH_RANGE), 0.0, eye)
	ok(far.x < near.x, "the far body is pulled toward the vanishing point")
	ok(far.x > eye, "but not past it")
	almost((far.x - eye) / (near.x - eye), AshamedWorld.FAR_SCALE, 0.001,
		"by exactly the foreshortening at that depth")
	# And symmetrically on the other side.
	var left := AshamedWorld.project(Vector2(600.0, AshamedWorld.DEPTH_RANGE), 0.0, eye)
	almost(eye - left.x, far.x - eye, 0.001, "the same either side of the axis")

func test_depth_is_drawn_smaller() -> void:
	almost(AshamedWorld.depth_scale(0.0), 1.0, 0.001, "the near edge is full size")
	almost(AshamedWorld.depth_scale(AshamedWorld.DEPTH_RANGE), AshamedWorld.FAR_SCALE,
		0.001, "the far edge is FAR_SCALE")
	ok(AshamedWorld.depth_scale(AshamedWorld.DEPTH_RANGE * 0.5)
		< AshamedWorld.depth_scale(0.0), "and it shrinks with distance")

func test_nearer_bodies_draw_in_front() -> void:
	ok(AshamedWorld.depth_z(0.0) > AshamedWorld.depth_z(AshamedWorld.DEPTH_RANGE),
		"the near body has the higher z_index")

func test_height_lifts_without_changing_depth() -> void:
	var grounded_at := AshamedWorld.project(Vector2(500.0, 120.0), 0.0, 500.0)
	var lifted := AshamedWorld.project(Vector2(500.0, 120.0), 80.0, 500.0)
	ok(lifted.y < grounded_at.y, "jumping is a straight lift")
	eq(lifted.x, grounded_at.x, "and does not move you along")

func test_a_jump_is_drawn_smaller_further_away() -> void:
	# The point of the pseudo-dimension: height is a world length like any
	# other, so it foreshortens exactly as the body it belongs to does.
	var h := 100.0
	var near_lift := AshamedWorld.project(Vector2(0.0, 0.0), 0.0, 0.0).y \
		- AshamedWorld.project(Vector2(0.0, 0.0), h, 0.0).y
	var far_lift := AshamedWorld.project(Vector2(0.0, AshamedWorld.DEPTH_RANGE), 0.0, 0.0).y \
		- AshamedWorld.project(Vector2(0.0, AshamedWorld.DEPTH_RANGE), h, 0.0).y
	almost(near_lift, h, 0.001, "a jump at the near edge is drawn full size")
	ok(far_lift < near_lift, "the same jump made further away is drawn smaller")
	almost(far_lift / near_lift, AshamedWorld.depth_scale(AshamedWorld.DEPTH_RANGE), 0.001,
		"shrunk by the same factor as the body making it")

func test_the_jump_itself_does_not_change_with_depth() -> void:
	# Only the *drawing* foreshortens. Two bodies jumping at different depths
	# follow identical arcs in world units, or the game would play differently
	# depending on where you stood.
	var near := {"ground": Vector2(500.0, 0.0), "height": 0.0, "v_height": 0.0, "grounded": true}
	var far := {"ground": Vector2(500.0, AshamedWorld.DEPTH_RANGE),
		"height": 0.0, "v_height": 0.0, "grounded": true}
	for i in 40:
		near = AshamedWorld.simulate(near["ground"], near["height"], near["v_height"],
			near["grounded"], Vector2.ZERO, i == 0, 1.0 / 60.0)
		far = AshamedWorld.simulate(far["ground"], far["height"], far["v_height"],
			far["grounded"], Vector2.ZERO, i == 0, 1.0 / 60.0)
		almost(far["height"], near["height"], 0.0001, "same height at tick %d" % i)
		almost(far["v_height"], near["v_height"], 0.0001, "same velocity at tick %d" % i)
	ok(near["height"] > 0.0, "and it was an actual jump")

func test_depth_and_its_ratio_round_trip() -> void:
	for i in 9:
		var d := AshamedWorld.DEPTH_RANGE * float(i) / 8.0
		almost(AshamedWorld.depth_at_ratio(AshamedWorld.depth_ratio(d)), d, 0.01,
			"depth %.0f survives the round trip" % d)

func test_projection_is_out_of_range_safe() -> void:
	# Depth is clamped in `simulate`, but the projection must not misbehave if
	# something hands it a silly number.
	between(AshamedWorld.depth_scale(-500.0), AshamedWorld.FAR_SCALE, 1.0, "behind the floor")
	between(AshamedWorld.depth_scale(99999.0), AshamedWorld.FAR_SCALE, 1.0, "far beyond it")
	between(AshamedWorld.depth_at_ratio(-3.0), 0.0, AshamedWorld.DEPTH_RANGE, "ratio below zero")
	between(AshamedWorld.depth_at_ratio(9.0), 0.0, AshamedWorld.DEPTH_RANGE, "ratio above one")

# --- walking the floor plane --------------------------------------------------

func test_you_can_walk_into_the_screen() -> void:
	var s := _standing(600.0, 0.0)
	for i in 30:
		s = _step(s, Vector2(0.0, 1.0), false)
	ok(s["ground"].y > 0.0, "depth increased")
	eq(s["ground"].x, 600.0, "without drifting along the level")

func test_you_can_walk_back_out_again() -> void:
	var s := _standing(600.0, 200.0)
	for i in 30:
		s = _step(s, Vector2(0.0, -1.0), false)
	ok(s["ground"].y < 200.0, "depth decreased")

func test_the_floor_has_edges() -> void:
	var s := _standing(600.0, 10.0)
	for i in 600:
		s = _step(s, Vector2(0.0, -1.0), false)
	eq(s["ground"].y, 0.0, "cannot walk out of the front of the floor")
	for i in 600:
		s = _step(s, Vector2(0.0, 1.0), false)
	eq(s["ground"].y, AshamedWorld.DEPTH_RANGE, "nor through the back of it")

func test_running_speed_is_pixels_per_second() -> void:
	var s := _standing()
	for i in 60:
		s = _step(s, Vector2(1.0, 0.0), false)
	almost(s["ground"].x - 600.0, AshamedWorld.RUN_SPEED, 0.5, "one second covers RUN_SPEED")

func test_depth_is_slower_than_running() -> void:
	ok(AshamedWorld.DEPTH_SPEED < AshamedWorld.RUN_SPEED,
		"walking into the screen is slower, as the perspective implies")

func test_diagonal_is_not_faster() -> void:
	var straight := _step(_standing(600.0, 100.0), Vector2(1.0, 0.0), false)
	var diagonal := _step(_standing(600.0, 100.0), Vector2(1.0, 1.0), false)
	var dx: float = diagonal["ground"].x - 600.0
	var straight_dx: float = straight["ground"].x - 600.0
	ok(dx < straight_dx,
		"a diagonal trades speed along for speed inward")

func test_an_oversized_move_is_clamped() -> void:
	var honest := _step(_standing(), Vector2(1.0, 0.0), false)
	var cheating := _step(_standing(), Vector2(999.0, 0.0), false)
	almost(cheating["ground"].x, honest["ground"].x, 0.0001,
		"asking to run faster does nothing")

func test_you_cannot_run_off_the_end_of_the_level() -> void:
	var s := _standing(200.0)
	for i in 600:
		s = _step(s, Vector2(-1.0, 0.0), false)
	almost(s["ground"].x, AshamedWorld.HALF.x, 0.001, "stopped by the left edge")

# --- gravity and jumping ------------------------------------------------------

func test_jumping_leaves_the_floor_without_changing_depth() -> void:
	var s := _step(_standing(600.0, 150.0), Vector2.ZERO, true)
	ok(s["height"] > 0.0, "off the floor")
	ok(s["v_height"] > 0.0, "moving upward")
	not_ok(bool(s["grounded"]), "no longer standing")
	eq(s["ground"].y, 150.0, "gravity never touches depth")

func test_you_cannot_jump_in_mid_air() -> void:
	var airborne := _step(_standing(), Vector2.ZERO, true)
	var v_before := float(airborne["v_height"])
	var again := _step(airborne, Vector2.ZERO, true)
	ok(float(again["v_height"]) < v_before, "a second jump only falls further")

func test_a_jump_comes_back_down() -> void:
	var s := _step(_standing(), Vector2.ZERO, true)
	var peak := float(s["height"])
	for i in 400:
		s = _step(s, Vector2.ZERO, false)
		peak = maxf(peak, float(s["height"]))
	ok(peak > 40.0, "it got meaningfully off the floor")
	eq(s["height"], 0.0, "and landed again")
	ok(bool(s["grounded"]), "standing once more")

func test_a_long_fall_is_capped() -> void:
	var s := {"ground": Vector2(600.0, 100.0), "height": 100000.0,
		"v_height": 0.0, "grounded": false}
	for i in 600:
		s = _step(s, Vector2.ZERO, false)
		ok(float(s["v_height"]) >= -AshamedWorld.TERMINAL_FALL - 0.001,
			"never exceeds terminal velocity")

func test_you_can_steer_in_the_air() -> void:
	var s := _step(_standing(600.0, 100.0), Vector2.ZERO, true)
	for i in 10:
		s = _step(s, Vector2(1.0, 1.0), false)
	ok(s["ground"].x > 600.0, "air control along the level")
	ok(s["ground"].y > 100.0, "and into the screen")

func test_stepping_is_pure() -> void:
	var a := _step(_standing(), Vector2(0.5, -0.3), true)
	for i in 20:
		var b := _step(_standing(), Vector2(0.5, -0.3), true)
		eq(b["ground"], a["ground"], "same inputs, same floor position")
		eq(b["height"], a["height"], "same height")
		eq(b["v_height"], a["v_height"], "same vertical speed")

# --- server and client agree --------------------------------------------------

func test_the_server_walks_a_player_from_queued_input() -> void:
	world.server_admit(7)
	var p: Node2D = world.players[7]
	p.ground = Vector2(600.0, 100.0)
	p.height = 0.0
	p.grounded = true
	for tick in range(1, 31):
		world.submit_input_for(7, tick, Vector2(1.0, 1.0), false)
	for i in 30:
		world._server_simulate(TICK)
	ok(p.ground.x > 600.0, "moved along")
	ok(p.ground.y > 100.0, "and inward")
	eq(p.last_tick, 30, "acknowledging the newest input applied")

func test_a_dropped_packet_never_repeats_a_jump() -> void:
	world.server_admit(7)
	var p: Node2D = world.players[7]
	p.ground = Vector2(600.0, 100.0)
	p.height = 0.0
	p.grounded = true
	world.submit_input_for(7, 1, Vector2.ZERO, true)
	world._server_simulate(TICK)
	not_ok(p.grounded, "airborne")
	for i in 200:                         # starved from here on
		world._server_simulate(TICK)
	ok(p.grounded, "gravity brought them down rather than hovering")

func test_reconcile_restores_every_axis() -> void:
	world.server_admit(7)
	var p: Node2D = world.players[7]
	p.net_ground = Vector2(800.0, 180.0)
	p.net_height = 120.0
	p.net_v_height = -200.0
	p.net_grounded = false
	world.pending = []
	world._reconcile(p, 0)
	vec_almost(p.ground, Vector2(800.0, 180.0), 0.001, "floor position restored")
	almost(p.height, 120.0, 0.001, "height restored")
	almost(p.v_height, -200.0, 0.001, "and vertical speed with it")
	not_ok(p.grounded, "and whether they were standing")

func test_reconcile_replays_unacknowledged_input() -> void:
	world.server_admit(7)
	var p: Node2D = world.players[7]
	p.net_ground = Vector2(600.0, 100.0)
	p.net_height = 0.0
	p.net_v_height = 0.0
	p.net_grounded = true
	world.pending = [
		{"tick": 1, "move": Vector2(1.0, 0.0), "jump": false, "delta": TICK},
		{"tick": 2, "move": Vector2(1.0, 0.0), "jump": false, "delta": TICK},
	]
	world._reconcile(p, 1)
	eq(world.pending.size(), 1, "the acknowledged input was dropped")
	var expect := AshamedWorld.simulate(Vector2(600.0, 100.0), 0.0, 0.0, true,
		Vector2(1.0, 0.0), false, TICK)
	vec_almost(p.ground, expect["ground"], 0.001, "and the rest was replayed")
