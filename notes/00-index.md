# Notes: building a trivial online multiplayer game

Eleven stages, smallest-possible online game in Godot 4.7. Each stage ends in something you
can run. Read them in order — later stages assume the vocabulary of earlier ones.

| # | Stage | You end up with |
|---|---|---|
| [1](01-one-square.md) | One square, no networking | A square you can move with the arrow keys |
| [2](02-lobby-and-peers.md) | Lobby: host and join | Two processes with a live connection between them |
| [3](03-spawn-and-despawn.md) | Spawn and despawn players | A square per connected player, appearing and vanishing |
| [4](04-movement-over-the-wire.md) | Movement across the wire | An actually-playable shared world on localhost |
| [5](05-dedicated-server.md) | Split the server out | A headless server process, clients connecting to it |
| [6](06-deploy-to-vps.md) | Put it on the internet | Someone on another network playing with you |
| [7](07-going-further.md) | Going further | Interpolation, prediction, shared objects |
| [8](08-projectiles.md) | Projectiles | Three weapons players can use on each other |
| [9](09-lobbies.md) | Lobbies | Several independent games on one server |
| [10](10-two-and-a-half-d.md) | Two and a half D | A side-on game with depth, and the state that makes it replicate |
| [11](11-the-third-dimension.md) | The third dimension | A 3D shooter on a server built for 2D, and what that cost |

## The whole thing in one picture

```
client: read input ──rpc_id(1, submit_input, dir)──▶ server: store dir per peer
                                                     server: _physics_process moves everyone
client: draw squares ◀──rpc(update_state, {id: pos})── server: broadcast ~20x/sec
```

## Ground rules chosen up front

- **GDScript**, not C#.
- **`ENetMultiplayerPeer`** (UDP). Desktop only — no web export, which would force WebSocket.
- **Hand-written `@rpc` functions.** Nothing auto-synced. The point is to see the traffic.
- **Server-authoritative.** Clients send input; the server owns every position. This is the
  model a dedicated server implies, and the one worth learning.

## Vocabulary you will need throughout

| Term | Meaning |
|---|---|
| **peer** | One participant in the session — server or client. |
| **peer id** | `int` identifying a peer. **The server is always `1`.** Clients get random positive ids. `0` means "the local machine" in some contexts. |
| **authority** | The peer allowed to decide something. Here: the server decides everything. |
| **RPC** | Remote Procedure Call — you call a function, it runs on *other* machines. |
| **`multiplayer`** | Every Node has this property: the `MultiplayerAPI` for its scene tree. |
| **`multiplayer_peer`** | The transport object. Until you assign one, no networking happens at all. |
