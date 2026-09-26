extends Node2D

## The shell: connection, identity, the menu, and the screen.
##
## Stage 9 took the game out of here. `Main` now owns the socket and the lobby
## registry; each running game lives in its own `World` node under `Worlds`.
## The server runs every lobby's World at once; a client is handed exactly one,
## because a World (and everything inside it) is only visible to peers that are
## members of that lobby.


const DEFAULT_PORT := 9000
const MAX_PLAYERS := 8
const NAME_MAX := 16
## Bump this whenever the RPC surface changes. A client built against a
## different number is refused with a clear message instead of failing weirdly
## half an hour later.
const PROTOCOL_VERSION := 1
const AUTH_TIMEOUT := 5.0
const ICONS: Array[String] = ["🐱", "🐶", "🦊", "🐸", "🐵", "🐙", "🦄", "🐝", "🦖", "🐧"]
const ANNOUNCE_SECONDS := 3.0
var icons: Dictionary = {}     # peer_id:int -> index into ICONS
var names: Dictionary = {}     # peer_id:int -> display name
var _pending_identity: Dictionary = {}   # server: peer_id -> {icon, name}, captured during auth
var is_dedicated := false
## Godot hands every tree an OfflineMultiplayerPeer, so `multiplayer_peer != null`
## and `is_server()` are both true before you have hosted or joined anything.
## Track the session explicitly instead of trusting either of them.
var in_session := false
var _announce_until := 0.0
var port := DEFAULT_PORT       # overridden by `-- --port N`

var _join_sfx: AudioStreamPlayer = null
var join_chimes := 0           # how many arrivals we have announced; handy under test

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
	_reset_to_menu()

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

func _setup_audio() -> void:
	if is_dedicated or DisplayServer.get_name() == "headless":
		return                     # a VPS has no speakers and no reason to decode an mp3
	if music.stream is AudioStreamMP3:
		music.stream.loop = true
	music.play()
	# One player per kind, so two different pickups in quick succession do not
	# cut each other off.
	_join_sfx = AudioStreamPlayer.new()
	_join_sfx.stream = preload("res://audio/player_join.mp3")
	_join_sfx.volume_db = -6.0
	add_child(_join_sfx)

## Deliberately local-only: you hear your own pickups, never anyone else's.
func _setup_camera() -> void:
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 8.0

## The playfield is the game's business, not the shell's, so the camera bounds
## come from whichever world you are actually in.
func _apply_camera_bounds(world: GameWorld) -> void:
	var bounds := Rect2(Vector2.ZERO, Vector2(1152, 648)) if world == null \
		else world.world_bounds()
	camera.limit_left = int(bounds.position.x)
	camera.limit_top = int(bounds.position.y)
	camera.limit_right = int(bounds.end.x)
	camera.limit_bottom = int(bounds.end.y)
	camera.position = bounds.get_center()

## Two fonts, because order decides whose metrics win. Emoji-first makes Latin
## text inherit the emoji font's fixed advance width and come out spaced like
## "1 7 / 2 5", so anything with words in it needs the text face first.
func _emoji_font(text_first: bool) -> SystemFont:
	var f := SystemFont.new()
	var emoji := ["Noto Color Emoji", "Segoe UI Emoji", "Apple Color Emoji", "Noto Emoji"]
	var names: Array = (["sans-serif"] + emoji) if text_first else (emoji + ["sans-serif"])
	f.font_names = PackedStringArray(names)
	return f

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

func _bind_key(action: String, key: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = key
	InputMap.action_add_event(action, ev)

func _set_status(msg: String) -> void:
	print(msg)
	status.text = msg

func _grid_cell(text: String, strong: bool) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _emoji_font(true))
	l.add_theme_font_size_override("font_size", 17)
	l.add_theme_color_override("font_color",
		Color(1, 0.86, 0.45) if strong else Color(0.78, 0.78, 0.82))
	l.custom_minimum_size.x = 120.0
	game_over_stats.add_child(l)

# --- lobby registry -----------------------------------------------------------
#
# In memory, server-side, and deliberately dumb: an id, a name, and who is in
# it. Clients never mutate it; they ask, and the server broadcasts the result.

var lobbies: Dictionary = {}       # lobby_id:int -> {name:String, members:Array[int]}
var worlds: Dictionary = {}        # lobby_id:int -> GameWorld node
var my_lobby_id: int = 0           # 0 = not in a game yet
var _next_lobby_id := 1
var _browser_seen: Array = []    # last digest received, as the browser shows it

