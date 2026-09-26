class_name Weapon
extends RefCounted

## Weapons are data, not code. Everything tunable about a projectile lives in
## SPECS; `projectile.gd` reads it and has no idea what a "freeze ray" is.
##
## Adding a third weapon should mean adding a third entry here plus a colour,
## and nothing else.

enum Kind { CAPTURE, FREEZE, STEAL }

## Speed is a multiple of the player's own, so retuning SPEED retunes both.
const SPECS := {
	Kind.CAPTURE: {
		"label": "Collector",
		"glyph": "◆",
		"key": KEY_A,
		"speed_mult": 2.0,
		"cost": 0,              # points it costs to fire
		"lifespan": 2.5,        # seconds in flight before it gives up
		"reflect": false,       # bounce off walls, or die on them
		"cooldown": 0.35,       # seconds between shots
		"hits_items": true,
		"hits_players": false,
		"freeze_seconds": 0.0,
		"steal_points": 0,
		"colour": Color(0.45, 0.95, 1.0),
		"texture": preload("res://assets/net.png"),
		"spin": 10.0,               # radians/sec, purely cosmetic
	},
	Kind.FREEZE: {
		"label": "Freeze Ray",
		"glyph": "❄",
		"key": KEY_S,
		"speed_mult": 2.0,
		"cost": 1,
		"lifespan": 2.5,
		"reflect": false,
		"cooldown": 0.6,
		"hits_items": false,
		"hits_players": true,
		"freeze_seconds": 3.0,
		"steal_points": 0,
		"colour": Color(0.65, 0.80, 1.0),
		"texture": preload("res://assets/freeze.png"),
		"spin": 5.2,                # radians/sec: a tumbling shard
	},
	Kind.STEAL: {
		"label": "Pickpocket",
		"glyph": "✋",
		"key": KEY_D,
		"speed_mult": 2.0,
		"cost": 0,
		"lifespan": 2.5,
		"reflect": false,
		"cooldown": 0.8,
		"hits_items": false,
		"hits_players": true,
		"freeze_seconds": 0.0,
		"steal_points": 1,          # lifted off the victim and handed to the shooter
		"colour": Color(1.0, 0.82, 0.30),
		"texture": null,            # no art yet: falls back to the drawn dot
		"spin": 0.0,
	},
}

## Collision radius. Deliberately independent of whatever a weapon looks like —
## a bigger sprite must not quietly become a bigger hitbox.
const RADIUS := 5.0

static func is_kind(kind: int) -> bool:
	return SPECS.has(kind)

static func spec(kind: int) -> Dictionary:
	return SPECS.get(kind, SPECS[Kind.CAPTURE])

static func speed(kind: int, player_speed: float) -> float:
	return player_speed * float(spec(kind)["speed_mult"])

static func cost(kind: int) -> int:
	return int(spec(kind)["cost"])

static func lifespan(kind: int) -> float:
	return float(spec(kind)["lifespan"])

static func reflects(kind: int) -> bool:
	return bool(spec(kind)["reflect"])

static func cooldown(kind: int) -> float:
	return float(spec(kind)["cooldown"])

static func hits_items(kind: int) -> bool:
	return bool(spec(kind)["hits_items"])

static func hits_players(kind: int) -> bool:
	return bool(spec(kind)["hits_players"])

static func freeze_seconds(kind: int) -> float:
	return float(spec(kind)["freeze_seconds"])

## Points this weapon takes off whoever it hits and hands to the shooter.
static func steal_points(kind: int) -> int:
	return int(spec(kind).get("steal_points", 0))

## The key that selects this weapon, and the action name bound to it. Kept in
## the spec so adding a weapon really is one row and nothing else.
static func key(kind: int) -> Key:
	return spec(kind).get("key", KEY_NONE)

static func action(kind: int) -> String:
	return "weapon_%d" % kind

static func key_label(kind: int) -> String:
	return OS.get_keycode_string(key(kind))

## Null when the weapon has no art and should be drawn instead.
static func texture(kind: int) -> Texture2D:
	return spec(kind).get("texture")

## Radians per second. Cosmetic, and derived from `age`, so every peer spins a
## shot identically without replicating anything. Zero for art that has an
## up — a rotating "NET" is just unreadable.
static func spin(kind: int) -> float:
	return float(spec(kind).get("spin", 0.0))

static func colour(kind: int) -> Color:
	return spec(kind)["colour"]

static func label(kind: int) -> String:
	return str(spec(kind)["label"])

static func glyph(kind: int) -> String:
	return str(spec(kind)["glyph"])
