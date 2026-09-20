extends Node2D

const DEFAULT_PORT := 9000
const MAX_PLAYERS := 8
const SPEED := 220.0
const ARENA := Vector2(1152, 648)   # a game rule, not a window size
const HALF := Vector2(16, 16)
const PICKUP_RADIUS := 24.0
const INPUT_BUFFER_MAX := 4         # queue longer than this: the client has run ahead
const INPUT_QUEUE_CAP := 16         # hard cap, so a flooding client cannot grow it forever
const PLAYER_SCENE := preload("res://player.tscn")

var players: Dictionary = {}   # peer_id:int -> Player node
var scores: Dictionary = {}    # peer_id:int -> int
var is_dedicated := false
var port := DEFAULT_PORT       # overridden by `-- --port N`

# Client-side prediction bookkeeping.
var input_tick := 0            # monotonically increasing sequence number
var pending: Array = []        # inputs sent but not yet acknowledged by the server

@onready var players_root: Node2D = $Players
@onready var dot: Node2D = $Dot
@onready var broadcast_timer: Timer = $BroadcastTimer
@onready var lobby: CanvasLayer = $Lobby
@onready var ip_field: LineEdit = $Lobby/VBoxContainer/IpField
@onready var status: Label = $Lobby/VBoxContainer/StatusLabel
@onready var score_label: Label = $Hud/ScoreLabel

func _ready() -> void:
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
	dot.position = _random_spawn()
	broadcast_timer.start()
	print("Dedicated server listening on UDP %d" % port)

# --- the simulation ----------------------------------------------------------

## The one movement rule, as a pure function of (state, input, delta).
##
## Reconciliation replays this over buffered inputs, so it must read nothing
## outside its arguments — no `Input`, no node state, no randomness. That purity
## is the whole reason client and server can agree on where a square ended up.
static func simulate(pos: Vector2, dir: Vector2, delta: float) -> Vector2:
	var moved := pos + dir.limit_length(1.0) * SPEED * delta
	return moved.clamp(HALF, ARENA - HALF)

func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer == null:
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
	_check_pickup()

func _check_pickup() -> void:
	for id in players:
		if players[id].position.distance_to(dot.position) > PICKUP_RADIUS:
			continue
		scores[id] = int(scores.get(id, 0)) + 1
		on_collected.rpc(id, scores[id], _random_spawn())
		return   # one per tick; a tie is broken by iteration order, the same way for everyone

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
	lobby.hide()
	_set_status("Hosting on %d, I am peer %d" % [port, multiplayer.get_unique_id()])
	dot.position = _random_spawn()
	broadcast_timer.start()
	spawn_player.rpc(1, _random_spawn())   # "call_local" means this also runs here

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
	# 1. catch the newcomer up on everyone already here
	for existing_id in players:
		spawn_player.rpc_id(id, existing_id, players[existing_id].position)
	# 2. tell everyone (including this server) about the newcomer
	spawn_player.rpc(id, _random_spawn())
	# 3. and on the shared world, which the spawn RPCs say nothing about
	sync_world.rpc_id(id, dot.position, scores)

func _on_peer_disconnected(id: int) -> void:
	print("[%d] peer_disconnected: %d" % [multiplayer.get_unique_id(), id])
	if not multiplayer.is_server():
		return
	despawn_player.rpc(id)

func _on_connected_to_server() -> void:
	lobby.hide()
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
	_refresh_scores()
	print("[%d] spawned %d at %s" % [multiplayer.get_unique_id(), id, pos])

@rpc("authority", "call_local", "reliable")
func despawn_player(id: int) -> void:
	if not players.has(id):
		return
	players[id].queue_free()
	players.erase(id)
	scores.erase(id)
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
func on_collected(peer_id: int, new_score: int, new_dot_pos: Vector2) -> void:
	scores[peer_id] = new_score
	dot.position = new_dot_pos
	_refresh_scores()
	print("[%d] %d collected, now on %d" % [multiplayer.get_unique_id(), peer_id, new_score])

## Shared state a late joiner cannot infer from the spawn RPCs.
@rpc("authority", "reliable")
func sync_world(dot_pos: Vector2, all_scores: Dictionary) -> void:
	dot.position = dot_pos
	scores = all_scores.duplicate()
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

func _random_spawn() -> Vector2:
	return Vector2(randf_range(100, ARENA.x - 100), randf_range(100, ARENA.y - 100))

func _refresh_scores() -> void:
	if is_dedicated:
		return
	var me := multiplayer.get_unique_id() if multiplayer.multiplayer_peer != null else 0
	var ids: Array = scores.keys()
	ids.sort()
	var parts := PackedStringArray()
	for id in ids:
		parts.append("%s %d" % ["you" if id == me else str(id), scores[id]])
	score_label.text = "   ".join(parts)

func _clear_world() -> void:
	input_tick = 0
	pending.clear()
	for id in players.keys():
		players[id].queue_free()
	players.clear()
	scores.clear()
	_refresh_scores()

func _set_status(msg: String) -> void:
	print(msg)
	status.text = msg
