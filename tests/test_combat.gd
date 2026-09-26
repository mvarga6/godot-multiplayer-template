extends GameTest

## Stage 8 behaviour: firing, what each projectile hits, and being frozen.

const TICK := 1.0 / 60.0

var world: World
var main: Node2D

func before_each() -> void:
	world = make_world()
	main = world.game
	world._apply_maze(20260926)
	main.in_session = true
	world.maze.grid = PackedByteArray()      # open field: keep walls out of these tests

func after_each() -> void:
	drop_world(world)

func _add(id: int, at: Vector2) -> Node2D:
	world.server_add_player(id, at)
	return world.players[id]

# --- firing -------------------------------------------------------------------

func test_firing_puts_a_shot_in_the_air_facing_the_way_you_moved() -> void:
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.UP
	var sid: int = world.server_fire(7, Weapon.Kind.CAPTURE)
	ok(sid > 0, "the shot was fired")
	eq(world.shots.size(), 1, "one shot in flight")
	var shot: Projectile = world.shots[sid]
	eq(shot.owner_id, 7, "it belongs to the shooter")
	vec_almost(shot.velocity.normalized(), Vector2.UP, 0.001, "it flies where they faced")
	almost(shot.velocity.length(), Weapon.speed(Weapon.Kind.CAPTURE, world.SPEED), 0.01, "at weapon speed")
	ok(shot.position.distance_to(p.position) > world.HALF.x,
		"and starts clear of the shooter's own body")

func test_the_cooldown_stops_a_held_trigger() -> void:
	_add(7, Vector2(600, 600))
	ok(world.server_fire(7, Weapon.Kind.CAPTURE) > 0, "first shot goes")
	eq(world.server_fire(7, Weapon.Kind.CAPTURE), 0, "second is refused immediately")
	eq(world.shots.size(), 1, "still only one shot")
	# let the cooldown run out
	for i in int(Weapon.cooldown(Weapon.Kind.CAPTURE) / TICK) + 2:
		world._tick_timers(world.players[7], TICK)
	ok(world.server_fire(7, Weapon.Kind.CAPTURE) > 0, "and fires again once it is ready")

func test_an_unknown_weapon_cannot_be_fired() -> void:
	_add(7, Vector2(600, 600))
	eq(world.server_fire(7, 999), 0, "a bogus kind fires nothing")
	eq(world.shots.size(), 0, "nothing in the air")

func test_a_weapon_with_a_price_charges_for_itself() -> void:
	_add(7, Vector2(600, 600))
	# Cost is configurable; prove the mechanism rather than the current default.
	var spec: Dictionary = Weapon.SPECS[Weapon.Kind.CAPTURE]
	var original: int = spec["cost"]
	spec["cost"] = 5
	world.scores[7] = 12
	ok(world.server_fire(7, Weapon.Kind.CAPTURE) > 0, "affordable, so it fires")
	eq(world.scores[7], 7, "and the points were spent")
	world.players[7].cooldowns.clear()
	world.scores[7] = 2
	eq(world.server_fire(7, Weapon.Kind.CAPTURE), 0, "too poor to fire")
	eq(world.scores[7], 2, "and nothing was taken")
	spec["cost"] = original

# --- the collector ------------------------------------------------------------

func test_the_collector_scores_a_gem_for_whoever_fired_it() -> void:
	world._clear_items()
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	var iid: int = world.server_add_item(Collectible.Kind.RUBY, Vector2(900, 600), 60.0)
	var sid: int = world.server_fire(7, Weapon.Kind.CAPTURE)
	for i in 120:
		world._advance_shots(TICK)
		if not world.items.has(iid):
			break
	not_ok(world.items.has(iid), "the gem was taken")
	eq(world.scores[7], Collectible.VALUE[Collectible.Kind.RUBY], "the shooter was paid for it")
	not_ok(world.shots.has(sid), "and the shot was spent doing it")

func test_the_collector_passes_straight_through_players() -> void:
	world._clear_items()
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	var victim := _add(8, Vector2(760, 600))
	var sid: int = world.server_fire(7, Weapon.Kind.CAPTURE)
	for i in 60:
		world._advance_shots(TICK)
	not_ok(victim.is_frozen(), "it does not freeze anyone")
	eq(victim.position, Vector2(760, 600), "or move them")

