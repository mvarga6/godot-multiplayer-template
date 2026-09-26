class_name GameTest
extends RefCounted

## Base class for the suite. Subclasses add `test_*` methods; the runner finds
## them by name, calls `before_each` / `after_each` around each one, and counts
## whatever the assertions report.

var tree: SceneTree          # set by the runner
var failures: Array[String] = []
var checks := 0

func before_each() -> void:
	pass

func after_each() -> void:
	pass

# --- assertions ---------------------------------------------------------------

func ok(condition: bool, what: String) -> void:
	checks += 1
	if not condition:
		failures.append("%s: expected true" % what)

func not_ok(condition: bool, what: String) -> void:
	checks += 1
	if condition:
		failures.append("%s: expected false" % what)

func eq(actual: Variant, expected: Variant, what: String) -> void:
	checks += 1
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [what, expected, actual])

func ne(actual: Variant, unexpected: Variant, what: String) -> void:
	checks += 1
	if actual == unexpected:
		failures.append("%s: expected anything but %s" % [what, unexpected])

func almost(actual: float, expected: float, eps: float, what: String) -> void:
	checks += 1
	if absf(actual - expected) > eps:
		failures.append("%s: expected %.4f +/- %.4f, got %.4f" % [what, expected, eps, actual])

func vec_almost(actual: Vector2, expected: Vector2, eps: float, what: String) -> void:
	checks += 1
	if actual.distance_to(expected) > eps:
		failures.append("%s: expected %s +/- %.3f, got %s" % [what, expected, eps, actual])

func between(value: float, lo: float, hi: float, what: String) -> void:
	checks += 1
	if value < lo or value > hi:
		failures.append("%s: expected %s..%s, got %s" % [what, lo, hi, value])

func has_key(d: Dictionary, key: Variant, what: String) -> void:
	checks += 1
	if not d.has(key):
		failures.append("%s: missing key %s in %s" % [what, key, d.keys()])

# --- helpers ------------------------------------------------------------------

## A Main in the tree, acting as its own server. Godot gives every tree an
## OfflineMultiplayerPeer, so `is_server()` is true and `rpc()` runs locally --
## which is exactly what a single-process behaviour test wants.
func make_main() -> Node2D:
	var main: Node2D = (load("res://main.tscn") as PackedScene).instantiate()
	tree.root.add_child(main)
	return main

## A Main with one World inside it, acting as its own server, with the local
## player already "in" that lobby. This is the shape stage 9 made normal: the
## shell owns the connection, the World owns the game.
func make_world() -> World:
	var main := make_main()
	var w: World = (load("res://world.tscn") as PackedScene).instantiate()
	w.lobby_id = 1
	w.maze_seed = 20260926
	main.lobbies[1] = {"name": "test game", "members": []}
	main.my_lobby_id = 1
	main.worlds[1] = w
	main.in_session = true
	main.get_node("Worlds").add_child(w)
	return w

## Free the World's Main, which takes the World with it.
func drop_world(w: World) -> void:
	if is_instance_valid(w) and w.game != null:
		drop_main(w.game)

func drop_main(main: Node2D) -> void:
	if is_instance_valid(main):
		tree.root.remove_child(main)
		main.free()
