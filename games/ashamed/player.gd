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
var move: float = 0.0                   # last horizontal input applied, -1..1
var velocity: Vector2 = Vector2.ZERO
var grounded: bool = false

## Replicated by the Sync node, server -> everyone.
##
## Deliberately not `position`/`velocity` themselves: the owning client predicts
## into those every tick, and a synchronizer writing over them would fight the
## prediction. These land beside them and the World decides what to do.
var net_position: Vector2 = Vector2.ZERO
var net_velocity: Vector2 = Vector2.ZERO
var net_grounded: bool = false

# --- client-only state -------------------------------------------------------
var target_position: Vector2 = Vector2.ZERO
var is_local_authority := false         # true: we set position ourselves

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

## Remote players are eased toward the last position the server sent; our own
## is wherever prediction put it.
func _process(delta: float) -> void:
	if is_local_authority:
		return
	position = position.lerp(target_position, 1.0 - pow(0.001, delta))

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
