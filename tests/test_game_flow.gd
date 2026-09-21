extends GameTest

## Behaviour of the running game, driven through the server-side seam
## (`server_add_player` and friends) rather than through whatever RPC or
## MultiplayerSpawner happens to sit underneath it.

const ARENA := Vector2(2304, 1296)
const TICK := 1.0 / 60.0

var main: Node2D

func before_each() -> void:
	main = make_main()
	main._apply_maze(20260920)
	main.in_session = true

func after_each() -> void:
	drop_main(main)

func _add(id: int, at: Vector2 = Vector2.ZERO) -> Node2D:
	main.server_add_player(id, at if at != Vector2.ZERO else main._open_spawn())
	return main.players[id]

# --- the player registry ------------------------------------------------------

func test_adding_a_player_registers_it_everywhere() -> void:
	var p := _add(7)
	eq(main.players.size(), 1, "one player")
	eq(main.scores[7], 0, "starts on zero points")
	eq(main.rounds_won[7], 0, "starts on zero rounds")
	eq(p.name, "7", "node is named after the peer id, so RPC paths agree")
	eq(main.players_root.get_child_count(), 1, "and it is in the scene")

func test_adding_the_same_player_twice_is_harmless() -> void:
	_add(7)
	main.scores[7] = 12
	main.server_add_player(7, Vector2(100, 100))
	eq(main.players.size(), 1, "still one player")
	eq(main.scores[7], 12, "an idempotent spawn does not reset the score")

func test_removing_a_player_clears_all_of_its_state() -> void:
	_add(7)
	_add(8)
	main.apply_identity(7, 3, "Mike")
	main.server_remove_player(7)
	eq(main.players.size(), 1, "one left")
	not_ok(main.players.has(7), "gone from the registry")
	not_ok(main.scores.has(7), "score gone")
	not_ok(main.rounds_won.has(7), "standings gone")
	not_ok(main.names.has(7), "name gone")
	not_ok(main.icons.has(7), "icon gone")

func test_removing_an_unknown_player_is_a_no_op() -> void:
	_add(7)
	main.server_remove_player(999)
	eq(main.players.size(), 1, "nothing happened")

# --- identity -----------------------------------------------------------------

func test_identity_reaches_the_player_node() -> void:
	var p := _add(7)
	main.apply_identity(7, 4, "Mike")
	eq(main.icons[7], 4, "icon index stored")
	eq(main.names[7], "Mike", "name stored")
	eq(p.icon_label.text, main.ICONS[4], "glyph on the node")
	eq(p.name_label.text, "Mike", "name tag on the node")

func test_an_out_of_range_icon_is_refused() -> void:
	_add(7)
	main.apply_identity(7, 4, "Mike")
	main.apply_identity(7, 9999, "Mike")
	eq(main.icons[7], 4, "a bogus index does not overwrite a good one")

func test_request_identity_sanitises_before_broadcasting() -> void:
	_add(1)
	main.request_identity(99999, "  Bad\u0007Name  ")
	eq(main.names[1], "BadName", "control characters stripped, trimmed")
	eq(main.icons[1], 0, "an out-of-range index is coerced, not rejected outright")

# --- collectibles -------------------------------------------------------------

func test_the_item_pool_stays_within_bounds() -> void:
	for i in 40:
		main._top_up_items()
		between(float(main.items.size()), float(main.MIN_ITEMS), float(main.MAX_ITEMS), "pool size")

func test_topping_up_cannot_spin_forever_without_a_maze() -> void:
	# An unbounded `while items.size() < target` once hung the whole game here.
	main._clear_items()
	Maze.grid = PackedByteArray()
	main._top_up_items()
	eq(main.items.size(), 0, "no maze, no items, and crucially no hang")

func test_items_spawn_on_walkable_floor() -> void:
	main._top_up_items()
	for iid in main.items:
		not_ok(Maze.is_blocked(main.items[iid].position, 16.0),
			"item %d is reachable" % iid)

func test_items_expire_on_their_own() -> void:
	main._clear_items()
	var iid: int = main.server_add_item(Collectible.Kind.GOLD, Vector2(500, 500), 2.0)
	eq(main.items.size(), 1, "spawned")
	main._expire_items(1.0)
	eq(main.items.size(), 1, "still alive at half its lifespan")
	main._expire_items(1.5)
	eq(main.items.size(), 0, "gone once its lifespan runs out")
	eq(main.scores.get(1, 0), 0, "expiry scores nothing for anyone")

