extends GameTest

## Stage 9: the server is something you are *connected to* before you are
## *playing on it*, and it holds more than one game at a time.

var main: Node2D

func before_each() -> void:
	main = make_main()
	main.in_session = true

func after_each() -> void:
	drop_main(main)

## `request_create_lobby` reads the sender, and offline that is always peer 1.
## For multi-lobby cases, drive the registry directly so each lobby keeps its
## own member -- otherwise peer 1 vacates the first one and it is pruned.
func _make_lobby(wanted: String, members: Array, type_id: String = GameType.DEFAULT) -> int:
	var id: int = main._next_lobby_id
	main._next_lobby_id += 1
	main.lobbies[id] = {
		"name": main._clean_lobby_name(wanted, id),
		"type": GameType.resolve(type_id),
		"members": [],
	}
	main._create_world(id, GameType.resolve(type_id))
	for m in members:
		main._server_move_peer(m, id)
	return id

func _create(who: int, wanted: String) -> int:
	return _make_lobby(wanted, [who])

func test_a_fresh_server_has_no_games() -> void:
	eq(main.lobbies.size(), 0, "nothing to join yet")
	eq(main.my_lobby_id, 0, "and you are in nothing")

func test_creating_a_lobby_names_it_and_puts_you_in_it() -> void:
	# The real client path: ask the server, end up inside what you asked for.
	main.request_create_lobby("Mike's game", GameType.DEFAULT)
	eq(main.lobbies.size(), 1, "one lobby now exists")
	var id: int = main.lobbies.keys()[0]
	ok(id > 0, "a lobby was created")
	eq(main.lobbies[id]["name"], "Mike's game", "under the name given")
	ok(main.is_member(id, 1), "the creator is in it")
	eq(main.lobby_members(id).size(), 1, "and is the only member")

func test_an_unnamed_lobby_still_gets_a_name() -> void:
	var id := _create(1, "   ")
	eq(main.lobbies[id]["name"], "Lobby %d" % id, "blank names are filled in")

func test_lobby_names_are_sanitised() -> void:
	var id := _create(1, "  Bad\u0007Name  ")
	eq(main.lobbies[id]["name"], "BadName", "control characters stripped, trimmed")

func test_a_lobby_gets_its_own_world() -> void:
	var id := _create(1, "game")
	ok(main.worlds.has(id), "a World was spawned for it")
	eq(main.worlds[id].lobby_id, id, "tagged with its lobby")
	ne(main.worlds[id].maze_seed, 0, "and given a maze")

func test_two_lobbies_are_two_separate_worlds() -> void:
	var a := _create(1, "first")
	var b := _create(2, "second")
	eq(main.lobbies.size(), 2, "both exist")
	ne(a, b, "with different ids")
	ne(main.worlds[a], main.worlds[b], "and different World nodes")
	ne(main.worlds[a].maze_seed, main.worlds[b].maze_seed, "and different mazes")

func test_the_browser_lists_every_lobby_and_who_is_in_it() -> void:
	var a := _create(1, "first")
	main.apply_identity(1, 0, "Mike")
	var b := _create(2, "second")
	main.apply_identity(2, 1, "Sparkles")
	var digest: Array = main._lobby_digest()
	eq(digest.size(), 2, "both lobbies are listed")
	var by_name := {}
	for entry in digest:
		by_name[entry["name"]] = entry
	has_key(by_name, "first", "the first is listed")
	has_key(by_name, "second", "the second is listed")
	eq(PackedStringArray(by_name["first"]["players"]), PackedStringArray(["Mike"]),
		"with the names of the players in it")
	eq(PackedStringArray(by_name["second"]["players"]), PackedStringArray(["Sparkles"]),
		"for each lobby separately")

func test_joining_moves_you_out_of_the_old_game() -> void:
	var a := _create(1, "first")
	var b := _create(2, "second")
	main._server_move_peer(1, b)
	not_ok(main.is_member(a, 1), "no longer in the first")
	ok(main.is_member(b, 1), "now in the second")

func test_you_cannot_join_a_lobby_that_does_not_exist() -> void:
	_create(1, "real")
	main.request_join_lobby(9999)
	eq(main.lobbies.size(), 1, "a bogus id changes nothing")

func test_a_lobby_nobody_is_in_is_cleaned_up() -> void:
	var id := _create(1, "temporary")
	ok(main.worlds.has(id), "it had a world")
	main._server_move_peer(1, 0)
	not_ok(main.lobbies.has(id), "the empty lobby is gone")
	not_ok(main.worlds.has(id), "and so is its world")

func test_leaving_takes_you_back_to_the_browser() -> void:
	var id := _create(1, "game")
	main.you_are_in(id)
	eq(main.my_lobby_id, id, "in a game")
	main.you_are_in(0)
	eq(main.my_lobby_id, 0, "and back out again")

func test_a_departing_peer_is_not_sent_messages() -> void:
	# `peer_disconnected` fires after ENet has dropped them, so any rpc_id to
	# that peer errors. The registry still has to be cleaned up.
	not_ok(main._can_notify(818181), "a peer that never existed is unreachable")
	ok(main._can_notify(1), "but the host can always talk to itself")

