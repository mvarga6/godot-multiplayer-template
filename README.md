# online-1

A deliberately tiny server-authoritative multiplayer game in Godot 4.7: coloured squares you
move with the arrow keys through a randomly generated lava maze, racing to grab gold, rubies,
emeralds and diamonds before they rot away. First to 25 wins the round, first to 10 rounds
wins the game.

It exists to be read, not shipped. Every packet is a hand-written `@rpc` — nothing is
auto-synced — so the whole network layer fits in one 230-line script you can hold in your
head. The build-up is documented stage by stage in [`notes/`](notes/00-index.md).

## The whole thing in one picture

```
client: read input ─rpc_id(1, submit_input, tick, dir)─▶ server: queue input per peer
        predict locally, buffer the input            server: consume one input per tick
                                                     server: simulate(pos, dir, delta)
client: reconcile own square  ◀─rpc(update_state,  ── server: broadcast 20x/sec
        interpolate everyone else's    {id: pos}, {id: tick})
```

Clients send *intent*, never position. The server owns every coordinate, clamps everyone to
the arena, and broadcasts the result. A client cannot teleport, speed-hack or leave the
arena, because it never gets to say where it is.

Three techniques hide the latency that costs you, and none of them remove it:

| Technique | Hides | Costs |
|---|---|---|
| **Interpolation** | the gap between 20 Hz updates | remote squares are rendered slightly in the past |
| **Prediction** | your own input latency | you can be wrong |
| **Reconciliation** | being wrong | your movement code must be a pure function |

`simulate(pos, dir, delta)` in `main.gd` is that pure function. It reads nothing outside its
arguments except the maze grid — no `Input`, no node state, no randomness — which is the only
reason the client can replay it and land where the server did.

### Why the maze ships as a seed

`set_maze` sends an `int`, never a layout. Every peer runs the same depth-first carve over the
same `RandomNumberGenerator` seed and gets a byte-identical grid.

That is not a bandwidth optimisation, it is a correctness requirement. `simulate()` tests
collision against the grid while replaying buffered inputs, so if two peers disagreed about a
single wall, every prediction after that point would be wrong and reconciliation would fight
the player forever. Shipping a seed makes disagreement impossible by construction.

Everything outside the navigable floor is drawn as lava: charred crust shading toward ember by
per-cell heat, with a molten lip on every face that touches open ground and a slow per-cell
shimmer. It is **decoration only** — those cells are walls, and `simulate()` treats them exactly
as it did before. Touching lava costs you nothing but time.

### Collectibles

Between 14 and 20 pickups lie in the maze at any time; the server re-rolls the target inside
that range every time one leaves. The count is tuned to the arena: at 4× the old floor area,
3–5 items meant wandering for a minute without seeing one. Each is one of four kinds, drawn by weight so the valuable
ones are rare:

| Kind | Worth | Appears |
|---|---|---|
| Gold coin | 1 | 50% |
| Ruby | 2 | 28% |
| Emerald | 3 | 15% |
| Diamond | 5 | 7% |

Every item is born with a lifespan of 8–18 seconds. The server ages them and calls
`remove_item` with `collector = 0` when one times out; clients blink the item out over its
last three seconds, accelerating as it runs down, so "about to vanish" is legible without
counting. `sync_world` sends a late joiner the time *remaining* rather than the full lifespan,
so their countdown lines up with everyone else's.

### Sound

`audio/background.mp3` loops under everything at -14 dB, started in `_setup_audio()`.

Each pickup kind has its own short cue — a flat two-note clink for gold, a warmer resolving
third for a ruby, a rising major arpeggio for an emerald, a four-note sparkle with a
shimmering tail for a diamond. They are generated WAVs, not samples; `tools/make_sounds.py`
regenerates them.

The cue is **deliberately local**. `remove_item` runs on every peer, but only the one whose
`get_unique_id()` matches the collector plays anything:

```gdscript
if collector == multiplayer.get_unique_id() and not is_dedicated:
    _play_pickup(c.kind)
```

So you hear your own pickups and never anyone else's, and a dedicated server never even
allocates the players — `_setup_audio()` returns early when headless, which also spares a VPS
from decoding an mp3 forever.

### Keep every reliable RPC under the MTU

