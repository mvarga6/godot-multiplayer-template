# Stage 10 — Two and a half D

> You end up with: a side-on game whose players can walk *into* the screen, where
> distance reads as perspective and every axis survives the trip over the wire.

Stage 9 left `games/ashamed/` as a skeleton: a second game type that existed to prove the
abstraction was real. This stage makes it a game, and the interesting part is not gravity —
it is the extra axis.

## The idea

A 2D side-scroller draws the world side-on: `x` goes along the level, `y` goes up. There is
no room in that for "further away", because `y` is already spent on height.

2.5D takes the axis back by *deriving* the screen position instead of storing it. A body
gets three numbers:

```
ground.x   along the level, left and right
ground.y   depth — into the screen, away from the camera
height     off the floor, which is what jumping changes
```

None of those is a screen coordinate. There is no third axis in the engine: every node is
still a `Node2D` at a `position`. The depth is a convention, and exactly one function is
allowed to know how it flattens:

```gdscript
static func project(ground: Vector2, height: float, eye_x: float) -> Vector2:
    var k := depth_scale(ground.y)
    return Vector2(
        eye_x + (ground.x - eye_x) * k,
        lerpf(GROUND_NEAR_Y, GROUND_FAR_Y, depth_ratio(ground.y)) - height * k)
```

Walking into the screen moves you *up* the floor band. Jumping moves you up too. On screen
they are the same direction, which is the whole illusion and also the reason the state has
to keep them apart: they behave completely differently. Depth is a position you hold; height
is a thing gravity is always taking back.

## One factor, applied to every length

Here is the rule the whole illusion rests on, and it is easy to half-apply:

> Every world-space **length** is drawn multiplied by the foreshortening at its depth.

There are three lengths in this game, and the first version of this code scaled only one of
them:

| Length | Drawn as |
|---|---|
| the body's own size | `scale = depth_scale(depth)` |
| the height of its jump | `height * depth_scale(depth)` |
| its distance sideways from the camera axis | `(x - eye_x) * depth_scale(depth)` |

Miss the second and a body drawn at 60% size still jumps its full near-field pixel height,
so a distant player leaps several times their own body height while a near one manages one.
Nothing about the physics is wrong — it is the drawing that lies.

Miss the third and the floor is a full-width band with small figures standing on it: the
parallel posts along the level stay parallel, which is precisely the cue that says "flat".
Running both edges of the floor through `project` makes them converge on a vanishing point,
and the posts converge with them.

`eye_x` is the axis all that convergence happens about, and it has to be the camera's, for a
practical reason: a body sitting on the camera's own axis has no sideways distance to
foreshorten, so the player you are controlling never slides sideways as they walk into the
screen. With smoothing enabled that axis is `camera.get_screen_center_position().x` and not
`camera.position`, which is where the camera is *heading* — converge the floor on a point the
camera has not reached yet and the whole world visibly swims.

**None of this touches the model.** `simulate()` never learns how deep you are; a jump's apex
is the same number of world units at every depth, and a test asserts exactly that by running
two jumps side by side at depth 0 and depth 240 and comparing them tick for tick. Only the
drawing foreshortens. That separation is the thing to hold on to: if fixing perspective ever
requires changing physics, the perspective is in the wrong place.

## The one cue projection cannot give you

Depth and height both draw you higher up the screen, so a distant player standing still and
a near player at the top of a jump are, on their own, the same picture. No amount of correct
projection fixes that — the information is genuinely absent.

The standard answer is a shadow, because it stays on the floor while the body leaves it. It
costs almost nothing here: drawn in the body's *local* space, which is already scaled by
`depth_scale`, so it shrinks with distance for free, and a screen lift of `height * k` is a
local offset of exactly `height`.

## Perspective is not a lerp

The obvious version of `depth_ratio` is `depth / DEPTH_RANGE` — depth 120 of 240 lands
halfway up the floor. It looks wrong immediately, like a ramp rather than a receding plane,
because real recession is not linear. Equal steps away from the eye cover less and less
screen as they go.

That falls out of similar triangles: a point at distance `d` from an eye `FOCAL` in front of
the near edge projects at `d / (d + FOCAL)`. Normalising so the far edge still lands on the
far line:

```gdscript
static func depth_ratio(depth: float) -> float:
    var d := clampf(depth, 0.0, DEPTH_RANGE)
    var k := d / (d + FOCAL)
    var k_max := DEPTH_RANGE / (DEPTH_RANGE + FOCAL)
    return k / k_max
```