@onready var worlds_root: Node2D = $Worlds
@onready var world_spawner: MultiplayerSpawner = $WorldSpawner

func is_member(lobby_id: int, peer: int) -> bool:
	if not lobbies.has(lobby_id):
		return false
	return (lobbies[lobby_id]["members"] as Array).has(peer)

func lobby_members(lobby_id: int) -> Array:
	if not lobbies.has(lobby_id):
		return []
	return lobbies[lobby_id]["members"]

func local_world() -> GameWorld:
	return worlds.get(my_lobby_id)

## Server only: a World per lobby, spawned into `Worlds`. Its own synchronizer
## is gated on membership, so only that lobby's players ever receive it.
func _create_world(lobby_id: int, type_id: String) -> GameWorld:
	var w: GameWorld = GameType.scene(type_id).instantiate()
	w.name = "world_%d" % lobby_id
	w.lobby_id = lobby_id
	w.game = self
	w.server_prepare()          # spawn state must be set before it enters the tree
	w.gate(w)
	worlds_root.add_child(w, true)
	w.refresh_visibility()          # now that it is in the tree and can ask
	worlds[lobby_id] = w
	return w

func _on_world_spawned(node: Node) -> void:
	node.game = self
	worlds[node.lobby_id] = node

func _on_world_despawned(node: Node) -> void:
	worlds.erase(node.lobby_id)

# --- lobby RPCs ---------------------------------------------------------------

@rpc("any_peer", "call_local", "reliable")
func request_create_lobby(wanted: String, type_id: String) -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	if peer == 0:
		peer = 1
	var id := _next_lobby_id
	_next_lobby_id += 1
	lobbies[id] = {
		"name": _clean_lobby_name(wanted, id),
		"type": GameType.resolve(type_id),
		"members": [],
	}
	_create_world(id, lobbies[id]["type"])
	_server_move_peer(peer, id)

@rpc("any_peer", "call_local", "reliable")
func request_join_lobby(lobby_id: int) -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	if peer == 0:
		peer = 1
	if not lobbies.has(lobby_id):
		return                      # never trust an any_peer argument
	if lobby_members(lobby_id).size() >= MAX_PLAYERS:
		return
	_server_move_peer(peer, lobby_id)

@rpc("any_peer", "call_local", "reliable")
func request_leave_lobby() -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	if peer == 0:
		peer = 1
	_server_move_peer(peer, 0)

## Server only: take a peer out of whatever lobby it is in and put it in another.
## Lobby 0 means "back to the browser".
func _server_move_peer(peer: int, lobby_id: int) -> void:
	for id in lobbies:
		var members: Array = lobbies[id]["members"]
		if members.has(peer):
			members.erase(peer)
			if worlds.has(id):
				worlds[id].server_evict(peer)
	if lobby_id != 0 and lobbies.has(lobby_id):
		(lobbies[lobby_id]["members"] as Array).append(peer)
	_prune_empty_lobbies()
	# Membership just changed, so every gated synchronizer has to re-ask.
	for id in worlds:
		worlds[id].refresh_visibility()
	# Not when they are leaving: `peer_disconnected` fires after ENet has
	# already dropped them, and `rpc_id` to a peer that is gone is an error
	# ("Attempt to call RPC with unknown peer ID"), not a no-op.
	if _can_notify(peer):
		you_are_in.rpc_id(peer, lobby_id)
	_broadcast_lobbies()
	# The host is already here; a client has to receive the World first.
	if lobby_id != 0 and peer == 1:
		_admit(lobby_id, 1)

## Is this peer still someone we can talk to? Peer 1 is us, and `get_peers()`
## lists the remote ones, so anything else has gone.
func _can_notify(peer: int) -> bool:
	return peer == 1 or multiplayer.get_peers().has(peer)

## A client reporting that its copy of the World has arrived. Only now is it
## safe to spawn their player into it.
@rpc("any_peer", "reliable")
func world_ready(lobby_id: int) -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	if peer == 0:
		peer = 1
	_admit(lobby_id, peer)

func _admit(lobby_id: int, peer: int) -> void:
	if not worlds.has(lobby_id) or not is_member(lobby_id, peer):
		return
	if worlds[lobby_id].players.has(peer):
		return                      # already in
	worlds[lobby_id].server_admit(peer)

