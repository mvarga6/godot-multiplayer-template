class_name AsaltedWorld
extends GameWorld

## "A Salted": a small first-person shooter, in 3D.
##
## The third game, and the first that is not flat. Two things make that less of
## a departure than it sounds:
##
##   * The World is still a `Node2D` -- `GameWorld` says so -- and the 3D lives
##     in a `Node3D` child of it. Godot is happy to render a 3D subtree hanging
##     off a 2D node; the two are separate render passes on the same viewport,
##     with the CanvasLayer HUD drawn over both.
##   * The networking is identical to the other two. Clients send input, the
##     server owns every position, `simulate()` is a pure function so the client
##     can replay it, and the map travels as a seed rather than a layout.
##
## What *is* new is that the shell's Camera2D is no longer the view. The game
## drives its own Camera3D and tells the shell to keep its hands off, through
## `uses_shell_camera()`.

## The body: a vertical cylinder for collision, whatever the meshes look like.
const PLAYER_RADIUS := 0.45
const PLAYER_HEIGHT := 1.8
const EYE_HEIGHT := 1.62

const RUN_SPEED := 8.5
const GRAVITY := 24.0
const JUMP_SPEED := 8.0
const TERMINAL_FALL := 40.0

const PITCH_LIMIT := 1.45            # just under 90 degrees, so up is never gimbal
const MOUSE_SENSITIVITY := 0.0022

const SHOT_RANGE := 120.0
const SHOT_COOLDOWN := 0.55
const HIT_RADIUS := 0.55             # a little wider than the body: forgiving aim

## Long enough to feel like a penalty and read the killfeed, short enough that
## you are not watching someone else's game.
const RESPAWN_DELAY := 2.5

## Clips are discovered from the folder rather than listed here, so dropping
## `shoot4.mp3` in beside the others adds a variation with no code change.
const SFX_DIR := "res://games/asalted/audio"

const CONTROLS := "WASD move   SPACE jump   MOUSE look   CLICK fire   ESC free the mouse"

const INPUT_BUFFER_MAX := 4
const INPUT_QUEUE_CAP := 16

const PLAYER_SCENE := preload("res://games/asalted/player.tscn")

## Spawn state, replicated with the World: everyone builds the same map from it.
var arena_seed: int = 0

var players: Dictionary = {}         # peer_id -> player node

var input_tick := 0
var pending: Array = []              # client: inputs sent but not acknowledged

## The local view. Only ever built on a peer that can actually draw.
var yaw := 0.0
var pitch := 0.0
var camera: Camera3D = null
var _mouse_held := false

var arena: Arena = null

@onready var space: Node3D = $Space
@onready var players_root: Node3D = $Space/Players
@onready var player_spawner: MultiplayerSpawner = $PlayerSpawner
@onready var crosshair: Control = $Hud/Crosshair

# --- what a game type provides -------------------------------------------------

func _setup() -> void:
	_setup_input()
	arena = Arena.new()
	arena.name = "Arena"
	space.add_child(arena)
	arena.generate(arena_seed)

	player_spawner.spawn_function = _build_player
	player_spawner.spawned.connect(_on_player_spawned)
	player_spawner.despawned.connect(_on_player_despawned)

	if _can_render():
		arena.build()
		_build_view()
	set_status_line(CONTROLS)

func server_prepare() -> void:
	arena_seed = randi()

## The shell's Camera2D is not the view here, so it must stop clamping and
## moving it -- and stop asking this game for a Rect2 that means nothing.
func uses_shell_camera() -> bool:
	return false

func world_bounds() -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(Arena.SIZE, Arena.SIZE))

func server_admit(peer: int) -> void:
	if players.has(peer):
		return
	var node: Node = player_spawner.spawn({"id": peer, "pos": _spawn_point()})
	if node != null:
		gate(node)
		_on_player_spawned(node)   # `spawned` only fires on peers that receive one

func server_evict(peer: int) -> void:
	if not players.has(peer):
		return
	var node: Node = players[peer]
	_on_player_despawned(node)
	node.queue_free()

func _spawn_point() -> Vector3:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return Arena.spawn_point(arena.barriers, rng)

# --- the simulation -------------------------------------------------------------

