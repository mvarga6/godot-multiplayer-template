# Stage 9 — Lobbies

**Goal:** connecting to the server is no longer the same thing as joining a game. You connect,
you land on a browser showing every game on the server and who is in each, and then you pick
one — or name a new one. Several games run at once, and they cannot see each other.

Up to now "the server" and "the game" were the same object. Pulling them apart is the whole
stage, and most of the work is in one word: *separation*.

---

## Key concepts

### Connected is not playing
The old flow was: assign a peer → `peer_connected` → spawn a square. There was nowhere to
*be* on the server without being in a game.

Now `_on_peer_connected` hands out an identity and a lobby list, and says `you_are_in(0)` —
lobby 0 meaning "the browser". Nothing is simulated for you until you choose. This is the
shape every real game has, and it is the reason `Main` exists separately from `World`.

### One World per lobby
`main.gd` used to be the whole program. It is now a shell: the socket, the handshake, the
identities and the screen. Each running game is a `World` node under `Worlds`, spawned by a
`MultiplayerSpawner` like anything else.

The server holds every World and simulates all of them. A client holds exactly one.

### The static trap
`Maze` kept its grid in a `static var`. One process, one maze. That is fine while a process
only ever runs one game, and it silently becomes a bug the moment it runs two — both lobbies
would collide against the same walls.

Making it instance state is the unglamorous core of this stage. It cascades: `simulate()` and
`Projectile.step()` are static and pure by design, so they can no longer reach a global
grid — the maze becomes their first argument:

```gdscript
static func simulate(maze: Maze, pos: Vector2, dir: Vector2, delta: float) -> Vector2:
static func step(maze: Maze, pos: Vector2, vel: Vector2, delta: float, reflect: bool)
```

Which is better anyway. A pure function that reaches for global state was only ever pure by
politeness.

### Visibility is what separates the games
`MultiplayerSpawner` has no visibility API. `MultiplayerSynchronizer` does. The two are
connected: **a spawn is only delivered to peers that can see the spawned node's
synchronizer** — so gating the synchronizer gates the spawn, the despawn and the updates
together, and a peer in another lobby never learns the node exists.

Every replicated node — the World, players, gems, shots — is born with
`public_visibility = false` in its scene, and the World grants it per peer:

```gdscript
for peer in multiplayer.get_peers():
    sync.set_visibility_for(peer, _can_see(peer))
```

That is the entire isolation mechanism. Not filtering on send, not separate scenes: one
boolean per node per peer.

### Grant outside-in, revoke inside-out
Hiding a World from a peer despawns its whole subtree on that peer in one go. If you then
send the despawn for each child, every one arrives with nothing to despawn:

```
ERROR: Condition "!pinfo.recv_nodes.has(net_id)" is true. Returning: ERR_UNAUTHORIZED
```

Exactly one per item and player — 16 of them, for a 14-gem world with two players. So
visibility is applied parent-first when granting and child-first when revoking.

### Wait to be told the world arrived
The server cannot put your square in a World you have not received yet; the spawn addresses
`Worlds/world_3/PlayerSpawner`, which does not exist on your side, and fails. A frame's delay
is a guess. The handshake is explicit: the client's `World._ready` calls
`world_ready.rpc_id(1, lobby_id)`, and only then does the server admit them.

### Identity outlives the game
Your name and icon belong to the *connection*, not to a lobby, so they follow you from the
browser into a game and out again. They live in `Main`; scores and rounds live in the
`World` and die with your membership.

One consequence worth knowing: `rpc()` only reaches peers connected *now*. A player who
connects later never hears the earlier `apply_identity` broadcasts, so the server replays the
whole table to each newcomer.

---

## Steps

### 1. Make the maze an instance
Drop `static` from `Maze`'s state and queries. Thread it through `simulate()` and
`Projectile.step()`. A projectile finds its own by walking up to its World, because a node
reference cannot ride along in spawn state.

### 2. Split `main.gd`
Everything about *the game* moves to `world.gd`; everything about *the connection and the
screen* stays. The World asks the shell for identities, sounds and screen space, and the
shell ignores any request from a World that is not the one on this screen:

```gdscript
func refresh_scores(world: World) -> void:
    if is_dedicated or world == null or not world.is_local():
        return
```

That guard, repeated, is how two simultaneous games share one HUD without fighting over it.

### 3. The registry
In memory, server-side: `{id: {name, members}}`. Clients never mutate it — they ask
(`request_create_lobby`, `request_join_lobby`, `request_leave_lobby`) and the server
broadcasts the result. Empty lobbies are pruned along with their World.

