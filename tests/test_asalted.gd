extends GameTest

## A Salted: a 3D arena shooter.
##
## Everything here is a pure function over a plain Array of barriers -- no
## PhysicsBody, no scene tree -- because the client replays movement during
## reconciliation and the physics server is not something you can replay.

const TICK := 1.0 / 60.0
const SEED := 20260926

var main: Node2D
var world: GameWorld

func before_each() -> void:
	main = make_main()
	main.in_session = true
	var id: int = main._next_lobby_id
	main._next_lobby_id += 1
	main.lobbies[id] = {"name": "the pit", "type": "asalted", "members": []}
	main._create_world(id, "asalted")
	main.my_lobby_id = id
	world = main.worlds[id]
	# The World picks a random map on creation. Pin it, or a test that puts a
	# body at a fixed spot is really a test of today's dice.
	world.arena_seed = SEED
	world.arena.generate(SEED)

func after_each() -> void:
	drop_main(main)

## One box, 2x2 at the origin, 1 metre tall. Small enough to jump onto.
func _one_box(top: float = 1.0) -> Array:
	return [{"kind": Arena.Kind.BOX, "pos": Vector3.ZERO, "half": Vector2(1.0, 1.0),
		"radius": sqrt(2.0), "top": top}]

func _standing(at: Vector3 = Vector3(6.0, 0.0, 6.0)) -> Dictionary:
	return {"pos": at, "vel_y": 0.0, "grounded": true}

func _step(bars: Array, s: Dictionary, move: Vector2, yaw: float, jump: bool) -> Dictionary:
	return AsaltedWorld.simulate(bars, s["pos"], float(s["vel_y"]), bool(s["grounded"]),
		move, yaw, jump, TICK)

# --- the map ------------------------------------------------------------------

func test_the_same_seed_builds_the_same_map() -> void:
	var a := Arena.build_barriers(SEED)
	var b := Arena.build_barriers(SEED)
	eq(a.size(), b.size(), "same number of barriers")
	ok(a.size() > 0, "and there are some")
	for i in a.size():
		eq(a[i]["pos"], b[i]["pos"], "barrier %d in the same place" % i)
		eq(a[i]["kind"], b[i]["kind"], "barrier %d the same shape" % i)
		almost(float(a[i]["top"]), float(b[i]["top"]), 0.0001, "barrier %d same height" % i)

func test_a_different_seed_builds_a_different_map() -> void:
	var a := Arena.build_barriers(SEED)
	var b := Arena.build_barriers(SEED + 1)
	var same := true
	for i in mini(a.size(), b.size()):
		if a[i]["pos"] != b[i]["pos"]:
			same = false
			break
	ok(not same, "the layout actually depends on the seed")

func test_barriers_keep_out_of_the_outer_lane() -> void:
	# There is always somewhere to run round the edge.
	for s in [1, 2, 99, 12345]:
		for b in Arena.build_barriers(s):
			var p: Vector3 = b["pos"]
			var reach := Arena.HALF - Arena.MID_MARGIN
			between(p.x, -reach, reach, "barrier x inside the middle")
			between(p.z, -reach, reach, "barrier z inside the middle")

func test_barriers_leave_room_to_walk_between() -> void:
	for s in [7, 8, 2024]:
		var bars := Arena.build_barriers(s)
		for i in bars.size():
			for j in range(i + 1, bars.size()):
				var a: Vector3 = bars[i]["pos"]
				var c: Vector3 = bars[j]["pos"]
				var gap: float = Vector2(a.x - c.x, a.z - c.z).length() \
					- float(bars[i]["radius"]) - float(bars[j]["radius"])
				ok(gap >= Arena.BARRIER_GAP - 0.001,
					"seed %d: barriers %d and %d are %.2f apart" % [s, i, j, gap])

func test_spawns_are_clear_and_inside_the_room() -> void:
	var bars := Arena.build_barriers(SEED)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for _i in 25:
		var p := Arena.spawn_point(bars, rng)
		almost(Arena.support_top(bars, p.x, p.z, AsaltedWorld.PLAYER_RADIUS), 0.0, 0.001,
			"nobody spawns inside a pillar")
		between(p.x, -Arena.HALF, Arena.HALF, "spawn x is in the room")
		between(p.z, -Arena.HALF, Arena.HALF, "spawn z is in the room")

