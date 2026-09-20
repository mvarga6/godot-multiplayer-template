# Stage 2 — Lobby: host and join

**Goal:** two running instances of the game establish a real network connection and print
each other's peer ids. Nothing is drawn or synced yet.

This is the milestone that actually matters. Once the connection exists, everything after it
is bookkeeping.

---

## Key concepts

### `MultiplayerAPI` and `multiplayer_peer`
Every node exposes `multiplayer` — the `MultiplayerAPI` for its scene tree. On its own it
does nothing. It becomes live the moment you assign a **transport** to
`multiplayer.multiplayer_peer`. Before that assignment, every RPC you call silently does
nothing at all. (Remember this; it is the single most common "why is nothing happening".)

### `ENetMultiplayerPeer`
Godot's default transport, wrapping the ENet library over **UDP**. UDP does not guarantee
delivery or ordering — ENet adds *optional* reliability on top, per message, which is why
stage 4 gets to choose `reliable` or `unreliable` per RPC. That per-message choice is the
thing TCP cannot give you and the reason games use UDP.

### Server and client are the same program
`create_server(port, max_clients)` listens; `create_client(address, port)` dials out. Same
scene, same script, same `.tscn` files — one boolean's worth of difference. That is why
`multiplayer.is_server()` appears everywhere from here on.

### Peer ids
- The **server is always `1`.** Hard-coded by the engine, never anything else.
- Each client gets a random positive `int` when it connects.
- `multiplayer.get_unique_id()` → who am I.
- A **host** is a server that also plays: it is peer `1` *and* has a square on screen.

### The connection lifecycle signals
Five signals, and which side sees which is the whole mental model:

| Signal | Fires on | Meaning |
|---|---|---|
| `peer_connected(id)` | **server and all clients** | Someone joined the session |
| `peer_disconnected(id)` | **server and all clients** | Someone left |
| `connected_to_server()` | **the joining client only** | My handshake succeeded |
| `connection_failed()` | **the joining client only** | Could not reach the server |
| `server_disconnected()` | **clients only** | Server died or kicked me |

Note the asymmetry: `peer_connected` fires on *everyone*, including on existing clients about
each other. Stage 3 depends on knowing exactly who hears what.

### Ports
`9000` here, arbitrary — any free port above 1024. The server binds it; clients only need to
know the number. Clients make **outbound** connections, so no client ever needs an open port.
That fact is what makes stage 6 cheap.

---

## Steps

### 1. Add lobby UI to `main.tscn`
A `CanvasLayer` named **`Lobby`** (a CanvasLayer draws in screen space, unaffected by any
future camera), containing a `VBoxContainer` with:

- `Button` **`HostButton`** — text "Host"
- `LineEdit` **`IpField`** — text `127.0.0.1`
- `Button` **`JoinButton`** — text "Join"
- `Label` **`StatusLabel`**

### 2. `main.gd`

```gdscript
extends Node2D

const PORT := 9000
const MAX_PLAYERS := 8

@onready var lobby: CanvasLayer = $Lobby
@onready var ip_field: LineEdit = $Lobby/VBoxContainer/IpField
@onready var status: Label = $Lobby/VBoxContainer/StatusLabel

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _on_host_button_pressed() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		_set_status("Cannot host: %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	lobby.hide()
	_set_status("Hosting on %d, I am peer %d" % [PORT, multiplayer.get_unique_id()])

func _on_join_button_pressed() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip_field.text, PORT)
	if err != OK:
		_set_status("Cannot join: %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	_set_status("Connecting to %s..." % ip_field.text)

# --- signal handlers ---------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	print("[%d] peer_connected: %d" % [multiplayer.get_unique_id(), id])

func _on_peer_disconnected(id: int) -> void:
	print("[%d] peer_disconnected: %d" % [multiplayer.get_unique_id(), id])

func _on_connected_to_server() -> void:
	lobby.hide()
	_set_status("Connected, I am peer %d" % multiplayer.get_unique_id())

func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	_set_status("Connection failed")

func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	lobby.show()
	_set_status("Server disconnected")

func _set_status(msg: String) -> void:
	print(msg)
	status.text = msg
```

Connect the two buttons' `pressed` signals to their handlers in the editor.

Also **delete the stage-1 player spawn** from `_ready()` and the `_physics_process` in
`player.gd` for now — stage 3 and 4 put them back, properly.

### 3. Set up two-instance testing
*Debug → Customize Run Instances* → enable **2 instances**. F5 now launches two windows.

---

## Verify

Run two instances. Click **Host** in one, **Join** in the other. Expected output:

```
Hosting on 9000, I am peer 1
[1] peer_connected: 1234567890        <- server hears the client
Connected, I am peer 1234567890
[1234567890] peer_connected: 1        <- client hears the server
```

Both sides see one `peer_connected`. Close the client window; the host prints
`peer_disconnected`.

Then try it with **three** instances — one host, two joiners. Watch the second client get
told about the first. That is the case stage 3 has to handle.

---

## Gotchas

- **Clicking Join before Host** → `connection_failed` after a few seconds. Expected.
- **Forgetting `multiplayer.multiplayer_peer = peer`** → no error, no connection, no clue.
  The `create_*` call alone does nothing.
- **Both instances clicked Host** → the second gets `ERR_CANT_CREATE` (address in use).
- **`connection_failed` doesn't fire immediately** — ENet retries for several seconds first.
- **Not clearing the peer on failure** → a dead peer object hangs around and later calls
  behave strangely. Always `multiplayer.multiplayer_peer = null` when a connection ends.

---

## What you should now understand

A session is live, you know who is in it, and you know which machine learns about it through
which signal. What you *cannot* do yet is make one machine cause something to happen on
another. That is an RPC — stage 3.
