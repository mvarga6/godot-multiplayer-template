class_name Arena
extends Node3D

## The map: a square room with random blocks and pillars dropped in the middle.
##
## Only the *seed* crosses the wire, exactly as the maze does in A Mazing, and
## for the same reason: reconciliation replays movement against this geometry,
## so two peers disagreeing about one pillar would make every prediction wrong
## forever. Replicating a seed instead of a layout makes that impossible.
##
## Collision lives here too, as static functions over a plain Array. Nothing
## here is a PhysicsBody: `simulate()` has to be a pure function of its
## arguments so the client can replay it, and the physics server is not
## something you can replay.

const SIZE := 44.0                  # the room is SIZE x SIZE metres
const HALF := SIZE * 0.5
const WALL_HEIGHT := 7.0
const WALL_THICKNESS := 0.6

## Barriers go in the middle, leaving a clear lane all the way round the edge
## so there is always somewhere to run.
const MID_MARGIN := 8.0
const BARRIER_COUNT := 16
const BARRIER_GAP := 2.4            # room to walk between any two of them

enum Kind { BOX, PILLAR }

## [{kind, pos: Vector3 (centre of the footprint, y = 0), half: Vector2 (box),
##   radius: float (pillar), top: float}]
var barriers: Array = []
var current_seed := 0

# --- generation ---------------------------------------------------------------

func generate(arena_seed: int) -> void:
	current_seed = arena_seed
	barriers = build_barriers(arena_seed)

