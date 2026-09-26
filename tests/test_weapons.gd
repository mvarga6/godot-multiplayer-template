extends GameTest

var maze := Maze.new()

func after_each() -> void:
	maze.free()

## Stage 8: the weapon spec table and the pure projectile step.

const ARENA := Vector2(2304, 1296)
const TICK := 1.0 / 60.0

func before_each() -> void:
	maze.grid = PackedByteArray()      # no walls: isolate flight from the maze

# --- the spec table -----------------------------------------------------------

func test_every_kind_is_fully_specified() -> void:
	var required := ["label", "glyph", "speed_mult", "cost", "lifespan", "reflect",
		"cooldown", "hits_items", "hits_players", "freeze_seconds", "steal_points",
		"colour", "texture", "spin", "key"]
	for kind in Weapon.Kind.values():
		ok(Weapon.is_kind(kind), "%s is a real kind" % Weapon.Kind.keys()[kind])
		for key in required:
			has_key(Weapon.spec(kind), key, "%s has %s" % [Weapon.Kind.keys()[kind], key])

func test_the_documented_defaults_hold() -> void:
	for kind in Weapon.Kind.values():
		almost(Weapon.speed(kind, 220.0), 440.0, 0.001, "default speed is 2x the player")
		not_ok(Weapon.reflects(kind), "walls eat shots by default")
		ok(Weapon.lifespan(kind) > 0.0, "every shot expires eventually")
		ok(Weapon.cooldown(kind) > 0.0, "and cannot be fired continuously")
		ok(Weapon.cost(kind) >= 0, "and never costs a negative amount")
	eq(Weapon.cost(Weapon.Kind.FREEZE), 1, "the freeze ray is the one you pay for")
	eq(Weapon.cost(Weapon.Kind.CAPTURE), 0, "the collector is free")
	eq(Weapon.cost(Weapon.Kind.STEAL), 0, "so is the pickpocket")

func test_every_weapon_has_its_own_key() -> void:
	var seen := {}
	for kind in Weapon.Kind.values():
		var k := Weapon.key(kind)
		ne(k, KEY_NONE, "%s is bound to something" % Weapon.Kind.keys()[kind])
		not_ok(seen.has(k), "%s does not share a key" % Weapon.Kind.keys()[kind])
		seen[k] = true
		ne(Weapon.action(kind), "", "and has an action name")

func test_the_three_weapons_do_different_jobs() -> void:
	ok(Weapon.hits_items(Weapon.Kind.CAPTURE), "the collector takes gems")
	not_ok(Weapon.hits_players(Weapon.Kind.CAPTURE), "and passes through players")
	ok(Weapon.hits_players(Weapon.Kind.FREEZE), "the freeze ray hits players")
	not_ok(Weapon.hits_items(Weapon.Kind.FREEZE), "and ignores gems")
	eq(Weapon.freeze_seconds(Weapon.Kind.FREEZE), 3.0, "freezing lasts 3s by default")
	eq(Weapon.freeze_seconds(Weapon.Kind.CAPTURE), 0.0, "the collector freezes nobody")
	eq(Weapon.steal_points(Weapon.Kind.STEAL), 1, "the pickpocket lifts one point")
	ok(Weapon.hits_players(Weapon.Kind.STEAL), "off a player")
	not_ok(Weapon.hits_items(Weapon.Kind.STEAL), "and leaves gems alone")
	eq(Weapon.steal_points(Weapon.Kind.FREEZE), 0, "the freeze ray steals nothing")
	eq(Weapon.steal_points(Weapon.Kind.CAPTURE), 0, "nor does the collector")

func test_art_never_changes_the_hitbox() -> void:
	for kind in Weapon.Kind.values():
		var tex: Texture2D = Weapon.texture(kind)
		if tex == null:
			continue              # drawn instead; nothing to widen the hitbox with
		# A sprite bigger than the hitbox must not quietly widen it.
		ok(float(tex.get_width()) > Weapon.RADIUS, "the sprite is wider than the hitbox")
	almost(Weapon.RADIUS, 5.0, 0.001, "and the hitbox is unchanged by any of them")

