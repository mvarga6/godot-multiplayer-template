# Stage 8 — Projectiles

**Goal:** three weapons. `A` picks the Collector, `S` the Freeze Ray, `D` the Pickpocket;
`Space` fires. A Collector shot swallows a gem and scores it for whoever fired it. A Freeze
Ray pins another player for three seconds. A Pickpocket lifts a point off them. All three are
configured from one table.

This is the first stage where players can *act on each other*, and it is where the earlier
rules — "reliable for events, unreliable for state", "the server owns every consequence",
"replicate the rule, not the state" — start paying for themselves.

---

## Key concepts

### Firing is an event, not state
Movement is a 60 Hz stream: miss a packet and the next one corrects you. Firing is not like
that. A dropped shot is a shot the player believes they took and never happened, and no
later packet repairs it.

So firing does **not** ride along in `submit_input`. It gets its own reliable RPC:

```gdscript
@rpc("any_peer", "call_local", "reliable")
func request_fire(kind: int) -> void:
```

Same rule as stage 3's spawn and stage 4's positions, applied to a third case. If you find
yourself tempted to add a `fire` boolean to the movement packet, this is the argument
against it.

### Replicate the rule, not the state — again
A shot crosses a corridor in a fraction of a second. Streaming its position at 20 Hz would
be both expensive and far too coarse to look right.

Instead only its *starting conditions* go over the wire — owner, kind, position, velocity,
lifespan — and every peer integrates the same pure function against the same maze:

```gdscript
static func step(pos: Vector2, vel: Vector2, delta: float, reflect: bool) -> Dictionary:
```

This is exactly the maze-seed trick from stage 8's predecessor: send what *determines* the
motion, not the motion. It works for the same reason — every peer already has an identical
maze, so every peer computes an identical flight path.

Clients fly the dot. The **server alone** decides it hit something, and the server alone
frees it. Divergence of a few pixels between peers is invisible and harmless, because the
pixels were never what mattered.

### Weapons are data
Everything tunable lives in one table, and `projectile.gd` has no idea what a freeze ray is:

```gdscript
const SPECS := {
    Kind.CAPTURE: {"speed_mult": 2.0, "cost": 0, "lifespan": 2.5, "reflect": false,
                   "hits_items": true,  "hits_players": false, "freeze_seconds": 0.0, ...},
    Kind.FREEZE:  {"speed_mult": 2.0, "cost": 0, "lifespan": 2.5, "reflect": false,
                   "hits_items": false, "hits_players": true,  "freeze_seconds": 3.0, ...},
}
```

Speed is a *multiple* of the player's, so retuning `SPEED` retunes the weapons with it. A
third weapon should be a third entry here and nothing else — that is the test of whether
the split is real.

### Facing is server-derived
Shots come out the way the player last actually moved, tracked from *consumed input* on the
server:

```gdscript
if p.input_dir.length() > 0.001:
    p.facing = p.input_dir.normalized()
```

The tempting alternative is to let the client send its aim with the fire request. It is more
responsive and more precise — and it is one more thing a client gets to assert about the
world. Deriving it from input the server already validated costs nothing and is not
spoofable. Standing still keeps you aimed where you were going, rather than snapping to a
default.

### A status effect has to reach the predictor
Freezing is the first thing in this game that stops a player moving *against their own
input*, and that breaks prediction unless you are careful.

The owning client predicts its own movement. If it does not know it is frozen, it predicts
motion for three seconds while the server refuses to move it, and reconciliation yanks it
back twenty times a second. The fix is that `frozen_remaining` is **replicated**, and both
sides feed movement through the same gate:

```gdscript
func effective_dir(wanted: Vector2) -> Vector2:
    return Vector2.ZERO if is_frozen() else wanted
```

`simulate()` stays pure and knows nothing about freezing — the *caller* decides what
direction to hand it. That keeps reconciliation's replay valid, because the predicted
direction stored in `pending` is the gated one.

### A status effect must not be refreshable
Freezing someone who is already frozen does **not** top their timer back up. Without that
rule, two players can trade shots and keep a third parked forever — a stun-lock, and the
classic reason status effects need an immunity window.

The shot is not consumed either: an already-frozen player is simply not a valid target, so
the projectile flies on and can still hit somebody behind them. That is a choice, not a
law — consuming it instead would make spamming at a frozen player cost you the shot.

### Charging for a shot is a score change like any other
The moment a weapon costs something, the deduction has to reach every peer. Writing it
straight into the server's own `scores` dictionary is invisible to clients and desyncs the
scoreboard — and it stays invisible for as long as every weapon happens to be free, which is
exactly how it survives review. Costs and steals both go out as a small reliable
`scores_changed`.