## Static, so a test can generate a layout without a scene tree, and so the
## same call produces the same map on every peer.
static func build_barriers(arena_seed: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = arena_seed
	var out: Array = []
	var reach := HALF - MID_MARGIN
	var tries := 0
	while out.size() < BARRIER_COUNT and tries < 600:
		tries += 1
		var b := {}
		var at := Vector3(rng.randf_range(-reach, reach), 0.0, rng.randf_range(-reach, reach))
		if rng.randf() < 0.6:
			var half := Vector2(rng.randf_range(1.0, 2.6), rng.randf_range(1.0, 2.6))
			b = {"kind": Kind.BOX, "pos": at, "half": half, "radius": half.length(),
				"top": rng.randf_range(1.2, 4.5)}
		else:
			var r := rng.randf_range(0.8, 2.0)
			b = {"kind": Kind.PILLAR, "pos": at, "half": Vector2(r, r), "radius": r,
				"top": rng.randf_range(2.0, 6.0)}
		if _too_close(out, b):
			continue
		out.append(b)
	return out

static func _too_close(existing: Array, b: Dictionary) -> bool:
	for other in existing:
		var a: Vector3 = b["pos"]
		var c: Vector3 = other["pos"]
		var need: float = float(b["radius"]) + float(other["radius"]) + BARRIER_GAP
		if Vector2(a.x - c.x, a.z - c.z).length() < need:
			return true
	return false

## Somewhere to appear that is not inside a pillar. Spawns hug the outer ring,
## which is kept clear of barriers by construction.
static func spawn_point(barriers_in: Array, rng: RandomNumberGenerator) -> Vector3:
	for _i in 60:
		var edge := HALF - 3.0
		var p := Vector3(rng.randf_range(-edge, edge), 0.0, rng.randf_range(-edge, edge))
		if maxf(absf(p.x), absf(p.z)) < HALF - MID_MARGIN - 2.0:
			continue                # too far in; that is barrier country
		if support_top(barriers_in, p.x, p.z, 0.5) == 0.0:
			return p
	return Vector3(HALF - 3.0, 0.0, HALF - 3.0)

# --- collision, as pure functions ---------------------------------------------

## Does a barrier's solid volume reach above a pair of feet at `feet`?
##
## Everything rests on the floor, so this is just "is its top above you". The
## epsilon keeps someone standing exactly on a box from being shoved off it.
static func _blocks(b: Dictionary, feet: float) -> bool:
	return feet < float(b["top"]) - 0.01

## Push a body's circle out of anything it has ended up inside, and keep it
## inside the room. Horizontal only -- vertical is the caller's business.
static func resolve(barriers_in: Array, pos: Vector3, radius: float) -> Vector3:
	var p := pos
	for b in barriers_in:
		if not _blocks(b, p.y):
			continue
		var c: Vector3 = b["pos"]
		if int(b["kind"]) == Kind.BOX:
			p = _out_of_box(p, c, b["half"], radius)
		else:
			p = _out_of_circle(p, c, float(b["radius"]), radius)
	var limit := HALF - WALL_THICKNESS - radius
	p.x = clampf(p.x, -limit, limit)
	p.z = clampf(p.z, -limit, limit)
	return p

static func _out_of_box(p: Vector3, c: Vector3, half: Vector2, radius: float) -> Vector3:
	var dx := p.x - c.x
	var dz := p.z - c.z
	var ox := half.x + radius - absf(dx)      # overlap on each axis
	var oz := half.y + radius - absf(dz)
	if ox <= 0.0 or oz <= 0.0:
		return p                              # clear of it
	# Leave by the nearer face: that is the shortest way out and the one that
	# lets you slide along a wall instead of sticking to it.
	var out := p
	if ox < oz:
		out.x = c.x + (half.x + radius) * (1.0 if dx >= 0.0 else -1.0)
	else:
		out.z = c.z + (half.y + radius) * (1.0 if dz >= 0.0 else -1.0)
	return out

static func _out_of_circle(p: Vector3, c: Vector3, r: float, radius: float) -> Vector3:
	var d := Vector2(p.x - c.x, p.z - c.z)
	var need := r + radius
	if d.length() >= need:
		return p
	if d.length() < 0.0001:
		d = Vector2(1.0, 0.0)                 # dead centre: pick a direction
	var fixed := d.normalized() * need
	return Vector3(c.x + fixed.x, p.y, c.z + fixed.y)

## Is a spot inside a barrier's footprint, grown by the body's radius? The same
## test `resolve` uses, so the moment you are pushed clear of something you stop
## being held up by it.
static func overlaps(b: Dictionary, x: float, z: float, radius: float) -> bool:
	var c: Vector3 = b["pos"]
	if int(b["kind"]) == Kind.BOX:
		var half: Vector2 = b["half"]
		return absf(x - c.x) < half.x + radius and absf(z - c.z) < half.y + radius
	return Vector2(x - c.x, z - c.z).length() < float(b["radius"]) + radius

## The tallest thing overlapping a spot, ignoring height. Used to ask whether a
## spot is clear, not to hold anybody up -- see `support_under`.
static func support_top(barriers_in: Array, x: float, z: float, radius: float) -> float:
	var best := 0.0
	for b in barriers_in:
		if overlaps(b, x, z, radius):
			best = maxf(best, float(b["top"]))
	return best

## What the body actually lands on: the floor, or the top of something it was
## already above.
##
## `feet_from` is where the feet started the tick, and skipping anything taller
## than that is the whole point. Without it, walking into the *side* of a box
## counts as standing on it and the body is snapped to its roof -- every piece
## of cover becomes a lift, and once on top nothing blocks you at all. That bug
## survived a unit test whose box happened to sit on round numbers; it took two
## real processes and a randomly generated map to show up.
static func support_under(barriers_in: Array, x: float, z: float, radius: float,
		feet_from: float) -> float:
	var best := 0.0
	for b in barriers_in:
		var top := float(b["top"])
		if top > feet_from + 0.01:
			continue                # you were not above it: you cannot land on it
		if overlaps(b, x, z, radius):
			best = maxf(best, top)
	return best

# --- ray casting, for hitscan --------------------------------------------------

## Distance along `dir` to the first bit of map, or `INF` if the shot flies
## clean. `dir` must be normalised.
static func ray_distance(barriers_in: Array, from: Vector3, dir: Vector3) -> float:
	var best := INF
	for b in barriers_in:
		var c: Vector3 = b["pos"]
		var d := INF
		if int(b["kind"]) == Kind.BOX:
			var half: Vector2 = b["half"]
			d = ray_box(from, dir,
				Vector3(c.x - half.x, 0.0, c.z - half.y),
				Vector3(c.x + half.x, float(b["top"]), c.z + half.y))
		else:
			d = ray_cylinder(from, dir, Vector2(c.x, c.z), float(b["radius"]),
				0.0, float(b["top"]))
		best = minf(best, d)
	# The room: four walls, the floor, and a ceiling so a shot fired upward
	# still stops somewhere.
	var limit := HALF - WALL_THICKNESS
	best = minf(best, ray_box(from, dir,
		Vector3(-limit, -1.0, -limit), Vector3(limit, 0.0, limit)))   # floor
	for wall in [
		[Vector3(-HALF, 0.0, -HALF), Vector3(-limit, WALL_HEIGHT, HALF)],
		[Vector3(limit, 0.0, -HALF), Vector3(HALF, WALL_HEIGHT, HALF)],
		[Vector3(-HALF, 0.0, -HALF), Vector3(HALF, WALL_HEIGHT, -limit)],
		[Vector3(-HALF, 0.0, limit), Vector3(HALF, WALL_HEIGHT, HALF)],
	]:
		best = minf(best, ray_box(from, dir, wall[0], wall[1]))
	best = minf(best, ray_box(from, dir,
		Vector3(-limit, WALL_HEIGHT, -limit), Vector3(limit, WALL_HEIGHT + 1.0, limit)))
	return best

## Slab method: clip the ray against each pair of parallel planes in turn and
## see whether anything is left.
static func ray_box(from: Vector3, dir: Vector3, bmin: Vector3, bmax: Vector3) -> float:
	var near := -INF
	var far := INF
	for axis in 3:
		var o: float = from[axis]
		var d: float = dir[axis]
		var lo: float = bmin[axis]
		var hi: float = bmax[axis]
		if absf(d) < 1e-7:
			if o < lo or o > hi:
				return INF          # parallel and outside: never hits
			continue
		var t1 := (lo - o) / d
		var t2 := (hi - o) / d
		near = maxf(near, minf(t1, t2))
		far = minf(far, maxf(t1, t2))
		if near > far:
			return INF
	if far < 0.0:
		return INF                  # entirely behind the muzzle
	return near if near >= 0.0 else 0.0

## A vertical cylinder: a circle in the XZ plane, capped in y.
static func ray_cylinder(from: Vector3, dir: Vector3, centre: Vector2, radius: float,
		ymin: float, ymax: float) -> float:
	var o := Vector2(from.x - centre.x, from.z - centre.y)
	var d := Vector2(dir.x, dir.z)
	var a := d.dot(d)
	if a < 1e-9:
		return INF                  # straight up or down: misses every wall
	var b := 2.0 * o.dot(d)
	var c := o.dot(o) - radius * radius
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return INF
	var root := sqrt(disc)
	for t in [(-b - root) / (2.0 * a), (-b + root) / (2.0 * a)]:
		if t < 0.0:
			continue
		var y: float = from.y + dir.y * t
		if y >= ymin and y <= ymax:
			return t
	return INF

# --- the visible map -----------------------------------------------------------
#
# Built from the same `barriers` array the collision reads, so what you see and
# what you bump into cannot drift apart.

const FLOOR_COLOUR := Color(0.22, 0.23, 0.27)
const WALL_COLOUR := Color(0.30, 0.31, 0.37)
const BOX_COLOUR := Color(0.40, 0.34, 0.30)
const PILLAR_COLOUR := Color(0.28, 0.36, 0.42)

func build() -> void:
	for child in get_children():
		child.queue_free()

	_slab(Vector3(0.0, -0.5, 0.0), Vector3(SIZE, 1.0, SIZE), FLOOR_COLOUR)

	var span := SIZE - WALL_THICKNESS
	var h := WALL_HEIGHT * 0.5
	var edge := HALF - WALL_THICKNESS * 0.5
	_slab(Vector3(0.0, h, -edge), Vector3(SIZE, WALL_HEIGHT, WALL_THICKNESS), WALL_COLOUR)
	_slab(Vector3(0.0, h, edge), Vector3(SIZE, WALL_HEIGHT, WALL_THICKNESS), WALL_COLOUR)
	_slab(Vector3(-edge, h, 0.0), Vector3(WALL_THICKNESS, WALL_HEIGHT, span), WALL_COLOUR)
	_slab(Vector3(edge, h, 0.0), Vector3(WALL_THICKNESS, WALL_HEIGHT, span), WALL_COLOUR)

	for b in barriers:
		var c: Vector3 = b["pos"]
		var top := float(b["top"])
		if int(b["kind"]) == Kind.BOX:
			var half: Vector2 = b["half"]
			_slab(Vector3(c.x, top * 0.5, c.z),
				Vector3(half.x * 2.0, top, half.y * 2.0), BOX_COLOUR)
		else:
			var mesh := CylinderMesh.new()
			mesh.top_radius = float(b["radius"])
			mesh.bottom_radius = float(b["radius"])
			mesh.height = top
			mesh.radial_segments = 16
			_mesh(mesh, Vector3(c.x, top * 0.5, c.z), PILLAR_COLOUR)

func _slab(at: Vector3, size: Vector3, colour: Color) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	_mesh(mesh, at, colour)

func _mesh(mesh: Mesh, at: Vector3, colour: Color) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.roughness = 0.9
	mi.material_override = mat
	add_child(mi)
