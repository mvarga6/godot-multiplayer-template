extends GameTest

## Ashamed: gravity, jumping and running. The state here is a position *and* a
## velocity, which is the thing that makes it different from A Mazing.

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

func _ground(x: float = 600.0) -> Dictionary:
	return {"pos": Vector2(x, AshamedWorld.GROUND_Y), "vel": Vector2.ZERO, "grounded": true}

func _step(s: Dictionary, move: float, jump: bool) -> Dictionary:
	return AshamedWorld.simulate(s["pos"], s["vel"], bool(s["grounded"]), move, jump, TICK)

# --- gravity ------------------------------------------------------------------

func test_a_body_in_the_air_accelerates_downward() -> void:
	var s := {"pos": Vector2(600, 100), "vel": Vector2.ZERO, "grounded": false}
	var first := _step(s, 0.0, false)
	almost(first["vel"].y, AshamedWorld.GRAVITY * TICK, 0.001, "one tick of gravity")
	var second := _step(first, 0.0, false)
	ok(second["vel"].y > first["vel"].y, "and it keeps accelerating")

func test_falling_stops_at_the_ground() -> void:
	var s := {"pos": Vector2(600, 100), "vel": Vector2.ZERO, "grounded": false}
	for i in 300:
		s = _step(s, 0.0, false)
	eq(s["pos"].y, AshamedWorld.GROUND_Y, "comes to rest on the floor")
	eq(s["vel"].y, 0.0, "with no downward speed left")
	ok(bool(s["grounded"]), "and is standing on it")

func test_a_long_fall_is_capped() -> void:
	var s := {"pos": Vector2(600, -100000), "vel": Vector2.ZERO, "grounded": false}
	for i in 600:
		s = _step(s, 0.0, false)
		ok(s["vel"].y <= AshamedWorld.TERMINAL_FALL + 0.001, "never exceeds terminal velocity")

# --- jumping ------------------------------------------------------------------

func test_jumping_leaves_the_ground() -> void:
	var s := _step(_ground(), 0.0, true)
	ok(s["vel"].y < 0.0, "the kick is upward")
	ok(s["pos"].y < AshamedWorld.GROUND_Y, "and you are off the floor")
	not_ok(bool(s["grounded"]), "no longer standing")

func test_you_cannot_jump_in_mid_air() -> void:
	var airborne := _step(_ground(), 0.0, true)
	var v_before: Vector2 = airborne["vel"]
	var again := _step(airborne, 0.0, true)
	ok(again["vel"].y > v_before.y, "a second jump does nothing but fall further")

func test_a_jump_comes_back_down() -> void:
	var s := _step(_ground(), 0.0, true)
	var peak: float = s["pos"].y
	for i in 400:
		s = _step(s, 0.0, false)
		peak = minf(peak, s["pos"].y)
	ok(peak < AshamedWorld.GROUND_Y - 40.0, "it got meaningfully off the ground")
	eq(s["pos"].y, AshamedWorld.GROUND_Y, "and landed again")

func test_you_can_jump_again_once_you_land() -> void:
	var s := _step(_ground(), 0.0, true)
	for i in 400:
		s = _step(s, 0.0, false)
	ok(bool(s["grounded"]), "back on the floor")
	var again := _step(s, 0.0, true)
	ok(again["vel"].y < 0.0, "and able to jump")

# --- running ------------------------------------------------------------------

func test_running_speed_is_pixels_per_second() -> void:
	var s := _ground()
	for i in 60:
		s = _step(s, 1.0, false)
	almost(s["pos"].x - 600.0, AshamedWorld.RUN_SPEED, 0.5, "one second covers RUN_SPEED")

func test_running_works_both_ways() -> void:
	var right := _step(_ground(), 1.0, false)
	var left := _step(_ground(), -1.0, false)
	ok(right["pos"].x > 600.0, "right is right")
	ok(left["pos"].x < 600.0, "left is left")

