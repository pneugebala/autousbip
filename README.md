# autousbip

Automatic USB/IP tunneling for a pair of Linux hosts.

This repo contains scripts, udev rules and systemd units that export a USB
device from one Linux box (the **server**) and re-attach it on another Linux
box (the **client**), with no manual `usbip bind`/`usbip attach` steps.

- **Server side**
  - Auto-binds matching devices to `usbip-host` as soon as they are plugged in
    (udev rule + dispatcher).
  - Auto-unbinds (best-effort cleanup) when a managed device is unplugged.
  - Binds devices that were already plugged in at boot (one-shot systemd unit).
  - Runs `usbipd` in the foreground under systemd.
- **Client side**
  - Continuously polls the server's export list and `usbip attach`es matching
    devices through `vhci-hcd`.
  - Detects when a device disappears locally (server reboot, network blip,
    device unplugged at the server) and automatically re-attaches it once the
    server advertises it again.

No Python, no daemons-of-our-own beyond `usbipd` and the small client loop.
Just plain bash + udev + systemd.

---

## Layout

```
autousbip/
├── install.sh                 # run as root on the target Linux host
├── config/
│   ├── server.conf.example     # list of vid:pid to export
│   └── client.conf.example     # server addr + list of vid:pid to import
├── server/
│   ├── autousbip-server        # /usr/local/sbin/autousbip-server (dispatcher)
│   ├── autousbip-usbipd.service
│   ├── autousbip-server-boot.service
│   ├── autousbip-server.modules-load.conf
│   └── 99-autousbip-server.rules
└── client/
    ├── autousbip-client        # /usr/local/sbin/autousbip-client (loop)
    ├── autousbip-client.service
    └── autousbip-client.modules-load.conf
```

## Prerequisites (target Linux host)

- Kernel with `CONFIG_USBIP_CORE`, `CONFIG_USBIP_HOST` (server) and
  `CONFIG_USBIP_VHCI_HCD` (client). On Debian/Ubuntu these are in the stock
  kernel; modules live in `linux-modules-extra-$(uname -r)` on Ubuntu.
- The `usbip` userspace tool (Debian: `usbip-utils`, Arch: `usbip-utils`,
  Fedora: `usbip-utils`). Provides both `usbip` and `usbipd`.
- `lsusb` (from `usbutils`) on the client - optional but recommended for fast
  attach verification. A sysfs fallback is used if it is missing.

## Quick start

```bash
# On the SERVER host (the box that physically has the USB device):
git clone https://github.com/pneugebala/autousbip.git autousbip && cd autousbip
sudo ./install.sh --server
# Edit /etc/autousbip/server.conf and add the device's vid:pid.
# Find it with `lsusb`, e.g.:
#   Bus 001 Device 004: ID 046d:c52b Logitech, Inc. Unifying Receiver
#   -> add a line:  046d:c52b   logitech_receiver
$EDITOR /etc/autousbip/server.conf
sudo systemctl restart autousbip-usbipd autousbip-server-boot
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=usb --action=add

# Verify the device is exported:
usbip list -l            # local list, should show "usbip-host" driver
ss -ltnp | grep 3240     # usbipd listening

# On the CLIENT host (the box that wants to USE the device):
git clone https://github.com/pneugebala/autousbip.git autousbip && cd autousbip
sudo ./install.sh --client
# Edit /etc/autousbip/client.conf to point at the server and list the same
# vid:pid values.
$EDITOR /etc/autousbip/client.conf
sudo systemctl restart autousbip-client

# Watch:
journalctl -u autousbip-client -f
lsusb                     # should now show the remote device locally
```

## How it works

### Server

1. `autousbip-usbipd.service` loads `usbip-core` + `usbip-host` and runs
   `usbipd` (the USB/IP daemon, TCP 3240).
2. `99-autousbip-server.rules` is a udev rule that matches every USB device
   (not interfaces) and invokes `autousbip-server udev-add <busid> <vid>
<pid>` on `add` and `autousbip-server udev-remove <busid>` on `remove`.
3. The dispatcher reads `/etc/autousbip/server.conf`. If the device's
   `vid:pid` is listed, it spawns a transient systemd unit
   (`autousbip-server-bind@<busid>.service`) that runs `usbip bind -b <busid>`
   off the udev thread, then records the busid in
   `/run/autousbip/server/<busid>.bound` so we know we own it.
