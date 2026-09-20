# online-1

A deliberately tiny server-authoritative multiplayer game in Godot 4.7: coloured squares you
move with the arrow keys through a randomly generated maze, racing for a collectible dot.

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

The maze regenerates whenever any score hits a multiple of 10. Players are repositioned into
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
| `player.gd` / `player.tscn` | A 32×32 `ColorRect`, its interpolation, and the server's per-peer input queue |
| `maze.gd` | Seeded 19×11 grid maze: generation, collision queries, and its own `_draw()` |
| `Makefile` | `server`, `tunnel`, `tunnel-stop`, `tunnel-status`, `tunnel-attach` |
| `notes/` | The seven-stage write-up this was built from |

Player nodes are named after their peer id and live under `Main/Players/<peer_id>`, so the
same node sits at the same path on every peer. That is what makes RPC addressing work.

## The seven RPCs

| RPC | Annotation | Why |
|---|---|---|
| `spawn_player` | `authority, call_local, reliable` | An *event*. Miss one and a player is invisible forever. |
| `despawn_player` | `authority, call_local, reliable` | Same. |
| `on_collected` | `authority, call_local, reliable` | Same — a missed score is permanently wrong. |
| `sync_world` | `authority, reliable` | Late-join catch-up: maze seed, dot, scoreboard. Sent *before* the spawns. |
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

## Status

Stages 1–7 are implemented and verified with real multi-process runs. Stage 6 went via a
playit.gg tunnel rather than the VPS the notes describe.

From stage 7's menu: **A** (interpolation), **B** (prediction), **C** (reconciliation) and
**D** (the collectible) are done. **E** — replacing the hand-written RPCs with
`MultiplayerSpawner` / `MultiplayerSynchronizer` — is deliberately not done; the point of this
project is the manual version. **F** (housekeeping: `Net` autoload, protocol version
handshake, player names, DTLS, graceful shutdown) is untouched.

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