# --- the freeze ray -----------------------------------------------------------

func test_the_freeze_ray_freezes_whoever_it_hits() -> void:
	world._clear_items()
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	var victim := _add(8, Vector2(820, 600))
	world.scores[7] = 5                 # the freeze ray is not free any more
	var sid: int = world.server_fire(7, Weapon.Kind.FREEZE)
	for i in 120:
		world._advance_shots(TICK)
		if victim.is_frozen():
			break
	ok(victim.is_frozen(), "the victim is frozen")
	almost(victim.frozen_remaining, Weapon.freeze_seconds(Weapon.Kind.FREEZE), 0.01,
		"for the configured duration")
	not_ok(world.shots.has(sid), "and the shot is spent")
	not_ok(p.is_frozen(), "the shooter is unaffected")

func test_the_freeze_ray_ignores_gems() -> void:
	world._clear_items()
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	var iid: int = world.server_add_item(Collectible.Kind.GOLD, Vector2(800, 600), 60.0)
	world.scores[7] = 5
	world.server_fire(7, Weapon.Kind.FREEZE)
	var after_firing: int = world.scores[7]   # already charged for the shot
	for i in 60:
		world._advance_shots(TICK)
	ok(world.items.has(iid), "the gem is still there")
	eq(world.scores[7], after_firing, "and flying past it scored nothing")

func test_you_cannot_freeze_yourself() -> void:
	world._clear_items()
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	world.scores[7] = 5
	world.server_fire(7, Weapon.Kind.FREEZE)
	for i in 30:
		world._advance_shots(TICK)
	not_ok(p.is_frozen(), "your own shot passes through you")

func test_the_freeze_ray_costs_a_point_to_fire() -> void:
	_add(7, Vector2(600, 600))
	world.scores[7] = 0
	eq(world.server_fire(7, Weapon.Kind.FREEZE), 0, "broke, so nothing happens")
	world.scores[7] = 2
	ok(world.server_fire(7, Weapon.Kind.FREEZE) > 0, "one point buys a shot")
	eq(world.scores[7], 1, "and it was taken off the shooter")

func test_a_frozen_player_cannot_be_kept_frozen() -> void:
	world._clear_items()
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	var victim := _add(8, Vector2(820, 600))
	world.scores[7] = 20
	# freeze them, let a second tick away, then hit them again
	world.server_fire(7, Weapon.Kind.FREEZE)
	for i in 120:
		world._advance_shots(TICK)
		if victim.is_frozen():
			break
	ok(victim.is_frozen(), "frozen by the first shot")
	for i in 60:
		world._tick_timers(victim, TICK)
	var left_before: float = victim.frozen_remaining
	ok(left_before < Weapon.freeze_seconds(Weapon.Kind.FREEZE), "the clock is running down")
	p.cooldowns.clear()
	world.server_fire(7, Weapon.Kind.FREEZE)
	for i in 120:
		world._advance_shots(TICK)
		if world.shots.is_empty():
			break
	almost(victim.frozen_remaining, left_before, 0.001,
		"a second hit does not top the timer back up")

func test_a_shot_that_cannot_freeze_carries_on_to_the_next_target() -> void:
	world._clear_items()
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	var already := _add(8, Vector2(760, 600))
	var behind := _add(9, Vector2(900, 600))
	already.frozen_remaining = 3.0
	world.scores[7] = 20
	world.server_fire(7, Weapon.Kind.FREEZE)
	for i in 180:
		world._advance_shots(TICK)
		if behind.is_frozen():
			break
	ok(behind.is_frozen(), "it passed through the frozen player and froze the one behind")

# --- the pickpocket -----------------------------------------------------------

func test_the_pickpocket_moves_a_point_across() -> void:
	world._clear_items()
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	var victim := _add(8, Vector2(820, 600))
	world.scores[7] = 3
	world.scores[8] = 6
	world.server_fire(7, Weapon.Kind.STEAL)
	for i in 120:
		world._advance_shots(TICK)
		if world.shots.is_empty():
			break
	eq(world.scores[8], 5, "one point left the victim")
	eq(world.scores[7], 4, "and arrived with the thief")