This one cost an evening. `sync_world` originally sent the whole world to a joiner in one
call — seed, scores, standings, icons, names, the full round history and a snapshot of all
20 items. That is **3260 bytes**. ENet's MTU is 1400.

On localhost it worked perfectly: ENet fragments the packet and every fragment arrives.
Through a playit tunnel it did not. The tunnel's effective MTU is lower, MTU-sized fragments
were dropped, the reliable packet could never complete — and because it was reliable and
ordered, **it head-of-line blocked every RPC queued behind it**. The joiner got no maze, no
players, no HUD: a blank screen. ENet then timed the peer out and the client printed
"Server disconnected".

The symptom is badly misleading. Nothing errors, nothing logs, and the one thing you would
suspect — the tunnel — is working fine.

The fix is structural, not a tweak: **bulk state is sent as many small messages, never one
big one.** Round history is built incrementally by every peer via `record_round`, so it never
travels in bulk; live items are replayed to a joiner with one `spawn_item` each. Worst case
with 8 players, maximum-length names, a full item field and nine rounds played:

| RPC | Bytes |
|---|---|
| `sync_world` | 696 |
| `set_maze` | 336 |
| `update_state` | 312 |
| `record_round` | 160 |
| `game_over` | 152 |
| `spawn_item` | 44 |

If you add a field to an RPC, measure it: `var_to_bytes([args]).size()`. Anything approaching
1200 bytes needs splitting.

### Rounds

A round ends when somebody reaches **25 points**; the game ends when somebody has won **10
rounds**. `set_maze` then carves a new layout, resets
every score to zero, and increments that player's win count — one RPC, so no peer can see a
half-applied round. The test is `>=`, not `==`: a 5-point diamond can jump you from 22 straight
past 25.

Per-round scores are transient; `rounds_won` and `round_history` persist until the game ends.
All of it rides along in `sync_world`, so a late joiner sees the standings immediately — even
one who arrives while the results page is up.

A round win pops a one-second overlay (scale-in with a back ease, hold, fade) driven by a
`Tween`. The tenth win opens the results page instead: every round's scores as a
`GridContainer`, a ★ on each round's winner, the totals, and a **Play again** button. The
button sends `request_restart` to the server, which is the only peer allowed to actually deal
a new game. `game_finished` freezes `_physics_process` on every peer while it is up, so nobody
drifts around behind the results.

### The arena and the camera

The arena is 2304×1296 — four viewports — carved into a 39×23 grid, so 19×11 = 209 maze cells.
That is too big to see at once, so a `Camera2D` follows your own square with smoothing, limited
to the arena bounds. The lobby and HUD are `CanvasLayer`s and stay put.

### The handshake

Nothing joins until it has proved it speaks the same protocol. `PROTOCOL_VERSION` is bumped
by hand whenever the RPC surface changes, and it rides in `multiplayer.auth_callback`
alongside the player's name and icon.

Using auth rather than a `hello` RPC matters for two reasons. `peer_connected` does not fire
until auth completes, so a rejected client never reaches the point of having a square in the
world — with a plain RPC we would have had to spawn first and clean up afterwards. And the
accepted client arrives with its identity already known, so it never flickers as
`Player 12345` with the default emoji for a few frames.

Both sides advertise their version, so both can diagnose independently. The server logs
`Refused peer 998613601: protocol 999, we speak 1` and simply never completes auth; the
client gets to say exactly what is wrong:

```
Cannot join: server speaks protocol 999, this build speaks 1
```

which is the whole point, given stage 6's warning about version lock-step.

### Leaving politely

`auto_accept_quit` is off; `NOTIFICATION_WM_CLOSE_REQUEST` closes the ENet peer before
quitting, and `_exit_tree` does the same for a headless server being stopped.

This is worth more than it sounds. Measured: a peer that simply vanishes takes about **10
seconds** for ENet to give up on. A peer that says goodbye is noticed in **0.00 s**.

### Names and icons

Pick an emoji and type a name in the lobby before hosting or joining. The client sends both
with `request_identity`; the server range-checks the index, strips control characters from the
name, caps it at 16 characters and substitutes `Player <id>` if it is empty — then broadcasts
`apply_identity`. A client handing out its own identity directly to other clients is exactly
the pattern stage 4 warned about, so it does not.
Nothing is drawn for the body — just the glyph and a name tag under it. The hitbox is still a
32×32 square whatever emoji you choose, it simply is not visible. The peer colour tints the
name tag, which is what tells two players who picked the same animal apart. Players are repositioned into
open cells as part of the same RPC — the new layout may well have dropped a wall where
somebody was standing — and clients drop their `pending` buffer, since predictions made
against the old walls mean nothing.

