extends GameTest

## Stage 8 behaviour: firing, what each projectile hits, and being frozen.

const TICK := 1.0 / 60.0

var main: Node2D

func before_each() -> void:
	main = make_main()
	main._apply_maze(20260926)
	main.in_session = true
	Maze.grid = PackedByteArray()      # open field: keep walls out of these tests

func after_each() -> void:
	drop_main(main)

func _add(id: int, at: Vector2) -> Node2D:
	main.server_add_player(id, at)
	return main.players[id]

# --- firing -------------------------------------------------------------------

func test_firing_puts_a_shot_in_the_air_facing_the_way_you_moved() -> void:
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.UP
	var sid: int = main.server_fire(7, Weapon.Kind.CAPTURE)
	ok(sid > 0, "the shot was fired")
	eq(main.shots.size(), 1, "one shot in flight")
	var shot: Projectile = main.shots[sid]
	eq(shot.owner_id, 7, "it belongs to the shooter")
	vec_almost(shot.velocity.normalized(), Vector2.UP, 0.001, "it flies where they faced")
	almost(shot.velocity.length(), Weapon.speed(Weapon.Kind.CAPTURE, main.SPEED), 0.01, "at weapon speed")
	ok(shot.position.distance_to(p.position) > main.HALF.x,
		"and starts clear of the shooter's own body")

func test_the_cooldown_stops_a_held_trigger() -> void:
	_add(7, Vector2(600, 600))
	ok(main.server_fire(7, Weapon.Kind.CAPTURE) > 0, "first shot goes")
	eq(main.server_fire(7, Weapon.Kind.CAPTURE), 0, "second is refused immediately")
	eq(main.shots.size(), 1, "still only one shot")
	# let the cooldown run out
	for i in int(Weapon.cooldown(Weapon.Kind.CAPTURE) / TICK) + 2:
		main._tick_timers(main.players[7], TICK)
	ok(main.server_fire(7, Weapon.Kind.CAPTURE) > 0, "and fires again once it is ready")

func test_an_unknown_weapon_cannot_be_fired() -> void:
	_add(7, Vector2(600, 600))
	eq(main.server_fire(7, 999), 0, "a bogus kind fires nothing")
	eq(main.shots.size(), 0, "nothing in the air")

func test_a_weapon_with_a_price_charges_for_itself() -> void:
	_add(7, Vector2(600, 600))
	# Cost is configurable; prove the mechanism rather than the current default.
	var spec: Dictionary = Weapon.SPECS[Weapon.Kind.FREEZE]
	var original: int = spec["cost"]
	spec["cost"] = 5
	main.scores[7] = 12
	ok(main.server_fire(7, Weapon.Kind.FREEZE) > 0, "affordable, so it fires")
	eq(main.scores[7], 7, "and the points were spent")
	main.players[7].cooldowns.clear()
	main.scores[7] = 2
	eq(main.server_fire(7, Weapon.Kind.FREEZE), 0, "too poor to fire")
	eq(main.scores[7], 2, "and nothing was taken")
	spec["cost"] = original

# --- the collector ------------------------------------------------------------

func test_the_collector_scores_a_gem_for_whoever_fired_it() -> void:
	main._clear_items()
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	var iid: int = main.server_add_item(Collectible.Kind.RUBY, Vector2(900, 600), 60.0)
	var sid: int = main.server_fire(7, Weapon.Kind.CAPTURE)
	for i in 120:
		main._advance_shots(TICK)
		if not main.items.has(iid):
			break
	not_ok(main.items.has(iid), "the gem was taken")
	eq(main.scores[7], Collectible.VALUE[Collectible.Kind.RUBY], "the shooter was paid for it")
	not_ok(main.shots.has(sid), "and the shot was spent doing it")

func test_the_collector_passes_straight_through_players() -> void:
	main._clear_items()
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	var victim := _add(8, Vector2(760, 600))
	var sid: int = main.server_fire(7, Weapon.Kind.CAPTURE)
	for i in 60:
		main._advance_shots(TICK)
	not_ok(victim.is_frozen(), "it does not freeze anyone")
	eq(victim.position, Vector2(760, 600), "or move them")

