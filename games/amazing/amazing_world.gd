class_name AmazingWorld
extends GameWorld

## "A Mazing": gems in a lava maze, three weapons, first to 25 takes the round.
##
## Everything here is this game's own. The lobby plumbing -- which lobby it is,
## who may see it, and the methods `Main` calls -- lives in `GameWorld`.

## Arriving in a game hands you everyone already in it, one spawn each. Without
## this, joining a four-player game would play the join chime four times.
const JOIN_CHIME_ARM_DELAY := 0.75

var _announce_joins := false
var _sfx: Dictionary = {}      # Collectible.Kind -> AudioStreamPlayer

## Called by GameWorld once we are in the tree, on every peer that has us.
func _setup() -> void:
	_setup_spawners()
	_setup_audio()
	_setup_input()
	if maze_seed != 0:
		_apply_maze(maze_seed)     # clients get the seed as spawn state
	refresh_hud()

## Our own sounds, our own players. A world in another lobby never plays them
## because everything here is guarded on `is_local()`.
func _setup_audio() -> void:
	if DisplayServer.get_name() == "headless":
		return                     # a VPS has no speakers
	for kind in Collectible.SOUND:
		var p := AudioStreamPlayer.new()
		p.stream = Collectible.SOUND[kind]
		p.volume_db = -4.0
		add_child(p)
		_sfx[kind] = p

## Deliberately local-only: you hear your own pickups, never anyone else's.
func play_pickup(kind: int) -> void:
	if is_local() and _sfx.has(kind):
		_sfx[kind].play()

## Our keys, registered by us. Physical keycodes, so A/S/D are still where your
## fingers are on AZERTY.
func _setup_input() -> void:
	_bind_key("fire", KEY_SPACE)
	for kind in Weapon.Kind.values():
		_bind_key(Weapon.action(kind), Weapon.key(kind))

