class_name AshamedWorld
extends GameWorld

## "Ashamed": a 2.5D side-scroller.
##
## Drawn side-on, but the floor is a *plane* rather than a line: you run along
## it, walk into and out of the screen, and jump off it. There is no third axis
## in the engine -- every node is still a `Node2D` at a screen position -- so
## the depth is entirely a convention this file maintains and `project()`
## flattens.
##
## A body has three numbers, and it is worth being precise about them because
## they are easy to confuse:
##
##     ground.x   along the level, left and right
##     ground.y   *depth* -- into the screen, away from the camera
##     height     off the floor, which is what jumping changes
##
## None of those is a screen coordinate. `project()` turns them into one, and
## nothing else in the game is allowed to care how. Depth reads as perspective
## twice over: further away is drawn higher up and smaller.

## Wide, because you scroll along it. `y` here is the screen height, not depth.
const ARENA := Vector2(4608, 648)

## How far back the floor goes, in world units.
const DEPTH_RANGE := 240.0

## The floor band on screen: depth 0 draws here, DEPTH_RANGE draws up there.
const GROUND_NEAR_Y := 566.0
const GROUND_FAR_Y := 398.0

## How much smaller the far edge of the floor is than the near edge.
const FAR_SCALE := 0.60

## Distance from the eye to the near edge of the floor, in the same units as
## depth. Smaller means a wider-angle lens and a more dramatic recession.
const FOCAL := 165.0

const GROUND_COLOUR := Color(0.16, 0.17, 0.21)
const GROUND_FAR_COLOUR := Color(0.11, 0.12, 0.16)
const SKY_COLOUR := Color(0.09, 0.10, 0.14)

const HALF := Vector2(16, 16)
const RUN_SPEED := 300.0        # pixels/sec along the level
const DEPTH_SPEED := 190.0      # a feel choice; the projection handles perspective
const GRAVITY := 1600.0         # units/sec/sec pulling `height` down
const JUMP_SPEED := 620.0       # upward kick when you leave the floor
const TERMINAL_FALL := 1400.0   # so a long fall stays predictable

const INPUT_BUFFER_MAX := 4     # queue longer than this: the client has run ahead
const INPUT_QUEUE_CAP := 16     # hard cap, so a flooding client cannot grow it

## The world x the camera is looking down, which the projection measures
## horizontal distance from. Cosmetic: the server never sets it and never
## needs to, because nothing about the simulation depends on the view.
var eye_x: float = 0.0

var input_tick := 0             # client: monotonically increasing sequence number
var pending: Array = []         # client: inputs sent but not yet acknowledged
const PLAYER_SCENE := preload("res://games/ashamed/player.tscn")

var players: Dictionary = {}     # peer_id:int -> player node

@onready var players_root: Node2D = $Players
@onready var player_spawner: MultiplayerSpawner = $PlayerSpawner

# --- the things a game type provides -------------------------------------

func _setup() -> void:
	_setup_input()
	player_spawner.spawn_function = _build_player
	player_spawner.spawned.connect(_on_player_spawned)
	player_spawner.despawned.connect(_on_player_despawned)
	set_status_line("← → along    ↑ ↓ into the screen    SPACE / W to jump")

func server_prepare() -> void:
	pass                         # no spawn state to choose

func world_bounds() -> Rect2:
	return Rect2(Vector2.ZERO, ARENA)

## Follow along the level, but hold the camera steady vertically: walking into
## the screen should move you up the floor, not drag the whole view with you.
func camera_focus(player: Node) -> Vector2:
	return Vector2(player.position.x, (GROUND_NEAR_Y + GROUND_FAR_Y) * 0.5)

func server_admit(peer: int) -> void:
	if players.has(peer):
		return
	# Somewhere on the floor plane: along it, and at some depth into it.
	var spot := Vector2(
		randf_range(120.0, ARENA.x - 120.0), randf_range(0.0, DEPTH_RANGE))
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

## How far back something *looks*, 0 at the front of the floor and 1 at the back.
##
## Not simply `depth / DEPTH_RANGE`. Under perspective, apparent distance goes
## as d/(d+focal), which is why equal steps into the screen bunch together
## toward the horizon. A linear ratio draws evenly spaced floor lines and reads
## as a flat ramp rather than a receding plane.
static func depth_ratio(depth: float) -> float:
	var d := clampf(depth, 0.0, DEPTH_RANGE)
	var k := d / (d + FOCAL)
	var k_max := DEPTH_RANGE / (DEPTH_RANGE + FOCAL)
	return k / k_max

## How much a world-space *length* shrinks at this depth. One factor, used for
## every length there is: the body's own size, the height of its jump, and how
## far sideways it sits from the camera. Using it for some and not others is
## what makes a pseudo-dimension look wrong.
static func depth_scale(depth: float) -> float:
	return lerpf(1.0, FAR_SCALE, depth_ratio(depth))

## Turn a position on the floor ratio back into a depth. `_draw` wants bands of
## even *screen* height, which are not bands of even depth.
static func depth_at_ratio(t: float) -> float:
	var k_max := DEPTH_RANGE / (DEPTH_RANGE + FOCAL)
	var u := clampf(t, 0.0, 1.0) * k_max
	return FOCAL * u / (1.0 - u)

