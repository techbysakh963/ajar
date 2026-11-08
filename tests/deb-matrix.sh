#!/bin/bash
# Install dist/ajar_*.deb with apt in throwaway containers; check deps, files, the helpers,
# and that removal turns passwordless sudo off and purge leaves nothing. Build it first:
#   tools/build-deb.sh && tests/deb-matrix.sh [image...]
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
deb="$(find "$repo/dist" -name "ajar_*_all.deb" 2>/dev/null | sort | tail -1)"
[[ -f "$deb" ]] || { echo "build the .deb first: tools/build-deb.sh"; exit 2; }
images=("$@"); (( ${#images[@]} )) || images=(debian:12 debian:13 kalilinux/kali-rolling ubuntu:24.04 ubuntu:26.04)
engine="$(command -v docker || command -v podman)"; overall=0
for img in "${images[@]}"; do
    echo "=================== $img"
    "$engine" run --rm -i -v "$deb:/tmp/ajar.deb:ro" "$img" bash -s <<'IN' || overall=1
set -uo pipefail; export DEBIAN_FRONTEND=noninteractive
pass=0; fail=0
t(){ local n="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PASS  $n"; pass=$((pass+1)); else echo "FAIL  $n"; fail=$((fail+1)); fi; }
apt-get update -qq >/dev/null
cp /tmp/ajar.deb /root/ajar.deb   # apt's _apt user must be able to read it
t "apt install ./ajar.deb (deps resolve)" apt-get install -y -qq /root/ajar.deb
. /etc/os-release; echo "distro: $PRETTY_NAME, $(sudo --version | head -1), pkexec: $(command -v pkexec)"
useradd -m -s /bin/bash -G sudo alice
t "dpkg reports installed"          dpkg-query -W -f='${Status}' ajar
t "ajar status works"               su - alice -c 'ajar status --json'
t "enable helper (as pkexec would)" env PKEXEC_UID="$(id -u alice)" /usr/libexec/ajar/enable
t "alice has passwordless sudo"     su - alice -c 'sudo -n true'
t "apt remove ajar"                 apt-get remove -y -qq ajar
t "removal turned it off"           bash -c '! test -e /etc/sudoers.d/90-ajar-alice'
t "apt purge ajar"                  apt-get purge -y -qq ajar
left="$(find / -xdev \( -name '*ajar*' -o -name 'io.github.techbysakh963*' \) -not -path '/proc/*' -not -path '/root/ajar.deb' -not -path '/tmp/ajar.deb' -not -path '/var/lib/dpkg/*' -not -path '/var/cache/*' 2>/dev/null)"
if [[ -z "$left" ]]; then echo "PASS  nothing left after purge"; pass=$((pass+1)); else echo "FAIL  left: $left"; fail=$((fail+1)); fi
echo "---- $pass passed, $fail failed"; exit $((fail > 0))
IN
done
exit $overall