# --- collision ----------------------------------------------------------------

func test_you_cannot_walk_through_a_box() -> void:
	var bars := _one_box(3.0)
	var s := _standing(Vector3(0.0, 0.0, 6.0))
	for _i in 120:                       # two seconds of walking straight at it
		s = _step(bars, s, Vector2(0.0, 1.0), 0.0, false)
	var p: Vector3 = s["pos"]
	ok(p.z > 1.0 + AsaltedWorld.PLAYER_RADIUS - 0.01,
		"stopped at the face, not inside it (z=%.2f)" % p.z)

func test_you_cannot_leave_the_room() -> void:
	var s := _standing(Vector3(0.0, 0.0, 0.0))
	for _i in 300:
		s = _step([], s, Vector2(1.0, 0.0), 0.0, false)   # strafe right forever
	var p: Vector3 = s["pos"]
	ok(p.x <= Arena.HALF - Arena.WALL_THICKNESS - AsaltedWorld.PLAYER_RADIUS + 0.001,
		"the wall holds (x=%.2f)" % p.x)

func test_you_slide_along_a_face_instead_of_sticking() -> void:
	# Walking diagonally into a box should still carry you sideways.
	var bars := _one_box(3.0)
	var s := _standing(Vector3(0.0, 0.0, 4.0))
	var before: Vector3 = s["pos"]
	for _i in 60:
		s = _step(bars, s, Vector2(1.0, 1.0), 0.0, false)
	var after: Vector3 = s["pos"]
	ok(after.x - before.x > 1.0, "you kept moving along the face (dx=%.2f)" % (after.x - before.x))

func test_standing_on_a_box_does_not_shove_you_off() -> void:
	var bars := _one_box(1.0)
	var s := {"pos": Vector3(0.0, 1.0, 0.0), "vel_y": 0.0, "grounded": true}
	for _i in 60:
		s = _step(bars, s, Vector2.ZERO, 0.0, false)
	var p: Vector3 = s["pos"]
	almost(p.x, 0.0, 0.001, "still on top, not pushed sideways")
	almost(p.y, 1.0, 0.001, "and still at box height")
	ok(bool(s["grounded"]), "and counted as standing")

func test_walking_into_cover_never_lifts_you() -> void:
	# The bug this test exists for: "support" used to mean "the tallest thing
	# whose footprint you overlap", so walking into the *side* of a box snapped
	# you onto its roof -- and once on top, nothing blocked you. Every piece of
	# cover was a lift. Deliberately awkward numbers, taken from a generated
	# map: the round ones above sat on the safe side of the boundary and hid it.
	var bars := [{"kind": Arena.Kind.BOX, "pos": Vector3(-3.77, 0.0, -5.15),
		"half": Vector2(1.88, 1.49), "radius": 2.40, "top": 2.34}]
	var s := {"pos": Vector3(-3.77, 0.0, 1.85), "vel_y": 0.0, "grounded": true}
	for _i in 180:
		s = _step(bars, s, Vector2(0.0, 1.0), 0.0, false)
		almost(float(s["pos"].y), 0.0, 0.0001, "the feet never leave the floor")
	ok(float(s["pos"].z) > -5.15 + 1.49, "and it stopped on the near side (z=%.2f)"
		% float(s["pos"].z))

func test_walking_into_a_pillar_never_lifts_you_either() -> void:
	var bars := [{"kind": Arena.Kind.PILLAR, "pos": Vector3(0.37, 0.0, -4.21),
		"half": Vector2(1.63, 1.63), "radius": 1.63, "top": 5.02}]
	var s := {"pos": Vector3(0.37, 0.0, 2.9), "vel_y": 0.0, "grounded": true}
	for _i in 180:
		s = _step(bars, s, Vector2(0.0, 1.0), 0.0, false)
		almost(float(s["pos"].y), 0.0, 0.0001, "the feet never leave the floor")
	ok(float(s["pos"].z) > -4.21 + 1.63, "and it stopped outside the pillar")

