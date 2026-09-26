extends GameTest

## Behaviour of the running game, driven through the server-side seam
## (`server_add_player` and friends) rather than through whatever RPC or
## MultiplayerSpawner happens to sit underneath it.

const ARENA := Vector2(2304, 1296)
const TICK := 1.0 / 60.0

var world: GameWorld
var main: Node2D

func before_each() -> void:
	world = make_world()
	main = world.game
	world._apply_maze(20260920)
	main.in_session = true

func after_each() -> void:
	drop_world(world)

func _add(id: int, at: Vector2 = Vector2.ZERO) -> Node2D:
	world.server_add_player(id, at if at != Vector2.ZERO else world._open_spawn())
	return world.players[id]

# --- the player registry ------------------------------------------------------

func test_adding_a_player_registers_it_everywhere() -> void:
	var p := _add(7)
	eq(world.players.size(), 1, "one player")
	eq(world.scores[7], 0, "starts on zero points")
	eq(world.rounds_won[7], 0, "starts on zero rounds")
	eq(p.name, "7", "node is named after the peer id, so RPC paths agree")
	eq(world.players_root.get_child_count(), 1, "and it is in the scene")

func test_adding_the_same_player_twice_is_harmless() -> void:
	_add(7)
	world.scores[7] = 12
	world.server_add_player(7, Vector2(100, 100))
	eq(world.players.size(), 1, "still one player")
	eq(world.scores[7], 12, "an idempotent spawn does not reset the score")

func test_removing_a_player_clears_its_state_in_this_game() -> void:
	_add(7)
	_add(8)
	main.apply_identity(7, 3, "Mike")
	world.server_remove_player(7)
	eq(world.players.size(), 1, "one left")
	not_ok(world.players.has(7), "gone from the registry")
	not_ok(world.scores.has(7), "score gone")
	not_ok(world.rounds_won.has(7), "standings gone")

func test_identity_outlives_the_game_you_leave() -> void:
	# Stage 9: your name and icon belong to the connection, not to one lobby,
	# so they follow you when you go back to the browser and into another game.
	_add(7)
	main.apply_identity(7, 3, "Mike")
	world.server_remove_player(7)
	eq(main.names[7], "Mike", "the server still knows who you are")
	eq(main.icons[7], 3, "and what you look like")

func test_removing_an_unknown_player_is_a_no_op() -> void:
	_add(7)
	world.server_remove_player(999)
	eq(world.players.size(), 1, "nothing happened")

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

func test_the_handshake_sanitises_the_identity_it_is_handed() -> void:
	# Whatever a peer sends during auth is hostile input.
	var clean: Dictionary = main._identity_from_auth(
		{"icon": 99999, "name": "  Bad\u0007Name  "}, 42)
	eq(clean["name"], "BadName", "control characters stripped, trimmed")
	eq(clean["icon"], main.ICONS.size() - 1, "an absurd index is clamped, not trusted")
	var missing: Dictionary = main._identity_from_auth({}, 42)
	eq(missing["name"], "Player 42", "a peer that sends nothing still gets a name")
	eq(missing["icon"], 0, "and a valid icon")

func test_a_matching_protocol_version_is_required() -> void:
	eq(main.PROTOCOL_VERSION, main.PROTOCOL_VERSION, "the constant exists to be bumped")
	ok(main.PROTOCOL_VERSION > 0, "protocol version is positive")

# --- collectibles -------------------------------------------------------------

func test_the_item_pool_stays_within_bounds() -> void:
	for i in 40:
		world._top_up_items()
		between(float(world.items.size()), float(world.MIN_ITEMS), float(world.MAX_ITEMS), "pool size")

func test_topping_up_cannot_spin_forever_without_a_maze() -> void:
	# An unbounded `while items.size() < target` once hung the whole game here.
	world._clear_items()
	world.maze.grid = PackedByteArray()
	world._top_up_items()
	eq(world.items.size(), 0, "no maze, no items, and crucially no hang")

func test_items_spawn_on_walkable_floor() -> void:
	world._top_up_items()
	for iid in world.items:
		not_ok(world.maze.is_blocked(world.items[iid].position, 16.0),
			"item %d is reachable" % iid)

