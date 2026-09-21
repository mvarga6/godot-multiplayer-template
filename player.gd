extends Node2D

const HALF := 16.0          # the hitbox is still a 32x32 square, whatever the icon looks like

var peer_id: int = 0
var tint := Color.WHITE

# --- server-only state -------------------------------------------------------
var input_dir: Vector2 = Vector2.ZERO   # last input actually applied
var input_queue: Array = []             # inputs received but not yet applied
var last_tick: int = 0                  # newest input consumed, echoed back to the owner

## Replicated by the Sync node, server -> everyone, at SYNC_HZ.
##
## Deliberately NOT `position`: if the synchronizer wrote straight into
## `position` it would overwrite the local prediction every tick and stamp on
## the interpolation. It lands here instead, and `Main` decides what to do with
## it — reconcile, if it is your own square; ease toward it, if it is not.
var net_position: Vector2 = Vector2.ZERO

# --- client-only state -------------------------------------------------------
var target_position: Vector2 = Vector2.ZERO
var is_local_authority := false         # true: we set position ourselves, do not interpolate

var _icon := "?"                        # may be set before the Labels exist
var _display := ""

@onready var icon_label: Label = $Icon
@onready var name_label: Label = $NameTag
@onready var sync: MultiplayerSynchronizer = $Sync

func setup(id: int) -> void:
	peer_id = id
	name = str(id)

func set_identity(glyph: String, display: String) -> void:
	_icon = glyph
	_display = display
	if is_node_ready():
		icon_label.text = _icon
		name_label.text = _display

func _ready() -> void:
	# Deterministic colour per peer: golden-ratio hue stepping keeps consecutive
	# ids visually far apart. Nothing is drawn for the body — just the glyph and
	# the name tag — so this tints the tag, which is what still tells two players
	# with the same emoji apart.
	tint = Color.from_hsv(fposmod(peer_id * 0.618034, 1.0), 0.65, 0.95)
	icon_label.text = _icon
	# Godot's bundled font has no emoji glyphs, so ask the OS for one.
	# Emoji-first here: this label only ever holds one glyph.
	var f := SystemFont.new()
	f.font_names = PackedStringArray([
		"Noto Color Emoji", "Segoe UI Emoji", "Apple Color Emoji", "Noto Emoji", "sans-serif",
	])
	icon_label.add_theme_font_override("font", f)
	icon_label.add_theme_font_size_override("font_size", 22)
	name_label.text = _display
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.add_theme_color_override("font_color", tint)
	name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	name_label.add_theme_constant_override("outline_size", 4)

func _process(delta: float) -> void:
	if is_local_authority:
		return
	# State arrives at 20 Hz, we draw at 60+. Ease toward the last known position
	# instead of snapping to it.
	#
	# `1.0 - pow(0.001, delta)` is the frame-rate independent form: a plain
	# lerp(a, b, 0.2) converges at different speeds at 30 and 144 fps, which is
	# the same class of bug as forgetting `delta` entirely.
	position = position.lerp(target_position, 1.0 - pow(0.001, delta))