## The one movement rule, pure in its arguments so reconciliation can replay it.
##
## `move` is (strafe, forward) in the player's own frame; `yaw_at` turns that
## into world space. The server is handed the yaw rather than deriving it,
## because the client turned the moment the mouse moved and its prediction
## already used the new heading.
static func simulate(barriers: Array, pos: Vector3, vel_y: float, grounded: bool,
		move: Vector2, yaw_at: float, jump: bool, delta: float) -> Dictionary:
	var p := pos
	var v := vel_y
	var on_ground := grounded
	var from_y := pos.y             # where the feet began the tick

	# Up first, then along: rising clear of a low box before stepping over it is
	# what makes it something you can jump onto rather than only walk around.
	if jump and on_ground:
		v = JUMP_SPEED
		on_ground = false
	v = maxf(v - GRAVITY * delta, -TERMINAL_FALL)
	p.y += v * delta

	# Settle before moving, so that a body standing on a box has its feet back
	# at the box top before `resolve` asks what it is inside of.
	var settled := _settle(barriers, p, v, from_y)
	p.y = settled[0]
	v = settled[1]
	on_ground = settled[2]

	var m := Vector2(clampf(move.x, -1.0, 1.0), clampf(move.y, -1.0, 1.0))
	if m.length() > 1.0:
		m = m.normalized()          # diagonals are not faster
	var basis := Basis(Vector3.UP, yaw_at)
	var forward: Vector3 = basis * Vector3(0.0, 0.0, -1.0)
	var right: Vector3 = basis * Vector3(1.0, 0.0, 0.0)
	var step := (right * m.x + forward * m.y) * RUN_SPEED * delta
	p.x += step.x
	p.z += step.z
	p = Arena.resolve(barriers, p, PLAYER_RADIUS)

	# And again where we ended up: walking off an edge has to drop you, and
	# landing on something has to stop you.
	settled = _settle(barriers, p, v, from_y)
	p.y = settled[0]
	v = settled[1]
	on_ground = settled[2]

	return {"pos": p, "vel_y": v, "grounded": on_ground}

## Land, or keep falling. Returns [y, vel_y, grounded].
static func _settle(barriers: Array, p: Vector3, v: float, from_y: float) -> Array:
	var support := Arena.support_under(barriers, p.x, p.z, PLAYER_RADIUS, from_y)
	if v <= 0.0 and p.y <= support:
		return [support, 0.0, true]
	return [p.y, v, false]

## Did this input actually push off the floor?
##
## Exactly the condition `simulate` uses to apply the impulse, pulled out so the
## sound cannot drift away from the physics -- and so that walking off a ledge,
## which also leaves you airborne, does not make a jumping noise.
static func is_jump_start(grounded: bool, jump: bool) -> bool:
	return jump and grounded

## Where the eye is, and which way it looks. Shared by the camera and the gun so
## that what you see down the crosshair is what the server traces.
static func eye_of(pos: Vector3) -> Vector3:
	return pos + Vector3(0.0, EYE_HEIGHT, 0.0)

static func look_dir(yaw_at: float, pitch_at: float) -> Vector3:
	return Vector3(
		-sin(yaw_at) * cos(pitch_at),
		sin(pitch_at),
		-cos(yaw_at) * cos(pitch_at)).normalized()

## Ray against one player, treated as a vertical cylinder. Returns the distance
## or INF.
static func hit_distance(target_pos: Vector3, from: Vector3, dir: Vector3) -> float:
	return Arena.ray_cylinder(from, dir, Vector2(target_pos.x, target_pos.z),
		HIT_RADIUS, target_pos.y, target_pos.y + PLAYER_HEIGHT)

# --- the tick -------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if game == null or not game.in_session:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return                       # still handshaking: an RPC now is an error
	if multiplayer.is_server():
		_server_simulate(delta)
	if is_local() and not game.is_dedicated:
		_send_input(delta)      # having no screen is not the same as not playing