func _prune_empty_lobbies() -> void:
	for id in lobbies.keys():
		if (lobbies[id]["members"] as Array).is_empty():
			lobbies.erase(id)
			if worlds.has(id):
				worlds[id].queue_free()
				worlds.erase(id)

func _clean_lobby_name(raw: String, id: int) -> String:
	var out := ""
	for ch in raw.strip_edges():
		if ch.unicode_at(0) >= 32 and ch.unicode_at(0) != 127:
			out += ch
		if out.length() >= NAME_MAX:
			break
	out = out.strip_edges()
	return out if out != "" else "Lobby %d" % id

## The browser's contents. Small enough to send whole: a name and a handful of
## player names per lobby.
func _broadcast_lobbies() -> void:
	lobbies_changed.rpc(_lobby_digest())

func _lobby_digest() -> Array:
	var out := []
	for id in lobbies:
		var who := PackedStringArray()
		for peer in lobbies[id]["members"]:
			who.append(str(names.get(peer, "Player %d" % peer)))
		var type_id: String = str(lobbies[id].get("type", GameType.DEFAULT))
		out.append({
			"id": id, "name": lobbies[id]["name"],
			"type": GameType.name_of(type_id), "players": who,
		})
	return out

@rpc("authority", "call_local", "reliable")
func lobbies_changed(digest: Array) -> void:
	_browser_seen = digest
	_render_browser(digest)

## `call_local`, because the host is a peer too: without it, telling peer 1 it
## has joined its own lobby fails with "RPC on yourself is not allowed".
@rpc("authority", "call_local", "reliable")
func you_are_in(lobby_id: int) -> void:
	my_lobby_id = lobby_id
	if lobby_id == 0:
		_show_browser()
	else:
		_show_playing()

# --- screens ------------------------------------------------------------------

@onready var connect_layer: CanvasLayer = $Lobby
@onready var ip_field: LineEdit = $Lobby/VBoxContainer/IpField
@onready var status: Label = $Lobby/VBoxContainer/StatusLabel
@onready var name_field: LineEdit = $Lobby/VBoxContainer/NameField
@onready var icon_picker: OptionButton = $Lobby/VBoxContainer/IconPicker
@onready var browser: CanvasLayer = $Browser
@onready var browser_list: VBoxContainer = $Browser/Root/Box/Scroll/List
@onready var lobby_name_field: LineEdit = $Browser/Root/Box/New/LobbyName
@onready var type_picker: OptionButton = $Browser/Root/Box/New/TypePicker
@onready var hud: CanvasLayer = $Hud
@onready var score_label: Label = $Hud/ScoreLabel
## Second HUD line. The game decides what goes in it.
@onready var status_line: Label = $Hud/StatusLabel
@onready var announce_label: Label = $Hud/AnnounceLabel
@onready var round_overlay: CanvasLayer = $RoundOverlay
@onready var round_overlay_root: Control = $RoundOverlay/Root
@onready var round_overlay_text: Label = $RoundOverlay/Root/Text
@onready var game_over_layer: CanvasLayer = $GameOver
@onready var game_over_title: Label = $GameOver/Root/Box/Title
@onready var game_over_stats: GridContainer = $GameOver/Root/Box/Stats
@onready var music: AudioStreamPlayer = $Music
@onready var camera: Camera2D = $Camera2D

func _ready() -> void:
	get_tree().auto_accept_quit = false
	_setup_auth()
	_setup_audio()
	_setup_camera()
	_setup_icon_picker()
	_setup_type_picker()
	# Every type's scene has to be spawnable, or a lobby of that type cannot
	# replicate to its members.
	for type_id in GameType.ids():
		world_spawner.add_spawnable_scene(GameType.scene_path(type_id))
	world_spawner.spawned.connect(_on_world_spawned)
	world_spawner.despawned.connect(_on_world_despawned)
	_connect_multiplayer_signals()
	var args := OS.get_cmdline_user_args()
	port = _port_from_args(args)
	is_dedicated = "--server" in args or OS.has_feature("dedicated_server")
	_show_connect()
	if is_dedicated:
		_start_dedicated_server()

func _setup_icon_picker() -> void:
	icon_picker.add_theme_font_override("font", _emoji_font(false))
	icon_picker.add_theme_font_size_override("font_size", 22)
	for l in [score_label, announce_label, round_overlay_text, game_over_title]:
		l.add_theme_font_override("font", _emoji_font(true))
	round_overlay_text.add_theme_font_size_override("font_size", 44)
	game_over_title.add_theme_font_size_override("font_size", 34)
	for i in ICONS.size():
		icon_picker.add_item(ICONS[i], i)
	icon_picker.selected = randi() % ICONS.size()