func _bind_key(action: String, key: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = key
	InputMap.action_add_event(action, ev)

## Both HUD lines, composed here and handed to the shell as text.
func refresh_hud() -> void:
	var ids: Array = scores.keys()
	ids.sort()
	var parts := PackedStringArray()
	for id in ids:
		parts.append("%s %d/%d  wins %d" % [
			game.label_for(id), int(scores[id]), WIN_SCORE, int(rounds_won.get(id, 0))])
	set_score_line("    ".join(parts))

	var weapons := PackedStringArray()
	for kind in Weapon.Kind.values():
		var key := Weapon.key_label(kind)
		var mark := "[%s]" % key if kind == selected_weapon else " %s " % key
		var price := Weapon.cost(kind)
		weapons.append("%s %s %s%s" % [
			mark, Weapon.glyph(kind), Weapon.label(kind),
			"" if price == 0 else " (%d)" % price])
	set_status_line("  ".join(weapons) + "   SPACE to fire")

## The end-of-game table, as rows of cells. The shell knows how to draw a grid;
## it does not know what a round is.
func results_table() -> Array:
	var ids: Array = rounds_won.keys()
	ids.sort()
	var rows := []
	var header := [{"text": "round", "strong": true}]
	for id in ids:
		header.append({"text": game.label_for(id), "strong": true})
	rows.append(header)
	for entry in round_history:
		var row := [{"text": str(int(entry["round"]))}]
		var round_scores: Dictionary = entry["scores"]
		for id in ids:
			var won: bool = int(entry["winner"]) == id
			row.append({"text": "%d%s" % [int(round_scores.get(id, 0)), "  ★" if won else ""],
				"strong": won})
		rows.append(row)
	var totals := [{"text": "rounds won", "strong": true}]
	for id in ids:
		totals.append({"text": str(int(rounds_won.get(id, 0))), "strong": true})
	rows.append(totals)
	return rows

## Should this peer's arrival be announced on this screen?
##
## Only in the game you are watching, only for somebody else, and only once your
## own arrival has settled -- otherwise the roster you are handed on joining
## would announce every player already present.
func should_announce_join(peer_id: int) -> bool:
	if game == null or game.is_dedicated or not is_local():
		return false
	if peer_id == multiplayer.get_unique_id():
		return false
	return _announce_joins


func _arm_join_chime() -> void:
	_announce_joins = false
	await get_tree().create_timer(JOIN_CHIME_ARM_DELAY).timeout
	_announce_joins = true


# --- the contract Main talks to ------------------------------------------------
#
# Main knows a lobby has a World and that players go into it. It does not know
# about mazes, gems or rounds, which is what lets a second game type exist.

## Called before the World enters the tree, so anything set here rides along as
## spawn state. For this game that means choosing the maze.
func server_prepare() -> void:
	maze_seed = randi()

func world_bounds() -> Rect2:
	return Rect2(Vector2.ZERO, ARENA)


## Put a peer into this game. Where they land is the game's business.
func server_admit(peer: int) -> void:
	server_add_player(peer, _open_spawn())


func server_evict(peer: int) -> void:
	server_remove_player(peer)


const SPEED := 220.0

const ARENA := Vector2(2304, 1296)  # a game rule, not a window size

const HALF := Vector2(16, 16)

const WIN_SCORE := 25            # points that win the round; the maze then regenerates

const GAME_WINS := 3            # rounds won that take the whole game

const MIN_ITEMS := 14            # how many collectibles are in the maze at once

const MAX_ITEMS := 20            # the arena is 4x what it was, so the count scaled with it

const LIFETIME_MIN := 8.0        # seconds a collectible survives before it rots away

const LIFETIME_MAX := 18.0

const INPUT_BUFFER_MAX := 4         # queue longer than this: the client has run ahead

const INPUT_QUEUE_CAP := 16         # hard cap, so a flooding client cannot grow it forever

const PLAYER_SCENE := preload("res://games/amazing/player.tscn")

const COLLECTIBLE_SCENE := preload("res://games/amazing/collectible.tscn")

const PROJECTILE_SCENE := preload("res://games/amazing/projectile.tscn")

## Where a shot is born, measured out from the player's centre so it does not
## immediately collide with the shooter's own square.
const MUZZLE_OFFSET := HALF.x + Weapon.RADIUS + 2.0


var players: Dictionary = {}   # peer_id:int -> Player node

var scores: Dictionary = {}    # peer_id:int -> points this round

var rounds_won: Dictionary = {}  # peer_id:int -> rounds won

var round_history: Array = []  # one {round, winner, scores} per finished round

var round_index := 1

var game_finished := false

var maze_seed := 0             # server: the seed every peer is currently generating from

var items: Dictionary = {}     # item_id:int -> Collectible node

var _next_item_id := 1         # server: hands out item ids

var _desired_items := MIN_ITEMS

var shots: Dictionary = {}     # shot_id:int -> Projectile node

var _next_shot_id := 1         # server: hands out shot ids

var selected_weapon := Weapon.Kind.CAPTURE   # client-local: which key you last pressed

var local_facing: Vector2 = Vector2.RIGHT    # client-local, for the aim indicator


# Client-side prediction bookkeeping.
var input_tick := 0            # monotonically increasing sequence number

var pending: Array = []        # inputs sent but not yet acknowledged by the server


@onready var players_root: Node2D = $Players

@onready var player_spawner: MultiplayerSpawner = $PlayerSpawner

@onready var item_spawner: MultiplayerSpawner = $ItemSpawner

@onready var projectile_spawner: MultiplayerSpawner = $ProjectileSpawner

@onready var shots_root: Node2D = $Projectiles

@onready var maze: Maze = $Maze

@onready var items_root: Node2D = $Collectibles


# --- the simulation ----------------------------------------------------------

## The one movement rule, as a pure function of (state, input, delta).
##
## Reconciliation replays this over buffered inputs, so it must read nothing
## outside its arguments — no `Input`, no node state, no randomness. That purity
## is the whole reason client and server can agree on where a square ended up.
static func simulate(maze: Maze, pos: Vector2, dir: Vector2, delta: float) -> Vector2:
	var step := dir.limit_length(1.0) * SPEED * delta
	var out := pos
	# If we somehow start inside a wall, let every move through rather than
	# blocking all four directions and trapping the player there forever.
	var stuck := maze.is_blocked(pos, HALF.x)
	# Resolve each axis separately, so running into a wall diagonally slides
	# along it instead of stopping dead. Both peers do this identically.
	var try_x := Vector2(out.x + step.x, out.y)
	if stuck or not maze.is_blocked(try_x, HALF.x):
		out = try_x
	var try_y := Vector2(out.x, out.y + step.y)
	if stuck or not maze.is_blocked(try_y, HALF.y):
		out = try_y
	return out.clamp(HALF, ARENA - HALF)


func _setup_spawners() -> void:
	player_spawner.spawn_function = _build_player
	player_spawner.spawned.connect(_on_player_spawned)
	player_spawner.despawned.connect(_on_player_despawned)
	# Scene-based auto-spawn rather than a custom spawn_function: only this path
	# replays already-live nodes to a peer that joins mid-game. Per-item data
	# rides along as spawn-state properties on the Collectible's synchronizer.
	item_spawner.add_spawnable_scene(COLLECTIBLE_SCENE.resource_path)
	item_spawner.spawned.connect(_on_item_spawned)
	item_spawner.despawned.connect(_on_item_despawned)
	projectile_spawner.add_spawnable_scene(PROJECTILE_SCENE.resource_path)
	projectile_spawner.spawned.connect(_on_shot_spawned)
	projectile_spawner.despawned.connect(_on_shot_despawned)


# --- spawn functions: run on every peer, building the node from the same data --

func _build_player(data: Dictionary) -> Node:
	var p := PLAYER_SCENE.instantiate()
	p.setup(int(data["id"]))
	p.position = data["pos"]
	p.net_position = data["pos"]
	p.target_position = data["pos"]
	return p


# --- registry upkeep, driven by the spawners rather than by hand --------------

func _on_player_spawned(node: Node) -> void:
	var id: int = node.peer_id
	players[id] = node
	if not scores.has(id):
		scores[id] = 0
	if not rounds_won.has(id):
		rounds_won[id] = 0
	node.set_identity(game.ICONS[int(game.icons.get(id, 0))], str(game.names.get(id, "Player %d" % id)))
	# The server owns every square. A client predicts only its own and
	# interpolates everyone else toward whatever the synchronizer delivers.
	node.is_local_authority = multiplayer.is_server() or id == multiplayer.get_unique_id()
	node.sync.synchronized.connect(_on_player_synchronized.bind(node))
	if should_announce_join(id):
		game.play_join()
	elif is_local() and id == multiplayer.get_unique_id():
		_arm_join_chime()          # our own arrival: start listening afterwards
	refresh_hud()
	print("[%d] spawned %d at %s" % [multiplayer.get_unique_id(), id, node.position])


func _on_item_spawned(node: Node) -> void:
	items[node.item_id] = node


func _on_item_despawned(node: Node) -> void:
	items.erase(node.item_id)


func _on_shot_spawned(node: Node) -> void:
	shots[node.shot_id] = node


func _on_shot_despawned(node: Node) -> void:
	shots.erase(node.shot_id)


func _on_player_despawned(node: Node) -> void:
	var id: int = node.peer_id
	if id == multiplayer.get_unique_id():
		_announce_joins = false    # we are leaving; nothing here concerns us
	players.erase(id)
	scores.erase(id)
	rounds_won.erase(id)
	refresh_hud()
	print("[%d] despawned %d" % [multiplayer.get_unique_id(), id])


## What `update_state` used to do, now driven by the synchronizer's own signal.
func _on_player_synchronized(node: Node) -> void:
	if multiplayer.is_server():
		return                      # the server already has the truth
	if node.peer_id == multiplayer.get_unique_id():
		_reconcile(node, node.net_position, node.last_tick)
	else:
		node.target_position = node.net_position


func _physics_process(delta: float) -> void:
	if game == null or not game.in_session:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return                      # still handshaking: an RPC now is an error, not a no-op
	if game_finished:
		return                      # nobody moves while the results are up
	if multiplayer.is_server():
		_server_simulate(delta)     # the server runs every lobby's game
	# ...but only one of them is the game on this screen.
	if is_local() and not game.is_dedicated:
		_send_input(delta)


func _send_input(delta: float) -> void:
	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if dir.length() > 0.001:
		local_facing = dir.normalized()
	for kind in Weapon.Kind.values():
		if Input.is_action_just_pressed(Weapon.action(kind)):
			selected_weapon = kind
			refresh_hud()
			break
	if Input.is_action_just_pressed("fire"):
		request_fire.rpc_id(1, selected_weapon)
	input_tick += 1
	# Every tick now carries a sequence number, rather than only sending on
	# change: reconciliation needs to know exactly which inputs the server saw.
	submit_input.rpc_id(1, input_tick, dir)
	if multiplayer.is_server():
		return                      # the host is the authority, it has nothing to predict
	var me := multiplayer.get_unique_id()
	if not players.has(me):
		return
	# Predict: move our own square immediately instead of waiting a round trip.
	# A frozen player predicts standing still, or prediction would fight the
	# server for the whole three seconds.
	var p: Node2D = players[me]
	var moved: Vector2 = p.effective_dir(dir)
	p.position = simulate(maze, p.position, moved, delta)
	p.target_position = p.position
	pending.append({"tick": input_tick, "dir": moved, "delta": delta})


func _server_simulate(delta: float) -> void:
	for id in players:
		var p: Node2D = players[id]
		# Consume one queued input per tick, so the server walks the same path
		# the client predicted. Drain two when the client has run ahead of us.
		var budget := 2 if p.input_queue.size() > INPUT_BUFFER_MAX else 1
		var consumed := 0
		while consumed < budget and not p.input_queue.is_empty():
			var inp: Dictionary = p.input_queue.pop_front()
			p.input_dir = inp["dir"]
			p.last_tick = inp["tick"]
			if p.input_dir.length() > 0.001:
				p.facing = p.input_dir.normalized()   # shots come out this way
			p.position = simulate(maze, p.position, p.effective_dir(p.input_dir), delta)
			consumed += 1
		if consumed == 0:
			# Nothing arrived in time. Assume they are still holding the same
			# key; if that guess is wrong, reconciliation fixes it.
			p.position = simulate(maze, p.position, p.effective_dir(p.input_dir), delta)
		_tick_timers(p, delta)
	for id in players:
		players[id].net_position = players[id].position
	_advance_shots(delta)
	_expire_items(delta)
	_check_pickup()
	_top_up_items()


## Server only: count down a player's freeze and its weapon cooldowns.
func _tick_timers(p: Node2D, delta: float) -> void:
	if p.frozen_remaining > 0.0:
		p.frozen_remaining = maxf(0.0, p.frozen_remaining - delta)
	for kind in p.cooldowns.keys():
		var left := float(p.cooldowns[kind]) - delta
		if left <= 0.0:
			p.cooldowns.erase(kind)
		else:
			p.cooldowns[kind] = left


## Server only: fly every shot and resolve whatever it ran into. Clients do the
## flying half of this in `Projectile._process`; only here does it mean anything.
func _advance_shots(delta: float) -> void:
	for sid in shots.keys():
		var shot: Projectile = shots[sid]
		if not shot.advance(maze, delta):
			server_remove_shot(sid)      # expired, or hit a wall it cannot bounce off
			continue
		if _resolve_shot_hit(shot):
			server_remove_shot(sid)


## True when the shot is spent on whatever it touched.
func _resolve_shot_hit(shot: Projectile) -> bool:
	if Weapon.hits_items(shot.kind):
		var reach := Collectible.RADIUS + Weapon.RADIUS
		for iid in items.keys():
			if shot.position.distance_to(items[iid].position) > reach:
				continue
			# The shot collects on the shooter's behalf, scoring exactly as if
			# they had walked into it.
			_award_item(shot.owner_id, iid)
			return true
	if Weapon.hits_players(shot.kind):
		var reach := HALF.x + Weapon.RADIUS
		for pid in players:
			if pid == shot.owner_id:
				continue                 # your own shot passes through you
			if shot.position.distance_to(players[pid].position) > reach:
				continue
			if _apply_to_player(shot, pid):
				return true
			# No effect on this target -- carry on, so the shot can still reach
			# somebody behind them.
	return false


## True when the shot actually did something to `pid` and is spent.
func _apply_to_player(shot: Projectile, pid: int) -> bool:
	var freeze := Weapon.freeze_seconds(shot.kind)
	if freeze > 0.0:
		# Already frozen: the shot passes through. Otherwise two players could
		# hold a third in place forever by taking turns.
		if players[pid].is_frozen():
			return false
		players[pid].frozen_remaining = freeze
		player_frozen.rpc(pid, freeze)
		return true
	var steal := Weapon.steal_points(shot.kind)
	if steal > 0:
		var victim_had := int(scores.get(pid, 0))
		if victim_had <= 0:
			return false             # nothing in their pockets; the shot flies on
		var taken := mini(steal, victim_had)
		var thief_now := int(scores.get(shot.owner_id, 0)) + taken
		scores_changed.rpc({pid: victim_had - taken, shot.owner_id: thief_now})
		points_stolen.rpc(shot.owner_id, pid, taken)
		if thief_now >= WIN_SCORE:
			_finish_round(shot.owner_id)
		return true
	return false


## Server only. Shared by walking into a gem and by shooting one.
func _award_item(pid: int, iid: int) -> void:
	if not players.has(pid) or not items.has(iid):
		return
	var after := int(scores.get(pid, 0)) + int(Collectible.VALUE[items[iid].kind])
	scores[pid] = after
	server_remove_item(iid, pid, after)
	# `>=`, not `==`: a 5-point diamond can jump 22 straight past 25.
	if after >= WIN_SCORE:
		_finish_round(pid)


func _check_pickup() -> void:
	var reach := Collectible.RADIUS + HALF.x
	for pid in players:
		var ppos: Vector2 = players[pid].position
		for iid in items.keys():
			var item: Collectible = items[iid]
			if ppos.distance_to(item.position) > reach:
				continue
			var before := int(scores.get(pid, 0))
			_award_item(pid, iid)
			if before + int(Collectible.VALUE[item.kind]) >= WIN_SCORE:
				return                     # the new round replaced every item
			break                          # this player has had their pickup this tick


## Server only: retire anything that has outlived its lifespan.
func _expire_items(delta: float) -> void:
	for iid in items.keys():
		var item: Collectible = items[iid]
		item.age += delta                  # the server ages them too; it does not _process
		if item.age >= item.lifetime:
			server_remove_item(iid, 0, 0)  # peer 0 == nobody collected it


## Server only: keep between MIN_ITEMS and MAX_ITEMS lying around.
func _top_up_items() -> void:
	# Bounded: a failed spawn must not turn this into a busy loop.
	var budget := MAX_ITEMS
	while items.size() < _desired_items and budget > 0:
		budget -= 1
		if not _spawn_item():
			return


func _spawn_item() -> bool:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var pos := _free_item_point(rng)
	if pos == Vector2.ZERO:
		return false                   # no maze yet, or nowhere free
	server_add_item(Collectible.random_kind(rng), pos,
		rng.randf_range(LIFETIME_MIN, LIFETIME_MAX))
	return true


## An open cell that no other collectible is already sitting in.
func _free_item_point(rng: RandomNumberGenerator) -> Vector2:
	for _attempt in 24:
		var p := maze.random_open_point(rng)
		if p == Vector2.ZERO:
			return Vector2.ZERO
		var clear := true
		for iid in items:
			if items[iid].position.distance_to(p) < Collectible.RADIUS * 3.0:
				clear = false
				break
		if clear:
			return p
	return maze.random_open_point(rng)


# --- server-side entry points -------------------------------------------------
#
# Everything on the server that creates or destroys a replicated thing goes
# through these four. They are the seam: what sits underneath can change (a
# hand-written RPC, a MultiplayerSpawner) without the game logic above noticing.

func server_add_player(id: int, pos: Vector2) -> void:
	if players.has(id):
		return                      # idempotent: a duplicate spawn is harmless
	var node: Node = player_spawner.spawn({"id": id, "pos": pos})
	if node != null:
		gate(node)
	# `spawned` only fires on peers that *receive* a spawn, so the authority
	# registers its own. Clients get there through the signal.
	if node != null:
		_on_player_spawned(node)


func server_remove_player(id: int) -> void:
	if not players.has(id):
		return
	var node: Node = players[id]
	_on_player_despawned(node)      # same asymmetry as spawning
	node.queue_free()               # the spawner replicates the despawn


func server_add_item(kind: int, pos: Vector2, lifetime: float) -> int:
	var iid := _next_item_id
	_next_item_id += 1
	var c: Collectible = COLLECTIBLE_SCENE.instantiate()
	c.item_id = iid
	c.setup(kind, lifetime)
	c.position = pos
	gate(c)
	items_root.add_child(c, true)   # the spawner notices and replicates
	items[iid] = c                  # `spawned` is remote-only, so register ours
	return iid


## Server only: put a shot in the air. Returns its id, or 0 if the weapon was
## not ready -- too soon since the last shot, or not enough points to pay for it.
func server_fire(shooter: int, kind: int) -> int:
	if not players.has(shooter) or not Weapon.is_kind(kind):
		return 0
	var p: Node2D = players[shooter]
	if float(p.cooldowns.get(kind, 0.0)) > 0.0:
		return 0
	var price := Weapon.cost(kind)
	if price > 0 and int(scores.get(shooter, 0)) < price:
		return 0
	if price > 0:
		# Must be broadcast, not just applied here: with every weapon free this
		# was invisible, but a priced weapon would silently desync the score.
		scores_changed.rpc({shooter: int(scores.get(shooter, 0)) - price})
	p.cooldowns[kind] = Weapon.cooldown(kind)

	var dir: Vector2 = p.facing.normalized() if p.facing.length() > 0.001 else Vector2.RIGHT
	var sid := _next_shot_id
	_next_shot_id += 1
	var shot: Projectile = PROJECTILE_SCENE.instantiate()
	shot.shot_id = sid
	shot.setup(shooter, kind, dir * Weapon.speed(kind, SPEED), Weapon.lifespan(kind))
	shot.position = p.position + dir * MUZZLE_OFFSET
	gate(shot)
	shots_root.add_child(shot, true)
	shots[sid] = shot              # `spawned` is remote-only, so register ours
	return sid


func server_remove_shot(sid: int) -> void:
	if not shots.has(sid):
		return
	var node: Node = shots[sid]
	shots.erase(sid)
	node.queue_free()              # the spawner replicates the despawn


## `collector` is 0 when the item simply timed out. The despawn itself rides on
## the spawner; only the score and the sound need saying out loud.
func server_remove_item(iid: int, collector: int, new_score: int) -> void:
	if not items.has(iid):
		return
	var node: Collectible = items[iid]
	if collector != 0:
		# The despawn itself rides on the spawner; this carries only the score
		# and the kind, which is all the collector needs to play its sound.
		item_collected.rpc(collector, new_score, node.kind)
	items.erase(iid)                # same asymmetry: despawned is remote-only
	_desired_items = randi_range(MIN_ITEMS, MAX_ITEMS)
	node.queue_free()


# --- rpcs --------------------------------------------------------------------

## Firing is an *event*, so it is reliable and separate from the 60 Hz movement
## stream: "reliable for events, unreliable for state". A dropped shot would be
## a shot the player believes they took.
@rpc("any_peer", "call_local", "reliable")
func request_fire(kind: int) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1                     # the host called it on itself
	if not Weapon.is_kind(kind):
		return                     # never trust an any_peer argument
	server_fire(id, kind)


## The freeze itself replicates through the synchronizer; this is the event, so
## the victim gets an immediate local reaction rather than waiting for the next
## 20 Hz sync to notice it has stopped moving.
## A score moved for a reason other than picking something up: paying for a
## shot, or having a point lifted. Small enough to be its own reliable event.
@rpc("authority", "call_local", "reliable")
func scores_changed(changed: Dictionary) -> void:
	for pid in changed:
		scores[pid] = int(changed[pid])
	refresh_hud()


@rpc("authority", "call_local", "reliable")
func points_stolen(thief: int, victim: int, amount: int) -> void:
	if thief == multiplayer.get_unique_id():
		say("Lifted %d point%s from %s" % [
			amount, "" if amount == 1 else "s", game.label_for(victim)])
	elif victim == multiplayer.get_unique_id():
		say("%s picked your pocket (-%d)" % [game.label_for(thief), amount])


@rpc("authority", "call_local", "reliable")
func player_frozen(pid: int, seconds: float) -> void:
	if players.has(pid):
		players[pid].frozen_remaining = seconds
	if pid == multiplayer.get_unique_id():
		pending.clear()            # predictions made while moving are void now
		say("Frozen for %.0f seconds" % seconds)


@rpc("authority", "call_local", "reliable")
func item_collected(collector: int, new_score: int, kind: int) -> void:
	scores[collector] = new_score
	if collector == multiplayer.get_unique_id() and not game.is_dedicated:
		play_pickup(kind)
	refresh_hud()
	print("[%d] %d picked up, now on %d" % [multiplayer.get_unique_id(), collector, new_score])


@rpc("any_peer", "call_local", "unreliable_ordered")
func submit_input(tick: int, dir: Vector2) -> void:
	if not multiplayer.is_server():
		return                                  # clients ignore this entirely
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1                                  # host called it on itself
	submit_input_for(id, tick, dir)


## The validation, separated from "who sent it". Everything here treats its
## arguments as hostile, because `submit_input` is reachable by anyone.
func submit_input_for(id: int, tick: int, dir: Vector2) -> void:
	if not players.has(id):
		return
	var p: Node2D = players[id]
	var newest: int = p.input_queue[-1]["tick"] if not p.input_queue.is_empty() else p.last_tick
	if tick <= newest:
		return                                  # stale, duplicated or replayed
	if p.input_queue.size() >= INPUT_QUEUE_CAP:
		p.input_queue.pop_front()               # flooding client: drop the oldest
	p.input_queue.append({"tick": tick, "dir": dir.limit_length(1.0)})   # never trust the magnitude


## Everyone regenerates the identical grid from `seed_value`; only the seed travels.
## Players are repositioned because the new layout may have dropped a wall on them.
@rpc("authority", "call_local", "reliable")
func set_maze(seed_value: int, placements: Dictionary, winner: int, standings: Dictionary,
		round_no: int) -> void:
	_apply_maze(seed_value)
	if multiplayer.is_server():
		_clear_items()         # clients get a despawn per item from the spawner
		_clear_shots()
	for id in players:
		players[id].frozen_remaining = 0.0
		players[id].cooldowns.clear()
	rounds_won = standings.duplicate()
	round_index = round_no
	for id in scores:
		scores[id] = 0                 # a new maze is a new round
	if winner != 0:
		banner("%s wins round %d\n%d of %d" % [
			game.label_for(winner), round_no - 1, int(rounds_won.get(winner, 0)), GAME_WINS])
	refresh_hud()
	for id in placements:
		if not players.has(id):
			continue
		var p: Node2D = players[id]
		p.position = placements[id]
		p.target_position = placements[id]
		p.input_queue.clear()
	pending.clear()   # predictions made against the old walls mean nothing now
	print("[%d] maze regenerated, seed %d" % [multiplayer.get_unique_id(), seed_value])


## One finished round. Sent as it happens, and replayed one-at-a-time to late
## joiners, so the history is never shipped as a single oversized payload.
@rpc("authority", "call_local", "reliable")
func record_round(round_no: int, winner: int, final_scores: Dictionary) -> void:
	for entry in round_history:
		if int(entry["round"]) == round_no:
			return                     # idempotent
	round_history.append({"round": round_no, "winner": winner, "scores": final_scores})


@rpc("authority", "call_local", "reliable")
func game_over(winner: int, standings: Dictionary, round_no: int) -> void:
	game_finished = true
	rounds_won = standings.duplicate()
	round_index = round_no
	game.show_game_over(self, winner)


## Anyone at the results screen may start the next game.
@rpc("any_peer", "call_local", "reliable")
func request_restart() -> void:
	if not multiplayer.is_server() or not game_finished:
		return
	for id in rounds_won:
		rounds_won[id] = 0
	for id in scores:
		scores[id] = 0
	round_history.clear()
	round_index = 1
	restart_game.rpc()
	_new_maze(0)


@rpc("authority", "call_local", "reliable")
func restart_game() -> void:
	game_finished = false
	round_history.clear()
	round_index = 1
	for id in rounds_won:
		rounds_won[id] = 0
	refresh_hud()


## Shared state a late joiner cannot infer from the spawn RPCs.
@rpc("authority", "reliable")
func sync_world(seed_value: int, all_scores: Dictionary, standings: Dictionary,
		round_no: int, finished: bool) -> void:
	_apply_maze(seed_value)
	scores = all_scores.duplicate()
	rounds_won = standings.duplicate()
	round_index = round_no
	game_finished = finished
	# Deliberately does NOT clear items: the spawner has already replayed every
	# live one to us, and wiping them here is exactly how they went missing.
	round_history.clear()
	refresh_hud()


# --- reconciliation ----------------------------------------------------------

## Snap to the authority, then replay every input it had not seen yet.
##
## If the server agreed with our prediction the replay lands exactly where we
## already were and nothing visibly happens. If it disagreed — we were blocked,
## pushed, or lying — we jump to the corrected position.
func _reconcile(p: Node2D, authoritative: Vector2, acked_tick: int) -> void:
	while not pending.is_empty() and int(pending[0]["tick"]) <= acked_tick:
		pending.pop_front()
	var pos := authoritative
	for entry in pending:
		pos = simulate(maze, pos, entry["dir"], entry["delta"])
	p.position = pos
	p.target_position = pos


# --- helpers -----------------------------------------------------------------

func _apply_maze(seed_value: int) -> void:
	maze_seed = seed_value
	maze.generate(seed_value, ARENA)
	maze.queue_redraw()


## Server only: bank the round, then either end the game or deal a new maze.
func _finish_round(winner: int) -> void:
	rounds_won[winner] = int(rounds_won.get(winner, 0)) + 1
	record_round.rpc(round_index, winner, scores.duplicate())
	round_index += 1
	if int(rounds_won[winner]) >= GAME_WINS:
		game_over.rpc(winner, rounds_won, round_index)
	else:
		_new_maze(winner)


## Server only: start a round. `winner` is 0 for the very first one.
func _new_maze(winner: int = 0) -> void:
	var seed_value := randi()
	_apply_maze(seed_value)                  # generate first, so _open_spawn() has a grid
	var placements := {}
	for id in players:
		placements[id] = _open_spawn()
	set_maze.rpc(seed_value, placements, winner, rounds_won, round_index)


## Server only: the spawner replicates each despawn.
func _clear_shots() -> void:
	for sid in shots.keys():
		if is_instance_valid(shots[sid]):
			shots[sid].queue_free()
	shots.clear()


func _clear_items() -> void:
	for iid in items.keys():
		items[iid].queue_free()
	items.clear()


func _open_spawn() -> Vector2:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return maze.random_open_point(rng)

