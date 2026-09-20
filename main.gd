# MAIN ENTRYPOINT OF GAME
extends Node2D

const DEFAULT_PORT := 9000
const MAX_PLAYERS := 8
const SPEED := 220.0
const ARENA := Vector2(2304, 1296)  # a game rule, not a window size
const HALF := Vector2(16, 16)
const WIN_SCORE := 25            # points that win the round; the maze then regenerates
const ANNOUNCE_SECONDS := 4.0
const ICONS: Array[String] = ["🐱", "🐶", "🦊", "🐸", "🐵", "🐙", "🦄", "🐝", "🦖", "🐧"]
const MIN_ITEMS := 3             # how many collectibles are in the maze at once
const MAX_ITEMS := 5
const LIFETIME_MIN := 8.0        # seconds a collectible survives before it rots away
const LIFETIME_MAX := 18.0
const INPUT_BUFFER_MAX := 4         # queue longer than this: the client has run ahead
const INPUT_QUEUE_CAP := 16         # hard cap, so a flooding client cannot grow it forever
const PLAYER_SCENE := preload("res://player.tscn")

var players: Dictionary = {}   # peer_id:int -> Player node
var scores: Dictionary = {}    # peer_id:int -> points this round
var rounds_won: Dictionary = {}  # peer_id:int -> rounds won
var icons: Dictionary = {}     # peer_id:int -> index into ICONS
var is_dedicated := false
var maze_seed := 0             # server: the seed every peer is currently generating from
var items: Dictionary = {}     # item_id:int -> Collectible node
var _next_item_id := 1         # server: hands out item ids
var _desired_items := MIN_ITEMS
## Godot hands every tree an OfflineMultiplayerPeer, so `multiplayer_peer != null`
## and `is_server()` are both true before you have hosted or joined anything.
## Track the session explicitly instead of trusting either of them.
var in_session := false
var _announce_until := 0.0
var port := DEFAULT_PORT       # overridden by `-- --port N`

# Client-side prediction bookkeeping.
var input_tick := 0            # monotonically increasing sequence number
var pending: Array = []        # inputs sent but not yet acknowledged by the server

@onready var players_root: Node2D = $Players
@onready var maze: Maze = $Maze
@onready var items_root: Node2D = $Collectibles
@onready var broadcast_timer: Timer = $BroadcastTimer
@onready var lobby: CanvasLayer = $Lobby
@onready var ip_field: LineEdit = $Lobby/VBoxContainer/IpField
@onready var status: Label = $Lobby/VBoxContainer/StatusLabel
@onready var score_label: Label = $Hud/ScoreLabel
@onready var announce_label: Label = $Hud/AnnounceLabel
@onready var camera: Camera2D = $Camera2D
@onready var icon_picker: OptionButton = $Lobby/VBoxContainer/IconPicker

func _ready() -> void:
	_setup_camera()
	_setup_icon_picker()
	announce_label.text = ""
	_connect_multiplayer_signals()
	var args := OS.get_cmdline_user_args()
	port = _port_from_args(args)
	is_dedicated = "--server" in args or OS.has_feature("dedicated_server")
	if is_dedicated:
		_start_dedicated_server()

func _connect_multiplayer_signals() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _start_dedicated_server() -> void:
	lobby.hide()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		push_error("Cannot bind port %d: %s" % [port, error_string(err)])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	in_session = true
	_new_maze()
	broadcast_timer.start()
	print("Dedicated server listening on UDP %d" % port)

# --- the simulation ----------------------------------------------------------

## The one movement rule, as a pure function of (state, input, delta).
##
## Reconciliation replays this over buffered inputs, so it must read nothing
## outside its arguments — no `Input`, no node state, no randomness. That purity
## is the whole reason client and server can agree on where a square ended up.
static func simulate(pos: Vector2, dir: Vector2, delta: float) -> Vector2:
	var step := dir.limit_length(1.0) * SPEED * delta
	var out := pos
	# If we somehow start inside a wall, let every move through rather than
	# blocking all four directions and trapping the player there forever.
	var stuck := Maze.is_blocked(pos, HALF.x)
	# Resolve each axis separately, so running into a wall diagonally slides
	# along it instead of stopping dead. Both peers do this identically.
	var try_x := Vector2(out.x + step.x, out.y)
	if stuck or not Maze.is_blocked(try_x, HALF.x):
		out = try_x
	var try_y := Vector2(out.x, out.y + step.y)
	if stuck or not Maze.is_blocked(try_y, HALF.y):
		out = try_y
	return out.clamp(HALF, ARENA - HALF)

