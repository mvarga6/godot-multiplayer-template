# Stage 1 — One square, no networking

**Goal:** a coloured square you can move with the arrow keys. No networking whatsoever.

This stage exists so that when stage 2 breaks, you know it is the *network* that broke and
not your scene, your input, or your main-scene setting.

---

## Key concepts

### Nodes, scenes, and the scene tree
A **node** is one object with one job (draw a rectangle, play a sound, hold a position). A
**scene** is a tree of nodes saved to a `.tscn` file. A scene can be *instanced* inside
another scene — that is Godot's only composition mechanism, and it is how `player.tscn` will
end up inside `main.tscn` once per connected player.

At runtime everything lives in one **scene tree**. `add_child()` puts a node into it;
`queue_free()` takes it out at the end of the frame. Multiplayer in Godot is built directly
on this tree: RPCs are addressed by **node path**, so a node must exist at the *same path*
on every peer for an RPC to reach it. That constraint drives the whole design in stage 3.

### `_process` vs `_physics_process`
`_process(delta)` runs once per rendered frame — variable rate, depends on the machine.
`_physics_process(delta)` runs at a **fixed** rate (60 Hz by default, `physics/common/
physics_ticks_per_second`). Use the physics one for anything that has to agree between two
computers. Fixed-rate simulation is a precondition for the server and client ever producing
the same answer.

### `delta` and frame independence
`delta` is seconds elapsed since the previous call. Always multiply movement by it
(`position += dir * SPEED * delta`) so speed is measured in pixels *per second* rather than
pixels per frame. Without it, a fast machine moves faster than a slow one — which in a
multiplayer game means two players disagree about where things are.

### Input actions
Godot maps physical keys to named **actions** in the input map. The project already has
built-in `ui_left` / `ui_right` / `ui_up` / `ui_down` bound to the arrow keys, so we reuse
those and skip editing the input map entirely.

`Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")` returns a `Vector2` already
normalised — diagonal movement is not faster than straight movement, which you would have
to fix by hand if you polled the four actions separately.

### `preload` vs `load`
`preload()` resolves at parse time and costs nothing at runtime; `load()` resolves when the
line executes. Use `preload` for scenes you know you need.

---

## Steps

### 1. `player.tscn`
- Root: `Node2D`, renamed **`Player`**. Attach `player.gd`.
- Child: `ColorRect`, size `32 x 32`, position `(-16, -16)`.

That offset is what makes the node's origin the *centre* of the square instead of its
top-left corner. Positions then mean what you expect.

### 2. `player.gd`

```gdscript
extends Node2D

const SPEED := 220.0

func _physics_process(delta: float) -> void:
	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	position += dir * SPEED * delta
```

### 3. `main.tscn` / `main.gd`
- Root: `Node2D`, renamed **`Main`**. Attach `main.gd`.
- Child: `Node2D` renamed **`Players`** — an empty container. Every player node will go in
  here, which keeps their node paths predictable (`/root/Main/Players/<peer_id>`).

```gdscript
extends Node2D

const PLAYER_SCENE := preload("res://player.tscn")

@onready var players_root: Node2D = $Players

func _ready() -> void:
	var p := PLAYER_SCENE.instantiate()
	p.position = Vector2(576, 324)
	players_root.add_child(p)
```

### 4. Make it the main scene
*Project → Project Settings → Application → Run → Main Scene* = `res://main.tscn`.
While you are in there, set *Display → Window → Size* to `1152 x 648` so two test windows
fit side by side on screen in stage 2.

---

## Verify

Press **F5**. A square appears near the middle and moves with the arrow keys. It should
drift at the same speed diagonally as it does straight.

---

## Gotchas

- **Nothing happens on F5** — main scene not set, or `main.gd` is not attached to the root.
- **The square moves from its corner** — you forgot the `(-16, -16)` offset on the ColorRect.
- **Diagonal movement is faster** — you are not using `Input.get_vector`, or you normalised
  after scaling instead of before.
- **`$Players` is null** — `@onready` runs when the node enters the tree; using a plain `var`
  with `$Players` at the top of the script runs too early and returns `null`.

---

## What you should now understand

The scene tree, and specifically that **node paths are stable addresses**. Hold onto that —
in stage 3 those paths become the addressing scheme for every packet you send.
