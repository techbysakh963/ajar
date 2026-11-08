#!/bin/bash
# Record the Ajar flow on a real GNOME desktop in a throwaway VM, and save key stills.
#   VM=ajar-ubuntu2404 tests/vm/gnome-demo.sh <outdir>
# Frames come from the VM's framebuffer (virsh screenshot); clicks are made through GNOME
# Shell (test-only unsafe-mode extension); the password is typed as real key events into the
# real polkit dialog. This is demo capture, not a test: the test suite never drives ON.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/vm/lib.sh
. "$here/lib.sh"
out="${1:?outdir}"; mkdir -p "$out/frames"
: "${VM:?set VM}"

TOGGLE='Main.panel.statusArea.quickSettings.menu._grid.get_children().find(c => c.title === "Sudo")'
qs_open()  { veval 'Main.panel.statusArea.quickSettings.menu.open(true); "ok"' >/dev/null; }
qs_close() { veval 'Main.panel.statusArea.quickSettings.menu.close(true); "ok"' >/dev/null; }
click()    { veval "$TOGGLE._onClicked(); 'ok'" >/dev/null; }
submenu()  { veval "$TOGGLE.menu.open(true); 'ok'" >/dev/null; }
state()    { vrun 'ajar status --json' | sed -E 's/.*"state":"([a-z]+)".*/\1/'; }
wait_state() { local w="$1" i; for i in $(seq 40); do [[ "$(state)" == "$w" ]] && return 0; sleep 0.5; done; echo "state never became $w" >&2; return 1; }

# --- recorder: framebuffer frames, ~4 per second ----------------------------------
rec_start() {
    ( n=0; while :; do
        virsh -c qemu:///system screenshot "$VM" "$out/frames/$(printf %05d $n).ppm" >/dev/null 2>&1 || true
        n=$((n+1)); sleep 0.2
      done ) & REC=$!
}
rec_stop() { kill "$REC" 2>/dev/null; wait "$REC" 2>/dev/null || true; }
trap 'rec_stop' EXIT

[[ "$(state)" == off ]] || { vrun 'ajar off' >/dev/null; wait_state off; }
# a clean desktop: no first-run welcome window, no leftover notifications
vrun 'mkdir -p ~/.config && echo yes > ~/.config/gnome-initial-setup-done; pkill -f '^/usr/libexec/gnome-initial-setup'; true'
veval 'Main.messageTray._notificationQueue?.forEach?.(n => n.destroy()); Main.panel.statusArea.dateMenu._messageList?._sectionList?.get_children?.().forEach?.(s => s.clear?.()); "ok"' >/dev/null || true
qs_close; sleep 1

rec_start
sleep 1.5
qs_open;                       sleep 2;   vshot "$out/01-quick-settings-off.png" >/dev/null
click;                         sleep 3;   vshot "$out/02-password-dialog.png" >/dev/null
vtype_password; sleep 0.4;     vkey KEY_ENTER
wait_state on;                 sleep 2.5; vshot "$out/03-on-notification.png" >/dev/null
qs_open;                       sleep 2;   vshot "$out/03b-quick-settings-on.png" >/dev/null
submenu;                       sleep 2.5; vshot "$out/04-toggle-menu.png" >/dev/null
qs_close;                      sleep 2.5; vshot "$out/05-top-bar-amber-door.png" >/dev/null
vrun 'ajar remind 3s' >/dev/null
sleep 7;                                  vshot "$out/06-reminder.png" >/dev/null
qs_open;                       sleep 1.5
click; wait_state off;         sleep 2.5; vshot "$out/07-turned-off.png" >/dev/null
qs_close;                      sleep 1.5
rec_stop; trap - EXIT

# The reminder notification is still waiting for an answer; close it via the CLI's own path.
vrun 'systemctl --user stop ajar-reminder.service 2>/dev/null; true'
echo "frames: $(find "$out/frames" -name '*.ppm' | wc -l), stills in $out"
