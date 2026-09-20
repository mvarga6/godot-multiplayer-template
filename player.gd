extends Node2D

var peer_id: int = 0

# --- server-only state -------------------------------------------------------
var input_dir: Vector2 = Vector2.ZERO   # last input actually applied
var input_queue: Array = []             # inputs received but not yet applied
var last_tick: int = 0                  # newest input consumed, echoed back to the owner

# --- client-only state -------------------------------------------------------
var target_position: Vector2 = Vector2.ZERO
var is_local_authority := false         # true: we set position ourselves, do not interpolate

@onready var rect: ColorRect = $ColorRect

func setup(id: int) -> void:
	peer_id = id
	name = str(id)

func _ready() -> void:
	# Deterministic colour per peer: golden-ratio hue stepping keeps
	# consecutive ids visually far apart.
	rect.color = Color.from_hsv(fposmod(peer_id * 0.618034, 1.0), 0.65, 0.95)

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