## World -> screen. The only place the pseudo-3D lives.
##
## `eye_x` is the world x the camera looks down: the axis distance is measured
## from. Two lengths foreshorten here, both by `depth_scale`:
##
##   * `height`, so a jump made far away is drawn as small as the body making
##     it. The jump itself is unchanged -- `simulate` neither knows nor cares
##     how deep you are, and the apex is the same number of world units
##     everywhere. Only the drawing of it shrinks.
##   * horizontal distance from the eye, so the floor recedes to a vanishing
##     point instead of staying a full-width band with small figures on it.
##     A body on the camera's own axis has no such distance, so the player you
##     control never slides sideways when they walk in.
static func project(ground: Vector2, height: float, eye_x: float) -> Vector2:
	var k := depth_scale(ground.y)
	return Vector2(
		eye_x + (ground.x - eye_x) * k,
		lerpf(GROUND_NEAR_Y, GROUND_FAR_Y, depth_ratio(ground.y)) - height * k)

## Nearer bodies draw in front of further ones.
static func depth_z(depth: float) -> int:
	return int(round(lerpf(64.0, 0.0, depth_ratio(depth))))

## The one movement rule, as a pure function of (state, input, delta).
##
## `ground` moves on the floor plane, `height` and `v_height` are the jump.
## Keeping them apart is what makes this 2.5D rather than a platformer: gravity
## acts on `height` alone and never touches depth.
##
## Reconciliation replays this over buffered inputs, so it reads nothing outside
## its arguments -- no `Input`, no node state, no projection.
static func simulate(ground: Vector2, height: float, v_height: float, grounded: bool,
		move: Vector2, jump: bool, delta: float) -> Dictionary:
	var vh := v_height
	if jump and grounded:
		vh = JUMP_SPEED
	vh = maxf(vh - GRAVITY * delta, -TERMINAL_FALL)
	var h := height + vh * delta
	var on_floor := false
	if h <= 0.0:
		h = 0.0
		vh = 0.0
		on_floor = true

	# Clamp each axis, then the vector, so a diagonal is not faster than a
	# straight line and a client cannot ask to run at any speed it likes.
	var m := Vector2(clampf(move.x, -1.0, 1.0), clampf(move.y, -1.0, 1.0))
	if m.length() > 1.0:
		m = m.normalized()
	var g := ground
	g.x = clampf(g.x + m.x * RUN_SPEED * delta, HALF.x, ARENA.x - HALF.x)
	g.y = clampf(g.y + m.y * DEPTH_SPEED * delta, 0.0, DEPTH_RANGE)
	return {"ground": g, "height": h, "v_height": vh, "grounded": on_floor}

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
	# Arrows walk the floor plane; up and down are depth, not jumping.
	var move := Vector2(
		Input.get_axis("ui_left", "ui_right"),
		Input.get_axis("ui_down", "ui_up"))
	var jump := Input.is_action_just_pressed("ashamed_jump")
	input_tick += 1
	submit_input.rpc_id(1, input_tick, move, jump)
	if multiplayer.is_server():
		return                      # the host is the authority, nothing to predict
	var me := multiplayer.get_unique_id()
	if not players.has(me):
		return
	var p: Node2D = players[me]
	_step(p, move, jump, delta)
	p.target_ground = p.ground
	p.target_height = p.height
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
			p.move = inp["move"]
			p.last_tick = int(inp["tick"])
			_step(p, p.move, bool(inp["jump"]), delta)
			consumed += 1
		if consumed == 0:
			# Nothing arrived in time. Keep them walking the same way, but never
			# repeat a jump: a repeated edge would be a free second jump.
			_step(p, p.move, false, delta)
		p.net_ground = p.ground
		p.net_height = p.height
		p.net_v_height = p.v_height
		p.net_grounded = p.grounded

func _step(p: Node2D, move: Vector2, jump: bool, delta: float) -> void:
	var r := simulate(p.ground, p.height, p.v_height, p.grounded, move, jump, delta)
	p.ground = r["ground"]
	p.height = float(r["height"])
	p.v_height = float(r["v_height"])
	p.grounded = bool(r["grounded"])

## Snap to the authority, then replay every input it had not seen yet -- over
## both halves of the state, position and velocity.
func _reconcile(p: Node2D, acked_tick: int) -> void:
	while not pending.is_empty() and int(pending[0]["tick"]) <= acked_tick:
		pending.pop_front()
	var g: Vector2 = p.net_ground
	var h: float = p.net_height
	var vh: float = p.net_v_height
	var grounded: bool = p.net_grounded
	for entry in pending:
		var r := simulate(g, h, vh, grounded, entry["move"],
			bool(entry["jump"]), float(entry["delta"]))
		g = r["ground"]
		h = float(r["height"])
		vh = float(r["v_height"])
		grounded = bool(r["grounded"])
	p.ground = g
	p.height = h
	p.v_height = vh
	p.grounded = grounded
	p.target_ground = g
	p.target_height = h