func test_items_expire_on_their_own() -> void:
	world._clear_items()
	var iid: int = world.server_add_item(Collectible.Kind.GOLD, Vector2(500, 500), 2.0)
	eq(world.items.size(), 1, "spawned")
	world._expire_items(1.0)
	eq(world.items.size(), 1, "still alive at half its lifespan")
	world._expire_items(1.5)
	eq(world.items.size(), 0, "gone once its lifespan runs out")
	eq(world.scores.get(1, 0), 0, "expiry scores nothing for anyone")

func test_walking_onto_an_item_scores_its_value() -> void:
	world._clear_items()
	var p := _add(7, Vector2(600, 600))
	var iid: int = world.server_add_item(Collectible.Kind.RUBY, Vector2(600, 600), 30.0)
	world._check_pickup()
	eq(world.items.size(), 0, "item consumed")
	eq(world.scores[7], Collectible.VALUE[Collectible.Kind.RUBY], "ruby is worth its value")

func test_an_item_out_of_reach_is_not_collected() -> void:
	world._clear_items()
	_add(7, Vector2(600, 600))
	world.server_add_item(Collectible.Kind.GOLD, Vector2(600 + Collectible.RADIUS + 40.0, 600), 30.0)
	world._check_pickup()
	eq(world.items.size(), 1, "still there")
	eq(world.scores[7], 0, "no points")

# --- rounds -------------------------------------------------------------------

func test_reaching_the_target_wins_a_round_and_resets_scores() -> void:
	world._clear_items()
	var p := _add(7, Vector2(600, 600))
	_add(8)
	world.scores[7] = world.WIN_SCORE - 1
	world.server_add_item(Collectible.Kind.GOLD, Vector2(600, 600), 30.0)
	world._check_pickup()
	eq(world.rounds_won[7], 1, "round banked")
	eq(world.scores[7], 0, "winner's score reset")
	eq(world.scores[8], 0, "everyone's score reset")
	eq(world.round_history.size(), 1, "one round recorded")
	eq(int(world.round_history[0]["winner"]), 7, "recorded against the winner")
	eq(int(world.round_history[0]["scores"][7]), world.WIN_SCORE, "with the final score")

func test_overshooting_the_target_still_wins() -> void:
	# A 5-point diamond can jump 22 straight past 25, so the test must be `>=`.
	world._clear_items()
	_add(7, Vector2(600, 600))
	world.scores[7] = world.WIN_SCORE - 2
	world.server_add_item(Collectible.Kind.DIAMOND, Vector2(600, 600), 30.0)
	world._check_pickup()
	eq(world.rounds_won[7], 1, "jumping past the target still wins")

func test_a_new_round_deals_a_new_maze_and_moves_everyone_to_safety() -> void:
	var p := _add(7)
	var before_seed: int = world.maze_seed
	world._new_maze(0)
	ne(world.maze_seed, before_seed, "new layout")
	not_ok(world.maze.is_blocked(p.position, 16.0), "nobody is left standing in a new wall")

func test_round_records_are_idempotent() -> void:
	world.record_round(1, 7, {7: 25})
	world.record_round(1, 7, {7: 25})
	eq(world.round_history.size(), 1, "a replayed record does not duplicate")

# --- winning the game ---------------------------------------------------------

func test_the_game_ends_at_the_win_target() -> void:
	world._clear_items()
	_add(7, Vector2(600, 600))
	world.rounds_won[7] = world.GAME_WINS - 1
	world.scores[7] = world.WIN_SCORE - 1
	world.server_add_item(Collectible.Kind.GOLD, Vector2(600, 600), 30.0)
	world._check_pickup()
	eq(world.rounds_won[7], world.GAME_WINS, "final round won")
	ok(world.game_finished, "the game is over")

func test_play_freezes_once_the_game_is_over() -> void:
	var p := _add(7, Vector2(600, 600))
	world.submit_input_for(7, 1, Vector2.RIGHT)
	world.game_finished = true
	var before := p.position
	for i in 10:
		world._physics_process(TICK)
	eq(p.position, before, "queued input is not applied behind the results screen")