func test_you_only_land_on_what_you_were_above() -> void:
	var bars := _one_box(2.0)
	almost(Arena.support_under(bars, 0.0, 0.0, 0.45, 0.0), 0.0, 0.001,
		"a box above your feet is not something you are standing on")
	almost(Arena.support_under(bars, 0.0, 0.0, 0.45, 2.0), 2.0, 0.001,
		"the same box is, once you are on top of it")
	almost(Arena.support_under(bars, 9.0, 9.0, 0.45, 5.0), 0.0, 0.001,
		"and open floor is always the floor")

func test_support_is_the_top_of_what_you_are_over() -> void:
	var bars := _one_box(2.5)
	almost(Arena.support_top(bars, 0.0, 0.0, 0.45), 2.5, 0.001, "over the box")
	almost(Arena.support_top(bars, 9.0, 9.0, 0.45), 0.0, 0.001, "over open floor")

func test_walking_off_a_box_drops_you() -> void:
	var bars := _one_box(1.0)
	var s := {"pos": Vector3(0.0, 1.0, 0.0), "vel_y": 0.0, "grounded": true}
	for _i in 90:
		s = _step(bars, s, Vector2(1.0, 0.0), 0.0, false)
	almost(float(s["pos"].y), 0.0, 0.01, "back on the floor")
	ok(bool(s["grounded"]), "and standing on it")

# --- movement ------------------------------------------------------------------

func test_yaw_decides_which_way_forward_is() -> void:
	# Forward at yaw 0 is -Z, the direction Godot calls forward.
	var s := _step([], _standing(Vector3.ZERO), Vector2(0.0, 1.0), 0.0, false)
	ok(float(s["pos"].z) < 0.0, "yaw 0 walks toward -Z")
	almost(float(s["pos"].x), 0.0, 0.0001, "and not sideways")
	# A quarter turn puts forward on -X.
	s = _step([], _standing(Vector3.ZERO), Vector2(0.0, 1.0), PI * 0.5, false)
	ok(float(s["pos"].x) < 0.0, "a quarter turn walks toward -X")
	almost(float(s["pos"].z), 0.0, 0.0001, "and not forward any more")

func test_a_diagonal_is_not_faster() -> void:
	var straight := _step([], _standing(Vector3.ZERO), Vector2(0.0, 1.0), 0.0, false)
	var diagonal := _step([], _standing(Vector3.ZERO), Vector2(1.0, 1.0), 0.0, false)
	var a: Vector3 = straight["pos"]
	var b: Vector3 = diagonal["pos"]
	almost(Vector2(b.x, b.z).length(), Vector2(a.x, a.z).length(), 0.0001,
		"the same distance either way")

func test_running_speed_is_metres_per_second() -> void:
	var s := _standing(Vector3.ZERO)
	for _i in 60:
		s = _step([], s, Vector2(0.0, 1.0), 0.0, false)
	almost(absf(float(s["pos"].z)), AsaltedWorld.RUN_SPEED, 0.2,
		"a second of running covers RUN_SPEED metres")

func test_you_cannot_jump_in_mid_air() -> void:
	var s := _step([], _standing(Vector3.ZERO), Vector2.ZERO, 0.0, true)
	ok(not bool(s["grounded"]), "the first jump leaves the floor")
	var rising := float(s["vel_y"])
	s = _step([], s, Vector2.ZERO, 0.0, true)          # hold the key
	ok(float(s["vel_y"]) < rising, "holding jump does not push you up again")

func test_a_jump_comes_back_down() -> void:
	var s := _step([], _standing(Vector3.ZERO), Vector2.ZERO, 0.0, true)
	var peak := 0.0
	for _i in 180:
		s = _step([], s, Vector2.ZERO, 0.0, false)
		peak = maxf(peak, float(s["pos"].y))
	ok(peak > 0.5, "it was a real jump (%.2f m)" % peak)
	almost(float(s["pos"].y), 0.0, 0.001, "and it ended on the floor")
	ok(bool(s["grounded"]), "standing again")

func test_a_low_box_can_be_jumped_onto() -> void:
	var bars := _one_box(1.0)
	var s := _standing(Vector3(0.0, 0.0, 3.2))
	s = _step(bars, s, Vector2(0.0, 1.0), 0.0, true)   # jump, carrying forward
	for _i in 20:
		s = _step(bars, s, Vector2(0.0, 1.0), 0.0, false)
	for _i in 60:                                      # let go and settle
		s = _step(bars, s, Vector2.ZERO, 0.0, false)
	almost(float(s["pos"].y), 1.0, 0.01, "ended up on top of it")
	ok(bool(s["grounded"]), "and standing on it")