func _on_player_synchronized(node: Node) -> void:
	if multiplayer.is_server():
		return                      # the server already has the truth
	if node.peer_id == multiplayer.get_unique_id():
		_reconcile(node, node.last_tick)
	else:
		# Interpolate the *world* values and project afterwards; easing a screen
		# position would slide bodies through the perspective rather than across
		# the floor.
		node.target_ground = node.net_ground
		node.target_height = node.net_height

# --- input --------------------------------------------------------------------

## The validation, separated from "who sent it". Everything here treats its
## arguments as hostile, because `submit_input` is reachable by anyone.
@rpc("any_peer", "call_local", "unreliable_ordered")
func submit_input(tick: int, move: Vector2, jump: bool) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1                      # the host called it on itself
	submit_input_for(id, tick, move, jump)

func submit_input_for(id: int, tick: int, move: Vector2, jump: bool) -> void:
	if not players.has(id):
		return
	var p: Node2D = players[id]
	var newest: int = p.input_queue[-1]["tick"] if not p.input_queue.is_empty() else p.last_tick
	if tick <= newest:
		return                      # stale, duplicated or replayed
	if p.input_queue.size() >= INPUT_QUEUE_CAP:
		p.input_queue.pop_front()   # flooding client: drop the oldest
	p.input_queue.append({
		"tick": tick,
		"move": Vector2(clampf(move.x, -1.0, 1.0), clampf(move.y, -1.0, 1.0)),
		"jump": jump,
	})

func _setup_input() -> void:
	if InputMap.has_action("ashamed_jump"):
		return
	InputMap.add_action("ashamed_jump")
	# Not the up arrow: that walks into the screen now.
	for key in [KEY_SPACE, KEY_W]:
		var ev := InputEventKey.new()
		ev.physical_keycode = key
		InputMap.action_add_event("ashamed_jump", ev)

# --- registry -----------------------------------------------------------------

func _build_player(data: Dictionary) -> Node:
	var p: Node2D = PLAYER_SCENE.instantiate()
	p.setup(int(data["id"]))
	p.ground = data["pos"]
	p.net_ground = data["pos"]
	p.target_ground = data["pos"]
	p.position = project(p.ground, 0.0, eye_x)
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

## Track what the camera is actually showing. With smoothing on, that is not
## `camera.position` -- that is where the camera is heading -- and converging
## the floor on a point the camera has not reached yet visibly swims.
func _process(_delta: float) -> void:
	if game == null or game.is_dedicated or not is_local():
		return
	var eye: float = game.camera.get_screen_center_position().x
	if not is_equal_approx(eye, eye_x):
		eye_x = eye
		queue_redraw()       # the floor is drawn relative to the eye, so it moves

## The floor, drawn as a plane rather than a band: every horizontal distance
## here goes through the same `project` the bodies do, so the edges converge on
## the camera's axis and the grid bunches toward the horizon.
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(ARENA.x, ARENA.y)), SKY_COLOUR)

	# Bands of even *screen* height, so the gradient is smooth; each one spans
	# a widening slice of depth, which `depth_at_ratio` recovers.
	var bands := 28
	for i in bands:
		var t0 := float(i) / float(bands)
		var t1 := float(i + 1) / float(bands)
		var d0 := depth_at_ratio(t0)
		var d1 := depth_at_ratio(t1)
		var near_l := project(Vector2(0.0, d0), 0.0, eye_x)
		var near_r := project(Vector2(ARENA.x, d0), 0.0, eye_x)
		var far_l := project(Vector2(0.0, d1), 0.0, eye_x)
		var far_r := project(Vector2(ARENA.x, d1), 0.0, eye_x)
		# Overlap by a hair: adjacent polygons otherwise leave seams.
		far_l.y -= 1.0
		far_r.y -= 1.0
		draw_colored_polygon(
			PackedVector2Array([near_l, near_r, far_r, far_l]),
			GROUND_COLOUR.lerp(GROUND_FAR_COLOUR, t0))

	# Lines of constant depth, spanning a floor that is narrowing as it recedes.
	var rule := Color(0.24, 0.26, 0.32, 0.55)
	for i in 9:
		var d := depth_at_ratio(float(i) / 8.0)
		draw_line(project(Vector2(0.0, d), 0.0, eye_x), project(Vector2(ARENA.x, d), 0.0, eye_x), rule, 1.0)

	# Posts along the level. These are parallel in the world and converge on
	# screen, which is the cue that does most of the work.
	var x := 0.0
	while x <= ARENA.x:
		draw_line(project(Vector2(x, DEPTH_RANGE), 0.0, eye_x), project(Vector2(x, 0.0), 0.0, eye_x),
			Color(0.22, 0.24, 0.30, 0.35), 1.0)
		x += 256.0

func _refresh() -> void:
	var who := PackedStringArray()
	var ids: Array = players.keys()
	ids.sort()
	for id in ids:
		who.append(game.label_for(id))
	set_score_line("here: %s" % ", ".join(who) if who.size() > 0 else "here: nobody")