func _send_input(delta: float) -> void:
	var me_id := multiplayer.get_unique_id()
	if players.has(me_id) and players[me_id].dead_timer > 0.0:
		pending.clear()          # nothing sent while dead is applied, so predict nothing
		return
	var move := Vector2(
		Input.get_axis("fps_left", "fps_right"),
		Input.get_axis("fps_back", "fps_forward"))
	var jump := Input.is_action_pressed("fps_jump")
	var fire := Input.is_action_just_pressed("fps_fire") and _mouse_held
	input_tick += 1
	submit_input.rpc_id(1, input_tick, move, yaw, pitch, jump, fire)

	var me := multiplayer.get_unique_id()
	if not players.has(me):
		return
	var p: Node3D = players[me]
	p.yaw = yaw
	p.pitch = pitch
	# Your own jump is predicted, so the sound is too. Waiting for the server to
	# confirm it would put a round trip between leaving the floor and hearing
	# it, and you would notice -- the shot can wait for the server because
	# nothing visible happens until it answers, but this cannot.
	if is_jump_start(p.grounded, jump) and _can_render():
		_play_flat(pick_sfx("jump"), -8.0)
	_step(p, move, yaw, jump, delta)
	p.target_pos = p.pos
	pending.append({"tick": input_tick, "move": move, "yaw": yaw,
		"jump": jump, "delta": delta})

func _server_simulate(delta: float) -> void:
	for id in players:
		var p: Node3D = players[id]
		p.cooldown = maxf(0.0, p.cooldown - delta)
		if p.dead_timer > 0.0:
			# A corpse neither moves nor shoots, and anything it sent while
			# waiting is discarded rather than applied on the way back.
			p.dead_timer = maxf(0.0, p.dead_timer - delta)
			p.input_queue.clear()
			if p.dead_timer <= 0.0:
				_server_respawn(id)
			continue
		var budget := 2 if p.input_queue.size() > INPUT_BUFFER_MAX else 1
		var consumed := 0
		while consumed < budget and not p.input_queue.is_empty():
			var inp: Dictionary = p.input_queue.pop_front()
			p.move = inp["move"]
			p.yaw = float(inp["yaw"])
			p.pitch = float(inp["pitch"])
			p.last_tick = int(inp["tick"])
			if is_jump_start(p.grounded, bool(inp["jump"])):
				_tell_members("jumped", [id, p.pos])
			_step(p, p.move, p.yaw, bool(inp["jump"]), delta)
			if bool(inp["fire"]):
				_server_fire(id)
			consumed += 1
		if consumed == 0:
			# Keep them moving the same way, but never repeat the jump or the
			# shot: both are edges, and a repeated edge is a free one.
			_step(p, p.move, p.yaw, false, delta)
	for id in players:
		var p: Node3D = players[id]
		p.net_pos = p.pos
		p.net_vel_y = p.vel_y
		p.net_grounded = p.grounded
		p.net_yaw = p.yaw

func _step(p: Node3D, move: Vector2, yaw_at: float, jump: bool, delta: float) -> void:
	var r := simulate(arena.barriers, p.pos, p.vel_y, p.grounded, move, yaw_at, jump, delta)
	p.pos = r["pos"]
	p.vel_y = float(r["vel_y"])
	p.grounded = bool(r["grounded"])

## Snap to the server, then replay everything it had not seen.
func _reconcile(p: Node3D, acked_tick: int) -> void:
	while not pending.is_empty() and int(pending[0]["tick"]) <= acked_tick:
		pending.pop_front()
	var pos: Vector3 = p.net_pos
	var vel: float = p.net_vel_y
	var grounded: bool = p.net_grounded
	for entry in pending:
		var r := simulate(arena.barriers, pos, vel, grounded, entry["move"],
			float(entry["yaw"]), bool(entry["jump"]), float(entry["delta"]))
		pos = r["pos"]
		vel = float(r["vel_y"])
		grounded = bool(r["grounded"])
	p.pos = pos
	p.vel_y = vel
	p.grounded = grounded
	p.target_pos = pos

func _on_player_synchronized(node: Node) -> void:
	if multiplayer.is_server():
		return
	if node.peer_id == multiplayer.get_unique_id():
		_reconcile(node, node.last_tick)
	else:
		node.target_pos = node.net_pos
		node.target_yaw = node.net_yaw

# --- shooting ---------------------------------------------------------------------