### One award path, two ways to reach it
Walking into a gem and shooting one must score identically — same points, same round-win
check, same despawn. That means one function:

```gdscript
func _award_item(pid: int, iid: int) -> void:
```

called by `_check_pickup` and by `_resolve_shot_hit`. Two copies of "add score, remove item,
maybe end the round" is how the two paths quietly drift apart.

---

## Steps

### 1. `weapon.gd` — the table
`class_name Weapon`, an enum of kinds, the `SPECS` dictionary, and typed accessors
(`Weapon.speed(kind, player_speed)`, `Weapon.cost(kind)`, …). Accessors rather than raw
dictionary lookups so a typo is a parse error rather than a `null`.

### 2. `projectile.tscn` / `projectile.gd`
A `Node2D` with a `MultiplayerSynchronizer` whose properties are all **spawn-state**
(`spawn = true`, `replication_mode = 0`): `shot_id`, `owner_id`, `kind`, `position`,
`velocity`, `lifespan`, `age`. Nothing streams after the spawn.

`step()` is static and pure. `advance()` wraps it with the lifespan countdown. `_process`
calls `advance()` on clients only — the server does its own stepping where it can also check
what was hit.

Axis-separated wall handling, the same shape as player movement: try X, then try Y. On a
blocked axis, either flip that component (reflect) or kill the shot.

### 3. Player state
`facing`, `frozen_remaining` (replicated), and a `cooldowns` dictionary. Add
`frozen_remaining` to the player's replication config — it is the whole reason prediction
survives.

### 4. A third spawner
`ProjectileSpawner`, `add_spawnable_scene("res://projectile.tscn")`, `spawn_path` pointing
at a `Projectiles` container. Same pattern as the collectibles: scene-based auto-spawn, not
a custom `spawn_function`, or live shots will not replay to a peer that joins mid-game.

### 5. Server simulation
In `_server_simulate`, after moving players:

```gdscript
_advance_shots(delta)     # fly, then resolve
```

`_resolve_shot_hit` consults the spec rather than the kind: `if Weapon.hits_items(...)`,
`if Weapon.hits_players(...)`. It skips `shot.owner_id`, so your own freeze ray passes
through you.

### 6. Input
Register the actions in code rather than in the input map — for the same reason stage 1
reused `ui_*`, it keeps the binding next to the code that reads it:

```gdscript
InputMap.add_action("fire")
var ev := InputEventKey.new()
ev.physical_keycode = KEY_SPACE
```

**Physical** keycodes, so `A`/`S` are still where your fingers are on AZERTY.

---

## Verify

- Fire at a gem down a corridor. It vanishes and your score goes up by its value.
- Fire a Collector at another player. Nothing happens; it flies on past.
- Fire a Freeze Ray at another player. They wash pale blue and stop for three seconds — on
  **both** screens. Then they thaw.
- Fire a Freeze Ray and walk into it. Nothing happens; it is your own shot.
- Hold `Space`. The cooldown limits you; you do not get a stream.
- Set `"reflect": true` on a weapon and shoot a wall. It comes back.
- Win a round with a shot in the air. The new maze sweeps it away and thaws everyone.

The one worth doing deliberately: **get frozen while running**. Your square stops dead
rather than stuttering back and forth. Stuttering would mean `frozen_remaining` was not
reaching your client and prediction was fighting the server.

---

## Gotchas

- **Shots die the instant they are fired.** The muzzle is inside the shooter's own square,
  or inside a wall. Push the spawn point out by `HALF + RADIUS` along the facing.
- **Nothing is ever hit.** Your test teleported the players somewhere arbitrary, and
  "arbitrary" in this arena is usually inside lava. Place them in a corridor.
- **The frozen player stutters instead of stopping.** `frozen_remaining` is not replicated,
  so the owning client is still predicting movement.
- **A frozen player snaps back on thaw.** The `pending` buffer still holds predictions made
  while moving. Clear it when the freeze lands.
- **Shots do not appear for a peer that joined mid-game.** The spawner is using a custom
  `spawn_function` instead of `add_spawnable_scene`. Custom spawn data is not replayed.
- **Holding fire floods the server.** `request_fire` is `any_peer`; without a cooldown it is
  an open invitation. The cooldown is rate limiting first and game balance second.

---

## What you should now understand

How to add an *interaction* rather than another piece of scenery: an event RPC for the
action, deterministic simulation for the presentation, server adjudication for the
consequence, and a replicated status effect that the client's own predictor has to respect.

The pattern generalises. A weapon that pushes players, a mine that arms after a delay, a
shield that blocks a freeze — all of them are the same four pieces, and most of them are a
new row in `SPECS`.
