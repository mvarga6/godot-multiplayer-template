GODOT ?= /home/mike/Programs/Godot/Godot_v4.7.2-stable_mono_linux.x86_64
PORT ?= 9000
PROJECT := $(CURDIR)

# playitd runs as user `playit` with RuntimeDirectoryMode=0750, so both the
# service and its IPC socket in /run/playit need root to touch.
SYSTEMCTL ?= sudo systemctl
PLAYIT ?= sudo playit

.PHONY: server tunnel tunnel-stop tunnel-status tunnel-attach

# Run the dedicated server in the foreground. Ctrl-C to stop.
# Override the port with: make server PORT=9001
server:
	$(GODOT) --headless --path $(PROJECT) -- --server --port $(PORT)

# Start the playit.gg agent. Boot start is disabled on purpose, so nothing
# tunnels anywhere until you run this.
tunnel:
	$(SYSTEMCTL) start playit.service

tunnel-stop:
	$(SYSTEMCTL) stop playit.service

# Process state, then agent state. Leading `-` because systemctl exits
# non-zero when the service is stopped, which is a normal answer here.
tunnel-status:
	-$(SYSTEMCTL) --no-pager --lines=0 status playit.service
	-$(PLAYIT) status

# Live TUI listing your tunnels and their public host:port addresses.
tunnel-attach:
	$(PLAYIT) attach
