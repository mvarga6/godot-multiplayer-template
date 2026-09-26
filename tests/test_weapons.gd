extends GameTest

## Stage 8: the weapon spec table and the pure projectile step.

const ARENA := Vector2(2304, 1296)
const TICK := 1.0 / 60.0

func before_each() -> void:
	Maze.grid = PackedByteArray()      # no walls: isolate flight from the maze

# --- the spec table -----------------------------------------------------------

func test_every_kind_is_fully_specified() -> void:
	var required := ["label", "glyph", "speed_mult", "cost", "lifespan", "reflect",
		"cooldown", "hits_items", "hits_players", "freeze_seconds", "colour", "texture", "spin"]
	for kind in Weapon.Kind.values():
		ok(Weapon.is_kind(kind), "%s is a real kind" % Weapon.Kind.keys()[kind])
		for key in required:
			has_key(Weapon.spec(kind), key, "%s has %s" % [Weapon.Kind.keys()[kind], key])

func test_the_documented_defaults_hold() -> void:
	for kind in Weapon.Kind.values():
		almost(Weapon.speed(kind, 220.0), 440.0, 0.001, "default speed is 2x the player")
		eq(Weapon.cost(kind), 0, "default cost is free")
		not_ok(Weapon.reflects(kind), "walls eat shots by default")
		ok(Weapon.lifespan(kind) > 0.0, "every shot expires eventually")
		ok(Weapon.cooldown(kind) > 0.0, "and cannot be fired continuously")

func test_the_two_weapons_do_different_jobs() -> void:
	ok(Weapon.hits_items(Weapon.Kind.CAPTURE), "the collector takes gems")
	not_ok(Weapon.hits_players(Weapon.Kind.CAPTURE), "and passes through players")
	ok(Weapon.hits_players(Weapon.Kind.FREEZE), "the freeze ray hits players")
	not_ok(Weapon.hits_items(Weapon.Kind.FREEZE), "and ignores gems")
	eq(Weapon.freeze_seconds(Weapon.Kind.FREEZE), 3.0, "freezing lasts 3s by default")
	eq(Weapon.freeze_seconds(Weapon.Kind.CAPTURE), 0.0, "the collector freezes nobody")

func test_art_never_changes_the_hitbox() -> void:
	for kind in Weapon.Kind.values():
		var tex: Texture2D = Weapon.texture(kind)
		ok(tex != null, "%s has a sprite" % Weapon.Kind.keys()[kind])
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
	# A tumbling shard reads well; a tumbling word does not.
	ok(Weapon.spin(Weapon.Kind.FREEZE) > 0.0, "the freeze shard tumbles")
	eq(Weapon.spin(Weapon.Kind.CAPTURE), 0.0, "the net stays the right way up")

func test_an_unknown_kind_is_rejected() -> void:
	not_ok(Weapon.is_kind(999), "999 is not a weapon")
	not_ok(Weapon.is_kind(-1), "nor is -1")

# --- the pure step ------------------------------------------------------------

func test_a_shot_travels_at_its_configured_speed() -> void:
	var vel := Vector2.RIGHT * Weapon.speed(Weapon.Kind.CAPTURE, 220.0)
	var pos := Vector2(500, 500)
	for i in 60:
		pos = Projectile.step(pos, vel, TICK, false)["pos"]
	almost(pos.x - 500.0, 440.0, 0.01, "one second of flight covers 2x SPEED")

func test_stepping_is_pure() -> void:
	var a: Dictionary = Projectile.step(Vector2(120, 340), Vector2(200, -90), TICK, false)
	for i in 30:
		eq(Projectile.step(Vector2(120, 340), Vector2(200, -90), TICK, false)["pos"],
			a["pos"], "same inputs, same answer -- every peer flies it identically")

func test_a_wall_eats_a_shot_that_does_not_reflect() -> void:
	Maze.generate(31337, ARENA)
	var hit := false
	for y in range(1, Maze.ROWS - 1):
		for x in range(1, Maze.COLS - 2):
			if Maze.at(x, y) != 0 or Maze.at(x + 1, y) != 1:
				continue
			var pos := (Vector2(x, y) + Vector2(0.5, 0.5)) * Maze.cell
			var vel := Vector2.RIGHT * 440.0
			for i in 60:
				var r: Dictionary = Projectile.step(pos, vel, TICK, false)
				pos = r["pos"]
				if bool(r["dead"]):
					hit = true
					break
			ok(hit, "a shot fired into a wall dies on it")
			return
	ok(false, "no wall found to shoot at")

func test_reflection_turns_a_shot_around_instead() -> void:
	Maze.generate(31337, ARENA)
	for y in range(1, Maze.ROWS - 1):
		for x in range(1, Maze.COLS - 2):
			if Maze.at(x, y) != 0 or Maze.at(x + 1, y) != 1:
				continue
			var pos := (Vector2(x, y) + Vector2(0.5, 0.5)) * Maze.cell
			var vel := Vector2.RIGHT * 440.0
			var bounced := false
			for i in 60:
				var r: Dictionary = Projectile.step(pos, vel, TICK, true)
				pos = r["pos"]
				vel = r["vel"]
				not_ok(bool(r["dead"]), "a reflecting shot is never killed by a wall")
				if vel.x < 0.0:
					bounced = true
					break
			ok(bounced, "it comes back the other way")
			not_ok(Maze.is_blocked(pos, Weapon.RADIUS), "and never ends up inside the wall")
			return
	ok(false, "no wall found to bounce off")

func test_a_shot_never_ends_a_step_inside_a_wall() -> void:
	Maze.generate(4242, ARENA)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var pos := Maze.random_open_point(rng)
	var vel := Vector2(1, 0.4).normalized() * 440.0
	for i in 300:
		var r: Dictionary = Projectile.step(pos, vel, TICK, true)
		pos = r["pos"]
		vel = r["vel"]
		not_ok(Maze.is_blocked(pos, Weapon.RADIUS), "step %d stays out of the walls" % i)