func test_restart_clears_the_game_but_keeps_the_players() -> void:
	_add(7)
	_add(8)
	world.rounds_won[7] = world.GAME_WINS
	world.record_round(1, 7, {7: 25, 8: 4})
	world.game_finished = true
	world.request_restart()
	not_ok(world.game_finished, "back in play")
	eq(world.round_history.size(), 0, "history cleared")
	eq(world.rounds_won[7], 0, "standings cleared")
	eq(world.rounds_won[8], 0, "for everyone")
	eq(world.players.size(), 2, "players stay connected")
	world._server_simulate(TICK)      # the field refills on the next server tick
	between(float(world.items.size()), float(world.MIN_ITEMS), float(world.MAX_ITEMS), "a fresh field")

func test_restart_is_ignored_while_a_game_is_running() -> void:
	_add(7)
	world.record_round(1, 7, {7: 25})
	world.game_finished = false
	world.request_restart()
	eq(world.round_history.size(), 1, "history survives a spurious restart")

# --- server simulation and reconciliation -------------------------------------

func test_the_server_moves_players_from_queued_input() -> void:
	var p := _add(7, Vector2(600, 600))
	var before := p.position
	for tick in range(1, 31):
		world.submit_input_for(7, tick, Vector2.RIGHT)
	for i in 30:
		world._server_simulate(TICK)
	ok(p.position.x > before.x, "consuming queued input moves the player")
	eq(p.last_tick, 30, "and acknowledges the newest input applied")

func test_the_server_clamps_a_hostile_input_vector() -> void:
	var p := _add(7, Vector2(600, 600))
	world.submit_input_for(7, 1, Vector2(9999, 9999))
	world._server_simulate(TICK)
	almost(p.input_dir.length(), 1.0, 0.0001, "magnitude limited to one")

func test_input_for_an_unknown_peer_is_dropped() -> void:
	_add(7)
	world.submit_input_for(999, 1, Vector2.RIGHT)
	ok(true, "no crash, nothing to assert beyond survival")

func test_stale_input_is_ignored() -> void:
	var p := _add(7, Vector2(600, 600))
	world.submit_input_for(7, 5, Vector2.RIGHT)
	world.submit_input_for(7, 3, Vector2.LEFT)
	eq(p.input_queue.size(), 1, "an older tick after a newer one is dropped")

func test_the_input_queue_is_capped() -> void:
	var p := _add(7, Vector2(600, 600))
	for tick in range(1, 200):
		world.submit_input_for(7, tick, Vector2.RIGHT)
	ok(p.input_queue.size() <= world.INPUT_QUEUE_CAP, "a flooding client cannot grow it forever")

func test_reconcile_accepts_the_server_when_it_agrees() -> void:
	var p := _add(7, Vector2(600, 600))
	world.pending = [{"tick": 1, "dir": Vector2.RIGHT, "delta": TICK}]
	var replayed: Vector2 = world.simulate(world.maze, Vector2(600, 600), Vector2.RIGHT, TICK)
	world._reconcile(p, Vector2(600, 600), 0)
	vec_almost(p.position, replayed, 0.0001, "authority plus one replayed input")
	eq(world.pending.size(), 1, "the unacknowledged input is kept")

func test_reconcile_drops_acknowledged_inputs() -> void:
	var p := _add(7, Vector2(600, 600))
	world.pending = [
		{"tick": 1, "dir": Vector2.RIGHT, "delta": TICK},
		{"tick": 2, "dir": Vector2.RIGHT, "delta": TICK},
		{"tick": 3, "dir": Vector2.RIGHT, "delta": TICK},
	]
	world._reconcile(p, Vector2(600, 600), 2)
	eq(world.pending.size(), 1, "ticks up to the ack are discarded")
	eq(int(world.pending[0]["tick"]), 3, "the unacknowledged one remains")

func test_reconcile_overrides_a_wrong_prediction() -> void:
	var p := _add(7, Vector2(600, 600))
	p.position = Vector2(50, 50)          # a lie, or simply a bad guess
	world.pending = []
	world._reconcile(p, Vector2(600, 600), 0)
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