func test_running_off_the_far_side_of_a_box_drops_you() -> void:
	# The other half of the same rule: nothing holds you up once you are past
	# the edge, so a box is a perch rather than a platform you stick to.
	var bars := _one_box(1.0)
	var s := _standing(Vector3(0.0, 0.0, 3.2))
	s = _step(bars, s, Vector2(0.0, 1.0), 0.0, true)
	for _i in 60:                                      # keep running the whole way
		s = _step(bars, s, Vector2(0.0, 1.0), 0.0, false)
	almost(float(s["pos"].y), 0.0, 0.01, "back on the floor the other side")
	ok(float(s["pos"].z) < -1.0, "and past the box (z=%.2f)" % float(s["pos"].z))

func test_a_tall_box_cannot_be_jumped_onto() -> void:
	var bars := _one_box(4.5)
	var s := _standing(Vector3(0.0, 0.0, 3.2))
	s = _step(bars, s, Vector2(0.0, 1.0), 0.0, true)
	for _i in 60:
		s = _step(bars, s, Vector2(0.0, 1.0), 0.0, false)
	almost(float(s["pos"].y), 0.0, 0.01, "still on the floor: it is cover, not a platform")

func test_terminal_velocity_is_capped() -> void:
	var s := {"pos": Vector3(0.0, 400.0, 0.0), "vel_y": 0.0, "grounded": false}
	for _i in 600:
		s = _step([], s, Vector2.ZERO, 0.0, false)
	ok(float(s["vel_y"]) >= -AsaltedWorld.TERMINAL_FALL - 0.001, "a long fall stays bounded")

func test_stepping_is_pure() -> void:
	# Reconciliation replays this, so it must read nothing but its arguments
	# and change nothing it was handed.
	var bars := _one_box(2.0)
	var before := bars.duplicate(true)
	var pos := Vector3(3.0, 0.0, 3.0)
	AsaltedWorld.simulate(bars, pos, 0.0, true, Vector2(1.0, 1.0), 0.7, true, TICK)
	eq(pos, Vector3(3.0, 0.0, 3.0), "the position handed in is untouched")
	eq(bars.size(), before.size(), "and the map is untouched")
	for i in bars.size():
		eq(bars[i]["pos"], before[i]["pos"], "barrier %d unmoved" % i)

# --- shooting -------------------------------------------------------------------

func test_looking_forward_is_minus_z() -> void:
	var d := AsaltedWorld.look_dir(0.0, 0.0)
	almost(d.z, -1.0, 0.0001, "yaw 0 looks down -Z")
	almost(d.x, 0.0, 0.0001, "and not sideways")
	almost(d.length(), 1.0, 0.0001, "and it is a unit vector")

func test_looking_up_raises_the_ray() -> void:
	var d := AsaltedWorld.look_dir(0.0, 0.6)
	ok(d.y > 0.0, "positive pitch aims up")
	almost(d.length(), 1.0, 0.0001, "still a unit vector")

func test_a_ray_finds_a_box_in_front_and_ignores_one_behind() -> void:
	var from := Vector3(0.0, 1.0, 10.0)
	var hit := Arena.ray_box(from, Vector3(0.0, 0.0, -1.0),
		Vector3(-1.0, 0.0, -1.0), Vector3(1.0, 3.0, 1.0))
	almost(hit, 9.0, 0.001, "the near face is 9 metres away")
	var behind := Arena.ray_box(from, Vector3(0.0, 0.0, 1.0),
		Vector3(-1.0, 0.0, -1.0), Vector3(1.0, 3.0, 1.0))
	ok(is_inf(behind), "a box behind you is not a hit")
	var wide := Arena.ray_box(from, Vector3(1.0, 0.0, 0.0),
		Vector3(-1.0, 0.0, -1.0), Vector3(1.0, 3.0, 1.0))
	ok(is_inf(wide), "and neither is one you are not aiming at")

