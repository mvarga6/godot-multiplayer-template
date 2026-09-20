# Stage 6 — Put it on the internet

**Goal:** the server runs on a machine with a public IP, and someone on a different network
joins and plays with you.

The game code barely changes. This stage is packaging, networking, and operations.

---

## Key concepts

### Why a public server solves NAT
Your home router does **Network Address Translation**: many devices behind one public IP. An
inbound UDP packet arriving unsolicited has no idea which internal machine to go to, so it is
dropped. That is why hosting from your desktop needs port forwarding.

But NAT happily allows *outbound* connections and remembers them, so return traffic flows.
Since ENet clients only ever dial out, **only the server needs a reachable port.** One
publicly addressable box removes the problem for every client. This is why essentially all
commercial games use dedicated servers or relays rather than asking players to configure
routers.

(CGNAT — where your ISP also NATs you — makes home hosting impossible rather than merely
annoying. Another reason not to bother.)

### Export templates and the dedicated-server preset
An **export template** is a prebuilt engine binary without the editor; exporting bundles your
project's assets into it. They are **not currently installed** on this machine
(`~/.local/share/godot/export_templates/` does not exist) — *Editor → Manage Export
Templates* downloads about 1 GB.

Godot's Linux preset has a **dedicated server** mode that strips rendering and audio from the
build and sets the `dedicated_server` feature tag — the one `OS.has_feature()` checks in
stage 5. Smaller binary, no graphics dependencies to install on the VPS.

**Shortcut for a first deploy:** skip exporting entirely. `scp` the project folder *and* the
Godot binary to the VPS and run the exact `--headless` command from stage 5. It works, it
avoids a 1 GB download, and it gets you to a real remote game today. Do the proper export
once you know the deployment works.

### UDP and firewalls
Two firewalls will block you and you must open both:

1. The **cloud provider's security group** (AWS/GCP/Azure/DigitalOcean/Hetzner panel).
2. The **host firewall** (`ufw`/`firewalld`) on the VM itself.

And the rule must say **UDP**. Opening TCP 9000 does nothing for ENet. Forgetting one of
these two is the single most common failure in this stage.

### Running as a service
An SSH session that ends kills its child processes. `systemd` solves that plus restart on
crash, start on boot, and log collection via `journalctl`.

### Version lock-step
RPCs are matched by method name and argument list. A client running yesterday's build against
today's server will fail in confusing ways — silently ignored calls, or type errors on the
receiving side. **Redeploy the server whenever the RPC surface changes**, and hand your
friend a fresh client build at the same time. Real games send a protocol version in the
handshake and reject mismatches; worth adding in stage 7 if this annoys you.

### Security posture
There is **no authentication and no encryption**. The port is open to the internet, so anyone
who finds it can join, and anyone on the path can read the traffic. For a learning sandbox
that is fine. Concretely:

- Do not run it as root; give it its own unprivileged user.
- Do not put it on a box that does anything else you care about.
- `MAX_PLAYERS` is your only protection against someone filling the server.
- An `any_peer` RPC is a public API. Stage 4's validation is the whole of your defence.

If you later want it locked down, Godot supports DTLS on `ENetMultiplayerPeer` and
`multiplayer.auth_callback` for a handshake. Both are firmly stage-8 material.

---

## Steps

### 1. Get a VPS
Anything with a public IPv4 works — Hetzner, DigitalOcean, Vultr, an Oracle/AWS free tier.
The smallest instance is far more than enough: this server is a dictionary of eight `Vector2`s
and a 20 Hz timer. 1 vCPU / 512 MB is generous.

Note the **public IP**; that string is what your friend types into the Join field.

### 2. Get the code there

Shortcut path (no export templates needed):

```bash
# from your machine
rsync -av --exclude '.godot' --exclude 'notes' \
  /home/mike/Source/sandbox/godot-playground/online-1/ \
  user@VPS_IP:~/online-1/
scp ~/Programs/Godot/Godot_v4.7.2-stable_mono_linux.x86_64 user@VPS_IP:~/godot
```