### 4. The browser
A digest — id, name, player names — small enough to send whole. Rebuilt as rows on receipt.

### 5. Gate everything
`public_visibility = false` in `player.tscn`, `collectible.tscn`, `projectile.tscn` and
`world.tscn`; `World.gate()` registers each synchronizer, and `refresh_visibility()` reapplies
membership whenever it changes.

---

## Verify

Five processes: a dedicated server and four clients. Two create games, two join them.

- Each client reports `worlds=1` — they hold their own game and nothing else.
- The two games have **different maze seeds**, different item pools and independent scores.
- Each client's roster lists only its own lobby's players, by name.
- One player leaves: they return to the browser (`lobby=0 worlds=0`), and the game they left
  drops to one player without disturbing the other game.
- That player then joins the *other* game and appears in its roster, on its maze.
- **Zero errors on every process**, which is the real test — this stage generates a great
  many spawns and despawns that must not go to the wrong peer.

---

## Gotchas

- **Clients see no world at all.** Visibility was installed with `add_visibility_filter()`.
  A filter is re-evaluated on the synchronizer's own schedule and does not reissue a spawn
  that was withheld before you joined. `set_visibility_for()` does.
- **`Node not found: .../PlayerSpawner`.** The server spawned your square before you had the
  World. Wait for the client to say it is ready.
- **A pile of `ERR_UNAUTHORIZED` on despawn.** Revoking parent visibility before the
  children's. Reverse the order.
- **`Cannot call method 'has_multiplayer_peer' on a null value`.** `multiplayer` is null until
  the node is in the tree — and gating deliberately happens before that, so a spawn never
  leaks. Guard it, and reapply once inside.
- **Two lobbies walk through each other's walls.** The maze is still static.
- **A newcomer sees raw peer ids instead of names.** Identity was broadcast with `rpc()`
  before they connected. Replay the table.
- **`const` Dictionaries refuse new keys.** Assigning to an existing key works, adding one
  does not, and the parser catches it. A registry has to be a `static var`.
- **The first lobby vanishes when you create a second.** Empty lobbies are pruned, and the
  creator moved out of the first into the second.

---

## Game types

A lobby is a *name* plus a *type*. The type is a row in `game_type.gd` saying what to call
the game and which scene to spawn as its World:

```gdscript
static var TYPES := {
    "amazing": {"name": "A Mazing", "blurb": "...", "scene": "res://world.tscn"},
}
```

The interesting part is not the table, it is what the table forces. For a second game to be
possible, `Main` must not know what the first one *is*. So the interface narrows to six
methods — `server_prepare`, `server_admit`, `server_evict`, `refresh_visibility`, `is_local`,
`gate` — and everything maze-shaped moves behind them. Main used to call
`world._open_spawn()` to pick a start position; now it calls `world.server_admit(peer)` and
the game decides what arriving means.

The test of an abstraction is whether a second implementation costs anything, so the second
one gets written: `games/ashamed/` is a second game — a 2D side-scroller, a skeleton at this
point: players appear standing on the ground and leave again. It came to **~170 lines**, and
the only file it changed outside its own folder was the one row in `game_type.gd`. (Stage 10
turns it into an actual game, and changes nothing outside its folder either.)

Writing it immediately found a leak that a single implementation could never have exposed:
the shell was clamping the camera to `AmazingWorld.ARENA`, because when there was only one
game its arena *was* the playfield. A lobby of idle avatars is a different size. That became
another overridable method, `world_bounds()`, and `main.gd` now contains no reference to any
specific game at all. (Stage 10 finds the same leak once more, one layer down: the shell was
also deciding *where* in the world the camera looks, which a side-on game wants to answer
differently. `camera_focus()` joins the list. This keeps happening, and it is not a sign
anything is wrong — every leak is a place the first game's assumptions had been mistaken for
the shell's.)

This is the general pattern. You do not find out whether a base class is the right shape by
looking at it; you find out by writing the second thing that has to fit.

## A footnote: the join chime

`audio/player_join.mp3` is a small example of how much of this stage is about *scope*.
"Play a sound when a player joins" has three qualifiers hiding in it — joins **your** game,
is **not you**, and you were **already there**. The third is the awkward one: arriving hands
you one spawn per player already present, so the obvious hook fires once per person in the
room. The World stays silent for a beat after your own square appears, and the whole decision
is one predicate you can test without an audio device.

## What you should now understand

How to run more than one instance of your game inside one process, and what that demands:
no global state in the simulation, replication scoped by visibility rather than by hope, and
an explicit handshake wherever one peer's readiness gates another's action.

Also the general lesson about `static`: it is an assumption about how many of something will
ever exist, written where nobody will look for it later.