## Hitscan, on the server, against the same geometry every peer has. The first
## thing the ray meets wins: a pillar in the way is a miss, which is the whole
## point of having cover.
func _server_fire(shooter: int) -> void:
	var s: Node3D = players[shooter]
	if s.cooldown > 0.0:
		return
	s.cooldown = SHOT_COOLDOWN
	var from := eye_of(s.pos)
	var dir := look_dir(s.yaw, s.pitch)
	var wall := Arena.ray_distance(arena.barriers, from, dir)
	var best := minf(wall, SHOT_RANGE)
	var victim := 0
	for id in players:
		if id == shooter or players[id].dead_timer > 0.0:
			continue                 # you cannot shoot someone who is waiting to come back
		var d := hit_distance(players[id].pos, from, dir)
		if d < best:
			best = d
			victim = id
	_tell_members("shot_fired", [from, from + dir * best, victim])
	if victim == 0:
		return
	s.score += 1
	var v: Node3D = players[victim]
	v.dead_timer = RESPAWN_DELAY
	v.vel_y = 0.0
	v.input_queue.clear()
	_tell_members("fragged", [shooter, victim, s.score, v.pos])

## Back on your feet, somewhere else. The position replicates like any other,
## but `move` has to be cleared or the body sprints off in whatever direction
## it was last told to run.
func _server_respawn(id: int) -> void:
	var p: Node3D = players[id]
	p.pos = _spawn_point()
	p.vel_y = 0.0
	p.grounded = true
	p.move = Vector2.ZERO
	p.cooldown = 0.0
	p.net_pos = p.pos
	p.net_vel_y = 0.0
	p.net_grounded = true

## A shot everyone can see: a tracer that fades, drawn from the muzzle to
## wherever the ray stopped.
@rpc("authority", "call_local", "reliable")
func shot_fired(from: Vector3, to: Vector3, victim: int) -> void:
	if not _can_render() or not is_local():
		return
	_draw_tracer(from, to, victim != 0)
	# Positional, so you can tell which way a shot came from -- which is most
	# of what hearing one is for.
	_play_at(pick_sfx("shoot"), from, 0.0)

## Someone else left the floor. The owner already played their own on the
## prediction, so this would be a double for them.
@rpc("authority", "call_local", "reliable")
func jumped(who: int, where: Vector3) -> void:
	if not _can_render() or not is_local():
		return
	if who == multiplayer.get_unique_id():
		return
	_play_at(pick_sfx("jump"), where, -8.0)

@rpc("authority", "call_local", "reliable")
func fragged(shooter: int, victim: int, new_score: int, where: Vector3) -> void:
	if players.has(shooter):
		players[shooter].score = new_score
	if players.has(victim):
		players[victim].dead_timer = RESPAWN_DELAY
	var me := multiplayer.get_unique_id()
	if shooter == me:
		say("Fragged %s" % game.label_for(victim))
	elif victim == me:
		say("%s fragged you" % game.label_for(shooter))
		pending.clear()              # predictions from before the respawn are void
	if _can_render() and is_local():
		# Your own death is not a sound coming from somewhere: it happened to
		# you, so it plays flat rather than positioned.
		if victim == me:
			_play_flat(pick_sfx("die"), 2.0)
		else:
			_play_at(pick_sfx("die"), where, -3.0)
	_refresh()

## RPCs here go to lobby members only. A peer in another lobby has no World
## node at this path, so a broadcast would arrive somewhere that cannot resolve
## it -- the visibility gating that hides the node does not filter RPCs.
func _tell_members(method: StringName, args: Array) -> void:
	if not multiplayer.is_server():
		return
	callv("rpc_id", [1, method] + args)          # the server's own copy
	for peer in multiplayer.get_peers():
		if game.is_member(lobby_id, peer):
			callv("rpc_id", [peer, method] + args)

# --- input ------------------------------------------------------------------------

@rpc("any_peer", "call_local", "unreliable_ordered")
func submit_input(tick: int, move: Vector2, yaw_at: float, pitch_at: float,
		jump: bool, fire: bool) -> void:
	if not multiplayer.is_server():
		return
	submit_input_for(multiplayer.get_remote_sender_id(), tick, move, yaw_at,
		pitch_at, jump, fire)

