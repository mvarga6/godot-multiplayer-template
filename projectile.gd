class_name Projectile
extends Node2D

## A shot in flight.
##
## Only its *starting conditions* go over the wire — owner, kind, position,
## velocity, lifespan — and then every peer integrates the same pure `step()`
## with the same maze. Same trick as the maze seed: replicate the rule, not the
## state. A projectile crosses the screen in well under a second, so streaming
## its position at 20 Hz would be both expensive and too coarse to look right.
##
## The server still owns every *consequence*. Clients move the dot; only the
## server decides that it hit something, and only the server frees it.

## Spawn state, handed over with the spawn itself.
var shot_id: int = 0
var owner_id: int = 0
var kind: int = Weapon.Kind.CAPTURE
var velocity: Vector2 = Vector2.ZERO
var lifespan: float = 2.5
var age: float = 0.0

func setup(shooter: int, weapon_kind: int, vel: Vector2, life: float) -> void:
	owner_id = shooter
	kind = weapon_kind
	velocity = vel
	lifespan = life

## Pure: advance one tick. Returns the new position, the new velocity (a bounce
## flips a component) and whether the shot is finished.
##
## Reads only its arguments and the shared maze, so server and client agree.
static func step(pos: Vector2, vel: Vector2, delta: float, reflect: bool) -> Dictionary:
	var out_pos := pos
	var out_vel := vel
	var dead := false

	var try_x := Vector2(out_pos.x + out_vel.x * delta, out_pos.y)
	if Maze.is_blocked(try_x, Weapon.RADIUS):
		if reflect:
			out_vel.x = -out_vel.x
		else:
			dead = true
	else:
		out_pos = try_x

	var try_y := Vector2(out_pos.x, out_pos.y + out_vel.y * delta)
	if Maze.is_blocked(try_y, Weapon.RADIUS):
		if reflect:
			out_vel.y = -out_vel.y
		else:
			dead = true
	else:
		out_pos = try_y

	return {"pos": out_pos, "vel": out_vel, "dead": dead}

func _ready() -> void:
	set_process(DisplayServer.get_name() != "headless")

## Clients fly it locally for smoothness. The server does its own stepping
## inside `_server_simulate`, where it can also check what it hit.
func _process(delta: float) -> void:
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		return
	advance(delta)
	queue_redraw()

## One tick of flight. Returns false once the shot is spent.
func advance(delta: float) -> bool:
	age += delta
	if age >= lifespan:
		return false
	var r := step(position, velocity, delta, Weapon.reflects(kind))
	position = r["pos"]
	velocity = r["vel"]
	return not bool(r["dead"])

func _draw() -> void:
	var c: Color = Weapon.colour(kind)
	# A short tail pointing back along the flight path reads as motion without
	# needing a particle system.
	if velocity.length() > 1.0:
		var tail := -velocity.normalized() * (Weapon.RADIUS * 2.4)
		draw_line(Vector2.ZERO, tail, Color(c.r, c.g, c.b, 0.35), Weapon.RADIUS * 0.9)
	draw_circle(Vector2.ZERO, Weapon.RADIUS, c)
	draw_circle(Vector2.ZERO, Weapon.RADIUS * 0.45, Color(1, 1, 1, 0.85))