4. On `remove`, if the busid is one we manage, a transient unit calls
   `usbip unbind -b <busid>` (errors are ignored - the kernel usually
   auto-cleans on unplug) and removes the marker.
5. `autousbip-server-boot.service` (Type=oneshot, after `usbipd`) walks
   `/sys/bus/usb/devices/*` at boot and binds every plugged-in device whose
   `vid:pid` is in the config. This handles the "already plugged in on boot"
   case.

The dispatcher is idempotent: replugging a device whose busid was already
bound will detect `is_exported` and skip; an `add` event for an
already-managed busid is also skipped.

### Client

`autousbip-client.service` runs `/usr/local/sbin/autousbip-client`, a
single long-running bash loop:

- For each configured `vid:pid`, it asks the server `usbip list -r $SERVER`
  and greps for `(vid:pid)`. The matching line gives the server-side busid.
- It calls `usbip attach -r $SERVER -b <busid>` and waits for the device to
  enumerate locally (checked via `lsusb` / sysfs fallback).
- Once attached, the loop monitors the local device. When it disappears
  (the remote end unplugged it, the server rebooted, or the network blipped),
  the loop cleans up the stale vhci port with `usbip detach -p <port>` and
  goes back to polling the server's export list.
- The server doesn't have to be up when the client starts - the loop will
  keep polling every `POLL_INTERVAL` seconds until it can reach it.

State machine per device: `detached` -> `waiting` (not advertised) ->
`attaching` -> `settling` -> `attached`. Any transition back to "not visible
locally" triggers a port cleanup and return to `detached`.

## Configuration reference

### `/etc/autousbip/server.conf`

```
# idVendor:idProduct [alias]
046d:c52b   logitech_receiver
046d:c534
1bcf:2281   sunplus_720p
```

### `/etc/autousbip/client.conf`

```bash
SERVER="192.168.1.10"
SERVER_PORT="3240"        # default 3240
POLL_INTERVAL="5"         # seconds between checks / attach attempts
RETRY_INTERVAL="10"      # seconds to back off after a failed attach
ATTACH_SETTLE="2"         # seconds to wait for local enumeration

DEVICES=(
    "046d:c52b   logitech_receiver"
    "046d:c534"
)
```

## Logging

Both scripts log to syslog with tags `autousbip-server` and
`autousbip-client`, and also to stderr (which systemd captures into the
journal). Useful filters:

```bash
journalctl -t autousbip-server -t autousbip-client -f
# or by unit:
journalctl -u autousbip-usbipd -u autousbip-server-boot -u autousbip-client -f
```

## Operating notes

- The server-side udev rule matches ALL usb devices and asks the dispatcher
  to consult the config - there is no per-device rule to regenerate when you
  edit `server.conf`. Just `udevadm control --reload-rules` (the dispatcher
  reads the config on every event) and you're done.
- The client uses `usbip list -r $SERVER` to discover the server-side busid
  of each device. This means the server must already have _bound_ the device
  before the client can see it - the two sides are coordinated by the
  `vid:pid` tuple, not by a fixed busid (busids change when devices are
  moved to different ports).
- The server does NOT expose the device to the network until `usbip bind`
  is run. `usbipd` only advertises bound devices. So if `usbipd` is up but
  nothing is bound, `usbip list -r` shows an empty export list.
- `usbip` traffic is **unencrypted** on TCP 3240. Run it over a VPN or a
  SSH tunnel if the network between the two hosts is not trusted.
- For multiple distinct servers, copy `autousbip-client.service` to
  `autousbip-client@.service` and set `Environment=AUTOUSBIP_CLIENT_CONFIG=
/etc/autousbip/client-%i.conf` in a drop-in, then `systemctl enable --now
autousbip-client@sitea`.

## Uninstall

```bash
sudo ./install.sh --uninstall
```

This stops + disables the services and removes all installed files. Your
`/etc/autousbip/*.conf` files are left untouched so you can re-install
without losing them.
