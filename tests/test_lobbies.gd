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
func _make_lobby(wanted: String, members: Array) -> int:
	var id: int = main._next_lobby_id
	main._next_lobby_id += 1
	main.lobbies[id] = {"name": main._clean_lobby_name(wanted, id), "members": []}
	main._create_world(id)
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
	main.request_create_lobby("Mike's game")
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

# --- the join chime -----------------------------------------------------------

func test_your_own_arrival_is_not_announced_to_you() -> void:
	var id := _create(1, "game")
	var w: World = main.worlds[id]
	w._announce_joins = true          # even once armed
	not_ok(w.should_announce_join(1), "you do not chime at yourself")

func test_arrivals_are_announced_once_you_have_settled() -> void:
	var id := _create(1, "game")
	var w: World = main.worlds[id]
	w._announce_joins = false
	not_ok(w.should_announce_join(7), "silent while your own arrival settles")
	w._announce_joins = true
	ok(w.should_announce_join(7), "and announced afterwards")

func test_another_lobbys_arrivals_are_silent() -> void:
	var mine := _make_lobby("mine", [1])
	var theirs := _make_lobby("theirs", [2])
	main.my_lobby_id = mine
	var other: World = main.worlds[theirs]
	other._announce_joins = true
	not_ok(other.should_announce_join(9),
		"somebody joining a different game is not your business")
	var own: World = main.worlds[mine]
	own._announce_joins = true
	ok(own.should_announce_join(9), "but your own game is")

func test_a_dedicated_server_never_chimes() -> void:
	var id := _create(1, "game")
	var w: World = main.worlds[id]
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
