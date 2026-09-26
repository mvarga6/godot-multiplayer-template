class_name Weapon
extends RefCounted

## Weapons are data, not code. Everything tunable about a projectile lives in
## SPECS; `projectile.gd` reads it and has no idea what a "freeze ray" is.
##
## Adding a third weapon should mean adding a third entry here plus a colour,
## and nothing else.

enum Kind { CAPTURE, FREEZE }

## Speed is a multiple of the player's own, so retuning SPEED retunes both.
const SPECS := {
	Kind.CAPTURE: {
		"label": "Collector",
		"glyph": "◆",
		"speed_mult": 2.0,
		"cost": 0,              # points it costs to fire
		"lifespan": 2.5,        # seconds in flight before it gives up
		"reflect": false,       # bounce off walls, or die on them
		"cooldown": 0.35,       # seconds between shots
		"hits_items": true,
		"hits_players": false,
		"freeze_seconds": 0.0,
		"colour": Color(0.45, 0.95, 1.0),
	},
	Kind.FREEZE: {
		"label": "Freeze Ray",
		"glyph": "❄",
		"speed_mult": 2.0,
		"cost": 0,
		"lifespan": 2.5,
		"reflect": false,
		"cooldown": 0.6,
		"hits_items": false,
		"hits_players": true,
		"freeze_seconds": 3.0,
		"colour": Color(0.65, 0.80, 1.0),
	},
}

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

static func colour(kind: int) -> Color:
	return spec(kind)["colour"]

static func label(kind: int) -> String:
	return str(spec(kind)["label"])

static func glyph(kind: int) -> String:
	return str(spec(kind)["glyph"])