func test_art_is_still_optional() -> void:
	# The drawn-dot fallback has to survive, or a new weapon must ship art.
	# `erase` on a const Dictionary silently does nothing, so blank it instead.
	var spec: Dictionary = Weapon.SPECS[Weapon.Kind.CAPTURE]
	var original: Variant = spec["texture"]
	spec["texture"] = null
	eq(Weapon.texture(Weapon.Kind.CAPTURE), null, "a weapon with no art reports none")
	spec["texture"] = original
	ok(Weapon.texture(Weapon.Kind.CAPTURE) != null, "and the real sprite is put back")

func test_spin_is_per_weapon() -> void:
	# Purely cosmetic, and derived from `age`, so it costs nothing to replicate.
	for kind in Weapon.Kind.values():
		ok(Weapon.spin(kind) >= 0.0, "%s has a sane spin" % Weapon.Kind.keys()[kind])
	ne(Weapon.spin(Weapon.Kind.FREEZE), Weapon.spin(Weapon.Kind.CAPTURE),
		"spin is set per weapon, not globally")

func test_an_unknown_kind_is_rejected() -> void:
	not_ok(Weapon.is_kind(999), "999 is not a weapon")
	not_ok(Weapon.is_kind(-1), "nor is -1")

# --- the pure step ------------------------------------------------------------

func test_a_shot_travels_at_its_configured_speed() -> void:
	var vel := Vector2.RIGHT * Weapon.speed(Weapon.Kind.CAPTURE, 220.0)
	var pos := Vector2(500, 500)
	for i in 60:
		pos = Projectile.step(maze, pos, vel, TICK, false)["pos"]
	almost(pos.x - 500.0, 440.0, 0.01, "one second of flight covers 2x SPEED")

func test_stepping_is_pure() -> void:
	var a: Dictionary = Projectile.step(maze, Vector2(120, 340), Vector2(200, -90), TICK, false)
	for i in 30:
		eq(Projectile.step(maze, Vector2(120, 340), Vector2(200, -90), TICK, false)["pos"],
			a["pos"], "same inputs, same answer -- every peer flies it identically")

func test_a_wall_eats_a_shot_that_does_not_reflect() -> void:
	maze.generate(31337, ARENA)
	var hit := false
	for y in range(1, Maze.ROWS - 1):
		for x in range(1, Maze.COLS - 2):
			if maze.at(x, y) != 0 or maze.at(x + 1, y) != 1:
				continue
			var pos := (Vector2(x, y) + Vector2(0.5, 0.5)) * maze.cell
			var vel := Vector2.RIGHT * 440.0
			for i in 60:
				var r: Dictionary = Projectile.step(maze, pos, vel, TICK, false)
				pos = r["pos"]
				if bool(r["dead"]):
					hit = true
					break
			ok(hit, "a shot fired into a wall dies on it")
			return
	ok(false, "no wall found to shoot at")

func test_reflection_turns_a_shot_around_instead() -> void:
	maze.generate(31337, ARENA)
	for y in range(1, Maze.ROWS - 1):
		for x in range(1, Maze.COLS - 2):
			if maze.at(x, y) != 0 or maze.at(x + 1, y) != 1:
				continue
			var pos := (Vector2(x, y) + Vector2(0.5, 0.5)) * maze.cell
			var vel := Vector2.RIGHT * 440.0
			var bounced := false
			for i in 60:
				var r: Dictionary = Projectile.step(maze, pos, vel, TICK, true)
				pos = r["pos"]
				vel = r["vel"]
				not_ok(bool(r["dead"]), "a reflecting shot is never killed by a wall")
				if vel.x < 0.0:
					bounced = true
					break
			ok(bounced, "it comes back the other way")
			not_ok(maze.is_blocked(pos, Weapon.RADIUS), "and never ends up inside the wall")
			return
	ok(false, "no wall found to bounce off")

func test_a_shot_never_ends_a_step_inside_a_wall() -> void:
	maze.generate(4242, ARENA)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var pos := maze.random_open_point(rng)
	var vel := Vector2(1, 0.4).normalized() * 440.0
	for i in 300:
		var r: Dictionary = Projectile.step(maze, pos, vel, TICK, true)
		pos = r["pos"]
		vel = r["vel"]
		not_ok(maze.is_blocked(pos, Weapon.RADIUS), "step %d stays out of the walls" % i)
