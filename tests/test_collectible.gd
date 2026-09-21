extends GameTest

func test_every_kind_has_a_value_weight_and_sound() -> void:
	for kind in Collectible.Kind.values():
		has_key(Collectible.VALUE, kind, "VALUE covers %s" % Collectible.Kind.keys()[kind])
		has_key(Collectible.WEIGHT, kind, "WEIGHT covers %s" % Collectible.Kind.keys()[kind])
		has_key(Collectible.SOUND, kind, "SOUND covers %s" % Collectible.Kind.keys()[kind])

func test_rarer_kinds_are_worth_more() -> void:
	var by_weight := Collectible.Kind.values()
	by_weight.sort_custom(func(a, b): return Collectible.WEIGHT[a] > Collectible.WEIGHT[b])
	for i in by_weight.size() - 1:
		var common: int = by_weight[i]
		var rare: int = by_weight[i + 1]
		ok(Collectible.VALUE[common] < Collectible.VALUE[rare],
			"%s (rarer) beats %s" % [Collectible.Kind.keys()[rare], Collectible.Kind.keys()[common]])

func test_random_kind_only_returns_real_kinds() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in 500:
		var k := Collectible.random_kind(rng)
		ok(Collectible.Kind.values().has(k), "draw %d is a real kind" % i)

func test_random_kind_follows_the_weights() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var draws := 20000
	var hist := {}
	for kind in Collectible.Kind.values():
		hist[kind] = 0
	for i in draws:
		hist[Collectible.random_kind(rng)] += 1
	var total_weight := 0
	for kind in Collectible.WEIGHT:
		total_weight += Collectible.WEIGHT[kind]
	for kind in hist:
		var expected := float(draws) * float(Collectible.WEIGHT[kind]) / float(total_weight)
		# generous band: this is a distribution check, not a PRNG audit
		between(float(hist[kind]), expected * 0.85, expected * 1.15,
			"%s frequency" % Collectible.Kind.keys()[kind])

func test_alpha_is_solid_until_the_fade_then_reaches_zero() -> void:
	var c := Collectible.new()
	c.setup(Collectible.Kind.GOLD, 10.0)
	c.age = 0.0
	eq(c._alpha(), 1.0, "a fresh item is fully opaque")
	c.age = 10.0 - Collectible.FADE_AT - 0.01
	eq(c._alpha(), 1.0, "still solid just before the fade window")
	c.age = 10.0 - 1.0
	ok(c._alpha() < 1.0, "inside the fade window it is dimmer")
	c.age = 10.0
	eq(c._alpha(), 0.0, "at the end of its life it is invisible")
	c.age = 11.0
	eq(c._alpha(), 0.0, "and stays invisible past the end")
	c.free()