func test_there_is_nothing_to_steal_from_a_player_on_zero() -> void:
	world._clear_items()
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	var victim := _add(8, Vector2(820, 600))
	world.scores[7] = 3
	world.scores[8] = 0
	world.server_fire(7, Weapon.Kind.STEAL)
	for i in 120:
		world._advance_shots(TICK)
	eq(world.scores[8], 0, "the victim cannot go negative")
	eq(world.scores[7], 3, "and the thief gains nothing")

func test_stealing_the_last_point_can_win_the_round() -> void:
	world._clear_items()
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	var victim := _add(8, Vector2(820, 600))
	world.scores[7] = world.WIN_SCORE - 1
	world.scores[8] = 4
	world.server_fire(7, Weapon.Kind.STEAL)
	for i in 120:
		world._advance_shots(TICK)
		if world.rounds_won.get(7, 0) > 0:
			break
	eq(world.rounds_won[7], 1, "the stolen point took the round")

func test_the_pickpocket_ignores_gems_and_its_owner() -> void:
	world._clear_items()
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	world.scores[7] = 4
	var iid: int = world.server_add_item(Collectible.Kind.GOLD, Vector2(800, 600), 60.0)
	world.server_fire(7, Weapon.Kind.STEAL)
	for i in 120:
		world._advance_shots(TICK)
	ok(world.items.has(iid), "the gem is untouched")
	eq(world.scores[7], 4, "and you cannot pick your own pocket")

# --- being frozen -------------------------------------------------------------

func test_a_frozen_player_cannot_move() -> void:
	var p := _add(7, Vector2(600, 600))
	p.frozen_remaining = 3.0
	for tick in range(1, 31):
		world.submit_input_for(7, tick, Vector2.RIGHT)
	for i in 30:
		world._server_simulate(TICK)
	vec_almost(p.position, Vector2(600, 600), 0.001, "input is accepted but goes nowhere")
	ok(p.is_frozen(), "still frozen after half a second")

func test_a_freeze_wears_off() -> void:
	var p := _add(7, Vector2(600, 600))
	p.frozen_remaining = 0.2
	for i in 20:
		world._tick_timers(p, TICK)
	not_ok(p.is_frozen(), "thawed once the clock runs out")
	eq(p.frozen_remaining, 0.0, "and the counter does not go negative")

func test_thawing_lets_you_move_again() -> void:
	var p := _add(7, Vector2(600, 600))
	p.frozen_remaining = 0.1
	var tick := 0
	for i in 60:
		tick += 1
		world.submit_input_for(7, tick, Vector2.RIGHT)
		world._server_simulate(TICK)
	ok(p.position.x > 600.0, "movement resumes after the freeze expires")

func test_a_frozen_player_can_still_shoot() -> void:
	# The spec freezes *movement*; being disarmed as well would be a different game.
	var p := _add(7, Vector2(600, 600))
	p.frozen_remaining = 3.0
	ok(world.server_fire(7, Weapon.Kind.CAPTURE) > 0, "frozen, but still armed")

# --- housekeeping -------------------------------------------------------------

func test_a_new_round_clears_the_air() -> void:
	var p := _add(7, Vector2(600, 600))
	p.frozen_remaining = 3.0
	world.server_fire(7, Weapon.Kind.CAPTURE)
	ok(world.shots.size() > 0, "a shot is in flight")
	world._new_maze(0)
	eq(world.shots.size(), 0, "the new round swept the shots away")
	not_ok(p.is_frozen(), "and thawed everybody")

func test_shots_expire_on_their_own() -> void:
	var p := _add(7, Vector2(600, 600))
	p.facing = Vector2.RIGHT
	var sid: int = world.server_fire(7, Weapon.Kind.CAPTURE)
	var ticks := int(Weapon.lifespan(Weapon.Kind.CAPTURE) / TICK) + 5
	for i in ticks:
		world._advance_shots(TICK)
	not_ok(world.shots.has(sid), "a shot that hits nothing still goes away")