## Running it

Requires Godot **4.7.2** (the mono build is what this was developed against; plain Godot
works too and avoids a .NET dependency on a server box).

### Locally, one machine

Press **F5** in the editor and click **Host**. That is a *listen server* — you are peer 1 and
you also have a square. To get a second player, enable *Debug → Customize Run Instances*
with 2 instances, then Host in one window and Join in the other.

### Against a dedicated server

```bash
make server              # terminal 1: headless, binds UDP 9000
make server PORT=7777    # ...or any other port
```

Then F5 and click **Join** in as many instances as you like. Nobody hosts; the server has no
square of its own and survives every client leaving.

`make server` is just shorthand for:

```bash
godot --headless --path . -- --server --port 9000
```

Override the binary with `make server GODOT=/path/to/godot`.

### Over the internet, via playit.gg

The transport is ENet over **UDP**, which rules out ngrok and Cloudflare Tunnel — neither
carries UDP. [playit.gg](https://playit.gg) does, free.

#### One-time setup

**0. Stop the agent starting at boot.** The package enables itself; this project would rather
you start the tunnel deliberately, so nothing is exposed to the internet while you are not
playing:

```bash
sudo systemctl disable playit.service   # one-off: removes the boot symlink
sudo systemctl stop playit.service      # if it is running right now
```

Disable, do not edit `/usr/lib/systemd/system/playit.service` — that file is owned by the
package and an upgrade will overwrite your change. `disable` only removes the
`multi-user.target.wants` symlink; `make tunnel` still starts it fine.

**1. Link the agent to your account.** A fresh install holds no secret and belongs to nobody
yet:

```bash
sudo playit setup          # provisions a secret interactively
sudo playit status         # should stop saying "not running"
```

If `setup` is awkward, the manual path is `playit claim generate` → `playit claim url <code>`
→ open that URL in a browser while logged in → `playit claim exchange <code>`.

**2. Create the tunnel.** There is **no CLI command for this** — `playit --help` lists only
`version`, `attach`, `start`, `stop`, `reset`, `secret-path`, `setup`, `account` and `claim`.
Tunnels are defined on the web dashboard, and the running agent picks them up automatically;
there is no local file to edit.

On [playit.gg](https://playit.gg), in your account's tunnels area, add a tunnel with:

| Setting | Value |
|---|---|
| Protocol | **UDP** — not TCP, and not "both" if it costs you a port |
| Local / target address | `127.0.0.1` |
| Local port | `9000` (match whatever `make server PORT=` you use) |
| Region | Nearest you, the machine actually running the server |

Getting the protocol wrong is the classic silent failure: a TCP tunnel to a UDP server
accepts your friend's connection attempt and then nothing ever happens.

**3. Read the public address.** The dashboard shows it next to the tunnel, or:

```bash
sudo playit attach         # live TUI, lists tunnels and their addresses
```

It looks like `something.playit.gg:53421`. **The public port is assigned and is almost never
9000** — that is the whole reason the Join field parses `host:port`.

#### Every session after that

```bash
make tunnel                # bring the tunnel up
make server                # terminal 1 — binds UDP 9000 locally
make tunnel-attach         # terminal 2 — confirm it is connected, read the address
```

Hand out the `something.playit.gg:53421` string; your friend pastes it whole into the Join
field and clicks Join. Nothing else changes — the server neither knows nor cares that it is
behind a tunnel.

When you are done:

```bash
make tunnel-stop           # nothing is publicly reachable again
```

| Target | Does |
|---|---|
| `make tunnel` | `systemctl start playit.service` |
| `make tunnel-stop` | `systemctl stop playit.service` |
| `make tunnel-status` | service state, then agent state |
| `make tunnel-attach` | live TUI with tunnel addresses |

playitd runs as user `playit` with `RuntimeDirectoryMode=0750`, so its IPC socket in
`/run/playit` is unreadable by you and every CLI call needs `sudo` — without it the CLI
claims the service is not running even when it is. If that gets tedious,
`sudo usermod -aG playit $USER` (then log out and back in) makes the socket reachable, after
which `make tunnel-attach PLAYIT=playit` works without a password prompt.

#### If it does not connect

1. `sudo playit attach` — is the agent connected and is the tunnel listed as online?
2. `ss -ulnp | grep 9000` — is the game server actually bound? No output means `make server`
   failed, usually because a previous one is still holding the port.
3. Is the tunnel **UDP**? Check it, then check it again.
4. Does the tunnel's local port match the `PORT` you launched with?
5. Did your friend include the `:53421` part? Without it the client silently dials 9000 on the
   tunnel host, which is not listening.
6. Give it 30 seconds before declaring failure — ENet waits ~31 s before reporting
   `connection failed`.

## Layout

| File | What it is |
|---|---|
| `main.gd` / `main.tscn` | Everything: lobby UI, peer registry, the six RPCs, server simulation, reconciliation |
| `player.gd` / `player.tscn` | The emoji glyph and name tag, interpolation, and the server's per-peer input queue |
| `maze.gd` | Seeded 19×11 grid maze: generation, collision queries, and the lava `_draw()` |
| `collectible.gd` | One pickup: its kind, sound, lifespan countdown, and how it draws itself |
| `audio/` | Looping background track, plus one synthesised cue per pickup kind |
| `Makefile` | `server`, `tunnel`, `tunnel-stop`, `tunnel-status`, `tunnel-attach` |
| `tests/` | A self-contained runner and 65 tests. `make test` |
| `notes/` | The seven-stage write-up this was built from |

Player nodes are named after their peer id and live under `Main/Players/<peer_id>`, so the
same node sits at the same path on every peer. That is what makes RPC addressing work.

## The fourteen RPCs

| RPC | Annotation | Why |
|---|---|---|
| `spawn_player` | `authority, call_local, reliable` | An *event*. Miss one and a player is invisible forever. |
| `despawn_player` | `authority, call_local, reliable` | Same. |
| `spawn_item` | `authority, call_local, reliable` | An *event*. A missed spawn is an item nobody can see. |
| `remove_item` | `authority, call_local, reliable` | Collection *and* expiry. A missed score is permanently wrong. |
| `sync_world` | `authority, reliable` | Late-join catch-up: seed, scores, standings, icons, live items. Sent *before* the spawns. |
| `request_identity` | `any_peer, call_local, reliable` | A client asks for an emoji and a name; both are validated. |
| `apply_identity` | `authority, call_local, reliable` | The server is the one that tells everybody. |
| `record_round` | `authority, call_local, reliable` | One finished round. Every peer keeps its own history. |
| `game_over` | `authority, call_local, reliable` | Winner and standings. History is already local. |
| `request_restart` | `any_peer, call_local, reliable` | Anyone at the results screen may deal a new game. |
| `restart_game` | `authority, call_local, reliable` | Clears standings and history everywhere. |
| `set_maze` | `authority, call_local, reliable` | A new seed plus everyone's safe position in the new layout. |
| `submit_input` | `any_peer, call_local, unreliable_ordered` | Untrusted. Ordering stops a stale direction overwriting a fresh one. |
| `update_state` | `authority, unreliable` | *State*. A dropped position is worthless 50 ms later — a newer one already arrived. |

The rule worth remembering: **reliable for events, unreliable for state.** Reliable delivery
of positions would stall the stream re-sending data that is already obsolete.

`submit_input` is a public API — anyone who can reach the port can call it. Its three guards
(ignore non-server, trust `get_remote_sender_id()` over any argument, `limit_length(1.0)` the
vector) are the whole of the defence, and they hold: a client spamming `Vector2(9999, 9999)`
moves at exactly normal speed and stops at the arena edge.

## Things that will waste your afternoon

Found the hard way while building this — several contradict the notes, which have not been
corrected.

- **`submit_input` needs `call_local`.** Without it the host's own square never moves and you
  get `RPC 'submit_input' on yourself is not allowed by selected mode`. The notes' stage 4
  omits it and then misdiagnoses the symptom as the `sender_id == 0` mapping.
- **ENet's failure detection is slow.** `connection_failed` with nothing listening takes
  **~31 s**. Noticing a hard-killed server (`kill -INT`) takes **~10 s**. Neither is a bug and
  neither is "a few seconds" — if you give up after five you will think it is broken.
- **`get_viewport_rect().size` returns 1152×1152 in headless mode**, not 1152×648. Hence
  `const ARENA` — a headless server using the viewport would let players walk off the bottom
  of every client's screen.
- **`multiplayer_peer` is never `null`.** Godot 4.7 installs an `OfflineMultiplayerPeer` on
  every scene tree, so before you host or join anything `multiplayer_peer != null`,
  `is_server()` is `true` and `get_connection_status()` is `CONNECTION_CONNECTED`. The
  stage-4 guard `if multiplayer.multiplayer_peer == null: return` therefore never guarded
  anything — the server simulation had been running since startup. Harmless until a `while`
  loop in the spawn code met an empty maze and span forever. Track the session yourself; this
  project uses an explicit `in_session` flag. The notes' stage-4 gotcha ("is `_physics_process`
  returning early because `multiplayer_peer` is `null`?") rests on a false premise.
- **GDScript's `\U` escape takes six hex digits, not eight.** `"\U0001F98A"` silently parses as
  U+0001F9 followed by a literal `8A`, so 🦊 renders as `ǹ8A`. Paste the emoji literally.
- **Do not destroy the peer inside `auth_callback`.** Setting `multiplayer_peer = null` from
  the callback tears the peer down while the multiplayer layer is still walking its own auth
  state, and the engine **segfaults** — signal 11, with a backtrace through `libcoreclr`. The
  message even prints first, so it looks like it worked. Defer the teardown with
  `call_deferred`.
- **`_exit_tree` must not clear the tree's peer unconditionally.** Godot's default
  `OfflineMultiplayerPeer` belongs to the tree, not to your node; clearing it on the way out
  stranded every later test in the shared runner with "no multiplayer peer". Skip the offline
  peer, and close rather than null.
- **`%-18s` does not align anything in a proportional font.** The results table looked like a
  drunk spreadsheet until it became a `GridContainer` with one `Label` per cell. Pad strings
  only under a monospace face.
- **Font order decides whose metrics win.** A `SystemFont` listing "Noto Color Emoji" first
  gives *Latin* text the emoji face's fixed advance width, and the HUD comes out as
  `1 7 / 2 5`. Text face first, emoji as fallback, for anything containing words; emoji first
  only for labels holding a single glyph.
- **An RPC during the handshake is an error, not a no-op.** Between assigning
  `multiplayer_peer` and `connected_to_server` firing, `rpc_id` throws *"Trying to call an RPC
  via a multiplayer peer which is not connected"*. Harmless before stage 7, because input was
  only sent on change and the opening direction is zero; fatal-looking once every tick sends.
  Hence the `get_connection_status()` guard in `_physics_process`.
- **Remote players are drawn in the past.** Interpolation eases toward the last broadcast
  position, so a remote square lags its true position by ~20–30 px while moving. That is the
  deliberate cost of not stepping at 20 Hz, and it is why shooters need lag compensation.
- **The mono editor prints `.NET Sdk not found`.** Harmless — this project is pure GDScript.
  Delete the `[dotnet]` section from `project.godot` to silence it.

## Tests

```bash
make test        # 65 tests, ~1s, exits non-zero on failure
```

No addon and no download: `tests/run_tests.gd` is a `SceneTree` script that finds `test_*`
methods on each suite and counts assertions. Godot hands every tree an
`OfflineMultiplayerPeer`, so `is_server()` is true and `rpc()` runs locally — which means the
whole game can be exercised in one process with no sockets.

They cover the maze (determinism from a seed, solid border, every open cell reachable,
collision queries), collectibles (weights, values, lifespan fade), `simulate()` (speed,
frame-independence, diagonal parity, hostile input clamping, purity, wall collision, sliding,
the unstick rule), parsing (`--port`, `host:port`, IPv6, name sanitising) and game flow
(registry, identity, item pool, scoring, rounds, winning, restart, input validation,
reconciliation, interpolation).

Game logic is driven through `server_add_player` / `server_remove_player` /
`server_add_item` / `server_remove_item` — a deliberate seam, so tests describe behaviour
rather than whichever replication mechanism is underneath.

## Status

Stages 1–7 are implemented and verified with real multi-process runs. Stage 6 went via a
playit.gg tunnel rather than the VPS the notes describe.

From stage 7's menu: **A** (interpolation), **B** (prediction), **C** (reconciliation) and
**D** (the collectible) are done. **E** is done: `MultiplayerSpawner`s replace every
spawn/despawn RPC and per-node `MultiplayerSynchronizer`s replace the 20 Hz `update_state`
broadcast. From **F**: player names, the **protocol version handshake** and **graceful shutdown** are
done. The `Net` autoload and DTLS are not — the autoload is only worth it if the game grows
separate lobby/match scenes, and DTLS behind a tunnel would have to run without hostname
verification, so it buys less than it looks.

### What stage 7E actually bought

Four RPCs are gone — `spawn_player`, `despawn_player`, `spawn_item`, `remove_item` — along
with the `BroadcastTimer`, the `update_state` broadcast, and the whole late-join catch-up
loop for players and items. What replaced them:

| Was | Now |
|---|---|
| `spawn_player` / `despawn_player` RPC | `PlayerSpawner`, a `MultiplayerSpawner` |
| `spawn_item` / `remove_item` RPC | `ItemSpawner`, via `add_spawnable_scene` |
| `update_state` at 20 Hz | a `MultiplayerSynchronizer` per node |
| per-item catch-up to a joiner | the spawners replay live nodes themselves |

What remains hand-written is the part the nodes genuinely cannot do: `submit_input`
(client to server, unreliable-ordered), the round and identity events, and `item_collected`,
which carries the score and the kind so the collector — and only the collector — can play a
sound.

The synchronizer replicates `net_position` and `last_tick`, **not** `position`. Writing
straight into `position` would overwrite the local prediction every tick and stamp on the
interpolation; landing it in a separate field lets `_on_player_synchronized` decide —
reconcile if it is your own square, ease toward it if it is not. Prediction and
reconciliation survive the refactor unchanged.

### Three things that cost real time

- **`spawn_function` data is not replayed to late joiners; `add_spawnable_scene` is.** With a
  custom spawn function, a peer joining mid-game saw an empty maze that slowly filled as new
  items spawned. Switching the items to a spawnable scene, with `kind`, `lifetime`, `age`,
  `position` and `item_id` as **spawn-state properties** (`spawn = true`) on the
  synchronizer, fixed it — and `age` arriving with the spawn keeps the newcomer's blink-out
  in step for free. Changing `Collectible` from `.new()` to a `PackedScene` was *not* what
  fixed it, despite being a reasonable guess.
- **`sync_world` was deleting the replay.** It called `_clear_items()` on the joiner, wiping
  the items the spawner had just handed it. The spawner was working the whole time; the game
  was destroying its output one frame later.
- **A synchronizer whose `replication_config` is still empty when the node enters the tree
  fails outright**, with `Condition "!sync->get_replication_config_ptr()" is true ...
  ERR_UNCONFIGURED`. Building the config in `_ready()` is too late — it belongs in the
  `.tscn` as a sub-resource.

Two asymmetries worth remembering: `spawned` and `despawned` fire **only on peers that
receive** a spawn, so the authority must register its own; and `_clear_items()` now runs on
the server only, because the spawner sends each despawn — having every peer clear locally as
well left clients with 189 items against the server's 19.

There is **no authentication and no encryption**. The port is open to whoever finds it.
`MAX_PLAYERS = 8` is the only thing standing between you and a stranger filling the arena.

## Experiments worth running

Each one takes a minute and teaches more than reading about it.

- **Turn interpolation off.** Set `BroadcastTimer.wait_time` to `0.2` (5 Hz) and comment out
  the `_process` body in `player.gd`. Unplayable. Put it back: surprisingly fine. That is the
  entire argument for interpolation.
- **Turn prediction off.** Return early from the prediction block in `_send_input`. On
  localhost you will barely notice; through the playit tunnel it is mush. That gap is why
  prediction exists.
- **Break reconciliation on purpose.** Make `_server_simulate` refuse to move anyone in the
  left half of the arena, but leave `simulate()` alone for the client. Walk left: you predict
  through, the server says no, and you watch yourself get dragged back 20 times a second.
- **Let clients claim the dot.** Change `on_collected` to `any_peer` and have the client call
  it on contact. Both clients award themselves the same point. Server authority, in one
  five-minute experiment.
