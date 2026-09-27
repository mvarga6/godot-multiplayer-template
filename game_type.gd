class_name GameType
extends RefCounted

## The catalogue of games this server can host.
##
## A lobby is a *name* plus a *type*; the type decides which scene gets spawned
## as that lobby's World. Adding a second game means adding a row here and a
## scene whose root extends `GameWorld`, overriding:
##
##     _setup()                build the game once it is in the tree
##     server_prepare()        set spawn state before entering the tree
##     server_admit(peer)      put a player in, wherever that means
##     server_evict(peer)      take them out
##     world_bounds()          how big the playfield is, for the camera
##
## `games/asalted/` is the newest one, and the first that is not flat: a 3D
## World whose scene root is still the `Node2D` the base class asks for, with
## the 3D hanging off it in a `Node3D` child.
##
## Everything else -- lobby identity, visibility gating, the screen helpers --
## comes from the base class. Nothing in `main.gd` knows what a maze is, and
## each game keeps its own scenes and assets under `games/<id>/`.

const DEFAULT := "amazing"

## A `static var`, not a `const`: a const Dictionary refuses new keys outright
## ("Cannot assign a new value to a constant"), and a registry you cannot
## register into is only a lookup table wearing a registry's name.
static var TYPES := {
	"amazing": {
		"name": "A Mazing",
		"blurb": "Grab gems in a lava maze. First to 25 takes the round.",
		"scene": "res://games/amazing/amazing_world.tscn",
	},
	"ashamed": {
		"name": "Ashamed",
		"blurb": "A 2.5D side-scroller: run, jump, and walk into the screen.",
		"scene": "res://games/ashamed/ashamed_world.tscn",
	},
	"asalted": {
		"name": "A Salted",
		"blurb": "A 3D arena shooter. Hitscan, cover, and no respawn timer.",
		"scene": "res://games/asalted/asalted_world.tscn",
	},
}

## Add a game to the catalogue. Everything downstream -- the create form, the
## browser, which scene a lobby spawns -- reads from here.
static func register(id: String, display: String, blurb_text: String, scene_file: String) -> void:
	TYPES[id] = {"name": display, "blurb": blurb_text, "scene": scene_file}

static func ids() -> Array:
	return TYPES.keys()

static func known(id: String) -> bool:
	return TYPES.has(id)

## Falls back to the default rather than failing: a lobby with no valid type is
## worse than a lobby of the wrong type.
static func resolve(id: String) -> String:
	return id if known(id) else DEFAULT

static func name_of(id: String) -> String:
	return str(TYPES[resolve(id)]["name"])

static func blurb(id: String) -> String:
	return str(TYPES[resolve(id)]["blurb"])

static func scene_path(id: String) -> String:
	return str(TYPES[resolve(id)]["scene"])

static func scene(id: String) -> PackedScene:
	return load(scene_path(id))
