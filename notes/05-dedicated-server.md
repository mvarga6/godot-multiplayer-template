# Stage 5 — Split the server out

**Goal:** the server runs as its own process with no window, started from the command line.
Clients connect to it. Nobody is "the host" any more.

---

## Key concepts

### Host vs dedicated server
Until now one player was also the server — a **listen server**. It is convenient and it is
what most small co-op games ship. Its problems: the host has zero latency while everyone else
pays for it, the game dies when the host quits, and the host's machine needs an open port.

A **dedicated server** is a process that simulates the game and plays no part in it. It is
peer `1`, it has no player node of its own, and it renders nothing. Every client is equal.
This is the only shape that works for stage 6, because a VPS has no one sitting at it.

### Headless mode
`--headless` starts Godot with a dummy display and dummy audio driver. No window, no GPU
required — which matters because a cheap VPS has no GPU and often no X server at all.

Anything that touches rendering must therefore not run. Your `_physics_process` input read,
your `ColorRect` colours, your viewport size lookups — all fine to *have* in the scene, but
guard the ones that assume a real window.

Note `get_viewport_rect().size` still returns something sensible in headless mode (the
project's configured window size), so the stage-4 clamp keeps working. Good — but it is now
a *game rule* that happens to be expressed in window units. Promote it to a constant:

```gdscript
const ARENA := Vector2(1152, 648)
```

so the server's arena does not depend on a display setting.

### Command-line arguments
Godot consumes its own arguments; yours go after a bare `--`:

```bash
godot --headless --path /project -- --server
```

- `OS.get_cmdline_args()` — everything, including Godot's own.
- `OS.get_cmdline_user_args()` — **only what follows `--`.** Use this one.

### `OS.has_feature("dedicated_server")`
Once you export with the dedicated-server preset (stage 6), this returns `true`, which is a
cleaner switch than an argument. Support both: the argument for running from source now, the
feature tag for the exported build later.

### Server lifetime
A dedicated server must survive every client leaving. Check your disconnect handling: nothing
should call `get_tree().quit()`, and the server should sit at zero players indefinitely,
waiting. This is also where an idle-timeout or a restart policy would go in a real service.

---

## Steps

### 1. Detect server mode at startup

```gdscript
var is_dedicated := false

func _ready() -> void:
	_connect_multiplayer_signals()
	is_dedicated = "--server" in OS.get_cmdline_user_args() \
		or OS.has_feature("dedicated_server")
	if is_dedicated:
		_start_dedicated_server()

func _start_dedicated_server() -> void:
	lobby.hide()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		push_error("Cannot bind port %d: %s" % [PORT, error_string(err)])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	broadcast_timer.start()
	print("Dedicated server listening on UDP %d" % PORT)
```

Note it does **not** call `spawn_player.rpc(1, ...)` — the dedicated server has no avatar.

### 2. Guard the client-only paths

```gdscript
func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if multiplayer.is_server():
		_server_simulate(delta)
	if not is_dedicated:
		_send_input()          # no keyboard on a VPS
```

`Input.get_vector` in headless mode returns zero rather than crashing, so this guard is about
clarity and wasted work rather than survival. Guard it anyway — the habit is what matters
when the scene grows something that *does* crash.

### 3. Keep the exit code meaningful
`get_tree().quit(1)` on a bind failure means `systemd` in stage 6 can tell a crash from a
clean shutdown. Log with `print()` (stdout) for normal events and `push_error()` (stderr) for
failures; `journalctl` separates them.

### 4. Make the host button optional, not gone
Leave Host working. Being able to run a listen server locally is the fastest way to test a
gameplay change without starting a second process.

---

## Verify

Terminal 1:

```bash
~/Programs/Godot/Godot_v4.7.2-stable_mono_linux.x86_64 \
  --headless --path /home/mike/Source/sandbox/godot-playground/online-1 -- --server
```

Expect `Dedicated server listening on UDP 9000` and then silence until someone joins.

Editor: run **2 instances**, click **Join** in both (neither hosts). Both squares appear in
both windows and move. The server terminal logs each spawn and despawn.

Then the tests that actually matter for a dedicated server:

1. **Close both clients.** Server keeps running, logs two despawns, does not exit.
2. **Reconnect.** New peer ids, everything works, no leftover squares from the old session.
3. **Ctrl-C the server** while clients are connected. Clients print `server_disconnected`
   and clear their squares, without crashing.
4. **`ss -ulnp | grep 9000`** in another terminal — confirms it is really listening on UDP.
   Learn this command now; in stage 6 it is the first thing you will reach for.

---

## Gotchas

- **`--server` ignored** — you used `OS.get_cmdline_args()` (which includes Godot's flags and
  will not contain yours the way you expect) instead of `get_cmdline_user_args()`, or you
  forgot the bare `--` separator on the command line.
- **Server exits immediately** — an error during startup, or an autoload calling `quit()`.
  Read the whole stdout; headless Godot prints its errors and keeps going otherwise.
- **`Address already in use`** — a previous server is still running. `pkill -f "\-\-server"`.
- **Clients see three squares for two players** — the server is still spawning its own
  player. Remove the `spawn_player.rpc(1, ...)` from the dedicated path.
- **Nothing moves, server logs look fine** — the broadcast timer is only started in
  `_on_host_button_pressed()`. It must also start in `_start_dedicated_server()`.

---

## What you should now understand

The same project produces two different programs depending on one flag, and the server has no
dependency on a display, a keyboard, or a player. Everything it needs is now a copy of the
project and a Godot binary — which is all stage 6 has to move onto a VPS.
