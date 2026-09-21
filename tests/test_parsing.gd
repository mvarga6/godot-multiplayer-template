extends GameTest

var main: Node2D

func before_each() -> void:
	main = make_main()

func after_each() -> void:
	drop_main(main)

# --- --port ------------------------------------------------------------------

func test_port_defaults_when_absent() -> void:
	eq(main._port_from_args(PackedStringArray([])), main.DEFAULT_PORT, "no args")
	eq(main._port_from_args(PackedStringArray(["--server"])), main.DEFAULT_PORT, "other args only")

func test_port_accepts_both_spellings() -> void:
	eq(main._port_from_args(PackedStringArray(["--port", "7777"])), 7777, "--port N")
	eq(main._port_from_args(PackedStringArray(["--port=7777"])), 7777, "--port=N")
	eq(main._port_from_args(PackedStringArray(["--server", "--port", "1234"])), 1234, "after other args")

func test_bad_ports_fall_back_to_the_default() -> void:
	eq(main._port_from_args(PackedStringArray(["--port", "abc"])), main.DEFAULT_PORT, "not a number")
	eq(main._port_from_args(PackedStringArray(["--port", "0"])), main.DEFAULT_PORT, "zero")
	eq(main._port_from_args(PackedStringArray(["--port", "70000"])), main.DEFAULT_PORT, "out of range")
	eq(main._port_from_args(PackedStringArray(["--port"])), main.DEFAULT_PORT, "flag with no value")

# --- the Join field -----------------------------------------------------------

func test_a_bare_host_uses_the_configured_port() -> void:
	main.port = 9000
	var r: Array = main._split_address("127.0.0.1")
	eq(r[0], "127.0.0.1", "host")
	eq(r[1], 9000, "port falls back")

func test_host_colon_port_is_split() -> void:
	# This is what a playit tunnel address looks like.
	var r: Array = main._split_address("della-affiliates.tun.ply.gg:30755")
	eq(r[0], "della-affiliates.tun.ply.gg", "host")
	eq(r[1], 30755, "port")

func test_surrounding_whitespace_is_ignored() -> void:
	var r: Array = main._split_address("  1.2.3.4 : 80  ")
	eq(r[0], "1.2.3.4", "host trimmed")
	eq(r[1], 80, "port trimmed")

func test_ipv6_literals() -> void:
	main.port = 9000
	var bracketed: Array = main._split_address("[::1]:9999")
	eq(bracketed[0], "::1", "bracketed host")
	eq(bracketed[1], 9999, "bracketed port")
	var no_port: Array = main._split_address("[::1]")
	eq(no_port[0], "::1", "bracketed host without a port")
	eq(no_port[1], 9000, "falls back")
	var bare: Array = main._split_address("::1")
	eq(bare[0], "::1", "a bare v6 literal is not split on its colons")
	eq(bare[1], 9000, "falls back")

func test_a_junk_port_falls_back_rather_than_failing() -> void:
	main.port = 9000
	eq(main._split_address("host:notaport")[1], 9000, "non-numeric")
	eq(main._split_address("host:0")[1], 9000, "zero")
	eq(main._split_address("host:70000")[1], 9000, "out of range")

# --- display names ------------------------------------------------------------

func test_names_are_trimmed_and_kept() -> void:
	eq(main._clean_name("  Mike  ", 7), "Mike", "trimmed")
	eq(main._clean_name("Dr. Unicode", 7), "Dr. Unicode", "inner spaces survive")

func test_an_empty_name_becomes_a_default() -> void:
	eq(main._clean_name("", 42), "Player 42", "empty")
	eq(main._clean_name("     ", 42), "Player 42", "whitespace only")

func test_names_are_capped() -> void:
	var long_name := "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWW"
	eq(main._clean_name(long_name, 1).length(), main.NAME_MAX, "capped at NAME_MAX")

func test_control_characters_are_stripped() -> void:
	# `any_peer` input: never render what a client sends verbatim.
	var dirty := "a\u0007b\u001Fc"
	var clean: String = main._clean_name(dirty, 1)
	eq(clean, "abc", "bell and NUL removed")
	for i in clean.length():
		ok(clean.unicode_at(i) >= 32, "no control characters survive")
