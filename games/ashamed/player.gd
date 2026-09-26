extends Node2D

## A player in Ashamed: a glyph, a name tag, and a body that falls.
##
## The state that matters here is position *and* velocity. A Mazing could
## reconcile by replaying inputs over a position, because letting go of a key
## stopped you dead. Under gravity you carry momentum, so the server has to
## hand back both halves or a correction lands you at the right place moving
## the wrong way.

var peer_id: int = 0

# --- server-only state -------------------------------------------------------
var input_queue: Array = []             # inputs received but not yet applied
var last_tick: int = 0                  # newest input consumed, echoed to the owner
var move: Vector2 = Vector2.ZERO        # last floor-plane input applied

## The body's actual state. `ground` is (along, depth) on the floor plane;
## `height` is how far off it. None of these is a screen coordinate.
var ground: Vector2 = Vector2.ZERO
var height: float = 0.0
var v_height: float = 0.0
var grounded: bool = false

## Replicated by the Sync node, server -> everyone.
##
## Deliberately not `position`/`velocity` themselves: the owning client predicts
## into those every tick, and a synchronizer writing over them would fight the
## prediction. These land beside them and the World decides what to do.
var net_ground: Vector2 = Vector2.ZERO
var net_height: float = 0.0
var net_v_height: float = 0.0
var net_grounded: bool = false

# --- client-only state -------------------------------------------------------
var target_ground: Vector2 = Vector2.ZERO
var target_height: float = 0.0
var is_local_authority := false         # true: we set our own state

## The world this body stands in, for the camera axis the projection needs.
@onready var _world: Node = get_parent().get_parent()

@onready var icon_label: Label = $Icon
@onready var name_label: Label = $NameTag

var _icon := "?"
var _display := ""

func setup(id: int) -> void:
	peer_id = id
	name = str(id)

func set_identity(glyph: String, display: String) -> void:
	_icon = glyph
	_display = display
	if is_node_ready():
		icon_label.text = _icon
		name_label.text = _display

## Remote bodies ease toward the last *world* state the server sent; our own is
## wherever prediction put it. Either way the screen transform is derived, never
## stored -- position, size and draw order all fall out of depth.
func _process(delta: float) -> void:
	if not is_local_authority:
		var k := 1.0 - pow(0.001, delta)
		ground = ground.lerp(target_ground, k)
		height = lerpf(height, target_height, k)
	var eye := 0.0
	if _world is AshamedWorld:
		eye = (_world as AshamedWorld).eye_x
	position = AshamedWorld.project(ground, height, eye)
	var s := AshamedWorld.depth_scale(ground.y)
	scale = Vector2(s, s)
	z_index = AshamedWorld.depth_z(ground.y)
	queue_redraw()           # the shadow tracks `height`, which moves every frame

## A blob on the floor, directly under the body.
##
## Height and depth both draw you higher up the screen, so on their own they are
## the same picture: a distant player standing still and a near one at the top of
## a jump look alike. The shadow stays on the floor and breaks the tie.
##
## Drawn in local space, which is already scaled by `depth_scale`, so it shrinks
## with distance for free -- and a screen lift of `height * k` is a local offset
## of exactly `height`.
func _draw() -> void:
	if height <= 0.5:
		return
	var t := clampf(height / 260.0, 0.0, 1.0)
	draw_set_transform(Vector2(0.0, height + 16.0), 0.0, Vector2(1.0, 0.34))
	draw_circle(Vector2.ZERO, lerpf(13.0, 8.0, t), Color(0.0, 0.0, 0.0, lerpf(0.5, 0.16, t)))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _ready() -> void:
	var tint := Color.from_hsv(fposmod(peer_id * 0.618034, 1.0), 0.65, 0.95)
	var f := SystemFont.new()
	f.font_names = PackedStringArray([
		"Noto Color Emoji", "Segoe UI Emoji", "Apple Color Emoji", "Noto Emoji", "sans-serif",
	])
	icon_label.add_theme_font_override("font", f)
	icon_label.add_theme_font_size_override("font_size", 22)
	icon_label.text = _icon
	name_label.text = _display
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.add_theme_color_override("font_color", tint)
	name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	name_label.add_theme_constant_override("outline_size", 4)
