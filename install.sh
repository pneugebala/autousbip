#!/bin/bash
# install.sh - deploy autousbip onto a Linux host.
#
# Run as root (or with sudo) on the *target* Linux box.
#
# Usage:
#   sudo ./install.sh                  # install everything (server + client)
#   sudo ./install.sh --server         # only server side
#   sudo ./install.sh --client         # only client side
#   sudo ./install.sh --uninstall      # remove everything
#
# Existing /etc/autousbip/*.conf files are NEVER overwritten: an example
# file is installed next to them as *.conf.example. You must copy/edit
# the example into a real *.conf before the services will do anything.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETC="/etc/autousbip"
UDEV_DIR="/etc/udev/rules.d"
SYSTEMD_DIR="/etc/systemd/system"
MODLOAD_DIR="/etc/modules-load.d"
SBIN_DIR="/usr/local/sbin"

MODE="all"
UNINSTALL=0

for arg in "$@"; do
    case "$arg" in
        --server)    MODE="server" ;;
        --client)    MODE="client" ;;
        --uninstall) UNINSTALL=1 ;;
        --all)       MODE="all" ;;
        -h|--help)
            sed -n '2,/^$/p' "$0"
            exit 0
            ;;
        *)
            echo "unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "must be run as root" >&2
    exit 1
fi

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }
}
need_cmd install
need_cmd systemctl
need_cmd udevadm

install_dir()   { install -d -m "$2" "$1"; }
install_file()  { install -m "$3" "$1" "$2"; }
install_script(){ install -m 0755 "$1" "$2"; }

do_install_server() {
    echo "==> installing server side"
    install_dir "$ETC"                0755
    install_dir "$SBIN_DIR"            0755
    install_dir "$UDEV_DIR"            0755
    install_dir "$SYSTEMD_DIR"         0755
    install_dir "$MODLOAD_DIR"         0755

    install_script "$SCRIPT_DIR/server/autousbip-server" "$SBIN_DIR/autousbip-server"

    install_file "$SCRIPT_DIR/server/autousbip-usbipd.service"        "$SYSTEMD_DIR/autousbip-usbipd.service"        0644
    install_file "$SCRIPT_DIR/server/autousbip-server-boot.service"    "$SYSTEMD_DIR/autousbip-server-boot.service"  0644
    install_file "$SCRIPT_DIR/server/99-autousbip-server.rules"       "$UDEV_DIR/99-autousbip-server.rules"         0644
    install_file "$SCRIPT_DIR/server/autousbip-server.modules-load.conf" "$MODLOAD_DIR/autousbip-server.conf"      0644

    # Example config (never overwrite an existing one)
    if [ ! -f "$ETC/server.conf" ]; then
        install_file "$SCRIPT_DIR/config/server.conf.example" "$ETC/server.conf" 0644
        echo "    created $ETC/server.conf  (edit this!)"
    fi
    install_file "$SCRIPT_DIR/config/server.conf.example" "$ETC/server.conf.example" 0644
}

do_install_client() {
    echo "==> installing client side"
    install_dir "$ETC"                0755
    install_dir "$SBIN_DIR"            0755
    install_dir "$SYSTEMD_DIR"         0755
    install_dir "$MODLOAD_DIR"         0755

    install_script "$SCRIPT_DIR/client/autousbip-client" "$SBIN_DIR/autousbip-client"

    install_file "$SCRIPT_DIR/client/autousbip-client.service"        "$SYSTEMD_DIR/autousbip-client.service"        0644
    install_file "$SCRIPT_DIR/client/autousbip-client.modules-load.conf" "$MODLOAD_DIR/autousbip-client.conf"      0644

    if [ ! -f "$ETC/client.conf" ]; then
        install_file "$SCRIPT_DIR/config/client.conf.example" "$ETC/client.conf" 0644
        echo "    created $ETC/client.conf  (edit this!)"
    fi
    install_file "$SCRIPT_DIR/config/client.conf.example" "$ETC/client.conf.example" 0644
}

reload_and_enable() {
    echo "==> reloading systemd + udev"
    systemctl daemon-reload
    udevadm control --reload-rules 2>/dev/null || true
    # Trigger a re-scan of currently-present USB devices so the new udev
    # rule fires for devices that were already plugged in.
    udevadm trigger --subsystem-match=usb --action=add 2>/dev/null || true

    if [ "$MODE" = "all" ] || [ "$MODE" = "server" ]; then
        echo "==> enabling server services"
        systemctl enable --now autousbip-usbipd.service
        systemctl enable --now autousbip-server-boot.service
    fi
    if [ "$MODE" = "all" ] || [ "$MODE" = "client" ]; then
        echo "==> enabling client service"
        systemctl enable --now autousbip-client.service
    fi
}

do_uninstall() {
    echo "==> stopping + disabling services"
    systemctl disable --now autousbip-client.service 2>/dev/null || true
    systemctl disable --now autousbip-server-boot.service 2>/dev/null || true
    systemctl disable --now autousbip-usbipd.service 2>/dev/null || true

    echo "==> removing files"
    rm -f "$SBIN_DIR/autousbip-server" \
          "$SBIN_DIR/autousbip-client" \
          "$SYSTEMD_DIR/autousbip-usbipd.service" \
          "$SYSTEMD_DIR/autousbip-server-boot.service" \
          "$SYSTEMD_DIR/autousbip-client.service" \
          "$UDEV_DIR/99-autousbip-server.rules" \
          "$MODLOAD_DIR/autousbip-server.conf" \
          "$MODLOAD_DIR/autousbip-client.conf"

    systemctl daemon-reload
    udevadm control --reload-rules 2>/dev/null || true
    echo "Note: $ETC/*.conf was left in place - remove manually if desired:"
    ls -1 "$ETC" 2>/dev/null | sed 's/^/    /'
}

if [ "$UNINSTALL" -eq 1 ]; then
    do_uninstall
    echo "==> done (uninstalled)"
    exit 0
fi

case "$MODE" in
    server) do_install_server ;;
    client) do_install_client ;;
    all)
        do_install_server
        do_install_client
        ;;
esac

reload_and_enable

cat <<EOF

==> done.
    Edit $ETC/server.conf and/or $ETC/client.conf, then either reboot or run:
        sudo systemctl restart autousbip-usbipd autousbip-server-boot
        sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=usb
        sudo systemctl restart autousbip-client

    Watch logs with:
        journalctl -u autousbip-usbipd -u autousbip-server-boot -u autousbip-client -f
        journalctl -t autousbip-server -t autousbip-client -f
EOF
