class_name GameWorld
extends Node2D

## Base class for every game this server can host.
##
## Holds the parts that are true of *any* networked game running as one lobby
## among several: which lobby it is, who is allowed to see it, and the handful
## of methods `Main` calls. It knows nothing about mazes, gems or rounds — a
## subclass supplies all of that.
##
## Subclasses override:
##
##     _setup()            build the game once the World is in the tree
##     server_prepare()    set spawn state *before* it enters the tree
##     server_admit(peer)  put a player in, wherever that means for this game
##     server_evict(peer)  take them out
##
## and use `gate()` on anything they spawn, so it is only replicated to peers
## in this lobby.

## Spawn state: replicated with the World itself, so a client that receives one
## knows immediately which lobby it belongs to.
var lobby_id: int = 0

## The shell. Owns the connection, the identities and the screen.
var game: Node = null

@onready var sync: MultiplayerSynchronizer = $Sync

var _gated: Array[MultiplayerSynchronizer] = []

func _ready() -> void:
	game = get_parent().get_parent()
	gate(self)
	_setup()
	if not multiplayer.is_server():
		# Tell the server we exist. It waits for this before putting our player
		# in, because spawning into a World the client has not received yet
		# fails with "Node not found: .../PlayerSpawner".
		game.world_ready.rpc_id(1, lobby_id)

# --- what a subclass fills in -------------------------------------------------

## Called once the World is in the tree, on every peer that has it.
func _setup() -> void:
	pass

## Called before the World enters the tree, so anything set here rides along as
## spawn state.
func server_prepare() -> void:
	pass

func server_admit(_peer: int) -> void:
	push_error("%s does not implement server_admit()" % get_script().resource_path)

func server_evict(_peer: int) -> void:
	push_error("%s does not implement server_evict()" % get_script().resource_path)

## How big this game's playfield is. The shell clamps the camera to it, and has
## no other way of knowing -- a maze and a lobby of idle avatars are not the
## same size.
func world_bounds() -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(1152, 648))

# --- lobby isolation ----------------------------------------------------------

## True when the local player is playing *this* game rather than another lobby's.
func is_local() -> bool:
	return game != null and game.my_lobby_id == lobby_id

## Gate a node's synchronizer on lobby membership.
##
## This is what keeps two games apart. MultiplayerSpawner has no visibility API
## of its own, but a spawn is only delivered to peers that can see the spawned
## node's synchronizer — so filtering here filters the spawn as well as the
## updates, and a peer in another lobby never learns the node exists.
func gate(node: Node) -> void:
	var s: MultiplayerSynchronizer = node.get_node_or_null("Sync")
	if s == null:
		return
	s.public_visibility = false
	if s.has_meta("gated"):
		return                      # MultiplayerSynchronizer has no way to ask
	s.set_meta("gated", true)       # which filters it already carries
	_gated.append(s)
	_apply_visibility(s)

## Set visibility per peer, explicitly, rather than installing a filter
## callable: a filter is only re-evaluated on the synchronizer's own schedule,
## and a spawn withheld before you joined is not reissued when it next runs.
## `set_visibility_for` does reissue it, which is the whole mechanism here.
func refresh_visibility() -> void:
	if not is_inside_tree() or multiplayer == null:
		return
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	var alive: Array[MultiplayerSynchronizer] = []
	for s in _gated:
		if is_instance_valid(s):
			alive.append(s)
	for peer in multiplayer.get_peers():
		var visible := _can_see(peer)
		# Grant outside-in, revoke inside-out. Hiding the World despawns its
		# whole subtree on that peer, so a child despawn sent afterwards finds
		# nothing and logs ERR_UNAUTHORIZED once per spawned node.
		var order := alive.duplicate()
		if not visible:
			order.reverse()
		for s in order:
			s.set_visibility_for(peer, visible)

func _apply_visibility(s: MultiplayerSynchronizer) -> void:
	# `multiplayer` is null until the node is in the tree, and gating happens
	# before that on purpose, so a spawn never leaks. Membership is applied
	# again by `refresh_visibility` once we are in.
	if not is_inside_tree() or multiplayer == null:
		return
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	for peer in multiplayer.get_peers():
		s.set_visibility_for(peer, _can_see(peer))

func _can_see(peer: int) -> bool:
	return game != null and game.is_member(lobby_id, peer)

# --- talking to the screen ----------------------------------------------------
#
# All guarded on `is_local()`, so a game running in another lobby cannot write
# to the screen of somebody who is not playing it.

func say(text: String) -> void:
	if game != null:
		game.announce_for(self, text)

func banner(text: String) -> void:
	if game != null:
		game.show_round_overlay(self, text)

func set_score_line(text: String) -> void:
	if game != null:
		game.set_score_line(self, text)

func set_status_line(text: String) -> void:
	if game != null:
		game.set_status_line(self, text)