Proper path: install export templates, add a **Linux/X11** preset with *dedicated server*
enabled, export to `server.x86_64` (+ its `.pck`), and `scp` those two files instead.

The mono build may need `libicu`/`.NET` runtime bits on the VPS. If it complains, that is a
reason to prefer the exported dedicated-server binary, or the non-mono Godot build, for the
server.

### 3. Smoke-test it by hand

```bash
ssh user@VPS_IP
./godot --headless --path ~/online-1 -- --server
```

You want `Dedicated server listening on UDP 9000`. Leave it running and, from your own
machine, put `VPS_IP` in the Join field. If it connects, the hard part is done — turn it into
a service. If it does not, go to Troubleshooting below *before* touching systemd.

### 4. Open the port

```bash
sudo ufw allow 9000/udp
sudo ufw status            # confirm the rule is actually there
```

Then open UDP 9000 in the provider's web console too. Both. Always both.

### 5. Run it under systemd

Create `/etc/systemd/system/online1.service`:

```ini
[Unit]
Description=Online-1 Godot dedicated server
After=network.target

[Service]
Type=simple
User=godot
WorkingDirectory=/home/godot
ExecStart=/home/godot/godot --headless --path /home/godot/online-1 -- --server
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now online1
systemctl status online1
journalctl -u online1 -f      # live log; your spawn/despawn prints appear here
```

`Restart=always` plus the `quit(1)` from stage 5 means a failed port bind retries every 5
seconds instead of dying silently.

### 6. Hand out a client
Your friend needs the game. Either export a client build for their platform, or have them
run the project from source with the same Godot version. Same project version as the server —
see **Version lock-step** above.

---

## Verify

- You and someone on a different network both Join `VPS_IP`, both see both squares move.
- `journalctl -u online1 -f` shows their peer id connecting.
- **Reboot the VPS.** The service comes back on its own — that is what `enable` bought you.
- **Feel the latency.** Your square now responds ~50–150 ms after you press a key, because of
  the round trip from stage 4's diagram. Compare with localhost. This is the concrete reason
  client-side prediction exists, and it is worth sitting with for a minute.

---

## Troubleshooting, in order

Work top to bottom; do not skip.

1. **Is the process alive?** `systemctl status online1`
2. **Is it listening?** `ss -ulnp | grep 9000` on the VPS. No output → the server is not
   bound; read `journalctl -u online1`.
3. **Host firewall?** `sudo ufw status`. Rule must say `9000/udp`.
4. **Cloud firewall?** The provider's console. This is the one people forget.
5. **Right IP?** Public, not the VM's private `10.x`/`172.x` address.
6. **Reaching it at all?** `nc -u -z -v VPS_IP 9000` from your machine. UDP makes this less
   conclusive than TCP, but a hard failure is still informative.
7. **Client-side blocking?** Corporate or campus networks often block outbound UDP on
   arbitrary ports. Test from a phone hotspot to rule it out.

---

## Gotchas

- **TCP rule instead of UDP.** Silent, total failure.
- **Server binds `127.0.0.1` only.** Godot binds all interfaces by default, so this is
  unlikely — but if you ever pass a bind address, `0.0.0.0` is what you want.
- **Running as root.** Works, bad habit, and a remote code execution bug in your `any_peer`
  RPC becomes a root compromise.
- **`.godot/` rsynced to the server.** Harmless but large; it is a local cache.
- **IP changes.** Most VPS IPs are static, but confirm; otherwise use a DNS name.
- **Both of you on the same LAN, testing "the internet".** Traffic may never leave the
  building and hide a misconfiguration. Use a hotspot for a genuine test.

---

## What you should now understand

Why NAT makes peer-to-peer hard and a public server easy; how a Godot project becomes a
deployable service; and — by feel — how much latency changes the experience. That last one is
what stage 7 is for.