func _setup_camera() -> void:
	# The arena is four viewports big now, so the view follows you.
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = int(ARENA.x)
	camera.limit_bottom = int(ARENA.y)
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 8.0
	camera.position = ARENA * 0.5

## Two fonts, because order decides whose metrics win. Emoji-first makes Latin
## text inherit the emoji font's fixed advance width and come out spaced like
## "1 7 / 2 5", so anything with words in it needs the text face first.
func _emoji_font(text_first: bool) -> SystemFont:
	var f := SystemFont.new()
	var emoji := ["Noto Color Emoji", "Segoe UI Emoji", "Apple Color Emoji", "Noto Emoji"]
	var names: Array = (["sans-serif"] + emoji) if text_first else (emoji + ["sans-serif"])
	f.font_names = PackedStringArray(names)
	return f

func _setup_icon_picker() -> void:
	icon_picker.add_theme_font_override("font", _emoji_font(false))
	icon_picker.add_theme_font_size_override("font_size", 22)
	score_label.add_theme_font_override("font", _emoji_font(true))
	announce_label.add_theme_font_override("font", _emoji_font(true))
	for i in ICONS.size():
		icon_picker.add_item(ICONS[i], i)
	icon_picker.selected = randi() % ICONS.size()

func _process(_delta: float) -> void:
	if is_dedicated:
		return
	if in_session:
		var me := multiplayer.get_unique_id()
		if players.has(me):
			camera.position = players[me].position
	if announce_label.text != "" and Time.get_unix_time_from_system() > _announce_until:
		announce_label.text = ""

func _physics_process(delta: float) -> void:
	if not in_session:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return                      # still handshaking: an RPC now is an error, not a no-op
	if multiplayer.is_server():
		_server_simulate(delta)
	if not is_dedicated:
		_send_input(delta)          # no keyboard on a VPS

func _send_input(delta: float) -> void:
	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
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
	var p: Node2D = players[me]
	p.position = simulate(p.position, dir, delta)
	p.target_position = p.position
	pending.append({"tick": input_tick, "dir": dir, "delta": delta})

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
			p.position = simulate(p.position, p.input_dir, delta)
			consumed += 1
		if consumed == 0:
			# Nothing arrived in time. Assume they are still holding the same
			# key; if that guess is wrong, reconciliation fixes it.
			p.position = simulate(p.position, p.input_dir, delta)
	_expire_items(delta)
	_check_pickup()
	_top_up_items()

func _check_pickup() -> void:
	var reach := Collectible.RADIUS + HALF.x
	for pid in players:
		var ppos: Vector2 = players[pid].position
		for iid in items.keys():
			var item: Collectible = items[iid]
			if ppos.distance_to(item.position) > reach:
				continue
			var after := int(scores.get(pid, 0)) + int(Collectible.VALUE[item.kind])
			scores[pid] = after
			remove_item.rpc(iid, pid, after)
			# `>=`, not `==`: a 5-point diamond can jump 22 straight past 25.
			if after >= WIN_SCORE:
				rounds_won[pid] = int(rounds_won.get(pid, 0)) + 1
				_new_maze(pid)
				return                     # the new round replaced every item
			break                          # this player has had their pickup this tick

## Server only: retire anything that has outlived its lifespan.
func _expire_items(delta: float) -> void:
	for iid in items.keys():
		var item: Collectible = items[iid]
		item.age += delta                  # the server ages them too; it does not _process
		if item.age >= item.lifetime:
			remove_item.rpc(iid, 0, 0)     # peer 0 == nobody collected it

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
	var id := _next_item_id
	_next_item_id += 1
	spawn_item.rpc(id, Collectible.random_kind(rng), pos,
		rng.randf_range(LIFETIME_MIN, LIFETIME_MAX))
	return true

