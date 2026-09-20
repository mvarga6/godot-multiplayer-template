# Stage 4 — Movement across the wire

**Goal:** a playable shared world. Each player moves their own square with the arrow keys and
sees everyone else's squares move.

---

## Key concepts

### The server owns every position
Clients do **not** move their own square. They send an input direction; the server simulates;
the server broadcasts positions; clients draw what they are told.

```
client                         server
------                         ------
read arrow keys
  │
  └─ submit_input(dir) ──────▶ players[sender].input_dir = dir
                               _physics_process: move everyone
  apply positions ◀────────── update_state({id: pos, ...})  @ 20 Hz
```

The cost is one round-trip of latency before you see your own square move — on localhost
invisible, from a VPS very visible (50–150 ms of mush). **That lag is the lesson.** Stage 7's
client-side prediction is the fix, and it will only make sense once you have felt the
problem.

The benefit: a client cannot teleport, move at 10x speed, or walk through walls, because it
never sends a position — only an intent. Every competitive game works this way.

### Two directions, two different problems

| | Client → server | Server → clients |
|---|---|---|
| Carries | an input vector | every player's position |
| Rate | when input changes | fixed, ~20 Hz |
| Size | tiny | grows with player count |
| Delivery | `unreliable_ordered` | `unreliable` |

### Why unreliable is the *correct* choice here
Counter-intuitive but central: **reliable delivery is wrong for state updates.**

A dropped position packet is worthless 50 ms later, because a newer one has already arrived
with the true current position. Reliable delivery would stall the stream re-sending stale
data, adding latency to every packet behind it — the same head-of-line blocking that makes
TCP a poor fit for games. Dropping it and moving on is strictly better.

The rule: **reliable for events, unreliable for state.** Spawn/despawn are events — miss one
and you are permanently wrong. Positions are state — miss one and you are wrong for 50 ms.

`unreliable_ordered` for input adds "never deliver an older input after a newer one", which
costs nothing and avoids a stale direction overwriting a fresh one.

### Tick rate vs frame rate
The server simulates at 60 Hz (physics) but broadcasts at **20 Hz**. Sending every physics
frame would triple the bandwidth for no visible gain. Real games do the same, then hide the
gap with interpolation (stage 7). Consequence for now: remote squares visibly step at 20 Hz.
That judder is not a bug, it is the send rate, and seeing it is the point.

### `get_remote_sender_id()`
Inside an `@rpc` method, `multiplayer.get_remote_sender_id()` returns who called it. This is
the **only** trustworthy identity — a client can put any id it likes in the *arguments*.

It returns `0` when the method was invoked locally rather than over the network (the host
calling itself via `call_local`). Handle that case explicitly.

### Never trust an `any_peer` method
`submit_input` is reachable by anyone who can open a socket to your port. Treat every
argument as hostile: clamp the vector's length, ignore unknown ids, and use the *sender* id
rather than anything in the payload. The whole client-authority attack surface lives in the
methods you mark `any_peer`.

---

## Steps

### 1. Client: send input when it changes

In `main.gd`:

```gdscript
const SPEED := 220.0
var _last_sent_dir: Vector2 = Vector2.ZERO

func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if multiplayer.is_server():
		_server_simulate(delta)
	_send_input()

func _send_input() -> void:
	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if dir == _last_sent_dir:
		return                      # only send on change: idle players cost nothing
	_last_sent_dir = dir
	submit_input.rpc_id(1, dir)
```

Sending only on change is a real optimisation and free to implement. It does mean a dropped
input packet keeps you moving in a stale direction — which is exactly why this one is
`unreliable_ordered` rather than plain `unreliable`. For a production game you would send
every tick with a sequence number instead.

### 2. Server: receive and validate input

```gdscript
@rpc("any_peer", "unreliable_ordered")
func submit_input(dir: Vector2) -> void:
	if not multiplayer.is_server():
		return                                  # clients ignore this entirely
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1                                  # host called it on itself
	if not players.has(id):
		return
	players[id].input_dir = dir.limit_length(1.0)   # never trust the magnitude
```

Three guards in six lines, all necessary.

### 3. Server: simulate

```gdscript
func _server_simulate(delta: float) -> void:
	var bounds := get_viewport_rect().size
	for id in players:
		var p: Node2D = players[id]
		p.position += p.input_dir * SPEED * delta
		p.position = p.position.clamp(Vector2(16, 16), bounds - Vector2(16, 16))
```

The clamp is the first genuinely *authoritative* rule: no client can leave the arena,
regardless of what it sends.

### 4. Server: broadcast at 20 Hz

Add a `Timer` node named **`BroadcastTimer`** to `main.tscn`, wait time `0.05`, autostart
off. Connect its `timeout`. Start it when hosting:

```gdscript
@onready var broadcast_timer: Timer = $BroadcastTimer

func _on_broadcast_timer_timeout() -> void:
	if not multiplayer.is_server() or players.is_empty():
		return
	var state := {}
	for id in players:
		state[id] = players[id].position
	update_state.rpc(state)
```

(In `_on_host_button_pressed()`: `broadcast_timer.start()`.)

### 5. Clients: apply state

```gdscript
@rpc("authority", "unreliable")
func update_state(state: Dictionary) -> void:
	if multiplayer.is_server():
		return                       # the server already has the truth
	for id in state:
		if players.has(id):
			players[id].position = state[id]
```

Snapping straight to the position is deliberate — stage 7 replaces it with interpolation, and
you want to have seen the difference.

---

## Verify

Two instances, host + join. Both squares move, both windows agree. Then:

- **Three instances.** All three move independently in all three windows.
- **Watch the judder.** On the *host* window every square is smooth — the host simulates at
  60 Hz and never goes through the network. On a *client* window every square steps, including
  your own, because they all arrive via the 20 Hz broadcast. Change the Timer to `0.2` and the
  stepping becomes obvious; that is the send rate made visible.
- **Open the Network Profiler** (*Debug* panel → *Network* tab) while running. Watch
  bandwidth rise with player count and with a faster timer. Worth thirty seconds of staring.
- **Hold a key and kill the client's window** — the server should stop simulating that player
  because `despawn_player` removed it from the dictionary.

---

## Gotchas

- **Nothing moves** — is `_physics_process` returning early because `multiplayer_peer` is
  `null`? Only assigned after Host/Join.
- **Only the host moves** — clients are running `_server_simulate`, or the broadcast timer
  was never started.
- **The host's own square does not move** — `get_remote_sender_id()` returned `0` and you did
  not map it to `1`.
- **Everything is jerky even on localhost** — expected at 20 Hz. Not a bug.
- **Positions fight each other** — a client is both simulating locally *and* applying
  `update_state`. Clients must not simulate. (Doing both on purpose, correctly, is stage 7.)
- **`Dictionary` keys come back as the wrong type** — Godot serialises ints fine, but if you
  ever key by `String` on one side and `int` on the other, lookups silently miss.

---

## What you should now understand

You have a real multiplayer game. More importantly you understand the reliability trade-off,
why the server simulates, and what input latency feels like. Stage 5 separates the server
from the game window so it can live somewhere else.