## The validation, separated from who sent it, so a test can drive it directly.
## Everything here treats its arguments as hostile.
func submit_input_for(id: int, tick: int, move: Vector2, yaw_at: float,
		pitch_at: float, jump: bool, fire: bool) -> void:
	if not players.has(id):
		return
	if not is_finite(move.x) or not is_finite(move.y):
		return
	if not is_finite(yaw_at) or not is_finite(pitch_at):
		return
	var p: Node3D = players[id]
	if tick <= p.last_tick:
		return                       # stale or replayed
	if p.input_queue.size() >= INPUT_QUEUE_CAP:
		p.input_queue.pop_front()    # a flooding client drops its oldest, not ours
	p.input_queue.append({"tick": tick, "move": move, "yaw": yaw_at,
		"pitch": pitch_at, "jump": jump, "fire": fire})

func _setup_input() -> void:
	if InputMap.has_action("fps_forward"):
		return
	for action in ["fps_forward", "fps_back", "fps_left", "fps_right", "fps_jump"]:
		InputMap.add_action(action)
	_bind("fps_forward", [KEY_W, KEY_UP])
	_bind("fps_back", [KEY_S, KEY_DOWN])
	_bind("fps_left", [KEY_A, KEY_LEFT])
	_bind("fps_right", [KEY_D, KEY_RIGHT])
	_bind("fps_jump", [KEY_SPACE])
	InputMap.add_action("fps_fire")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	InputMap.action_add_event("fps_fire", click)

func _bind(action: String, keys: Array) -> void:
	for key in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = key
		InputMap.action_add_event(action, ev)

# --- the view -----------------------------------------------------------------------

## True on a peer that has a screen. The dedicated server and the headless test
## runner build no lights, no camera and no meshes -- and a headless process
## running four lobbies must not install four WorldEnvironments into one
## viewport.
func _can_render() -> bool:
	return game != null and not game.is_dedicated and DisplayServer.get_name() != "headless"

func _build_view() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.07, 0.08, 0.11)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.45, 0.48, 0.58)
	e.ambient_light_energy = 0.85
	e.fog_enabled = true
	e.fog_light_color = Color(0.07, 0.08, 0.11)
	e.fog_density = 0.006
	env.environment = e
	space.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -38.0, 0.0)
	sun.light_energy = 1.1
	space.add_child(sun)

	camera = Camera3D.new()
	camera.fov = 90.0                # wide, like the game it is copying
	camera.near = 0.05
	space.add_child(camera)
	camera.current = true
	crosshair.visible = true
	_capture_mouse(true)

var _was_dead := false

func _process(_delta: float) -> void:
	if camera == null or not is_local():
		return
	if not multiplayer.has_multiplayer_peer():
		return                       # disconnected: there is no "me" to follow
	var me := multiplayer.get_unique_id()
	if not players.has(me):
		return
	var p: Node3D = players[me]
	# The camera stays where you fell, so you watch the room rather than a
	# black screen -- but the crosshair goes, because you cannot shoot.
	camera.position = eye_of(p.pos)
	camera.rotation = Vector3(pitch, yaw, 0.0)

	var dead: bool = p.dead_timer > 0.0
	if dead:
		set_status_line("Respawning in %.1f" % p.dead_timer)
	elif _was_dead:
		set_status_line(CONTROLS)
	if dead != _was_dead:
		crosshair.visible = not dead
		_was_dead = dead

func _input(event: InputEvent) -> void:
	if camera == null or not is_local():
		return
	if event is InputEventMouseMotion and _mouse_held:
		var motion := event as InputEventMouseMotion
		yaw -= motion.relative.x * MOUSE_SENSITIVITY
		yaw = wrapf(yaw, -PI, PI)
		pitch = clampf(pitch - motion.relative.y * MOUSE_SENSITIVITY,
			-PITCH_LIMIT, PITCH_LIMIT)
	elif event.is_action_pressed("ui_cancel"):
		_capture_mouse(false)        # give the mouse back, so the UI is usable
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and not _mouse_held:
		_capture_mouse(true)

func _capture_mouse(on: bool) -> void:
	if not _can_render():
		return
	_mouse_held = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE

## Leaving the game must hand the mouse back, or the lobby screen is unusable.
func _exit_tree() -> void:
	if _mouse_held:
		_capture_mouse(false)