func test_a_disconnect_empties_their_seat() -> void:
	var id := _make_lobby("game", [1, 42])
	eq(main.lobby_members(id).size(), 2, "two in the lobby")
	main._on_peer_disconnected(42)
	not_ok(main.is_member(id, 42), "the departed peer is out of the lobby")
	not_ok(main.names.has(42), "and its identity is released")
	not_ok(main.icons.has(42), "including its icon")
	ok(main.lobbies.has(id), "the lobby survives while someone is still in it")

func test_the_last_player_leaving_takes_the_lobby_with_them() -> void:
	var id := _make_lobby("game", [42])
	main._on_peer_disconnected(42)
	not_ok(main.lobbies.has(id), "an empty lobby is pruned")
	not_ok(main.worlds.has(id), "and its world with it")

# --- game types ---------------------------------------------------------------

func test_the_catalogue_is_well_formed() -> void:
	ok(GameType.ids().size() > 0, "the server hosts at least one game")
	for id in GameType.ids():
		ok(GameType.known(id), "%s is known" % id)
		ne(GameType.name_of(id), "", "%s has a display name" % id)
		ne(GameType.blurb(id), "", "%s has a description" % id)
		ok(ResourceLoader.exists(GameType.scene_path(id)),
			"%s points at a scene that exists" % id)

func test_our_game_is_called_a_mazing() -> void:
	eq(GameType.name_of("amazing"), "A Mazing", "the maze game has a name")
	eq(GameType.DEFAULT, "amazing", "and is what you get by default")

func test_an_unknown_type_falls_back_rather_than_failing() -> void:
	not_ok(GameType.known("tetris"), "we do not host that")
	eq(GameType.resolve("tetris"), GameType.DEFAULT, "so you get the default instead")
	eq(GameType.resolve(""), GameType.DEFAULT, "same for a blank type")

func test_a_lobby_remembers_its_type() -> void:
	var id := _make_lobby("game", [1])
	eq(main.lobbies[id]["type"], GameType.DEFAULT, "the type is stored with the lobby")

func test_creating_with_a_bogus_type_still_works() -> void:
	main.request_create_lobby("hopeful", "pinball")
	var id: int = main.lobbies.keys()[0]
	eq(main.lobbies[id]["type"], GameType.DEFAULT, "coerced to something we can host")
	ok(main.worlds.has(id), "and it still got a world")

func test_the_browser_shows_the_type_beside_the_name() -> void:
	var id := _make_lobby("Mike's game", [1])
	var digest: Array = main._lobby_digest()
	eq(digest.size(), 1, "one lobby listed")
	eq(digest[0]["name"], "Mike's game", "with its name")
	eq(digest[0]["type"], "A Mazing", "and the game type spelled out")

func test_the_world_spawned_matches_the_type() -> void:
	var id := _make_lobby("game", [1])
	var w = main.worlds[id]
	eq(w.get_scene_file_path(), GameType.scene_path(GameType.DEFAULT),
		"the lobby's type chose the scene")

func test_main_does_not_reach_into_the_game() -> void:
	# The contract is what lets a second game type exist: Main admits a player
	# and the World decides what that means.
	var id := _make_lobby("game", [])
	var w = main.worlds[id]
	for required in ["server_prepare", "server_admit", "server_evict",
			"refresh_visibility", "is_local", "gate"]:
		ok(w.has_method(required), "World provides %s()" % required)

func test_the_second_game_is_on_offer() -> void:
	ok(GameType.known("ashamed"), "the server hosts Ashamed")
	eq(GameType.name_of("ashamed"), "Ashamed", "by name")
	ne(GameType.scene_path("ashamed"), GameType.scene_path("amazing"),
		"and it is a different scene from A Mazing")

func test_ashamed_is_shaped_like_a_side_scroller() -> void:
	var id := _make_lobby("side quest", [], "ashamed")
	var w: GameWorld = main.worlds[id]
	var bounds: Rect2 = w.world_bounds()
	ok(bounds.size.x > bounds.size.y * 2.0,
		"the playfield is wide and short, not square")
	# Players stand *on* the floor plane, at some depth into it.
	for peer in [7, 8, 9]:
		w.server_admit(peer)
		var p = w.players[peer]
		eq(p.height, 0.0, "peer %d spawned standing on the floor" % peer)
		between(p.ground.y, 0.0, AshamedWorld.DEPTH_RANGE,
			"peer %d spawned within the floor's depth" % peer)

func test_an_ashamed_lobby_spawns_an_ashamed_world() -> void:
	main.request_create_lobby("skeleton", "ashamed")
	var id: int = main.lobbies.keys()[0]
	eq(main.lobbies[id]["type"], "ashamed", "the lobby is of that type")
	var w: GameWorld = main.worlds[id]
	eq(w.get_scene_file_path(), GameType.scene_path("ashamed"), "and got its scene")
	ok(w is AshamedWorld, "which is an AshamedWorld")
	ok(w is GameWorld, "and therefore a GameWorld")