func test_walking_onto_an_item_scores_its_value() -> void:
	main._clear_items()
	var p := _add(7, Vector2(600, 600))
	var iid: int = main.server_add_item(Collectible.Kind.RUBY, Vector2(600, 600), 30.0)
	main._check_pickup()
	eq(main.items.size(), 0, "item consumed")
	eq(main.scores[7], Collectible.VALUE[Collectible.Kind.RUBY], "ruby is worth its value")

func test_an_item_out_of_reach_is_not_collected() -> void:
	main._clear_items()
	_add(7, Vector2(600, 600))
	main.server_add_item(Collectible.Kind.GOLD, Vector2(600 + Collectible.RADIUS + 40.0, 600), 30.0)
	main._check_pickup()
	eq(main.items.size(), 1, "still there")
	eq(main.scores[7], 0, "no points")

# --- rounds -------------------------------------------------------------------

func test_reaching_the_target_wins_a_round_and_resets_scores() -> void:
	main._clear_items()
	var p := _add(7, Vector2(600, 600))
	_add(8)
	main.scores[7] = main.WIN_SCORE - 1
	main.server_add_item(Collectible.Kind.GOLD, Vector2(600, 600), 30.0)
	main._check_pickup()
	eq(main.rounds_won[7], 1, "round banked")
	eq(main.scores[7], 0, "winner's score reset")
	eq(main.scores[8], 0, "everyone's score reset")
	eq(main.round_history.size(), 1, "one round recorded")
	eq(int(main.round_history[0]["winner"]), 7, "recorded against the winner")
	eq(int(main.round_history[0]["scores"][7]), main.WIN_SCORE, "with the final score")

func test_overshooting_the_target_still_wins() -> void:
	# A 5-point diamond can jump 22 straight past 25, so the test must be `>=`.
	main._clear_items()
	_add(7, Vector2(600, 600))
	main.scores[7] = main.WIN_SCORE - 2
	main.server_add_item(Collectible.Kind.DIAMOND, Vector2(600, 600), 30.0)
	main._check_pickup()
	eq(main.rounds_won[7], 1, "jumping past the target still wins")

func test_a_new_round_deals_a_new_maze_and_moves_everyone_to_safety() -> void:
	var p := _add(7)
	var before_seed: int = main.maze_seed
	main._new_maze(0)
	ne(main.maze_seed, before_seed, "new layout")
	not_ok(Maze.is_blocked(p.position, 16.0), "nobody is left standing in a new wall")

func test_round_records_are_idempotent() -> void:
	main.record_round(1, 7, {7: 25})
	main.record_round(1, 7, {7: 25})
	eq(main.round_history.size(), 1, "a replayed record does not duplicate")

# --- winning the game ---------------------------------------------------------

func test_the_game_ends_at_the_win_target() -> void:
	main._clear_items()
	_add(7, Vector2(600, 600))
	main.rounds_won[7] = main.GAME_WINS - 1
	main.scores[7] = main.WIN_SCORE - 1
	main.server_add_item(Collectible.Kind.GOLD, Vector2(600, 600), 30.0)
	main._check_pickup()
	eq(main.rounds_won[7], main.GAME_WINS, "final round won")
	ok(main.game_finished, "the game is over")

func test_play_freezes_once_the_game_is_over() -> void:
	var p := _add(7, Vector2(600, 600))
	main.submit_input_for(7, 1, Vector2.RIGHT)
	main.game_finished = true
	var before := p.position
	for i in 10:
		main._physics_process(TICK)
	eq(p.position, before, "queued input is not applied behind the results screen")

func test_restart_clears_the_game_but_keeps_the_players() -> void:
	_add(7)
	_add(8)
	main.rounds_won[7] = main.GAME_WINS
	main.record_round(1, 7, {7: 25, 8: 4})
	main.game_finished = true
	main.request_restart()
	not_ok(main.game_finished, "back in play")
	eq(main.round_history.size(), 0, "history cleared")
	eq(main.rounds_won[7], 0, "standings cleared")
	eq(main.rounds_won[8], 0, "for everyone")
	eq(main.players.size(), 2, "players stay connected")
	main._server_simulate(TICK)      # the field refills on the next server tick
	between(float(main.items.size()), float(main.MIN_ITEMS), float(main.MAX_ITEMS), "a fresh field")

