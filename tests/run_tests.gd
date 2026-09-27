extends SceneTree

## Self-contained test runner: no addon, no download, no network.
##   godot --headless --script res://tests/run_tests.gd
## Exits non-zero if anything fails, so `make test` is CI-usable.

const SUITES := [
	"res://tests/test_maze.gd",
	"res://tests/test_collectible.gd",
	"res://tests/test_simulate.gd",
	"res://tests/test_parsing.gd",
	"res://tests/test_weapons.gd",
	"res://tests/test_game_flow.gd",
	"res://tests/test_combat.gd",
	"res://tests/test_lobbies.gd",
	"res://tests/test_ashamed.gd",
	"res://tests/test_asalted.gd",
]

var _total := 0
var _failed := 0
var _checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var started := Time.get_ticks_msec()
	for path in SUITES:
		_run_suite(path)
	var ms := Time.get_ticks_msec() - started
	print("")
	if _failed == 0:
		print("PASSED  %d tests, %d assertions, %d ms" % [_total, _checks, ms])
	else:
		print("FAILED  %d of %d tests (%d assertions, %d ms)" % [_failed, _total, _checks, ms])
	quit(1 if _failed > 0 else 0)

func _run_suite(path: String) -> void:
	var script: GDScript = load(path)
	if script == null or not script.can_instantiate():
		print("%s  -- FAILED TO COMPILE" % path.get_file())
		_total += 1
		_failed += 1
		return
	var names: Array[String] = []
	for m in script.new().get_method_list():
		var n: String = m["name"]
		if n.begins_with("test_") and not names.has(n):
			names.append(n)
	names.sort()
	print("%s  (%d)" % [path.get_file(), names.size()])
	for n in names:
		var case: GameTest = script.new()
		case.tree = self
		case.before_each()
		case.call(n)
		case.after_each()
		_total += 1
		_checks += case.checks
		if case.failures.is_empty():
			print("  ok    %s" % n)
		else:
			_failed += 1
			print("  FAIL  %s" % n)
			for f in case.failures:
				print("          %s" % f)