func test_an_oversized_move_is_clamped() -> void:
	var honest := _step(_ground(), 1.0, false)
	var cheating := _step(_ground(), 999.0, false)
	almost(cheating["pos"].x, honest["pos"].x, 0.0001, "asking to run faster does nothing")

func test_you_cannot_run_off_the_end_of_the_level() -> void:
	var s := _ground(200.0)
	for i in 600:
		s = _step(s, -1.0, false)
	almost(s["pos"].x, AshamedWorld.HALF.x, 0.001, "stopped by the left edge")
	s = _ground(AshamedWorld.ARENA.x - 200.0)
	for i in 600:
		s = _step(s, 1.0, false)
	almost(s["pos"].x, AshamedWorld.ARENA.x - AshamedWorld.HALF.x, 0.001, "and the right")

func test_stepping_is_pure() -> void:
	var a := _step(_ground(), 0.5, true)
	for i in 20:
		var b := _step(_ground(), 0.5, true)
		eq(b["pos"], a["pos"], "same inputs, same position")
		eq(b["vel"], a["vel"], "and the same velocity")

# --- the server and the client agree ------------------------------------------

func test_the_server_moves_a_player_from_queued_input() -> void:
	world.server_admit(7)
	var p: Node2D = world.players[7]
	p.position = Vector2(600, AshamedWorld.GROUND_Y)
	p.grounded = true
	for tick in range(1, 31):
		world.submit_input_for(7, tick, 1.0, false)
	for i in 30:
		world._server_simulate(TICK)
	ok(p.position.x > 600.0, "consuming queued input runs them right")
	eq(p.last_tick, 30, "and acknowledges the newest input applied")

func test_a_dropped_packet_never_repeats_a_jump() -> void:
	# The server keeps running you the same way when nothing arrives, but a
	# repeated jump edge would be a free second jump every starved tick.
	world.server_admit(7)
	var p: Node2D = world.players[7]
	p.position = Vector2(600, AshamedWorld.GROUND_Y)
	p.grounded = true
	world.submit_input_for(7, 1, 0.0, true)
	world._server_simulate(TICK)          # consumes the jump
	not_ok(p.grounded, "airborne")
	for i in 200:                         # starved from here on
		world._server_simulate(TICK)
	ok(p.grounded, "gravity brought them back down rather than hovering")

func test_reconcile_restores_velocity_as_well_as_position() -> void:
	# The A Mazing version only replayed a position. Mid-jump that would put you
	# in the right place moving the wrong way.
	world.server_admit(7)
	var p: Node2D = world.players[7]
	p.net_position = Vector2(800, AshamedWorld.GROUND_Y - 120.0)
	p.net_velocity = Vector2(0.0, -200.0)
	p.net_grounded = false
	world.pending = []
	world._reconcile(p, 0)
	vec_almost(p.position, Vector2(800, AshamedWorld.GROUND_Y - 120.0), 0.001,
		"snapped to the authority's position")
	vec_almost(p.velocity, Vector2(0.0, -200.0), 0.001, "and its velocity")
	not_ok(p.grounded, "and its grounded state")

func test_reconcile_replays_unacknowledged_input() -> void:
	world.server_admit(7)
	var p: Node2D = world.players[7]
	p.net_position = Vector2(600, AshamedWorld.GROUND_Y)
	p.net_velocity = Vector2.ZERO
	p.net_grounded = true
	world.pending = [
		{"tick": 1, "move": 1.0, "jump": false, "delta": TICK},
		{"tick": 2, "move": 1.0, "jump": false, "delta": TICK},
	]
	world._reconcile(p, 1)
	eq(world.pending.size(), 1, "the acknowledged input was dropped")
	var expect := AshamedWorld.simulate(Vector2(600, AshamedWorld.GROUND_Y),
		Vector2.ZERO, true, 1.0, false, TICK)
	vec_almost(p.position, expect["pos"], 0.001, "and the rest was replayed")