func test_a_ray_finds_a_pillar() -> void:
	var from := Vector3(0.0, 1.0, 10.0)
	var hit := Arena.ray_cylinder(from, Vector3(0.0, 0.0, -1.0), Vector2.ZERO, 2.0, 0.0, 4.0)
	almost(hit, 8.0, 0.001, "the curved face is 8 metres away")
	var over := Arena.ray_cylinder(from, Vector3(0.0, 0.0, -1.0), Vector2.ZERO, 2.0, 5.0, 9.0)
	ok(is_inf(over), "a pillar whose span is above the ray is a miss")

func test_cover_blocks_a_shot() -> void:
	# The whole point of having barriers: a body behind one cannot be hit.
	var bars := [{"kind": Arena.Kind.BOX, "pos": Vector3.ZERO, "half": Vector2(2.0, 2.0),
		"radius": 2.83, "top": 4.0}]
	var from := AsaltedWorld.eye_of(Vector3(0.0, 0.0, 10.0))
	var dir := AsaltedWorld.look_dir(0.0, 0.0)
	var target := Vector3(0.0, 0.0, -10.0)
	var to_wall := Arena.ray_distance(bars, from, dir)
	var to_body := AsaltedWorld.hit_distance(target, from, dir)
	ok(to_wall < to_body, "the box is hit first, so the shot never reaches them")
	# Step aside and the same shot connects.
	var clear_from := AsaltedWorld.eye_of(Vector3(8.0, 0.0, 10.0))
	var clear_wall := Arena.ray_distance(bars, clear_from, dir)
	var clear_body := AsaltedWorld.hit_distance(Vector3(8.0, 0.0, -10.0), clear_from, dir)
	ok(clear_body < clear_wall, "with a clear lane the body is hit first")

func test_a_shot_that_misses_everything_still_stops_at_the_room() -> void:
	var from := Vector3(0.0, 1.6, 0.0)
	var d := Arena.ray_distance([], from, Vector3(0.0, 0.0, -1.0))
	ok(not is_inf(d), "it hits the far wall")
	between(d, 1.0, Arena.SIZE, "somewhere inside the room")

# --- server and client agree -------------------------------------------------------

func test_the_server_walks_a_player_from_queued_input() -> void:
	var p := _fake_player(7, Vector3(18.0, 0.0, 6.0))
	world.submit_input_for(7, 1, Vector2(0.0, 1.0), 0.0, 0.0, false, false)
	world._server_simulate(TICK)
	ok(float(p.pos.z) < 6.0, "the queued input moved them")
	eq(p.last_tick, 1, "and the tick was acknowledged")

func test_stale_input_is_ignored() -> void:
	var p := _fake_player(7, Vector3(18.0, 0.0, 0.0))
	world.submit_input_for(7, 5, Vector2(0.0, 1.0), 0.0, 0.0, false, false)
	world._server_simulate(TICK)
	var after: Vector3 = p.pos
	world.submit_input_for(7, 3, Vector2(0.0, 1.0), 0.0, 0.0, false, false)
	eq(p.input_queue.size(), 0, "an old tick is dropped rather than queued")
	world._server_simulate(TICK)
	ok(float(p.pos.z) <= float(after.z), "and it never rewinds them")

func test_a_flooding_client_cannot_grow_the_queue() -> void:
	var p := _fake_player(7, Vector3(18.0, 0.0, 0.0))
	for i in range(1, 200):
		world.submit_input_for(7, i, Vector2(0.0, 1.0), 0.0, 0.0, false, false)
	ok(p.input_queue.size() <= AsaltedWorld.INPUT_QUEUE_CAP,
		"the queue is capped at %d" % AsaltedWorld.INPUT_QUEUE_CAP)

func test_reconcile_restores_every_axis() -> void:
	var p := _fake_player(7, Vector3(18.0, 0.0, 3.0))
	p.pos = Vector3(99.0, 9.0, 99.0)         # a wrong prediction
	p.vel_y = 12.0
	p.grounded = false
	p.net_pos = Vector3(18.0, 0.0, 3.0)
	p.net_vel_y = 0.0
	p.net_grounded = true
	world.pending.clear()
	world._reconcile(p, 0)
	eq(p.pos, Vector3(18.0, 0.0, 3.0), "position snaps back")
	almost(p.vel_y, 0.0, 0.0001, "velocity too")
	ok(p.grounded, "and so does standing on something")

