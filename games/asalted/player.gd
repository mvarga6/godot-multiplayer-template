extends Node3D

## A player in A Salted: six ellipsoids, a name tag, and a body that falls.
##
## The state is a position, a vertical velocity and a heading. Position and
## velocity are the same pair Ashamed needs and for the same reason -- under
## gravity you carry momentum, so a correction that fixed only the position
## would leave you in the right place moving the wrong way.
##
## Yaw is here too, and it is *input*, not simulation: the client turned the
## instant the mouse moved and predicted with the new heading, so it sends the
## heading along and the server uses it rather than deriving one.

var peer_id: int = 0

# --- server-only state ----------------------------------------------------------
var input_queue: Array = []
var last_tick: int = 0
var move: Vector2 = Vector2.ZERO
var cooldown: float = 0.0
var pitch: float = 0.0              # only the server and the owner need this

## The body's actual state. `pos` is the feet, in metres.
var pos: Vector3 = Vector3.ZERO
var vel_y: float = 0.0
var grounded: bool = false
var yaw: float = 0.0

## Replicated by the Sync node, server -> everyone. Deliberately beside the
## live values rather than on top of them: the owning client predicts into
## those every tick and a synchronizer writing there would fight it.
var net_pos: Vector3 = Vector3.ZERO
var net_vel_y: float = 0.0
var net_grounded: bool = false
var net_yaw: float = 0.0

## Score is not predicted by anyone -- only the server ever writes it -- so it
## replicates directly with no shadow copy.
var score: int = 0

# --- client-only state ----------------------------------------------------------
var target_pos: Vector3 = Vector3.ZERO
var target_yaw: float = 0.0
var is_local_authority := false

var _icon := "?"
var _display := ""
var _body: Node3D = null
var _tag: Label3D = null

func setup(id: int) -> void:
	peer_id = id
	name = str(id)

func set_label(glyph: String, display: String) -> void:
	_icon = glyph
	_display = display
	if _tag != null:
		_tag.text = "%s %s" % [_icon, _display]

## First person: you do not see yourself from the inside.
func hide_body() -> void:
	if _body != null:
		_body.visible = false
	if _tag != null:
		_tag.visible = false

func _ready() -> void:
	_build_body()

func _process(delta: float) -> void:
	if not is_local_authority:
		var k := 1.0 - pow(0.001, delta)
		pos = pos.lerp(target_pos, k)
		yaw = lerp_angle(yaw, target_yaw, k)
	position = pos
	rotation.y = yaw

# --- the body ---------------------------------------------------------------------
#
# Ellipsoids: one SphereMesh each, scaled. Enough to read as a person facing a
# direction, which is all an opponent needs to be.

func _build_body() -> void:
	var tint := Color.from_hsv(fposmod(peer_id * 0.618034, 1.0), 0.62, 0.95)
	_body = Node3D.new()
	_body.name = "Body"
	add_child(_body)

	_blob(Vector3(0.0, 1.00, 0.0), Vector3(0.62, 0.80, 0.42), tint)          # torso
	_blob(Vector3(0.0, 1.62, 0.0), Vector3(0.42, 0.46, 0.42), tint.lightened(0.15))
	_blob(Vector3(-0.38, 1.00, 0.0), Vector3(0.18, 0.58, 0.18), tint.darkened(0.15))
	_blob(Vector3(0.38, 1.00, 0.0), Vector3(0.18, 0.58, 0.18), tint.darkened(0.15))
	_blob(Vector3(-0.17, 0.31, 0.0), Vector3(0.24, 0.62, 0.24), tint.darkened(0.3))
	_blob(Vector3(0.17, 0.31, 0.0), Vector3(0.24, 0.62, 0.24), tint.darkened(0.3))
	# A snout on the front of the head, so you can tell where someone is looking.
	_blob(Vector3(0.0, 1.60, -0.24), Vector3(0.14, 0.12, 0.26), Color(0.95, 0.95, 1.0))

	_tag = Label3D.new()
	_tag.text = "%s %s" % [_icon, _display]
	_tag.position = Vector3(0.0, 2.15, 0.0)
	_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_tag.no_depth_test = false      # a name showing through cover is a wallhack
	_tag.font_size = 48
	_tag.pixel_size = 0.006
	_tag.modulate = tint.lightened(0.4)
	_tag.outline_size = 12
	_tag.outline_modulate = Color(0, 0, 0, 0.9)
	_body.add_child(_tag)

func _blob(at: Vector3, size: Vector3, colour: Color) -> void:
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.5               # a unit ball, so `size` reads as the extent
	mesh.height = 1.0
	mesh.radial_segments = 12
	mesh.rings = 7
	mi.mesh = mesh
	mi.position = at
	mi.scale = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.roughness = 0.75
	mi.material_override = mat
	_body.add_child(mi)
