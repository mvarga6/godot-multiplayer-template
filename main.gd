# MAIN ENTRYPOINT OF GAME
extends Node2D

const DEFAULT_PORT := 9000
const MAX_PLAYERS := 8
const SPEED := 220.0
const ARENA := Vector2(2304, 1296)  # a game rule, not a window size
const HALF := Vector2(16, 16)
const WIN_SCORE := 25            # points that win the round; the maze then regenerates
const ANNOUNCE_SECONDS := 3.0
const GAME_WINS := 10            # rounds won that take the whole game
const NAME_MAX := 16
## Bump this whenever the RPC surface changes. A client built against a
## different number is refused with a clear message instead of failing weirdly
## half an hour later.
const PROTOCOL_VERSION := 1
const AUTH_TIMEOUT := 5.0
const ICONS: Array[String] = ["🐱", "🐶", "🦊", "🐸", "🐵", "🐙", "🦄", "🐝", "🦖", "🐧"]
const MIN_ITEMS := 14            # how many collectibles are in the maze at once
const MAX_ITEMS := 20            # the arena is 4x what it was, so the count scaled with it
const LIFETIME_MIN := 8.0        # seconds a collectible survives before it rots away
const LIFETIME_MAX := 18.0
const INPUT_BUFFER_MAX := 4         # queue longer than this: the client has run ahead
const INPUT_QUEUE_CAP := 16         # hard cap, so a flooding client cannot grow it forever
const PLAYER_SCENE := preload("res://player.tscn")
const COLLECTIBLE_SCENE := preload("res://collectible.tscn")
const PROJECTILE_SCENE := preload("res://projectile.tscn")
## Where a shot is born, measured out from the player's centre so it does not
## immediately collide with the shooter's own square.
const MUZZLE_OFFSET := HALF.x + Weapon.RADIUS + 2.0

var players: Dictionary = {}   # peer_id:int -> Player node
var scores: Dictionary = {}    # peer_id:int -> points this round
var rounds_won: Dictionary = {}  # peer_id:int -> rounds won
var icons: Dictionary = {}     # peer_id:int -> index into ICONS
var names: Dictionary = {}     # peer_id:int -> display name
var round_history: Array = []  # one {round, winner, scores} per finished round
var round_index := 1
var game_finished := false
var _pending_identity: Dictionary = {}   # server: peer_id -> {icon, name}, captured during auth
var is_dedicated := false
var maze_seed := 0             # server: the seed every peer is currently generating from
var items: Dictionary = {}     # item_id:int -> Collectible node
var _next_item_id := 1         # server: hands out item ids
var _desired_items := MIN_ITEMS
var shots: Dictionary = {}     # shot_id:int -> Projectile node
var _next_shot_id := 1         # server: hands out shot ids
var selected_weapon := Weapon.Kind.CAPTURE   # client-local: which key you last pressed
var local_facing: Vector2 = Vector2.RIGHT    # client-local, for the aim indicator
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
@onready var player_spawner: MultiplayerSpawner = $PlayerSpawner
@onready var item_spawner: MultiplayerSpawner = $ItemSpawner
@onready var projectile_spawner: MultiplayerSpawner = $ProjectileSpawner
@onready var shots_root: Node2D = $Projectiles
@onready var weapon_label: Label = $Hud/WeaponLabel
@onready var maze: Maze = $Maze
@onready var items_root: Node2D = $Collectibles
@onready var lobby: CanvasLayer = $Lobby
@onready var ip_field: LineEdit = $Lobby/VBoxContainer/IpField
@onready var status: Label = $Lobby/VBoxContainer/StatusLabel
@onready var score_label: Label = $Hud/ScoreLabel
@onready var hud: CanvasLayer = $Hud
@onready var announce_label: Label = $Hud/AnnounceLabel
@onready var round_overlay: CanvasLayer = $RoundOverlay
@onready var round_overlay_root: Control = $RoundOverlay/Root
@onready var round_overlay_text: Label = $RoundOverlay/Root/Text
@onready var game_over_layer: CanvasLayer = $GameOver
@onready var game_over_title: Label = $GameOver/Root/Box/Title
@onready var game_over_stats: GridContainer = $GameOver/Root/Box/Stats
@onready var name_field: LineEdit = $Lobby/VBoxContainer/NameField
@onready var music: AudioStreamPlayer = $Music
@onready var camera: Camera2D = $Camera2D
@onready var icon_picker: OptionButton = $Lobby/VBoxContainer/IconPicker

