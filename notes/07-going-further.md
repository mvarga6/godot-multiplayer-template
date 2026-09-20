# Stage 7 — Going further

**Goal:** you have a working online game. These are the next things worth learning, roughly
in order of insight-per-hour. Do them in any order; each is independent.

---

## Key concepts

### The fundamental problem
Information takes time to travel. When you press a key, the server learns about it ~50 ms
later, and you learn the result ~50 ms after that. Every technique below is a way of hiding,
tolerating, or compensating for that delay. There is no technique that removes it.

The three classic tools:

| Technique | Hides | Cost |
|---|---|---|
| **Interpolation** | the gap between infrequent updates | you render the past (~1 tick behind) |
| **Prediction** | your own input latency | you can be wrong and must correct |
| **Reconciliation** | the correction itself | complexity, and visible snaps when badly done |

Every networked action game uses all three. You have built the version with none of them,
which is why you can now feel exactly what each one is for.

---

## A. Interpolation — smooth out the 20 Hz stepping

**What you will learn:** why rendering the past is the right default.

The server sends 20 updates/sec, you render 60 frames/sec. Snapping makes remote squares
visibly step. Instead, store the incoming position as a *target* and move toward it each
frame.

In `player.gd`:

```gdscript
var target_position: Vector2 = Vector2.ZERO
var is_local_authority := false      # set true for your own square later

func _process(delta: float) -> void:
	if is_local_authority:
		return
	position = position.lerp(target_position, 1.0 - pow(0.001, delta))
```

That `1.0 - pow(0.001, delta)` is the frame-rate-independent form of exponential smoothing —
plain `lerp(a, b, 0.2)` gives different results at 30 and 144 fps, which is the same class of
bug as forgetting `delta` in stage 1.

Then `update_state` sets `target_position` instead of `position`.

**Try it:** set the broadcast timer to `0.2` (5 Hz). Without interpolation it is unplayable;
with it, surprisingly fine. That is the whole argument for interpolation in one experiment.

**The cost:** you are now rendering remote players slightly in the past. In a shooter that
means you must aim where someone *was*, which is why servers do lag compensation — rewinding
the world to what the shooter saw. Worth knowing the term.

---

## B. Client-side prediction — make your own square responsive

**What you will learn:** the real reason netcode is hard.

Move your own square immediately on input, *and* send the input to the server. Now your
square responds instantly while remaining server-authoritative.

1. In `_send_input()`, also apply the movement locally to your own player node.
2. In `update_state`, **skip your own id** — or the server's older position will yank you
   backwards 20 times a second.

That skip is a lie: you are ignoring the authority. It works only while your prediction
agrees with the server. The moment it disagrees — you were blocked, you were pushed, you
cheated — you are wrong and nothing corrects you.

**Try it:** make the server refuse to move players in the left half of the arena. Your
predicted square walks in; the server says no. Watch the two disagree permanently. That is
the problem **reconciliation** exists to solve.

---

## C. Reconciliation — correct the prediction properly

**What you will learn:** how real netcode actually works.

The standard algorithm:

1. Number every input you send (`tick` counter) and keep unacknowledged ones in a buffer.
2. The server echoes back the last tick it processed, along with the position.
3. On receiving state: snap your player to the server's position, then **replay** every
   buffered input after that tick.
4. If the server agreed with you, replay lands exactly where you already were — no visible
   change. If it disagreed, you jump to the corrected position.

This requires your movement code to be a pure function of `(state, input, delta)` so it can be
re-run — which is why real games factor movement into a `simulate(state, input, delta)`
function called from both client and server. Refactoring stage 4's `_server_simulate` into
that shape is most of the work.

This is Gabriel Gambetta's "Fast-Paced Multiplayer" series, and Valve's Source multiplayer
networking docs, in miniature. Both are worth reading once you have felt the problem.

---

## D. Something to fight over — shared authoritative state

**What you will learn:** what authority buys you.

Add a collectible dot. The **server** decides who touched it first, increments that peer's
score, and respawns it:

```gdscript
@rpc("authority", "call_local", "reliable")
func on_collected(peer_id: int, new_score: int, new_dot_pos: Vector2) -> void:
```

Reliable, because a missed score update is permanently wrong. Notice the shape: clients never
claim the pickup, they are *told* about it. Two players touching it in the same frame is
resolved by whoever the server processes first — arbitrary, but consistent for everyone,
which is the property that matters.

**Try breaking it:** let clients claim the dot themselves and watch both clients award
themselves the point. That five-minute experiment teaches more about server authority than
any amount of reading.

---

## E. Refactor: `MultiplayerSpawner` and `MultiplayerSynchronizer`

**What you will learn:** what Godot's built-in nodes were doing all along.

- **`MultiplayerSpawner`** — point it at a scene and a container node; when the server adds a
  child, it replicates the spawn to all clients. That is stage 3, as a node.
- **`MultiplayerSynchronizer`** — list properties and a replication interval; it sends deltas
  automatically. That is stage 4, as a node, with delta compression you did not write.

Replace your RPCs with them and the code gets much shorter. You will also immediately
recognise every property in their inspector — spawn path, replication interval, reliable vs
unreliable per property, authority — because you have now implemented all of it by hand.

Doing this *after* the manual version is the right order. Doing it first teaches you a set of
checkboxes.

---

## F. Housekeeping worth doing

Small, unglamorous, each one a real lesson:

- **`Net` autoload.** Move the peer/session code out of `main.gd` into a singleton so the
  game scene can change without tearing down the connection. This is how you would get a
  lobby → match → results flow.
- **Protocol version handshake.** Send a version string on connect; the server kicks
  mismatches with a clear message instead of failing weirdly. Fixes stage 6's lock-step pain.
- **Player names.** A first real piece of client→server data that is not movement. Validate
  it: length limit, strip control characters. `any_peer` means hostile input.
- **`multiplayer.auth_callback`.** Godot's built-in hook for a handshake before a peer is
  considered connected. The place a password or token would go.
- **DTLS.** `ENetMultiplayerPeer` supports encryption with a certificate. Turns your open
  plaintext port into something you would not be embarrassed by.
- **Graceful shutdown.** Catch `NOTIFICATION_WM_CLOSE_REQUEST`, tell the server, disconnect
  cleanly instead of timing out.

---

## Where to read next

- **Gabriel Gambetta, "Fast-Paced Multiplayer"** — the clearest explanation of prediction and
  reconciliation anywhere, with interactive demos.
- **Valve Developer Wiki, "Source Multiplayer Networking"** — interpolation and lag
  compensation from people shipping it at scale.
- **Godot docs → Networking → High-level multiplayer** — now that you have built it by hand,
  the parts that read as hand-waving on a first pass will read as precise.

---

## What you should now understand

Where the remaining hard problems are: they are not about sending packets, they are about two
computers disagreeing about time. Everything in this stage is a strategy for disagreeing
gracefully.
