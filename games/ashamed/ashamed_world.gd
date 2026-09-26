class_name AshamedWorld
extends GameWorld

## "Ashamed": a 2D side-scroller.
##
## A skeleton so far -- players appear standing on the ground and leave again.
## No gravity, no jumping, no movement, no input yet; what is here is only the
## handful of methods `GameWorld` asks of any game type.
##
## Side-on rather than top-down, which shows up in two places: the playfield is
## wide and short instead of square, and a spawn picks an x along the ground
## rather than a point anywhere in a rectangle.

## Wide, because you scroll along it. Height is roughly one screen.
const ARENA := Vector2(4608, 648)

## Where the floor is. Everything stands on this line until there is gravity.
const GROUND_Y := 520.0
const GROUND_COLOUR := Color(0.16, 0.17, 0.21)
const SKY_COLOUR := Color(0.09, 0.10, 0.14)

const HALF := Vector2(16, 16)
const RUN_SPEED := 300.0        # pixels/sec at full tilt
const GRAVITY := 1600.0         # pixels/sec/sec
const JUMP_SPEED := 620.0       # upward kick when you leave the floor
const TERMINAL_FALL := 1400.0   # so a long fall stays predictable

const INPUT_BUFFER_MAX := 4     # queue longer than this: the client has run ahead
const INPUT_QUEUE_CAP := 16     # hard cap, so a flooding client cannot grow it

var input_tick := 0             # client: monotonically increasing sequence number
var pending: Array = []         # client: inputs sent but not yet acknowledged
const PLAYER_SCENE := preload("res://games/ashamed/player.tscn")

var players: Dictionary = {}     # peer_id:int -> player node

@onready var players_root: Node2D = $Players
@onready var player_spawner: MultiplayerSpawner = $PlayerSpawner

# --- the four things a game type provides -------------------------------------

func _setup() -> void:
	_setup_input()
	player_spawner.spawn_function = _build_player
	player_spawner.spawned.connect(_on_player_spawned)
	player_spawner.despawned.connect(_on_player_despawned)
	set_status_line("← → to run    SPACE / W / ↑ to jump")

func server_prepare() -> void:
	pass                         # no spawn state to choose

func world_bounds() -> Rect2:
	return Rect2(Vector2.ZERO, ARENA)

func server_admit(peer: int) -> void:
	if players.has(peer):
		return
	# Along the ground, not anywhere in the box: this is a side-scroller.
	var spot := Vector2(randf_range(120.0, ARENA.x - 120.0), GROUND_Y)
	var node: Node = player_spawner.spawn({"id": peer, "pos": spot})
	# `spawned` only fires on peers that *receive* a spawn, so the authority
	# registers its own.
	if node != null:
		gate(node)
		_on_player_spawned(node)

func server_evict(peer: int) -> void:
	if not players.has(peer):
		return
	var node: Node = players[peer]
	_on_player_despawned(node)
	node.queue_free()            # the spawner replicates the despawn

# --- the simulation -----------------------------------------------------------

## The one movement rule, as a pure function of (state, input, delta).
##
## State is a position *and* a velocity, because gravity means you carry
## momentum between ticks. Reconciliation replays this over buffered inputs, so
## it must read nothing outside its arguments -- no `Input`, no node state.
static func simulate(pos: Vector2, vel: Vector2, grounded: bool,
		move: float, jump: bool, delta: float) -> Dictionary:
	var v := vel
	# Horizontal is direct rather than accelerated: it keeps replay cheap and
	# the controls crisp. Clamped, so a client cannot ask to run at any speed.
	v.x = clampf(move, -1.0, 1.0) * RUN_SPEED
	if jump and grounded:
		v.y = -JUMP_SPEED
	v.y = minf(v.y + GRAVITY * delta, TERMINAL_FALL)

	var p := pos + v * delta
	var on_floor := false
	if p.y >= GROUND_Y:
		p.y = GROUND_Y
		v.y = 0.0
		on_floor = true
	p.x = clampf(p.x, HALF.x, ARENA.x - HALF.x)
	return {"pos": p, "vel": v, "grounded": on_floor}

func _physics_process(delta: float) -> void:
	if game == null or not game.in_session:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return                      # still handshaking: an RPC now is an error
	if multiplayer.is_server():
		_server_simulate(delta)
	if is_local() and not game.is_dedicated:
		_send_input(delta)

func _send_input(delta: float) -> void:
	var move := Input.get_axis("ui_left", "ui_right")
	var jump := Input.is_action_just_pressed("ashamed_jump")
	input_tick += 1
	submit_input.rpc_id(1, input_tick, move, jump)
	if multiplayer.is_server():
		return                      # the host is the authority, nothing to predict
	var me := multiplayer.get_unique_id()
	if not players.has(me):
		return
	var p: Node2D = players[me]
	var r := simulate(p.position, p.velocity, p.grounded, move, jump, delta)
	p.position = r["pos"]
	p.velocity = r["vel"]
	p.grounded = bool(r["grounded"])
	p.target_position = p.position
	pending.append({"tick": input_tick, "move": move, "jump": jump, "delta": delta})