A quarter of the way back is then **45%** of the way up the screen, not 25%. `FOCAL` is the
lens: smaller is wider-angle and more dramatic.

The same ratio drives two more things, because one depth cue is never convincing:

```gdscript
static func depth_scale(depth) -> float: return lerpf(1.0, FAR_SCALE, depth_ratio(depth))
static func depth_z(depth) -> int: return int(round(lerpf(64.0, 0.0, depth_ratio(depth))))
```

Further away is drawn higher, smaller, and behind. The floor's own `_draw()` uses it a fourth
time: depth rules at even *world* intervals bunch visibly toward the horizon, which is what
sells the plane as a plane.

Moving in depth is also deliberately slower than running (`DEPTH_SPEED` 190 against
`RUN_SPEED` 300). Perspective implies it — the same world distance covers less screen going
back than going sideways — and without it, walking in feels like being winched.

## What this costs on the network

Nothing, if the state is chosen correctly, and that is the actual lesson.

The temptation is to replicate `position`, because that is what you can see. Don't: it is
*derived*. Replicating it sends the same information twice, in a form that cannot be
simulated forward, and leaves the receiver unable to say how high up the screen something
should be drawn when it arrives between updates.

So the wire carries the world, not the screen — `net_ground`, `net_height`, `net_v_height`,
`net_grounded` — and each peer projects locally. Remote players interpolate the *world*
values and project afterwards:

```gdscript
ground = ground.lerp(target_ground, k)
height = lerpf(height, target_height, k)
position = AshamedWorld.project(ground, height, eye)
scale = Vector2.ONE * AshamedWorld.depth_scale(ground.y)
z_index = AshamedWorld.depth_z(ground.y)
```

Interpolating the screen position instead would slide a body along a straight line between
two points on a curve, at constant size, through the wrong z-order. Interpolating the world
makes the perspective fall out correctly for free at every intermediate frame, because the
projection is applied *after* the smoothing rather than before it.

This is the same rule as the maze seed in stage 7, wearing different clothes: **replicate the
cause, derive the effect.**

## Gravity, and what reconciliation now has to carry

A Mazing could reconcile a position alone: let go of a key there and you stop dead, so
replaying the inputs rebuilds the state completely. Momentum breaks that. `simulate()` takes
and returns position, vertical velocity *and* whether you are standing on something, and all
three are replayed:

```gdscript
static func simulate(ground, height, v_height, grounded, move, jump, delta) -> Dictionary
```

Reconciling only the position leaves you in the right place moving the wrong way — visible
as a stutter at the top of every jump. Reconciling only the position and velocity lets a
correction land you airborne one tick, so the next input gets you a second jump.

Gravity acts on `height` and never on depth, which is the one invariant worth writing a test
about: walking into the screen must not make you fall, and jumping must not move you back.

One consequence of momentum, when a client's input does not arrive in time: the server keeps
running you the same *direction*, but **never repeats the jump**. A jump is an edge, not a
state. A repeated edge is a free second jump on every starved tick.

## Verifying it

27 unit tests cover the parts that are pure functions — projection (further is higher,
smaller, behind; a jump foreshortens by exactly the factor its body does; sideways distance
converges symmetrically about the eye; the jump *model* is identical at every depth;
out-of-range depth is clamped rather than extrapolated), the floor plane (in, out, edges,
diagonals no faster than straight lines), gravity and jumping (no mid-air jump, arcs that
return to where they started, terminal velocity, air control), and reconciliation restoring
every axis.

None of that can tell you the axes survive replication, so real processes do: a client walks
into the screen and jumps while another watches. Both agree on depth 228 and scale 0.61, and
disagree on height mid-jump by exactly the interpolation lag you would expect. A second run
checks the projection end to end, asserting that each body's rendered `position.x` equals the
formula and that a body at depth 0 lands on its world x untouched.

One warning from doing that, for anyone who repeats it: run every client headless. A Godot
process with a real window will pick up stray key events from whatever has focus, and a
player who drifts because your terminal sent them a keystroke looks exactly like a
replication bug for about twenty minutes.

## What you should now understand

That "what do I store?" is a networking decision, not a rendering one. Storing the screen
position would have worked fine in a single process and been wrong the moment a second one
had to draw the same body between two updates.

And that a pseudo-dimension costs almost nothing when every peer computes it from replicated
state, and costs a great deal when anyone tries to send it.