var _sfx: Dictionary = {}      # Collectible.Kind -> AudioStreamPlayer

func _ready() -> void:
	# Say goodbye properly instead of vanishing: ENet takes ~10s to notice a
	# peer that simply stopped answering, but nothing at all to notice one that
	# announced it was leaving.
	get_tree().auto_accept_quit = false
	_setup_auth()
	_setup_input()
	_setup_spawners()
	_setup_audio()
	_setup_camera()
	_setup_icon_picker()
	_refresh_weapon_label()
	hud.visible = false               # the lobby is what you see first
	announce_label.text = ""
	_connect_multiplayer_signals()
	var args := OS.get_cmdline_user_args()
	port = _port_from_args(args)
	is_dedicated = "--server" in args or OS.has_feature("dedicated_server")
	if is_dedicated:
		_start_dedicated_server()

## Nothing may join until it has proved it speaks the same protocol. Doing this
## through `auth_callback` rather than a hello RPC matters: `peer_connected`
## does not fire until auth completes, so a rejected client never reaches the
## point of having a square in the world, and an accepted one arrives with its
## name and icon already known.
func _setup_auth() -> void:
	multiplayer.auth_callback = _on_auth_received
	multiplayer.auth_timeout = AUTH_TIMEOUT
	multiplayer.peer_authenticating.connect(_on_peer_authenticating)
	multiplayer.peer_authentication_failed.connect(_on_peer_authentication_failed)

func _on_peer_authenticating(id: int) -> void:
	# Both sides advertise themselves, so both can produce their own diagnosis.
	multiplayer.send_auth(id, var_to_bytes({
		"v": PROTOCOL_VERSION,
		"name": name_field.text if is_instance_valid(name_field) else "",
		"icon": icon_picker.selected if is_instance_valid(icon_picker) else 0,
	}))

func _on_auth_received(id: int, data: PackedByteArray) -> void:
	# Hostile input: `bytes_to_var`, never the `_with_objects` variant.
	var info: Variant = bytes_to_var(data)
	if typeof(info) != TYPE_DICTIONARY:
		_reject_peer(id, -1)
		return
	var their_version := int((info as Dictionary).get("v", -1))
	if their_version != PROTOCOL_VERSION:
		_reject_peer(id, their_version)
		return
	if multiplayer.is_server():
		_pending_identity[id] = _identity_from_auth(info, id)
	multiplayer.complete_auth(id)

## Pulls a usable icon and name out of whatever a peer actually sent.
func _identity_from_auth(info: Dictionary, id: int) -> Dictionary:
	return {
		"icon": clampi(int(info.get("icon", 0)), 0, ICONS.size() - 1),
		"name": _clean_name(str(info.get("name", "")), id),
	}

func _reject_peer(id: int, their_version: int) -> void:
	var theirs := "an unreadable handshake" if their_version < 0 else "protocol %d" % their_version
	if multiplayer.is_server():
		push_warning("Refused peer %d: %s, we speak %d" % [id, theirs, PROTOCOL_VERSION])
		return                  # never complete auth; it times out and drops
	# The server told us its version, so we can say exactly what is wrong.
	_set_status("Cannot join: server speaks %s, this build speaks %d" % [theirs, PROTOCOL_VERSION])
	_abort_connection.call_deferred()

## Tearing the peer down has to wait for the current frame to finish. Doing it
## inside `auth_callback` destroys the peer while the multiplayer layer is still
## walking its own auth state, which segfaults the engine.
func _abort_connection() -> void:
	var peer := multiplayer.multiplayer_peer
	if peer != null and not (peer is OfflineMultiplayerPeer):
		peer.close()
	multiplayer.multiplayer_peer = null
	_clear_world()
	lobby.show()

func _on_peer_authentication_failed(id: int) -> void:
	_pending_identity.erase(id)
	if multiplayer.is_server() or multiplayer.multiplayer_peer == null:
		return
	_set_status("Handshake failed or timed out")
	_abort_connection.call_deferred()

# --- leaving politely ---------------------------------------------------------

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_shutdown_network()
		get_tree().quit()

func _exit_tree() -> void:
	_shutdown_network()          # also covers a headless server being asked to stop

## Closing the ENet peer sends a disconnect to everyone still listening, which
## turns a ~10 second timeout into an immediate `peer_disconnected`.
func _shutdown_network() -> void:
	var peer := multiplayer.multiplayer_peer
	# An OfflineMultiplayerPeer is the one Godot hands every tree; there is
	# nobody to say goodbye to, and clearing it would strand the tree itself.
	if peer == null or peer is OfflineMultiplayerPeer:
		return
	peer.close()
	in_session = false

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

