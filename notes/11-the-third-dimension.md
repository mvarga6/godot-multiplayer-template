# Stage 11 — The third dimension

> You end up with: a 3D first-person shooter running as one lobby among several,
> on a server that was built for 2D games and barely noticed.

Stage 10 made the second game properly 3D-ish. This one makes the third game actually 3D:
`games/asalted/` — "A Salted", a small Quake-shaped arena shooter. A square room, random
blocks and pillars in the middle, players drawn as a handful of ellipsoids, and hitscan.

The interesting question was never "can Godot do 3D". It was **how much of a server built
around 2D games has to change to host one.** The answer turned out to be one method.

## The shell changed by exactly one method

`GameWorld extends Node2D`, and it still does. The 3D lives in a `Node3D` child of the
World:

```
AsaltedWorld (Node2D)        <- what GameWorld requires
├── Sync                     <- lobby_id and arena_seed
├── Space (Node3D)           <- the 3D world
│   ├── Arena                <- floor, walls, barriers
│   └── Players (Node3D)     <- spawn path
├── PlayerSpawner
└── Hud (CanvasLayer)        <- the crosshair
```

Godot is perfectly happy with a `Node3D` hanging off a `Node2D`. They are not really
parent and child in a spatial sense — 3D and the canvas are two passes over the same
viewport, and the `Node3D` simply becomes a root in the 3D pass. The CanvasLayer HUD draws
over both. This was worth checking before designing anything around it, and checking it
took one throwaway script.

So the temptation — rewrite `GameWorld` as a plain `Node`, move A Mazing's and Ashamed's
2D drawing into child nodes, touch every game to make room for the new one — was not just
risky, it was unnecessary. **The refactor that is obviously needed is worth ten minutes of
trying to avoid.**

What *did* have to change is that the shell owns a `Camera2D` and has always assumed it is
the view:

```gdscript
## Whether the shell's Camera2D is this game's view.
func uses_shell_camera() -> bool:
    return true
```

A 3D game returns false, drives its own `Camera3D`, and the shell stops clamping and moving
a camera that is not looking at anything. That is the third leak of the same kind — after
`world_bounds()` and `camera_focus()` — and the pattern is consistent: every one of them was
a place where the *first* game's assumptions had quietly been written down as the shell's.

## Why there is not a single PhysicsBody in it

Godot has `CharacterBody3D` and `move_and_slide`, and this game uses neither. Collision is
hand-written: circles and boxes, resolved by arithmetic, in static functions over a plain
`Array`.

That is not purism. It falls straight out of stage 7:

> Reconciliation replays `simulate()` over the buffered inputs, so it must read only its
> arguments.

You cannot replay the physics server. Rewinding a client four ticks and re-running them
means calling the movement function four times *inside one frame*, and a `PhysicsBody` only
moves when the physics step runs. Prediction and a physics engine want opposite things, and
this is why so many networked games end up with their own collision code.

So the map is a list of `{kind, pos, half, radius, top}` and the whole of collision is:

* push a circle out of a box or a circle, leaving by the nearer face so you slide along
  cover instead of sticking to it;
* find what is underfoot;
* clamp to the room.

Only the *seed* goes over the wire — the same rule as the maze in stage 7. Every peer builds
the same barriers, so every peer's replay agrees.

## The bug that took two processes to find

The landing rule started as: **the support under you is the top of the tallest barrier whose
footprint you overlap.** That sounds right and is completely wrong.

Walk into the side of a box and you do overlap its footprint. So the server decided you were
standing on its roof and snapped you up 2.3 metres — and once you were on top, nothing
blocked you, so you strolled across every piece of cover in the map.

The unit test for it passed. It used a tidy box: half-extents of exactly 1.0 at the origin,
where the push-out lands the body exactly on the boundary and the floating-point rounding
happened to fall on the safe side. Generated maps use numbers like `half = (1.88, 1.49)` at
`z = -5.15`, where it falls the other way.

What found it was two real processes and a randomly seeded map: a client ran at a barrier
and sailed straight through it, and the server agreed — which ruled out replication and
pointed at the rule itself.

The fix names the thing the old rule left out:

```gdscript
## What the body actually lands on: the floor, or the top of something it was
## already above.
static func support_under(barriers, x, z, radius, feet_from: float) -> float:
    for b in barriers:
        if float(b["top"]) > feet_from + 0.01:
            continue        # you were not above it: you cannot land on it
```

You land on things you fall onto. You do not get lifted by things you walk into. With that,
a low box is a perch you can jump onto and a tall one is cover you cannot — and neither
needs a special case.

The regression test now uses those awkward generated numbers on purpose. **A test whose
fixture sits on round numbers is testing the round numbers.**

## Hitscan, and why cover works

Shooting is a ray from the eye, on the server, against the same geometry every peer has.
The first thing the ray meets wins:

```gdscript
var wall := Arena.ray_distance(arena.barriers, from, dir)
var best := minf(wall, SHOT_RANGE)
for id in players:
    var d := hit_distance(players[id].pos, from, dir)
    if d < best:
        best = d
        victim = id
```

A pillar nearer than a body means the body is not hit. That one comparison *is* the cover
mechanic, and it is worth stating plainly because it is easy to write a shooter where the
ray checks players first and everyone shoots through walls.

Yaw is sent with the input rather than derived on the server, for the same reason positions
are predicted: the client turned the instant the mouse moved and predicted with the new
heading. If the server used a heading of its own the two would disagree on every shot.

## One thing visibility gating does not cover

Lobby isolation works by hiding each World's synchronizer from peers in other lobbies. That
hides spawns, despawns and state — but **it does not filter RPCs**. A peer in another lobby
has no node at this path at all, so a broadcast `rpc()` arrives somewhere it cannot be
resolved.

So this game addresses its members explicitly:

```gdscript
func _tell_members(method: StringName, args: Array) -> void:
    callv("rpc_id", [1, method] + args)
    for peer in multiplayer.get_peers():
        if game.is_member(lobby_id, peer):
            callv("rpc_id", [peer, method] + args)
```

## Verifying it

31 unit tests cover the pure parts: that a seed reproduces a map exactly, that barriers
leave a walkable gap and keep out of the spawn ring, that you cannot walk through cover or
leave the room, that you slide along a face, that a low box can be jumped onto and a tall
one cannot, that walking into either kind never lifts you, that ray-box and ray-cylinder
hit what is in front and ignore what is behind, and that reconciliation restores position,
velocity and footing.

Then five processes, because none of that proves the wire works: a server, two players in
the shooter and two more in an A Mazing lobby at the same time. The client's predicted stop
against a barrier matched the server's computed block point to the centimetre; a shot
through cover scored nothing and the same shot in the open scored a frag and respawned the
victim; every peer agreed on every number, and all five logs were clean.

## What you should now understand

That "can this architecture host a different kind of game" is answered by writing one, not
by reasoning about it — and that the answer is usually "yes, plus one method you had not
noticed was an assumption".

And that prediction is what decides your collision code. The moment a client replays input,
the physics engine is no longer available to you, and that constraint reaches all the way
down into how the map is represented.