func _server_simulate(delta: float) -> void:
	for id in players:
		var p: Node2D = players[id]
		# Consume one queued input per tick so the server walks the same path
		# the client predicted. Drain two when the client has run ahead.
		var budget := 2 if p.input_queue.size() > INPUT_BUFFER_MAX else 1
		var consumed := 0
		while consumed < budget and not p.input_queue.is_empty():
			var inp: Dictionary = p.input_queue.pop_front()
			p.move = float(inp["move"])
			p.last_tick = int(inp["tick"])
			_step(p, p.move, bool(inp["jump"]), delta)
			consumed += 1
		if consumed == 0:
			# Nothing arrived in time. Keep them running the same way, but never
			# repeat a jump: a repeated edge would be a free second jump.
			_step(p, p.move, false, delta)
		p.net_position = p.position
		p.net_velocity = p.velocity
		p.net_grounded = p.grounded

func _step(p: Node2D, move: float, jump: bool, delta: float) -> void:
	var r := simulate(p.position, p.velocity, p.grounded, move, jump, delta)
	p.position = r["pos"]
	p.velocity = r["vel"]
	p.grounded = bool(r["grounded"])

## Snap to the authority, then replay every input it had not seen yet -- over
## both halves of the state, position and velocity.
func _reconcile(p: Node2D, acked_tick: int) -> void:
	while not pending.is_empty() and int(pending[0]["tick"]) <= acked_tick:
		pending.pop_front()
	var pos: Vector2 = p.net_position
	var vel: Vector2 = p.net_velocity
	var grounded: bool = p.net_grounded
	for entry in pending:
		var r := simulate(pos, vel, grounded, float(entry["move"]),
			bool(entry["jump"]), float(entry["delta"]))
		pos = r["pos"]
		vel = r["vel"]
		grounded = bool(r["grounded"])
	p.position = pos
	p.velocity = vel
	p.grounded = grounded
	p.target_position = pos

func _on_player_synchronized(node: Node) -> void:
	if multiplayer.is_server():
		return                      # the server already has the truth
	if node.peer_id == multiplayer.get_unique_id():
		_reconcile(node, node.last_tick)
	else:
		node.target_position = node.net_position

# --- input --------------------------------------------------------------------

## The validation, separated from "who sent it". Everything here treats its
## arguments as hostile, because `submit_input` is reachable by anyone.
@rpc("any_peer", "call_local", "unreliable_ordered")
func submit_input(tick: int, move: float, jump: bool) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1                      # the host called it on itself
	submit_input_for(id, tick, move, jump)

func submit_input_for(id: int, tick: int, move: float, jump: bool) -> void:
	if not players.has(id):
		return
	var p: Node2D = players[id]
	var newest: int = p.input_queue[-1]["tick"] if not p.input_queue.is_empty() else p.last_tick
	if tick <= newest:
		return                      # stale, duplicated or replayed
	if p.input_queue.size() >= INPUT_QUEUE_CAP:
		p.input_queue.pop_front()   # flooding client: drop the oldest
	p.input_queue.append({
		"tick": tick, "move": clampf(move, -1.0, 1.0), "jump": jump,
	})

func _setup_input() -> void:
	if InputMap.has_action("ashamed_jump"):
		return
	InputMap.add_action("ashamed_jump")
	for key in [KEY_SPACE, KEY_W, KEY_UP]:
		var ev := InputEventKey.new()
		ev.physical_keycode = key
		InputMap.action_add_event("ashamed_jump", ev)

# --- registry -----------------------------------------------------------------

func _build_player(data: Dictionary) -> Node:
	var p: Node2D = PLAYER_SCENE.instantiate()
	p.setup(int(data["id"]))
	p.position = data["pos"]
	p.net_position = data["pos"]
	p.target_position = data["pos"]
	# The server owns every body. A client predicts only its own and eases
	# everyone else toward whatever the synchronizer delivers.
	p.is_local_authority = multiplayer.is_server() \
		or int(data["id"]) == multiplayer.get_unique_id()
	return p

func _on_player_spawned(node: Node) -> void:
	var id: int = node.peer_id
	players[id] = node
	node.set_identity(game.ICONS[int(game.icons.get(id, 0))],
		str(game.names.get(id, "Player %d" % id)))
	node.get_node("Sync").synchronized.connect(_on_player_synchronized.bind(node))
	_refresh()

func _on_player_despawned(node: Node) -> void:
	players.erase(node.peer_id)
	_refresh()

## A horizon and a floor, so it reads as side-on at a glance. A real level would
## replace this with actual geometry.
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(ARENA.x, GROUND_Y + 16.0)), SKY_COLOUR)
	draw_rect(Rect2(Vector2(0.0, GROUND_Y + 16.0),
		Vector2(ARENA.x, ARENA.y - GROUND_Y - 16.0)), GROUND_COLOUR)
	# Stripes along the floor, so scrolling is visible before anything moves.
	var mark := Color(0.24, 0.26, 0.32)
	var x := 0.0
	while x < ARENA.x:
		draw_rect(Rect2(Vector2(x, GROUND_Y + 16.0), Vector2(4.0, 10.0)), mark)
		x += 128.0

func _refresh() -> void:
	var who := PackedStringArray()
	var ids: Array = players.keys()
	ids.sort()
	for id in ids:
		who.append(game.label_for(id))
	set_score_line("here: %s" % ", ".join(who) if who.size() > 0 else "here: nobody")
