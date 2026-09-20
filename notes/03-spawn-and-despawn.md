# Stage 3 — Spawn and despawn players

**Goal:** every peer sees one square per connected player. Join and a square appears in all
windows; quit and it vanishes from all windows.

Still no movement. This stage is about **making the scene trees agree**.

---

## Key concepts

### RPC — Remote Procedure Call
You call a function; it runs on *other* machines. Godot addresses the call by **node path +
method name**, so the receiving peer must have a node at the same path with a method of the
same name. Mismatch it and you get an error on the receiving end, not the sending one.

```gdscript
spawn_player.rpc(id, pos)          # call it on every other peer
spawn_player.rpc_id(7, id, pos)    # call it on peer 7 only
spawn_player.rpc_id(1, id, pos)    # call it on the server only
```

### The `@rpc` annotation
A method is only callable remotely if it is annotated. Un-annotated, the call is rejected —
this is a security boundary, not a formality, since anyone can connect to your open port.

```gdscript
@rpc("authority", "call_local", "reliable")
func spawn_player(id: int, pos: Vector2) -> void:
```

Three independent choices:

**Who is allowed to call this on me?**
- `"authority"` (default) — only the node's authority, i.e. the server. Use for anything the
  server decides.
- `"any_peer"` — any connected client may call it. Every `any_peer` method is untrusted
  input: always validate inside it.

**Does it also run on the caller?**
- `"call_local"` — yes. Without it, the sender skips its own copy.
- Omitted (default) — remote peers only.

This is the single most common bug in Godot multiplayer: the **host** calls `spawn_player`,
every client spawns a square, and the host does not spawn its own. Add `"call_local"`.

**How should it be delivered?**
- `"reliable"` — resent until acknowledged, delivered in order. Costs latency.
- `"unreliable"` — fire and forget.
- `"unreliable_ordered"` — may drop, never arrives out of order.

Spawn and despawn are **`reliable`**: a dropped spawn means a player who is invisible
forever. Stage 4 explains why movement is the opposite.

### Node names *are* addresses
Name each player node after its peer id (`str(id)`). Now `/root/Main/Players/1234567890`
means the same node on every machine, which is exactly what RPC addressing needs. Anything
you might later want to RPC *directly on a player node* depends on this.

### Who tells whom, and when
The asymmetry from stage 2 has a consequence. When client C joins a session that already
contains A and B:

1. **Everyone** gets `peer_connected(C)`.
2. But C knows nothing about A and B — it was not there when they joined.

So the server does two different things in one handler:

```
on peer_connected(C):
    for each existing player P:  spawn_player.rpc_id(C, P)   # catch C up
    spawn_player.rpc(C)                                      # tell everyone about C
```

Late-join catch-up is a problem every networked game has, and this is the smallest possible
version of the answer.

### Only the server decides
Clients never call `spawn_player` themselves. They apply what the server tells them. This is
what "server-authoritative" means in practice, and `@rpc("authority")` enforces it.

---

## Steps

### 1. `player.gd` — make it dumb

```gdscript
extends Node2D

var peer_id: int = 0
var input_dir: Vector2 = Vector2.ZERO

@onready var rect: ColorRect = $ColorRect

func setup(id: int) -> void:
	peer_id = id
	name = str(id)

func _ready() -> void:
	# Deterministic colour per peer: golden-ratio hue stepping keeps
	# consecutive ids visually far apart.
	rect.color = Color.from_hsv(fposmod(peer_id * 0.618034, 1.0), 0.65, 0.95)
```

No `_physics_process` yet. The player node holds state; `main.gd` owns all the logic.

### 2. `main.gd` — the player registry

```gdscript
const PLAYER_SCENE := preload("res://player.tscn")

var players: Dictionary = {}   # peer_id:int -> Player node

func _random_spawn() -> Vector2:
	var size := get_viewport_rect().size
	return Vector2(randf_range(100, size.x - 100), randf_range(100, size.y - 100))
```

### 3. Spawn the host's own player when hosting

At the end of `_on_host_button_pressed()`, after assigning the peer:

```gdscript
	spawn_player.rpc(1, _random_spawn())   # "call_local" means this also runs here
```

### 4. Handle arrivals and departures (server only)

```gdscript
func _on_peer_connected(id: int) -> void:
	if not multiplayer.is_server():
		return
	# 1. catch the newcomer up on everyone already here
	for existing_id in players:
		spawn_player.rpc_id(id, existing_id, players[existing_id].position)
	# 2. tell everyone (including this server) about the newcomer
	spawn_player.rpc(id, _random_spawn())

func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	despawn_player.rpc(id)
```

### 5. The RPCs themselves

```gdscript
@rpc("authority", "call_local", "reliable")
func spawn_player(id: int, pos: Vector2) -> void:
	if players.has(id):
		return                     # idempotent: a duplicate spawn is harmless
	var p := PLAYER_SCENE.instantiate()
	p.setup(id)
	p.position = pos
	players_root.add_child(p)
	players[id] = p
	print("[%d] spawned %d at %s" % [multiplayer.get_unique_id(), id, pos])

@rpc("authority", "call_local", "reliable")
func despawn_player(id: int) -> void:
	if not players.has(id):
		return
	players[id].queue_free()
	players.erase(id)
	print("[%d] despawned %d" % [multiplayer.get_unique_id(), id])
```

Both are written to tolerate being called twice or for an unknown id. Defensive RPCs are
much easier than debugging a desync.

### 6. Clean up on disconnect (client side)

In `_on_server_disconnected()` and `_on_connection_failed()`, clear everything:

```gdscript
	for id in players.keys():
		players[id].queue_free()
	players.clear()
```

---

## Verify

Run **3 instances**. Host in one, join in the other two.

- Host window: three squares, three colours.
- First client: three squares, **in the same colours and positions** as the host.
- Second client: same again — this proves the late-join catch-up works.
- Close the second client → its square disappears from both remaining windows.
- Close the *host* → clients print `server_disconnected` and clear their squares.

Colours matching across windows is the real check: it means the ids agree everywhere.

---

## Gotchas

- **The host has no square** — missing `"call_local"`.
- **A client spawns only itself** — you called `.rpc()` when you meant `.rpc_id(id, ...)` for
  the catch-up loop, or skipped the catch-up entirely.
- **`Node not found` errors on the receiving peer** — the RPC's node path differs between
  peers. `main.gd` lives on the root node, so this usually means one instance is running a
  stale scene. Re-run both.
- **`RPC 'spawn_player' is not allowed`** — missing `@rpc` annotation, or a client tried to
  call an `"authority"` method.
- **Mutating `players` while iterating it** — use `players.keys()` when you free inside the
  loop.
- **Two players spawn on top of each other** — `randf_range` without `randomize()`. Godot 4
  seeds randomness automatically, but both instances can still collide by chance. Harmless.

---

## What you should now understand

RPCs, the authority/`call_local`/reliability triple, and late-join catch-up. The scene trees
now agree on *who exists*. Stage 4 makes them agree on *where everyone is* — which turns out
to need a completely different set of trade-offs.