## Cached statically, because the folder really is global: one set of clips
## however many lobbies are running, and a lobby cannot change what is on disk.
static var _sfx_cache: Dictionary = {}

## Every clip whose name starts with the action -- `shoot1.mp3`, `shoot2.mp3`,
## and so on.
static func clips_for(action: String) -> Array:
	if not _sfx_cache.has(action):
		_sfx_cache[action] = _scan_clips(action)
	return _sfx_cache[action]

static func _scan_clips(action: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(SFX_DIR)
	if dir == null:
		return out
	var seen := {}
	var names := dir.get_files()
	names.sort()                     # a stable order, so two runs list the same
	for entry in names:
		# Running from source lists both `shoot1.mp3` and `shoot1.mp3.import`.
		var file := entry.trim_suffix(".import")
		if seen.has(file) or not file.begins_with(action):
			continue
		if not (file.ends_with(".mp3") or file.ends_with(".wav") or file.ends_with(".ogg")):
			continue
		seen[file] = true
		var stream: Resource = load("%s/%s" % [SFX_DIR, file])
		if stream is AudioStream:
			out.append(stream)
	return out

## One of them, at random.
##
## Chosen locally, at the moment of playing, rather than picked by the server
## and sent along: which variation you happen to hear is texture, not state.
## It could not be shared anyway -- your own jump plays off the prediction,
## before the server has heard about it.
##
## Null when the folder holds nothing for this action, which comes out as
## silence rather than a crash.
static func pick_sfx(action: String) -> AudioStream:
	var clips := clips_for(action)
	if clips.is_empty():
		return null
	return clips[randi() % clips.size()]

## A one-shot sound somewhere in the world. The node frees itself when the
## stream ends, so nothing has to keep a list of them.
func _play_at(stream: AudioStream, at: Vector3, db: float) -> void:
	if stream == null:
		return
	var a := AudioStreamPlayer3D.new()
	a.stream = stream
	a.position = at
	a.volume_db = db
	a.unit_size = 14.0               # audible across the room, not the whole map
	a.max_distance = Arena.SIZE * 1.5
	space.add_child(a)
	a.finished.connect(a.queue_free)
	a.play()

## A sound that happened *to you* rather than somewhere near you.
func _play_flat(stream: AudioStream, db: float) -> void:
	if stream == null:
		return
	var a := AudioStreamPlayer.new()
	a.stream = stream
	a.volume_db = db
	add_child(a)
	a.finished.connect(a.queue_free)
	a.play()

func _draw_tracer(from: Vector3, to: Vector3, hit: bool) -> void:
	var mesh := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1.0, 0.85, 0.4) if hit else Color(0.6, 0.8, 1.0)
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	mesh.surface_add_vertex(from)
	mesh.surface_add_vertex(to)
	mesh.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	space.add_child(mi)
	get_tree().create_timer(0.1).timeout.connect(mi.queue_free)

# --- registry -------------------------------------------------------------------------

func _build_player(data: Dictionary) -> Node:
	var p: Node3D = PLAYER_SCENE.instantiate()
	p.setup(int(data["id"]))
	p.pos = data["pos"]
	p.net_pos = data["pos"]
	p.target_pos = data["pos"]
	p.is_local_authority = multiplayer.is_server() \
		or int(data["id"]) == multiplayer.get_unique_id()
	return p

func _on_player_spawned(node: Node) -> void:
	var id: int = node.peer_id
	players[id] = node
	node.set_label(game.ICONS[int(game.icons.get(id, 0))],
		str(game.names.get(id, "Player %d" % id)))
	node.get_node("Sync").synchronized.connect(_on_player_synchronized.bind(node))
	# You do not see your own body from the inside.
	if id == multiplayer.get_unique_id() and _can_render():
		node.hide_body()
	_refresh()

func _on_player_despawned(node: Node) -> void:
	players.erase(node.peer_id)
	_refresh()

func _refresh() -> void:
	var ids: Array = players.keys()
	ids.sort()
	var parts := PackedStringArray()
	for id in ids:
		parts.append("%s %d" % [game.label_for(id), int(players[id].score)])
	set_score_line("  ".join(parts) if parts.size() > 0 else "nobody here")