## An open cell that no other collectible is already sitting in.
func _free_item_point(rng: RandomNumberGenerator) -> Vector2:
	for _attempt in 24:
		var p := Maze.random_open_point(rng)
		if p == Vector2.ZERO:
			return Vector2.ZERO
		var clear := true
		for iid in items:
			if items[iid].position.distance_to(p) < Collectible.RADIUS * 3.0:
				clear = false
				break
		if clear:
			return p
	return Maze.random_open_point(rng)

func _on_broadcast_timer_timeout() -> void:
	if not multiplayer.is_server() or players.is_empty():
		return
	var state := {}
	var acks := {}
	for id in players:
		state[id] = players[id].position
		acks[id] = players[id].last_tick
	update_state.rpc(state, acks)

# --- lobby -------------------------------------------------------------------

func _on_host_button_pressed() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		_set_status("Cannot host: %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	in_session = true
	lobby.hide()
	request_icon.rpc_id(1, icon_picker.selected)
	_set_status("Hosting on %d, I am peer %d" % [port, multiplayer.get_unique_id()])
	_new_maze()
	broadcast_timer.start()
	spawn_player.rpc(1, _open_spawn())     # "call_local" means this also runs here

func _on_join_button_pressed() -> void:
	# A tunnel (playit.gg) hands out an arbitrary public port, so the field
	# accepts "host:port" as well as a bare host.
	var target := _split_address(ip_field.text)
	var host: String = target[0]
	var target_port: int = target[1]
	if host.is_empty():
		_set_status("Enter an address to join")
		return
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, target_port)
	if err != OK:
		_set_status("Cannot join: %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	_set_status("Connecting to %s:%d..." % [host, target_port])

# --- signal handlers ---------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	print("[%d] peer_connected: %d" % [multiplayer.get_unique_id(), id])
	if not multiplayer.is_server():
		return
	# 1. the shared world first, so the newcomer can collide before it can move
	sync_world.rpc_id(id, maze_seed, scores, rounds_won, icons, _item_snapshot())
	# 2. catch the newcomer up on everyone already here
	for existing_id in players:
		spawn_player.rpc_id(id, existing_id, players[existing_id].position)
	# 3. tell everyone (including this server) about the newcomer
	spawn_player.rpc(id, _open_spawn())

func _on_peer_disconnected(id: int) -> void:
	print("[%d] peer_disconnected: %d" % [multiplayer.get_unique_id(), id])
	if not multiplayer.is_server():
		return
	despawn_player.rpc(id)

func _on_connected_to_server() -> void:
	in_session = true
	lobby.hide()
	request_icon.rpc_id(1, icon_picker.selected)
	_set_status("Connected, I am peer %d" % multiplayer.get_unique_id())

func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	_clear_world()
	_set_status("Connection failed")

func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	_clear_world()
	lobby.show()
	_set_status("Server disconnected")

# --- rpcs --------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func spawn_player(id: int, pos: Vector2) -> void:
	if players.has(id):
		return                     # idempotent: a duplicate spawn is harmless
	var p := PLAYER_SCENE.instantiate()
	p.setup(id)
	p.position = pos
	p.target_position = pos
	# The server simulates every square itself. A client predicts only its own
	# and interpolates everyone else's toward the broadcast position.
	p.is_local_authority = multiplayer.is_server() or id == multiplayer.get_unique_id()
	players_root.add_child(p)
	players[id] = p
	if not scores.has(id):
		scores[id] = 0
	if not rounds_won.has(id):
		rounds_won[id] = 0
	p.set_icon(ICONS[int(icons.get(id, 0))])
	_refresh_scores()
	print("[%d] spawned %d at %s" % [multiplayer.get_unique_id(), id, pos])

@rpc("authority", "call_local", "reliable")
func despawn_player(id: int) -> void:
	if not players.has(id):
		return
	players[id].queue_free()
	players.erase(id)
	scores.erase(id)
	rounds_won.erase(id)
	icons.erase(id)
	_refresh_scores()
	print("[%d] despawned %d" % [multiplayer.get_unique_id(), id])

@rpc("any_peer", "call_local", "unreliable_ordered")
func submit_input(tick: int, dir: Vector2) -> void:
	if not multiplayer.is_server():
		return                                  # clients ignore this entirely
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1                                  # host called it on itself
	if not players.has(id):
		return
	var p: Node2D = players[id]
	var newest: int = p.input_queue[-1]["tick"] if not p.input_queue.is_empty() else p.last_tick
	if tick <= newest:
		return                                  # stale, duplicated or replayed
	if p.input_queue.size() >= INPUT_QUEUE_CAP:
		p.input_queue.pop_front()               # flooding client: drop the oldest
	p.input_queue.append({"tick": tick, "dir": dir.limit_length(1.0)})   # never trust the magnitude

@rpc("authority", "unreliable")
func update_state(state: Dictionary, acks: Dictionary) -> void:
	if multiplayer.is_server():
		return                       # the server already has the truth
	var me := multiplayer.get_unique_id()
	for id in state:
		if not players.has(id):
			continue
		var p: Node2D = players[id]
		if id == me:
			_reconcile(p, state[id], int(acks.get(id, 0)))
		else:
			p.target_position = state[id]    # _process eases toward it

@rpc("authority", "call_local", "reliable")
func spawn_item(id: int, kind: int, pos: Vector2, lifetime: float) -> void:
	if items.has(id):
		return
	var c := Collectible.new()
	c.name = "item_%d" % id
	c.setup(kind, lifetime)
	c.position = pos
	items_root.add_child(c)
	items[id] = c

## `collector` is 0 when the item simply timed out.
@rpc("authority", "call_local", "reliable")
func remove_item(id: int, collector: int, new_score: int) -> void:
	if not items.has(id):
		return
	var c: Collectible = items[id]
	items.erase(id)
	c.queue_free()
	_desired_items = randi_range(MIN_ITEMS, MAX_ITEMS)
	if collector == 0:
		return
	scores[collector] = new_score
	_refresh_scores()
	print("[%d] %d picked up %s, now on %d" % [
		multiplayer.get_unique_id(), collector,
		Collectible.Kind.keys()[c.kind], new_score])

## Clients ask for an icon; the server is the one that tells everybody.
@rpc("any_peer", "call_local", "reliable")
func request_icon(index: int) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1                                  # host called it on itself
	if index < 0 or index >= ICONS.size():
		return                                  # never trust an any_peer argument
	icons[id] = index
	apply_icon.rpc(id, index)

@rpc("authority", "call_local", "reliable")
func apply_icon(id: int, index: int) -> void:
	if index < 0 or index >= ICONS.size():
		return
	icons[id] = index
	if players.has(id):
		players[id].set_icon(ICONS[index])
	_refresh_scores()

## Everyone regenerates the identical grid from `seed_value`; only the seed travels.
## Players are repositioned because the new layout may have dropped a wall on them.
@rpc("authority", "call_local", "reliable")
func set_maze(seed_value: int, placements: Dictionary, winner: int, standings: Dictionary) -> void:
	_apply_maze(seed_value)
	_clear_items()
	rounds_won = standings.duplicate()
	for id in scores:
		scores[id] = 0                 # a new maze is a new round
	if winner != 0:
		_announce("%s wins the round!  (%d total)" % [_label_for(winner), int(rounds_won.get(winner, 0))])
	_refresh_scores()
	for id in placements:
		if not players.has(id):
			continue
		var p: Node2D = players[id]
		p.position = placements[id]
		p.target_position = placements[id]
		p.input_queue.clear()
	pending.clear()   # predictions made against the old walls mean nothing now
	print("[%d] maze regenerated, seed %d" % [multiplayer.get_unique_id(), seed_value])

## Shared state a late joiner cannot infer from the spawn RPCs.
@rpc("authority", "reliable")
func sync_world(seed_value: int, all_scores: Dictionary, standings: Dictionary,
		all_icons: Dictionary, snapshot: Array) -> void:
	_apply_maze(seed_value)
	scores = all_scores.duplicate()
	rounds_won = standings.duplicate()
	icons = all_icons.duplicate()
	_clear_items()
	for entry in snapshot:
		# `lifetime` here is what is LEFT, so the newcomer's blink-out lines up
		# with everyone else's rather than restarting the clock.
		spawn_item(int(entry["id"]), int(entry["kind"]), entry["pos"], float(entry["left"]))
	_refresh_scores()

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
		pos = simulate(pos, entry["dir"], entry["delta"])
	p.position = pos
	p.target_position = pos

# --- address parsing ---------------------------------------------------------

## Reads `--port N` or `--port=N` out of the user args (everything after a bare `--`).
func _port_from_args(args: PackedStringArray) -> int:
	for i in args.size():
		var a := args[i]
		if a == "--port" and i + 1 < args.size():
			return _parse_port(args[i + 1], DEFAULT_PORT)
		if a.begins_with("--port="):
			return _parse_port(a.trim_prefix("--port="), DEFAULT_PORT)
	return DEFAULT_PORT

func _parse_port(text: String, fallback: int) -> int:
	var s := text.strip_edges()
	if not s.is_valid_int():
		push_error("Not a port number: '%s', using %d" % [s, fallback])
		return fallback
	var n := s.to_int()
	if n < 1 or n > 65535:
		push_error("Port %d out of range, using %d" % [n, fallback])
		return fallback
	return n

## Splits "host", "host:port" or "[ipv6]:port" into [host, port], defaulting to `port`.
func _split_address(text: String) -> Array:
	var s := text.strip_edges()
	if s.begins_with("["):                      # bracketed IPv6 literal
		var close := s.find("]")
		if close != -1:
			var rest := s.substr(close + 1)
			var host := s.substr(1, close - 1)
			if rest.begins_with(":"):
				return [host, _parse_port(rest.substr(1), port)]
			return [host, port]
	var bits := s.split(":")
	if bits.size() == 2:                        # host:port
		return [bits[0].strip_edges(), _parse_port(bits[1], port)]
	return [s, port]                            # bare host, or a bare IPv6 literal

# --- helpers -----------------------------------------------------------------

func _apply_maze(seed_value: int) -> void:
	maze_seed = seed_value
	Maze.generate(seed_value, ARENA)
	maze.queue_redraw()

## Server only: start a round. `winner` is 0 for the very first one.
func _new_maze(winner: int = 0) -> void:
	var seed_value := randi()
	_apply_maze(seed_value)                  # generate first, so _open_spawn() has a grid
	var placements := {}
	for id in players:
		placements[id] = _open_spawn()
	set_maze.rpc(seed_value, placements, winner, rounds_won)

func _item_snapshot() -> Array:
	var out := []
	for iid in items:
		var c: Collectible = items[iid]
		out.append({"id": iid, "kind": c.kind, "pos": c.position,
			"left": maxf(c.lifetime - c.age, 0.5)})
	return out

func _clear_items() -> void:
	for iid in items.keys():
		items[iid].queue_free()
	items.clear()

func _open_spawn() -> Vector2:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return Maze.random_open_point(rng)

func _label_for(id: int) -> String:
	var glyph: String = ICONS[int(icons.get(id, 0))]
	var me := multiplayer.get_unique_id() if in_session else 0
	return "%s %s" % [glyph, "you" if id == me else str(id)]

func _refresh_scores() -> void:
	if is_dedicated:
		return
	var ids: Array = scores.keys()
	ids.sort()
	var parts := PackedStringArray()
	for id in ids:
		parts.append("%s %d/%d  wins %d" % [
			_label_for(id), int(scores[id]), WIN_SCORE, int(rounds_won.get(id, 0))])
	score_label.text = "    ".join(parts)

func _announce(msg: String) -> void:
	print(msg)
	if is_dedicated:
		return
	announce_label.text = msg
	_announce_until = Time.get_unix_time_from_system() + ANNOUNCE_SECONDS

func _clear_world() -> void:
	in_session = false
	input_tick = 0
	pending.clear()
	_clear_items()
	rounds_won.clear()
	icons.clear()
	for id in players.keys():
		players[id].queue_free()
	players.clear()
	scores.clear()
	_refresh_scores()

func _set_status(msg: String) -> void:
	print(msg)
	status.text = msg
