class_name Collectible
extends Node2D

## One pickup lying in the maze. The server owns spawning, expiry and scoring;
## this node only knows how to draw itself and count down its own lifespan.

enum Kind { GOLD, RUBY, EMERALD, DIAMOND }

const VALUE := {
	Kind.GOLD: 1,
	Kind.RUBY: 2,
	Kind.EMERALD: 3,
	Kind.DIAMOND: 5,
}

## Rarer things are worth more. Weights are relative, not percentages.
const WEIGHT := {
	Kind.GOLD: 50,
	Kind.RUBY: 28,
	Kind.EMERALD: 15,
	Kind.DIAMOND: 7,
}

## One short cue per kind. Only the peer who actually grabbed it hears this.
const SOUND := {
	Kind.GOLD: preload("res://audio/pickup_gold.wav"),
	Kind.RUBY: preload("res://audio/pickup_ruby.wav"),
	Kind.EMERALD: preload("res://audio/pickup_emerald.wav"),
	Kind.DIAMOND: preload("res://audio/pickup_diamond.wav"),
}

const RADIUS := 11.0
const FADE_AT := 3.0        # seconds left when it starts blinking out

## All four are spawn-state on the Sync node, so a peer that joins mid-game is
## handed them with the spawn itself -- including `age`, which keeps everyone's
## blink-out in step rather than restarting the clock for the newcomer.
var item_id: int = 0
var kind: int = Kind.GOLD
var lifetime := 12.0
var age := 0.0

func setup(k: int, life: float) -> void:
	kind = k
	lifetime = life

func _ready() -> void:
	set_process(DisplayServer.get_name() != "headless")

func _process(delta: float) -> void:
	age += delta
	queue_redraw()

## Server only: pick a kind, rarer ones less often.
static func random_kind(rng: RandomNumberGenerator) -> int:
	var total := 0
	for k in WEIGHT:
		total += WEIGHT[k]
	var roll := rng.randi() % total
	for k in WEIGHT:
		roll -= WEIGHT[k]
		if roll < 0:
			return k
	return Kind.GOLD

# --- drawing -----------------------------------------------------------------

func _alpha() -> float:
	var left := lifetime - age
	if left > FADE_AT:
		return 1.0
	if left <= 0.0:
		return 0.0
	# Blink faster and faster as it runs out, so "about to vanish" is legible
	# at a glance rather than something you have to be counting.
	var urgency := 1.0 - (left / FADE_AT)
	var blink := 0.5 + 0.5 * sin(age * TAU * (2.0 + 6.0 * urgency))
	return lerpf(0.35, 1.0, blink)

func _draw() -> void:
	var a := _alpha()
	if a <= 0.01:
		return
	match kind:
		Kind.GOLD: _draw_gold(a)
		Kind.RUBY: _draw_ruby(a)
		Kind.EMERALD: _draw_emerald(a)
		Kind.DIAMOND: _draw_diamond(a)

func _draw_gold(a: float) -> void:
	draw_circle(Vector2.ZERO, RADIUS, Color(0.55, 0.38, 0.05, a))
	draw_circle(Vector2.ZERO, RADIUS * 0.82, Color(1.0, 0.80, 0.22, a))
	# off-centre highlight reads as a struck coin face
	draw_circle(Vector2(-RADIUS * 0.25, -RADIUS * 0.28), RADIUS * 0.26, Color(1.0, 0.96, 0.72, a))

func _draw_ruby(a: float) -> void:
	var r := RADIUS * 1.05
	var body := PackedVector2Array([
		Vector2(0, -r), Vector2(r * 0.78, 0), Vector2(0, r), Vector2(-r * 0.78, 0),
	])
	draw_colored_polygon(body, Color(0.75, 0.06, 0.16, a))
	# top facet catching the light
	draw_colored_polygon(PackedVector2Array([
		Vector2(0, -r), Vector2(r * 0.78, 0), Vector2(0, -r * 0.1), Vector2(-r * 0.78, 0),
	]), Color(1.0, 0.30, 0.42, a))

func _draw_emerald(a: float) -> void:
	var r := RADIUS
	var pts := PackedVector2Array()
	for i in 6:
		var ang := TAU * (float(i) / 6.0) - PI / 2.0
		pts.append(Vector2(cos(ang), sin(ang)) * r)
	draw_colored_polygon(pts, Color(0.05, 0.62, 0.36, a))
	var inner := PackedVector2Array()
	for i in 6:
		var ang := TAU * (float(i) / 6.0) - PI / 2.0
		inner.append(Vector2(cos(ang), sin(ang)) * r * 0.5)
	draw_colored_polygon(inner, Color(0.45, 1.0, 0.72, a))

func _draw_diamond(a: float) -> void:
	var r := RADIUS * 1.1
	# classic brilliant-cut silhouette: flat table on top, point below
	draw_colored_polygon(PackedVector2Array([
		Vector2(-r * 0.55, -r * 0.45), Vector2(r * 0.55, -r * 0.45),
		Vector2(r, -r * 0.05), Vector2(0, r), Vector2(-r, -r * 0.05),
	]), Color(0.62, 0.90, 1.0, a))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-r * 0.55, -r * 0.45), Vector2(r * 0.55, -r * 0.45),
		Vector2(r * 0.30, -r * 0.05), Vector2(-r * 0.30, -r * 0.05),
	]), Color(0.96, 1.0, 1.0, a))