func _show_connect() -> void:
	connect_layer.visible = true
	browser.visible = false
	hud.visible = false
	game_over_layer.visible = false
	round_overlay.visible = false

## Connected to the server, but not playing anything yet. This is the screen
## stage 9 exists to add: you are *on* the server without being *in* a game.
func _show_browser() -> void:
	connect_layer.visible = false
	browser.visible = true
	hud.visible = false
	game_over_layer.visible = false
	round_overlay.visible = false

func _show_playing() -> void:
	connect_layer.visible = false
	browser.visible = false
	hud.visible = true
	var w := local_world()
	_apply_camera_bounds(w)
	if w != null and w.has_method("refresh_hud"):
		w.refresh_hud()

# --- the browser --------------------------------------------------------------

func _render_browser(digest: Array) -> void:
	if is_dedicated or not is_instance_valid(browser_list):
		return
	for child in browser_list.get_children():
		child.queue_free()
	if digest.is_empty():
		var empty := Label.new()
		empty.text = "No games yet. Name one and start it."
		browser_list.add_child(empty)
	for entry in digest:
		browser_list.add_child(_lobby_row(entry))

func _lobby_row(entry: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var who: PackedStringArray = entry["players"]
	var title := Label.new()
	title.add_theme_font_override("font", _emoji_font(true))
	title.text = "%s  (%d)" % [entry["name"], who.size()]
	title.custom_minimum_size.x = 220.0
	row.add_child(title)
	var kind := Label.new()
	kind.text = str(entry.get("type", ""))
	kind.custom_minimum_size.x = 130.0
	kind.add_theme_color_override("font_color", Color(0.75, 0.80, 1.0))
	row.add_child(kind)
	var roster := Label.new()
	roster.add_theme_font_override("font", _emoji_font(true))
	roster.text = ", ".join(who) if who.size() > 0 else "empty"
	roster.custom_minimum_size.x = 330.0
	row.add_child(roster)
	var join := Button.new()
	join.text = "Join"
	join.pressed.connect(func() -> void: request_join_lobby.rpc_id(1, int(entry["id"])))
	row.add_child(join)
	return row

func _on_create_lobby_pressed() -> void:
	request_create_lobby.rpc_id(1, lobby_name_field.text, _selected_type())

func _selected_type() -> String:
	var ids: Array = GameType.ids()
	var i: int = type_picker.selected
	return str(ids[i]) if i >= 0 and i < ids.size() else GameType.DEFAULT

func _setup_type_picker() -> void:
	type_picker.clear()
	for i in GameType.ids().size():
		var id: String = str(GameType.ids()[i])
		type_picker.add_item(GameType.name_of(id), i)
		type_picker.set_item_tooltip(i, GameType.blurb(id))
	type_picker.selected = 0

func _on_leave_lobby_pressed() -> void:
	request_leave_lobby.rpc_id(1)

# --- services the World asks of the screen ------------------------------------
#
# A World calls these for every event; they do nothing unless that World is the
# one on this screen. That is the whole of "two games cannot see each other" on
# the presentation side.

func label_for(id: int) -> String:
	return "%s %s" % [ICONS[int(icons.get(id, 0))], str(names.get(id, "Player %d" % id))]

## Somebody walked into the game you are already playing.
func play_join() -> void:
	join_chimes += 1
	if _join_sfx != null:
		_join_sfx.play()

## The two HUD lines are just text. A game composes its own; the shell only
## decides whether this game is the one on screen.
func set_score_line(world: GameWorld, text: String) -> void:
	if is_dedicated or world == null or not world.is_local():
		return
	score_label.text = text

func set_status_line(world: GameWorld, text: String) -> void:
	if is_dedicated or world == null or not world.is_local():
		return
	status_line.text = text

func announce_for(world: GameWorld, msg: String) -> void:
	print(msg)
	if is_dedicated or world == null or not world.is_local():
		return
	announce_label.text = msg
	_announce_until = Time.get_unix_time_from_system() + ANNOUNCE_SECONDS

func show_round_overlay(world: GameWorld, text: String) -> void:
	announce_for(world, text.replace("\n", "  "))
	if is_dedicated or world == null or not world.is_local():
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

func show_game_over(world: GameWorld, winner: int) -> void:
	print("GAME OVER: %s takes it" % label_for(winner))
	if is_dedicated or world == null or not world.is_local():
		return
	round_overlay.visible = false
	game_over_title.text = "%s wins the game" % label_for(winner)
	_fill_stats_grid(world.results_table())
	hud.visible = false
	game_over_layer.visible = true

func _fill_stats_grid(table: Array) -> void:
	for child in game_over_stats.get_children():
		child.queue_free()
	if table.is_empty():
		return
	game_over_stats.columns = (table[0] as Array).size()
	for r in table.size():
		var row: Array = table[r]
		for cell in row:
			_grid_cell(str(cell["text"]), bool(cell.get("strong", false)))

func _on_play_again_pressed() -> void:
	var w := local_world()
	if w != null:
		w.request_restart.rpc_id(1)
	game_over_layer.visible = false
	hud.visible = true

func _process(_delta: float) -> void:
	if is_dedicated:
		return
	var w := local_world()
	if w != null:
		var me := multiplayer.get_unique_id()
		if w.players.has(me):
			camera.position = w.players[me].position
	if announce_label.text != "" and Time.get_unix_time_from_system() > _announce_until:
		announce_label.text = ""

# --- connection ---------------------------------------------------------------

func _start_dedicated_server() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		push_error("Cannot bind port %d: %s" % [port, error_string(err)])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	in_session = true
	print("Dedicated server listening on UDP %d" % port)

func _on_host_button_pressed() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		_set_status("Cannot host: %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	in_session = true
	# The host never authenticates with anyone, so it announces itself directly.
	apply_identity.rpc(1, icon_picker.selected, _clean_name(name_field.text, 1))
	_set_status("Hosting on %d, I am peer %d" % [port, multiplayer.get_unique_id()])
	# Hosting no longer drops you into a game -- it drops you into the browser.
	_show_browser()
	_broadcast_lobbies()

func _on_join_button_pressed() -> void:
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

func _on_peer_connected(id: int) -> void:
	print("[%d] peer_connected: %d" % [multiplayer.get_unique_id(), id])
	if not multiplayer.is_server():
		return
	# Connected is not playing. Hand them their identity and the lobby list, and
	# let them choose a game.
	var ident: Dictionary = _pending_identity.get(id, {})
	_pending_identity.erase(id)
	apply_identity.rpc(id, int(ident.get("icon", 0)), str(ident.get("name", "Player %d" % id)))
	# `rpc()` only reaches peers connected *now*, so a newcomer would never
	# learn who everybody else is. Catch it up on the whole table.
	for pid in names:
		if pid != id:
			apply_identity.rpc_id(id, pid, int(icons.get(pid, 0)), str(names[pid]))
	# A new peer is not in anything yet, but every existing World has to learn
	# that it exists so it can be told "not for you".
	for lid in worlds:
		worlds[lid].refresh_visibility()
	you_are_in.rpc_id(id, 0)
	_broadcast_lobbies()

func _on_peer_disconnected(id: int) -> void:
	print("[%d] peer_disconnected: %d" % [multiplayer.get_unique_id(), id])
	if not multiplayer.is_server():
		return
	_server_move_peer(id, 0)
	icons.erase(id)
	names.erase(id)
	_broadcast_lobbies()

func _on_connected_to_server() -> void:
	in_session = true
	_set_status("Connected, I am peer %d" % multiplayer.get_unique_id())
	_show_browser()

func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	_reset_to_menu()
	_set_status("Connection failed")

func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	_reset_to_menu()
	_set_status("Server disconnected")

func _reset_to_menu() -> void:
	in_session = false
	my_lobby_id = 0
	for id in worlds.keys():
		if is_instance_valid(worlds[id]):
			worlds[id].queue_free()
	worlds.clear()
	lobbies.clear()
	icons.clear()
	names.clear()
	_show_connect()

## The server is the one that tells everybody who a peer is. Identity is global
## rather than per-lobby: your name follows you between games.
@rpc("authority", "call_local", "reliable")
func apply_identity(id: int, index: int, display: String) -> void:
	if index < 0 or index >= ICONS.size():
		return
	icons[id] = index
	names[id] = display
	for lid in worlds:
		var w: GameWorld = worlds[lid]
		if w.players.has(id):
			w.players[id].set_identity(ICONS[index], display)
	var lw := local_world()
	if lw != null and lw.has_method("refresh_hud"):
		lw.refresh_hud()
