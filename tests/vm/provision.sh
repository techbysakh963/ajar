#!/bin/bash
# Build a throwaway desktop VM from an official cloud image, for testing Ajar on a real
# desktop and taking real screenshots. Uses libvirt (qemu:///system). Nothing in the base
# image is modified: each VM gets a thin qcow2 overlay.
#
#   tests/vm/provision.sh <name> <base-image> <desktop>
#     desktop: gnome | xfce | gnome43-tray
#   e.g. tests/vm/provision.sh ajar-debian13 ~/ajar-vms/debian-13.qcow2 gnome
#
# The VM gets user "demo" (throwaway password in $VMDIR/password, sudo group), your SSH key
# from $VMDIR/id_ed25519.pub, autologin into the desktop, and qemu-guest-agent.
set -euo pipefail
name="$1"; base="$2"; desktop="$3"
VMDIR="${VMDIR:-$HOME/ajar-vms}"
disk="$VMDIR/$name.qcow2"
[[ -f "$VMDIR/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C ajar-vm -f "$VMDIR/id_ed25519"
[[ -f "$VMDIR/password" ]] || { head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12 > "$VMDIR/password"; chmod 600 "$VMDIR/password"; }
pw="$(cat "$VMDIR/password")"
hash="$(python3 -c 'import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))' "$pw" 2>/dev/null \
        || openssl passwd -6 "$pw")"

case "$desktop" in
    gnome)
        if grep -qi ubuntu <<<"$base"; then pkgs="ubuntu-desktop-minimal"; dm=gdm3
        else pkgs="task-gnome-desktop"; dm=gdm3; fi ;;
    gnome43-tray) pkgs="task-gnome-desktop gnome-shell-extension-appindicator"; dm=gdm3 ;;
    xfce) pkgs="task-xfce-desktop"; dm=lightdm ;;
    *) echo "desktop must be gnome, xfce or gnome43-tray" >&2; exit 2 ;;
esac

if [[ "$dm" == gdm3 ]]; then
    autologin='printf "[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=demo\nWaylandEnable=true\n" > /etc/gdm3/daemon.conf'
    grep -qi ubuntu <<<"$base" && autologin="${autologin//\/etc\/gdm3\/daemon.conf//etc/gdm3/custom.conf}"
else
    autologin='mkdir -p /etc/lightdm/lightdm.conf.d && printf "[Seat:*]\nautologin-user=demo\nautologin-user-timeout=0\n" > /etc/lightdm/lightdm.conf.d/50-autologin.conf'
fi

ud="$VMDIR/$name-user-data"
cat > "$ud" <<EOF
#cloud-config
hostname: $name
users:
  - name: demo
    gecos: Demo User
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: false
    passwd: '$hash'
    ssh_authorized_keys: ['$(cat "$VMDIR/id_ed25519.pub")']
ssh_pwauth: false
package_update: true
packages: [qemu-guest-agent, spice-vdagent]
runcmd:
  - [sh, -c, 'rm -f /etc/sudoers.d/90-cloud-init-users']
  - [sh, -c, 'DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/var/log/desktop-install.log 2>&1']
  - [sh, -c, '$autologin']
  - [systemctl, set-default, graphical.target]
  - [sh, -c, 'touch /var/lib/ajar-vm-ready']
  - [reboot]
EOF

# Our own NoCloud seed (volume label "cidata"). Not virt-install --cloud-init: with --wait 0
# virt-install exits at once and deletes its temporary seed before the guest can read it.
seed="$VMDIR/$name-seed.iso"; sd="$(mktemp -d)"
cp "$ud" "$sd/user-data"; printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$name" "$(date +%s)" "$name" > "$sd/meta-data"
xorriso -as mkisofs -quiet -o "$seed" -V cidata -J -r "$sd/user-data" "$sd/meta-data"
rm -rf "$sd"

qemu-img create -q -f qcow2 -F qcow2 -b "$(readlink -f "$base")" "$disk" 24G
virt-install --connect qemu:///system --name "$name" --memory 4096 --vcpus 2 \
    --disk "path=$disk,format=qcow2" --disk "path=$seed,device=cdrom" \
    --import --os-variant detect=on,require=off \
    --network network=default --graphics spice --video virtio --channel spicevmc \
    --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
    --noautoconsole --wait 0
echo "$name: provisioning (desktop install takes 5-15 min). Password: $VMDIR/password"