func test_restart_is_ignored_while_a_game_is_running() -> void:
	_add(7)
	main.record_round(1, 7, {7: 25})
	main.game_finished = false
	main.request_restart()
	eq(main.round_history.size(), 1, "history survives a spurious restart")

# --- server simulation and reconciliation -------------------------------------

func test_the_server_moves_players_from_queued_input() -> void:
	var p := _add(7, Vector2(600, 600))
	var before := p.position
	for tick in range(1, 31):
		main.submit_input_for(7, tick, Vector2.RIGHT)
	for i in 30:
		main._server_simulate(TICK)
	ok(p.position.x > before.x, "consuming queued input moves the player")
	eq(p.last_tick, 30, "and acknowledges the newest input applied")

func test_the_server_clamps_a_hostile_input_vector() -> void:
	var p := _add(7, Vector2(600, 600))
	main.submit_input_for(7, 1, Vector2(9999, 9999))
	main._server_simulate(TICK)
	almost(p.input_dir.length(), 1.0, 0.0001, "magnitude limited to one")

func test_input_for_an_unknown_peer_is_dropped() -> void:
	_add(7)
	main.submit_input_for(999, 1, Vector2.RIGHT)
	ok(true, "no crash, nothing to assert beyond survival")

func test_stale_input_is_ignored() -> void:
	var p := _add(7, Vector2(600, 600))
	main.submit_input_for(7, 5, Vector2.RIGHT)
	main.submit_input_for(7, 3, Vector2.LEFT)
	eq(p.input_queue.size(), 1, "an older tick after a newer one is dropped")

func test_the_input_queue_is_capped() -> void:
	var p := _add(7, Vector2(600, 600))
	for tick in range(1, 200):
		main.submit_input_for(7, tick, Vector2.RIGHT)
	ok(p.input_queue.size() <= main.INPUT_QUEUE_CAP, "a flooding client cannot grow it forever")

func test_reconcile_accepts_the_server_when_it_agrees() -> void:
	var p := _add(7, Vector2(600, 600))
	main.pending = [{"tick": 1, "dir": Vector2.RIGHT, "delta": TICK}]
	var replayed: Vector2 = main.simulate(Vector2(600, 600), Vector2.RIGHT, TICK)
	main._reconcile(p, Vector2(600, 600), 0)
	vec_almost(p.position, replayed, 0.0001, "authority plus one replayed input")
	eq(main.pending.size(), 1, "the unacknowledged input is kept")

func test_reconcile_drops_acknowledged_inputs() -> void:
	var p := _add(7, Vector2(600, 600))
	main.pending = [
		{"tick": 1, "dir": Vector2.RIGHT, "delta": TICK},
		{"tick": 2, "dir": Vector2.RIGHT, "delta": TICK},
		{"tick": 3, "dir": Vector2.RIGHT, "delta": TICK},
	]
	main._reconcile(p, Vector2(600, 600), 2)
	eq(main.pending.size(), 1, "ticks up to the ack are discarded")
	eq(int(main.pending[0]["tick"]), 3, "the unacknowledged one remains")

func test_reconcile_overrides_a_wrong_prediction() -> void:
	var p := _add(7, Vector2(600, 600))
	p.position = Vector2(50, 50)          # a lie, or simply a bad guess
	main.pending = []
	main._reconcile(p, Vector2(600, 600), 0)
	vec_almost(p.position, Vector2(600, 600), 0.0001, "snapped back to the authority")

# --- client-side view ---------------------------------------------------------

func test_remote_players_interpolate_and_your_own_does_not() -> void:
	var mine := _add(1, Vector2(600, 600))
	var theirs := _add(7, Vector2(600, 600))
	mine.is_local_authority = true
	theirs.is_local_authority = false
	theirs.target_position = Vector2(900, 600)
	mine.target_position = Vector2(900, 600)
	theirs._process(0.1)
	mine._process(0.1)
	ok(theirs.position.x > 600.0, "a remote square eases toward its target")
	ok(theirs.position.x < 900.0, "without snapping straight to it")
	eq(mine.position, Vector2(600, 600), "your own square is never interpolated")