# --- the freeze ray -----------------------------------------------------------

func test_the_freeze_ray_freezes_whoever_it_hits() -> void:
	main._clear_items()
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	var victim := _add(8, Vector2(820, 600))
	var sid: int = main.server_fire(7, Weapon.Kind.FREEZE)
	for i in 120:
		main._advance_shots(TICK)
		if victim.is_frozen():
			break
	ok(victim.is_frozen(), "the victim is frozen")
	almost(victim.frozen_remaining, Weapon.freeze_seconds(Weapon.Kind.FREEZE), 0.01,
		"for the configured duration")
	not_ok(main.shots.has(sid), "and the shot is spent")
	not_ok(p.is_frozen(), "the shooter is unaffected")

func test_the_freeze_ray_ignores_gems() -> void:
	main._clear_items()
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	var iid: int = main.server_add_item(Collectible.Kind.GOLD, Vector2(800, 600), 60.0)
	main.server_fire(7, Weapon.Kind.FREEZE)
	for i in 60:
		main._advance_shots(TICK)
	ok(main.items.has(iid), "the gem is still there")
	eq(int(main.scores.get(7, 0)), 0, "and nobody scored")

func test_you_cannot_freeze_yourself() -> void:
	main._clear_items()
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	main.server_fire(7, Weapon.Kind.FREEZE)
	for i in 30:
		main._advance_shots(TICK)
	not_ok(p.is_frozen(), "your own shot passes through you")

# --- being frozen -------------------------------------------------------------

func test_a_frozen_player_cannot_move() -> void:
	var p := _add(7, Vector2(600, 600))
	p.frozen_remaining = 3.0
	for tick in range(1, 31):
		main.submit_input_for(7, tick, Vector2.RIGHT)
	for i in 30:
		main._server_simulate(TICK)
	vec_almost(p.position, Vector2(600, 600), 0.001, "input is accepted but goes nowhere")
	ok(p.is_frozen(), "still frozen after half a second")

func test_a_freeze_wears_off() -> void:
	var p := _add(7, Vector2(600, 600))
	p.frozen_remaining = 0.2
	for i in 20:
		main._tick_timers(p, TICK)
	not_ok(p.is_frozen(), "thawed once the clock runs out")
	eq(p.frozen_remaining, 0.0, "and the counter does not go negative")

func test_thawing_lets_you_move_again() -> void:
	var p := _add(7, Vector2(600, 600))
	p.frozen_remaining = 0.1
	var tick := 0
	for i in 60:
		tick += 1
		main.submit_input_for(7, tick, Vector2.RIGHT)
		main._server_simulate(TICK)
	ok(p.position.x > 600.0, "movement resumes after the freeze expires")

func test_a_frozen_player_can_still_shoot() -> void:
	# The spec freezes *movement*; being disarmed as well would be a different game.
	var p := _add(7, Vector2(600, 600))
	p.frozen_remaining = 3.0
	ok(main.server_fire(7, Weapon.Kind.CAPTURE) > 0, "frozen, but still armed")

# --- housekeeping -------------------------------------------------------------

func test_a_new_round_clears_the_air() -> void:
	var p := _add(7, Vector2(600, 600))
	p.frozen_remaining = 3.0
	main.server_fire(7, Weapon.Kind.CAPTURE)
	ok(main.shots.size() > 0, "a shot is in flight")
	main._new_maze(0)
	eq(main.shots.size(), 0, "the new round swept the shots away")
	not_ok(p.is_frozen(), "and thawed everybody")

func test_shots_expire_on_their_own() -> void:
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	var sid: int = main.server_fire(7, Weapon.Kind.CAPTURE)
	var ticks := int(Weapon.lifespan(Weapon.Kind.CAPTURE) / TICK) + 5
	for i in ticks:
		main._advance_shots(TICK)
	not_ok(main.shots.has(sid), "a shot that hits nothing still goes away")