func test_reconcile_replays_unacknowledged_input() -> void:
	var p := _fake_player(7, Vector3(18.0, 0.0, 6.0))
	p.net_pos = Vector3(18.0, 0.0, 6.0)
	p.net_vel_y = 0.0
	p.net_grounded = true
	world.pending = [
		{"tick": 1, "move": Vector2(0.0, 1.0), "yaw": 0.0, "jump": false, "delta": TICK},
		{"tick": 2, "move": Vector2(0.0, 1.0), "yaw": 0.0, "jump": false, "delta": TICK},
	]
	world._reconcile(p, 0)
	ok(float(p.pos.z) < 6.0, "the unacknowledged inputs were replayed")
	eq(world.pending.size(), 2, "and are still pending until the server sees them")

func test_only_pushing_off_the_floor_counts_as_a_jump() -> void:
	# The sound hangs off this, so it has to mean exactly what the impulse in
	# `simulate` means -- no noise for holding the key in mid-air, and none for
	# walking off a ledge, which also leaves you airborne.
	ok(AsaltedWorld.is_jump_start(true, true), "pressing jump while standing")
	ok(not AsaltedWorld.is_jump_start(false, true), "holding it in mid-air does not")
	ok(not AsaltedWorld.is_jump_start(true, false), "and standing still is not a jump")

func test_walking_off_a_ledge_is_not_a_jump() -> void:
	var bars := _one_box(1.0)
	var s := {"pos": Vector3(0.0, 1.0, 0.0), "vel_y": 0.0, "grounded": true}
	var jumps := 0
	for _i in 60:
		if AsaltedWorld.is_jump_start(bool(s["grounded"]), false):
			jumps += 1
		s = _step(bars, s, Vector2(1.0, 0.0), 0.0, false)
	eq(jumps, 0, "you fall off it silently")
	almost(float(s["pos"].y), 0.0, 0.01, "and you did leave the box")

func test_holding_jump_does_not_retrigger_in_mid_air() -> void:
	var s := _standing(Vector3(18.0, 0.0, 0.0))
	var jumps := 0
	for _i in 20:                       # held down, still airborne throughout
		if AsaltedWorld.is_jump_start(bool(s["grounded"]), true):
			jumps += 1
		s = _step([], s, Vector2.ZERO, 0.0, true)
	eq(jumps, 1, "one push off the floor, one sound")
	ok(not bool(s["grounded"]), "and still in the air at the end of it")

func test_landing_with_the_key_held_jumps_again() -> void:
	# Not a bug to be silenced: holding jump hops you along, and each hop is a
	# real push off the floor, so each one gets its own sound.
	var s := _standing(Vector3(18.0, 0.0, 0.0))
	var jumps := 0
	for _i in 130:                      # a couple of full arcs
		if AsaltedWorld.is_jump_start(bool(s["grounded"]), true):
			jumps += 1
		s = _step([], s, Vector2.ZERO, 0.0, true)
	ok(jumps >= 2, "each landing starts a new hop (got %d)" % jumps)

# --- the sound bank -------------------------------------------------------------

func test_every_action_has_clips_to_choose_from() -> void:
	for action in ["shoot", "die", "jump"]:
		var clips := AsaltedWorld.clips_for(action)
		ok(clips.size() >= 2, "%s has %d clips to vary between" % [action, clips.size()])
		for c in clips:
			ok(c is AudioStream, "every %s entry is playable" % action)

func test_clips_belong_to_the_action_that_claims_them() -> void:
	for action in ["shoot", "die", "jump"]:
		for c in AsaltedWorld.clips_for(action):
			var file: String = c.resource_path.get_file()
			ok(file.begins_with(action), "%s is a %s clip" % [file, action])

func test_picking_reaches_every_clip() -> void:
	# Enough draws that missing one would mean the pick is not random at all.
	var seen := {}
	for _i in 80:
		seen[AsaltedWorld.pick_sfx("shoot").resource_path] = true
	eq(seen.size(), AsaltedWorld.clips_for("shoot").size(),
		"every shoot clip comes up")