## Stage 7E: the two spawners replace the hand-written spawn/despawn RPCs, and
## each player's MultiplayerSynchronizer replaces the 20 Hz `update_state`
## broadcast. The spawners also replicate everything that already exists to a
## peer that connects later, which is the whole late-join catch-up loop gone.
## Registered in code rather than in the input map, for the same reason stage 1
## reused `ui_*`: it keeps the bindings next to the code that reads them.
## Physical keycodes, so this is still A/S/Space on AZERTY.
func _setup_input() -> void:
	_bind_key("fire", KEY_SPACE)
	_bind_key("select_capture", KEY_A)
	_bind_key("select_freeze", KEY_S)

func _bind_key(action: String, key: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = key
	InputMap.action_add_event(action, ev)

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
	node.set_identity(ICONS[int(icons.get(id, 0))], str(names.get(id, "Player %d" % id)))
	# The server owns every square. A client predicts only its own and
	# interpolates everyone else toward whatever the synchronizer delivers.
	node.is_local_authority = multiplayer.is_server() or id == multiplayer.get_unique_id()
	node.sync.synchronized.connect(_on_player_synchronized.bind(node))
	_refresh_scores()
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
	players.erase(id)
	scores.erase(id)
	rounds_won.erase(id)
	icons.erase(id)
	names.erase(id)
	_refresh_scores()
	print("[%d] despawned %d" % [multiplayer.get_unique_id(), id])

## What `update_state` used to do, now driven by the synchronizer's own signal.
func _on_player_synchronized(node: Node) -> void:
	if multiplayer.is_server():
		return                      # the server already has the truth
	if node.peer_id == multiplayer.get_unique_id():
		_reconcile(node, node.net_position, node.last_tick)
	else:
		node.target_position = node.net_position

func _setup_audio() -> void:
	if is_dedicated or DisplayServer.get_name() == "headless":
		return                     # a VPS has no speakers and no reason to decode an mp3
	if music.stream is AudioStreamMP3:
		music.stream.loop = true
	music.play()
	# One player per kind, so two different pickups in quick succession do not
	# cut each other off.
	for kind in Collectible.SOUND:
		var p := AudioStreamPlayer.new()
		p.stream = Collectible.SOUND[kind]
		p.bus = "Master"
		p.volume_db = -4.0
		add_child(p)
		_sfx[kind] = p

## Deliberately local-only: you hear your own pickups, never anyone else's.
func _play_pickup(kind: int) -> void:
	if _sfx.has(kind):
		_sfx[kind].play()

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
	round_overlay_text.add_theme_font_override("font", _emoji_font(true))
	round_overlay_text.add_theme_font_size_override("font_size", 44)
	game_over_title.add_theme_font_override("font", _emoji_font(true))
	game_over_title.add_theme_font_size_override("font_size", 34)

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
	if game_finished:
		return                      # nobody moves while the results are up
	if multiplayer.is_server():
		_server_simulate(delta)
	if not is_dedicated:
		_send_input(delta)          # no keyboard on a VPS

func _send_input(delta: float) -> void:
	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if dir.length() > 0.001:
		local_facing = dir.normalized()
	if Input.is_action_just_pressed("select_capture"):
		selected_weapon = Weapon.Kind.CAPTURE
		_refresh_weapon_label()
	elif Input.is_action_just_pressed("select_freeze"):
		selected_weapon = Weapon.Kind.FREEZE
		_refresh_weapon_label()
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
	p.position = simulate(p.position, moved, delta)
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
			p.position = simulate(p.position, p.effective_dir(p.input_dir), delta)
			consumed += 1
		if consumed == 0:
			# Nothing arrived in time. Assume they are still holding the same
			# key; if that guess is wrong, reconciliation fixes it.
			p.position = simulate(p.position, p.effective_dir(p.input_dir), delta)
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
		if not shot.advance(delta):
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
				continue                 # your own freeze ray passes through you
			if shot.position.distance_to(players[pid].position) > reach:
				continue
			players[pid].frozen_remaining = Weapon.freeze_seconds(shot.kind)
			player_frozen.rpc(pid, Weapon.freeze_seconds(shot.kind))
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

# --- lobby -------------------------------------------------------------------

func _on_host_button_pressed() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		_set_status("Cannot host: %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	in_session = true
	_show_playing_ui()
	_set_status("Hosting on %d, I am peer %d" % [port, multiplayer.get_unique_id()])
	_new_maze()
	server_add_player(1, _open_spawn())

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
	# 1. the shared world first, so the newcomer can collide before it can move.
	#    Everything here is deliberately small: a reliable RPC bigger than the
	#    path MTU stalls the whole channel behind it and eventually times the
	#    peer out. Bulk state goes as many little messages, never one big one.
	sync_world.rpc_id(id, maze_seed, scores, rounds_won, icons, names,
		round_index, game_finished)
	for entry in round_history:
		record_round.rpc_id(id, int(entry["round"]), int(entry["winner"]), entry["scores"])
	# 2. existing players and items need no catch-up at all: the spawners replay
	#    every live one, and the items carry their age as spawn state.
	# 3. the identity we captured during the handshake, so the newcomer never
	#    flickers as "Player 12345" with the default icon
	var ident: Dictionary = _pending_identity.get(id, {})
	_pending_identity.erase(id)
	apply_identity.rpc(id, int(ident.get("icon", 0)), str(ident.get("name", "Player %d" % id)))
	# 4. and only then, its square
	server_add_player(id, _open_spawn())

func _on_peer_disconnected(id: int) -> void:
	print("[%d] peer_disconnected: %d" % [multiplayer.get_unique_id(), id])
	if not multiplayer.is_server():
		return
	server_remove_player(id)

func _on_connected_to_server() -> void:
	in_session = true
	_show_playing_ui()
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

# --- server-side entry points -------------------------------------------------
#
# Everything on the server that creates or destroys a replicated thing goes
# through these four. They are the seam: what sits underneath can change (a
# hand-written RPC, a MultiplayerSpawner) without the game logic above noticing.

func server_add_player(id: int, pos: Vector2) -> void:
	if players.has(id):
		return                      # idempotent: a duplicate spawn is harmless
	var node: Node = player_spawner.spawn({"id": id, "pos": pos})
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
		scores[shooter] = int(scores.get(shooter, 0)) - price
		_refresh_scores()
	p.cooldowns[kind] = Weapon.cooldown(kind)

	var dir: Vector2 = p.facing.normalized() if p.facing.length() > 0.001 else Vector2.RIGHT
	var sid := _next_shot_id
	_next_shot_id += 1
	var shot: Projectile = PROJECTILE_SCENE.instantiate()
	shot.shot_id = sid
	shot.setup(shooter, kind, dir * Weapon.speed(kind, SPEED), Weapon.lifespan(kind))
	shot.position = p.position + dir * MUZZLE_OFFSET
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
@rpc("authority", "call_local", "reliable")
func player_frozen(pid: int, seconds: float) -> void:
	if players.has(pid):
		players[pid].frozen_remaining = seconds
	if pid == multiplayer.get_unique_id():
		pending.clear()            # predictions made while moving are void now
		_announce("Frozen for %.0f seconds" % seconds)

@rpc("authority", "call_local", "reliable")
func item_collected(collector: int, new_score: int, kind: int) -> void:
	scores[collector] = new_score
	if collector == multiplayer.get_unique_id() and not is_dedicated:
		_play_pickup(kind)
	_refresh_scores()
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

@rpc("authority", "call_local", "reliable")
func apply_identity(id: int, index: int, display: String) -> void:
	if index < 0 or index >= ICONS.size():
		return
	icons[id] = index
	names[id] = display
	if players.has(id):
		players[id].set_identity(ICONS[index], display)
	_refresh_scores()

## `any_peer` input: strip control characters, cap the length, never allow empty.
func _clean_name(raw: String, id: int) -> String:
	var out := ""
	for ch in raw.strip_edges():
		if ch.unicode_at(0) >= 32 and ch.unicode_at(0) != 127:
			out += ch
		if out.length() >= NAME_MAX:
			break
	out = out.strip_edges()
	return out if out != "" else "Player %d" % id

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
		_show_round_overlay("%s wins round %d\n%d of %d" % [
			_label_for(winner), round_no - 1, int(rounds_won.get(winner, 0)), GAME_WINS])
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
	_show_game_over(winner)

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
	game_over_layer.visible = false
	hud.visible = true
	_refresh_scores()

## Shared state a late joiner cannot infer from the spawn RPCs.
@rpc("authority", "reliable")
func sync_world(seed_value: int, all_scores: Dictionary, standings: Dictionary,
		all_icons: Dictionary, all_names: Dictionary, round_no: int, finished: bool) -> void:
	_apply_maze(seed_value)
	scores = all_scores.duplicate()
	rounds_won = standings.duplicate()
	icons = all_icons.duplicate()
	names = all_names.duplicate()
	round_index = round_no
	game_finished = finished
	# Deliberately does NOT clear items: the spawner has already replayed every
	# live one to us, and wiping them here is exactly how they went missing.
	round_history.clear()
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
	return Maze.random_open_point(rng)

func _label_for(id: int) -> String:
	var glyph: String = ICONS[int(icons.get(id, 0))]
	return "%s %s" % [glyph, str(names.get(id, "Player %d" % id))]

## The score and weapon readouts belong to a live session. Left visible they
## sit on top of the Host/Join menu, which is just clutter over a screen where
## you cannot shoot anything.
func _show_playing_ui() -> void:
	lobby.hide()
	hud.visible = true
	_refresh_weapon_label()

func _refresh_weapon_label() -> void:
	if is_dedicated:
		return
	var parts := PackedStringArray()
	for kind in [Weapon.Kind.CAPTURE, Weapon.Kind.FREEZE]:
		var key := "A" if kind == Weapon.Kind.CAPTURE else "S"
		var mark := "[%s]" % key if kind == selected_weapon else " %s " % key
		var price := Weapon.cost(kind)
		parts.append("%s %s %s%s" % [
			mark, Weapon.glyph(kind), Weapon.label(kind),
			"" if price == 0 else " (%d pts)" % price])
	weapon_label.text = "   ".join(parts) + "    SPACE to fire"

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

## ~1 second total: pop in, hold, fade out.
func _show_round_overlay(text: String) -> void:
	_announce(text.replace("\n", "  "))
	if is_dedicated:
		return
	round_overlay_text.text = text
	round_overlay_root.pivot_offset = get_viewport_rect().size * 0.5
	round_overlay_root.modulate.a = 0.0
	round_overlay_root.scale = Vector2(0.82, 0.82)
	round_overlay.visible = true
	var tw := create_tween()
	tw.tween_property(round_overlay_root, "modulate:a", 1.0, 0.15)
	tw.parallel().tween_property(round_overlay_root, "scale", Vector2.ONE, 0.18) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.52)
	tw.tween_property(round_overlay_root, "modulate:a", 0.0, 0.3)
	tw.tween_callback(func() -> void: round_overlay.visible = false)

func _show_game_over(winner: int) -> void:
	print("GAME OVER: %s takes it %d-%d" % [
		_label_for(winner), int(rounds_won.get(winner, 0)), GAME_WINS])
	if is_dedicated:
		return
	round_overlay.visible = false
	game_over_title.text = "%s wins the game" % _label_for(winner)
	_fill_stats_grid()
	hud.visible = false               # the results page is the whole screen now
	game_over_layer.visible = true

## Rounds down the rows, players across the columns. A GridContainer rather than
## a padded string, because the font is proportional and `%-18s` does not line up.
func _fill_stats_grid() -> void:
	for child in game_over_stats.get_children():
		child.queue_free()
	var ids: Array = rounds_won.keys()
	ids.sort()
	game_over_stats.columns = ids.size() + 1
	_grid_cell("round", true)
	for id in ids:
		_grid_cell(_label_for(id), true)
	for entry in round_history:
		_grid_cell(str(int(entry["round"])), false)
		var round_scores: Dictionary = entry["scores"]
		for id in ids:
			var won: bool = int(entry["winner"]) == id
			_grid_cell("%d%s" % [int(round_scores.get(id, 0)), "  ★" if won else ""], won)
	_grid_cell("rounds won", true)
	for id in ids:
		_grid_cell(str(int(rounds_won.get(id, 0))), true)

func _grid_cell(text: String, strong: bool) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _emoji_font(true))
	l.add_theme_font_size_override("font_size", 17)
	l.add_theme_color_override("font_color",
		Color(1, 0.86, 0.45) if strong else Color(0.78, 0.78, 0.82))
	l.custom_minimum_size.x = 120.0
	game_over_stats.add_child(l)

func _on_play_again_pressed() -> void:
	request_restart.rpc_id(1)

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
	_clear_shots()
	rounds_won.clear()
	icons.clear()
	names.clear()
	round_history.clear()
	round_index = 1
	game_finished = false
	game_over_layer.visible = false
	round_overlay.visible = false
	hud.visible = false               # back at the lobby: nothing to show over it
	for id in players.keys():
		players[id].queue_free()
	players.clear()
	scores.clear()
	_refresh_scores()

func _set_status(msg: String) -> void:
	print(msg)
	status.text = msg
