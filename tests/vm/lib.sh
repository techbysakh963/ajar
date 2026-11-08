#!/bin/bash
# Helpers for driving throwaway desktop VMs (see provision.sh). Source it:
#   . tests/vm/lib.sh; VM=ajar-ubuntu2404
#   vrun 'ajar status'          run as the VM's desktop user, inside the graphical session
#   vroot 'apt-get install …'   run as root in the VM
#   veval 'JS'                  GNOME Shell Eval (needs the test-only unsafe-mode extension)
#   vshot out.png               real framebuffer screenshot via libvirt
#   vtype 'text'                type text with real key events; vtype_password types the
#                               throwaway VM password from $VMDIR/password (never printed)
# Screenshots and key events go through libvirt, not through the guest.

VMDIR="${VMDIR:-$HOME/ajar-vms}"
VM="${VM:-}"
VUSER="${VUSER:-demo}"
_K=(-i "$VMDIR/id_ed25519" -o UserKnownHostsFile="$VMDIR/known_hosts" -o StrictHostKeyChecking=no
    -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR)

# Ask the guest itself (QEMU guest agent) first: after a desktop install NetworkManager takes
# a second DHCP lease, and both the lease list and the host ARP table can name a stale address.
vip() {
    local ip src
    ip="$(virsh -c qemu:///system domifaddr "$VM" --source agent 2>/dev/null \
          | awk '/ipv4/ && $4 !~ /^127\./{split($4,a,"/"); print a[1]; exit}')"
    [[ -n "$ip" ]] && { echo "$ip"; return; }
    for src in arp lease; do
        ip="$(virsh -c qemu:///system domifaddr "$VM" --source "$src" 2>/dev/null | awk '/ipv4/{split($4,a,"/"); print a[1]; exit}')"
        [[ -n "$ip" ]] && { echo "$ip"; return; }
    done
}
# shellcheck disable=SC2029  # intended: callers build the remote command line
vssh() { ssh "${_K[@]}" "$VUSER@$(vip)" "$@"; }

# Run in the user's graphical session environment (session bus, Wayland/X display).
vrun() {   # always bash on the remote side (Kali's login shell is zsh)
    local script="export XDG_RUNTIME_DIR=/run/user/\$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus
          export WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 XAUTHORITY=\$(ls -1 \$HOME/.Xauthority /run/user/\$(id -u)/.mutter-Xwaylandauth.* 2>/dev/null | head -1)
          $*"
    vssh "bash -c $(printf '%q' "$script")"
}
vroot() { vssh "sudo -n bash -c $(printf '%q' "$*")"; }

veval() {
    vrun "gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Eval $(printf '%q' "$1")"
}

vshot() {   # vshot <out.png>
    local ppm; ppm="$(mktemp --suffix=.ppm)"
    virsh -c qemu:///system screenshot "$VM" "$ppm" >/dev/null && magick "$ppm" "$1" && rm -f "$ppm" && echo "$1"
}

# Real key events through the hypervisor. Supports a-z A-Z 0-9 space - . / = | >
vtype() {
    local s="$1" i c k
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-z]) k="KEY_${c^^}"; virsh -c qemu:///system send-key "$VM" "$k" >/dev/null ;;
            [A-Z]) virsh -c qemu:///system send-key "$VM" KEY_LEFTSHIFT "KEY_$c" >/dev/null ;;
            [0-9]) virsh -c qemu:///system send-key "$VM" "KEY_$c" >/dev/null ;;
            ' ')   virsh -c qemu:///system send-key "$VM" KEY_SPACE >/dev/null ;;
            -) virsh -c qemu:///system send-key "$VM" KEY_MINUS >/dev/null ;;
            .) virsh -c qemu:///system send-key "$VM" KEY_DOT >/dev/null ;;
            /) virsh -c qemu:///system send-key "$VM" KEY_SLASH >/dev/null ;;
            =) virsh -c qemu:///system send-key "$VM" KEY_EQUAL >/dev/null ;;
            '|') virsh -c qemu:///system send-key "$VM" KEY_LEFTSHIFT KEY_BACKSLASH >/dev/null ;;
            '>') virsh -c qemu:///system send-key "$VM" KEY_LEFTSHIFT KEY_DOT >/dev/null ;;
            *) echo "vtype: unsupported character" >&2; return 1 ;;
        esac
        sleep 0.05
    done
}
vkey() { virsh -c qemu:///system send-key "$VM" "$@" >/dev/null; }
vtype_password() { vtype "$(cat "$VMDIR/password")"; }

# Install the test-only unsafe-mode extension in the VM (lets veval and Shell screenshots
# work). Only for throwaway VMs; takes effect at the next shell start.
vinstall_unsafe_helper() {
    local id=ajar-test-unsafe-mode@localhost
    vrun "mkdir -p ~/.local/share/gnome-shell/extensions/$id && cd ~/.local/share/gnome-shell/extensions/$id &&
      printf '%s' '{\"uuid\":\"$id\",\"name\":\"test-only unsafe mode\",\"description\":\"throwaway test VM only\",\"shell-version\":[\"43\",\"44\",\"45\",\"46\",\"47\",\"48\",\"49\",\"50\"]}' > metadata.json &&
      if [ \$(gnome-shell --version | grep -oE '[0-9]+' | head -1) -ge 45 ]; then
        printf '%s' 'export default class { enable() { global.context.unsafe_mode = true; } disable() { global.context.unsafe_mode = false; } }' > extension.js
      else   # GNOME 43/44: legacy (non-module) extension format
        printf '%s' 'function init() { return { enable() { global.context.unsafe_mode = true; }, disable() { global.context.unsafe_mode = false; } }; }' > extension.js
      fi"
}
venable_extensions() {   # venable_extensions uuid... : add to enabled-extensions (read at shell start)
    local u list
    list="$(vrun 'gsettings get org.gnome.shell enabled-extensions')"
    for u in "$@"; do
        [[ "$list" == *"'$u'"* ]] && continue
        if [[ "$list" == "@as []" || "$list" == "[]" ]]; then list="['$u']"; else list="${list%]}, '$u']"; fi
    done
    vrun "gsettings set org.gnome.shell enabled-extensions \"$list\""
    vrun 'gsettings set org.gnome.shell disable-user-extensions false'
}
vrelogin() {   # the "log out and back in once": restart the display manager (autologin returns)
    vroot 'systemctl restart display-manager'
    sleep 20
}

# Run a command as root through the QEMU guest agent (no network or SSH needed).
# Prints stdout+stderr; returns the command's exit code.
vagent() {
    local cmd="$1" pid st out i
    pid="$(virsh -c qemu:///system qemu-agent-command "$VM" "$(python3 -c 'import json,sys; print(json.dumps({"execute":"guest-exec","arguments":{"path":"/bin/sh","arg":["-c",sys.argv[1]],"capture-output":True}}))' "$cmd")" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"]["pid"])')" || return 1
    for i in $(seq 120); do
        st="$(virsh -c qemu:///system qemu-agent-command "$VM" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}")"
        if python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["return"]["exited"] else 1)' <<<"$st"; then
            out="$(python3 -c 'import json,sys,base64; r=json.load(sys.stdin)["return"]; sys.stdout.write(base64.b64decode(r.get("out-data","")).decode(errors="replace") + base64.b64decode(r.get("err-data","")).decode(errors="replace")); sys.exit(r.get("exitcode",1))' <<<"$st")"
            local rc=$?; printf '%s\n' "$out"; return $rc
        fi
        sleep 0.5
    done
    echo "vagent: timed out" >&2; return 1
}
