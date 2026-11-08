#!/bin/bash
# Record real `sudo -n -l` output for parser tests, inside a throwaway container.
#   tests/fixtures/capture-sudo-l.sh <image> <label>
# Runs only inside a container (`docker run --rm`), never on the host.
set -euo pipefail
image="$1"; label="$2"
out="$(cd "$(dirname "$0")" && pwd)/sudo-l"
mkdir -p "$out"

docker run --rm -i -e LABEL="$label" -v "$out:/out" "$image" bash -s <<'IN_CONTAINER'
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq sudo >/dev/null 2>&1
useradd -m -s /bin/bash -G sudo alice
echo 'alice:pw' | chpasswd
sudo_ver="$(sudo --version | head -1)"

snap() {   # snap <scenario>  -> /out/<label>--<scenario>.txt
    local f="/out/${LABEL}--$1.txt"
    { echo "# $sudo_ver"
      su alice -c 'sudo -n -l' 2>&1; echo "# exit=$?"; } > "$f"
    rm -f /etc/sudoers.d/zz-* ; su alice -c 'sudo -k' 2>/dev/null
}
command -v sudo >/dev/null || { echo "sudo failed to install" >&2; exit 8; }
# A rule this sudo rejects (sudo-rs has no `!authenticate`) is recorded as unsupported, not fatal.
drop(){
    printf '%s\n' "$1" > /etc/sudoers.d/zz-test; chmod 0440 /etc/sudoers.d/zz-test
    visudo -cq >/dev/null 2>&1 && return 0
    rm -f /etc/sudoers.d/zz-test; echo "unsupported: $1"; return 1
}

snap group-only
su alice -c 'echo pw | sudo -S -v' 2>/dev/null
{ echo "# $sudo_ver"; su alice -c 'sudo -n -l' 2>&1; echo "# exit=$?"; } > "/out/${LABEL}--group-cached.txt"
su alice -c 'sudo -k'
drop 'alice ALL=(ALL) NOPASSWD: ALL' &&                       snap full-nopasswd
drop 'alice ALL=(ALL:ALL) NOPASSWD: ALL' &&                   snap full-nopasswd-group
drop 'alice ALL=(root) NOPASSWD: /usr/bin/apt' &&             snap narrow-nopasswd
drop 'alice ALL=(ALL) NOPASSWD: SETENV: ALL' &&               snap tags-setenv
drop 'alice ALL=(ALL) NOPASSWD: /usr/bin/id, PASSWD: ALL' &&  snap mixed-passwd-all
drop 'alice ALL=(nobody) NOPASSWD: ALL' &&                    snap other-runas
drop 'Defaults:alice !authenticate' &&                        snap defaults-noauth

if grep -qi kali /etc/os-release; then
    apt-get install -y -qq kali-grant-root >/dev/null 2>&1
    { echo "### debconf + files of kali-grant-root"
      debconf-show kali-grant-root 2>&1
      ls -la /etc/sudoers.d/; for f in /etc/sudoers.d/*; do echo "--- $f"; cat "$f"; done
      apt-cache show kali-grant-root | grep -E '^(Version|Description)'
      echo "--- reverse depends (who pulls it in)"; apt-cache rdepends kali-grant-root 2>&1 | head -20
    } > "/out/${LABEL}--kali-grant-root-info.txt"
    usermod -aG kali-trusted alice 2>/dev/null; snap kali-trusted
fi
IN_CONTAINER
echo "captured $label -> $out"