func test_an_action_with_no_clips_is_silent_rather_than_broken() -> void:
	ok(AsaltedWorld.pick_sfx("nosuchaction") == null, "no clips means no sound")
	eq(AsaltedWorld.clips_for("nosuchaction").size(), 0, "and an empty list, not an error")

# --- dying, and coming back ----------------------------------------------------

func test_a_frag_does_not_put_you_straight_back_in_play() -> void:
	var shooter := _fake_player(1, Vector3(18.0, 0.0, 9.0))
	var victim := _fake_player(2, Vector3(18.0, 0.0, -9.0))
	var fell_at: Vector3 = victim.pos
	world._server_fire(1)
	eq(shooter.score, 1, "the shooter scores")
	almost(victim.dead_timer, AsaltedWorld.RESPAWN_DELAY, 0.001, "the victim is waiting")
	eq(victim.pos, fell_at, "and is still where they fell, not already elsewhere")

func test_a_dead_player_does_not_move() -> void:
	var p := _fake_player(2, Vector3(18.0, 0.0, -9.0))
	p.dead_timer = 5.0
	var fell_at: Vector3 = p.pos
	world.submit_input_for(2, 1, Vector2(0.0, 1.0), 0.0, 0.0, false, false)
	for _i in 10:
		world._server_simulate(TICK)
	eq(p.pos, fell_at, "a body waiting to respawn stays put")
	eq(p.input_queue.size(), 0, "and what it sent while dead is discarded")

func test_a_dead_player_cannot_fire() -> void:
	var shooter := _fake_player(1, Vector3(18.0, 0.0, 9.0))
	var victim := _fake_player(2, Vector3(18.0, 0.0, -9.0))
	shooter.dead_timer = 2.0
	world.submit_input_for(1, 1, Vector2.ZERO, 0.0, 0.0, false, true)
	for _i in 5:
		world._server_simulate(TICK)
	eq(shooter.score, 0, "the trigger does nothing while you are waiting")
	almost(victim.dead_timer, 0.0, 0.001, "and nobody was hit by it")

func test_you_cannot_shoot_someone_waiting_to_respawn() -> void:
	var shooter := _fake_player(1, Vector3(18.0, 0.0, 9.0))
	var victim := _fake_player(2, Vector3(18.0, 0.0, -9.0))
	victim.dead_timer = 2.0
	world._server_fire(1)
	eq(shooter.score, 0, "no second score for shooting a body that is already down")

func test_you_come_back_somewhere_else_when_the_timer_runs_out() -> void:
	var p := _fake_player(2, Vector3(18.0, 0.0, -9.0))
	p.move = Vector2(0.0, 1.0)         # they were running when they died
	p.dead_timer = 0.2
	var fell_at: Vector3 = p.pos
	for _i in 20:
		world._server_simulate(TICK)
	almost(p.dead_timer, 0.0, 0.001, "the timer ran out")
	ok(p.pos != fell_at, "and they came back somewhere else")
	ok(bool(p.grounded), "standing on something")
	eq(p.move, Vector2.ZERO, "and not still sprinting in the direction they died in")
	almost(Arena.support_top(world.arena.barriers, p.pos.x, p.pos.z,
		AsaltedWorld.PLAYER_RADIUS), 0.0, 0.001, "nor stuck inside a pillar")

func test_the_respawn_delay_is_actually_a_delay() -> void:
	var p := _fake_player(2, Vector3(18.0, 0.0, -9.0))
	p.dead_timer = AsaltedWorld.RESPAWN_DELAY
	var fell_at: Vector3 = p.pos
	for _i in 30:                      # half a second in
		world._server_simulate(TICK)
	ok(p.dead_timer > 0.0, "still waiting half a second later")
	eq(p.pos, fell_at, "and still on the floor where they fell")

## A player node the World will accept, without going through the spawner.
func _fake_player(id: int, at: Vector3) -> Node3D:
	var p: Node3D = (load("res://games/asalted/player.tscn") as PackedScene).instantiate()
	p.setup(id)
	p.pos = at
	p.net_pos = at
	p.target_pos = at
	p.grounded = true
	world.get_node("Space/Players").add_child(p)
	world.players[id] = p
	return p