func test_two_types_can_run_side_by_side() -> void:
	var a := _make_lobby("maze game", [1], "amazing")
	var b := _make_lobby("skeleton", [2], "ashamed")
	ok(main.worlds[a] is AmazingWorld, "one is A Mazing")
	ok(main.worlds[b] is AshamedWorld, "the other is Ashamed")
	ne(main.worlds[a].get_script(), main.worlds[b].get_script(), "different games")
	ok(main.worlds[a]._can_see(1), "each still gates on its own membership")
	not_ok(main.worlds[a]._can_see(2), "across types as well as within one")
	ok(main.worlds[b]._can_see(2), "symmetrically")

func test_ashamed_admits_and_evicts_players() -> void:
	var id := _make_lobby("skeleton", [], "ashamed")
	var w: GameWorld = main.worlds[id]
	w.server_admit(7)
	eq(w.players.size(), 1, "a player was admitted")
	ok(w.players.has(7), "the right one")
	w.server_admit(7)
	eq(w.players.size(), 1, "admitting twice is harmless")
	w.server_evict(7)
	eq(w.players.size(), 0, "and evicting takes them out again")

func test_every_registered_type_answers_the_contract() -> void:
	# The real payoff: this loops over the catalogue, so a future game that
	# forgets a method fails here rather than at runtime in somebody's lobby.
	for type_id in GameType.ids():
		var scene: PackedScene = GameType.scene(type_id)
		var w = scene.instantiate()
		ok(w is GameWorld, "%s extends GameWorld" % type_id)
		for required in ["_setup", "server_prepare", "server_admit", "server_evict",
				"refresh_visibility", "is_local", "gate", "world_bounds"]:
			ok(w.has_method(required), "%s provides %s()" % [type_id, required])
		var bounds: Rect2 = w.world_bounds()
		ok(bounds.size.x > 0.0 and bounds.size.y > 0.0,
			"%s declares a playfield with area" % type_id)
		w.free()

func test_a_second_type_needs_nothing_but_a_row() -> void:
	# The honest test of an abstraction: register another game and check that
	# creation, the digest and the spawned scene all follow it, with no change
	# anywhere else. It reuses the same scene because there is only one game so
	# far -- what is being proved is that the *registry* drives everything.
	GameType.register("duel", "Maze Duel", "Same maze, fewer friends.",
		GameType.scene_path(GameType.DEFAULT))
	ok(GameType.known("duel"), "the new type is known")
	eq(GameType.name_of("duel"), "Maze Duel", "by its own name")

	main.request_create_lobby("grudge match", "duel")
	var id: int = main.lobbies.keys()[0]
	eq(main.lobbies[id]["type"], "duel", "the lobby took the type asked for")
	ok(main.worlds.has(id), "and got a world for it")
	var digest: Array = main._lobby_digest()
	eq(digest[0]["type"], "Maze Duel", "the browser shows the new type by name")

	GameType.TYPES.erase("duel")

# --- the join chime -----------------------------------------------------------

func test_your_own_arrival_is_not_announced_to_you() -> void:
	var id := _create(1, "game")
	var w: GameWorld = main.worlds[id]
	w._announce_joins = true          # even once armed
	not_ok(w.should_announce_join(1), "you do not chime at yourself")

func test_arrivals_are_announced_once_you_have_settled() -> void:
	var id := _create(1, "game")
	var w: GameWorld = main.worlds[id]
	w._announce_joins = false
	not_ok(w.should_announce_join(7), "silent while your own arrival settles")
	w._announce_joins = true
	ok(w.should_announce_join(7), "and announced afterwards")

func test_another_lobbys_arrivals_are_silent() -> void:
	var mine := _make_lobby("mine", [1])
	var theirs := _make_lobby("theirs", [2])
	main.my_lobby_id = mine
	var other: GameWorld = main.worlds[theirs]
	other._announce_joins = true
	not_ok(other.should_announce_join(9),
		"somebody joining a different game is not your business")
	var own: GameWorld = main.worlds[mine]
	own._announce_joins = true
	ok(own.should_announce_join(9), "but your own game is")

func test_a_dedicated_server_never_chimes() -> void:
	var id := _create(1, "game")
	var w: GameWorld = main.worlds[id]
	w._announce_joins = true
	main.is_dedicated = true
	not_ok(w.should_announce_join(7), "a VPS has nobody to play it to")
	main.is_dedicated = false

func test_membership_is_what_gates_visibility() -> void:
	# A World is only shown to peers in its lobby; this is the predicate the
	# synchronizer filter asks.
	var a := _create(1, "mine")
	var b := _create(2, "theirs")
	ok(main.worlds[a]._can_see(1), "a member can see their own world")
	not_ok(main.worlds[a]._can_see(2), "someone in another lobby cannot")
	ok(main.worlds[b]._can_see(2), "and vice versa")
	not_ok(main.worlds[b]._can_see(1), "symmetrically")
