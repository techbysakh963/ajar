#!/bin/bash
# Run the real GNOME Shell headless, with the Ajar extension, in a throwaway session.
#
#   tests/gnome-nested.sh start [WxH]   start shell on a virtual monitor (default 1280x800)
#   tests/gnome-nested.sh eval 'JS'     run JS inside that shell, print the result
#   tests/gnome-nested.sh shot FILE     screenshot the virtual monitor to FILE (png)
#   tests/gnome-nested.sh stop
#
# Isolation: its own D-Bus session, Wayland socket, settings (keyfile backend) and
# XDG data/config dirs under $AJAR_NESTED_DIR. Shell "unsafe mode" (needed for Eval and
# Screenshot from a script) is switched on by a helper extension that exists ONLY in that
# throwaway data dir, so it can never be enabled in your real session.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
T="${AJAR_NESTED_DIR:-${TMPDIR:-/tmp}/ajar-nested-$UID}"
UUID=ajar@techbysakh963.github.io
HELPER=ajar-test-unsafe-mode@localhost

bus() { cat "$T/bus"; }
call() {   # call <method> <args...> on org.gnome.Shell
    gdbus call --address "$(bus)" --dest org.gnome.Shell "$@"
}

start() {
    local size="${1:-1280x800}"
    stop 2>/dev/null || true
    rm -rf "$T"; mkdir -p "$T"/{data/gnome-shell/extensions,config,shots}
    chmod 700 "$T"
    cp -rL "$here/gnome-extension" "$T/data/gnome-shell/extensions/$UUID"
    mkdir -p "$T/data/gnome-shell/extensions/$HELPER"
    cat > "$T/data/gnome-shell/extensions/$HELPER/metadata.json" <<EOF
{"uuid": "$HELPER", "name": "test-only unsafe mode", "description": "throwaway test session only",
 "shell-version": ["45","46","47","48","49","50"]}
EOF
    cat > "$T/data/gnome-shell/extensions/$HELPER/extension.js" <<'EOF'
export default class { enable() { global.context.unsafe_mode = true; } disable() { global.context.unsafe_mode = false; } }
EOF
    export XDG_DATA_HOME="$T/data" XDG_CONFIG_HOME="$T/config" GSETTINGS_BACKEND=keyfile
    gsettings set org.gnome.shell enabled-extensions "['$HELPER', '$UUID']"
    gsettings set org.gnome.shell disable-user-extensions false
    gsettings set org.gnome.shell welcome-dialog-last-shown-version '999'
    gsettings set org.gnome.desktop.interface color-scheme prefer-dark
    dbus-daemon --session --fork --print-address=3 --print-pid=4 3>"$T/bus" 4>"$T/bus.pid"
    DBUS_SESSION_BUS_ADDRESS="$(bus)" XDG_SESSION_TYPE=wayland \
        setsid gnome-shell --headless --wayland --no-x11 --wayland-display "ajar-test-$$" \
        --virtual-monitor "$size" >"$T/shell.log" 2>&1 &
    echo $! > "$T/shell.pid"
    for _ in $(seq 60); do
        if call --object-path /org/gnome/Shell --method org.gnome.Shell.Eval 'global.context.unsafe_mode' 2>/dev/null | grep -q true; then
            echo "nested GNOME Shell up ($(gnome-shell --version)), state dir $T"; return 0
        fi
        sleep 0.5
    done
    echo "shell did not come up; log:" >&2; tail -30 "$T/shell.log" >&2; return 1
}

js() { call --object-path /org/gnome/Shell --method org.gnome.Shell.Eval "$1"; }

shot() {
    local out; out="$(readlink -f "$1")"
    call --object-path /org/gnome/Shell/Screenshot --method org.gnome.Shell.Screenshot.Screenshot false false "$out" >/dev/null
    echo "$out"
}

stop() {
    [[ -f "$T/shell.pid" ]] && kill "$(cat "$T/shell.pid")" 2>/dev/null || true
    [[ -f "$T/bus.pid" ]] && kill "$(cat "$T/bus.pid")" 2>/dev/null || true
    rm -f "$T/shell.pid" "$T/bus.pid"
}

case "${1:-}" in
    start) shift; start "$@" ;;
    eval)  js "$2" ;;
    shot)  shot "$2" ;;
    stop)  stop ;;
    *) sed -n '2,8p' "$0"; exit 2 ;;
esac
