#!/bin/bash
# Distro matrix: run the real installer, helpers, CLI, lockdown and uninstall inside
# throwaway containers. No desktop, so no polkit dialog: the ON path is exercised by calling
# the root helper the way pkexec would (PKEXEC_UID), which is only possible as root inside
# the container. Nothing touches the host.
#
#   tests/matrix.sh                     all images
#   tests/matrix.sh debian:12 ...       chosen images
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
images=("$@")
(( ${#images[@]} )) || images=(debian:12 debian:13 kalilinux/kali-rolling ubuntu:24.04 ubuntu:26.04)
engine="$(command -v docker || command -v podman)"
overall=0

for img in "${images[@]}"; do
    echo "=================== $img"
    "$engine" run --rm -i -v "$repo:/src:ro" "$img" bash -s <<'IN' || overall=1
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
pass=0; fail=0
ok(){ echo "PASS  $1"; pass=$((pass+1)); }
no(){ echo "FAIL  $1"; fail=$((fail+1)); }
t(){ local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else no "$n"; fi; }
f(){ local n="$1"; shift; if "$@" >/dev/null 2>&1; then no "$n"; else ok "$n"; fi; }

apt-get update -qq >/dev/null && apt-get install -y -qq sudo procps >/dev/null 2>&1
. /etc/os-release; echo "distro: $PRETTY_NAME, $(sudo --version | head -1)"
groupadd -f installers
useradd -m -s /bin/bash -G sudo,installers alice
echo 'alice:correct-horse' | chpasswd          # lockdown requires a usable password
useradd -m -s /bin/bash bob                   # no password, no admin group: lockdown must not touch him
echo 'bob ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/91-bob; chmod 440 /etc/sudoers.d/91-bob
useradd -m -s /bin/bash -G sudo al.ice        # name with a dot: must not match "alXice" style regexes
echo 'alXice ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/92-alxice; chmod 440 /etc/sudoers.d/92-alxice
useradd -m -s /bin/bash carol                 # no sudo rights at all
# install-time sudo via a GROUP rule: lockdown reports group rules but never edits them
echo '%installers ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/00-installers; chmod 440 /etc/sudoers.d/00-installers
# a per-user grant for lockdown to remove (cloud-init writes exactly this shape)
echo 'alice ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-cloud-init-users; chmod 440 /etc/sudoers.d/90-cloud-init-users
if grep -qi kali /etc/os-release; then
    apt-get install -y -qq kali-grant-root >/dev/null 2>&1 && usermod -aG kali-trusted alice
fi
cp -r /src /home/alice/ajar && chown -R alice: /home/alice/ajar
A(){ su - alice -c "cd ~/ajar && $*"; }

echo "== install (non-interactive, with lockdown)"
A './install.sh --yes --lockdown' > /tmp/install.log 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "install.sh --yes --lockdown exits 0" || { no "install.sh exit $rc"; tail -25 /tmp/install.log; }
t "pkexec available"                 command -v pkexec
t "helpers root-owned 0755"          test "$(stat -c '%a %U' /usr/libexec/ajar/enable /usr/libexec/ajar/disable | sort -u)" = "755 root"
t "policy installed"                 test -f /usr/share/polkit-1/actions/io.github.techbysakh963.ajar.policy
t "policy is valid XML"              python3 -c 'import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])' /usr/share/polkit-1/actions/io.github.techbysakh963.ajar.policy
t "ajar on PATH for alice"           A 'command -v ajar'
t "manifest written"                 test -s /usr/local/share/ajar/MANIFEST
t "lockdown: cloud-init line commented" grep -q '^# disabled by ajar --lockdown: alice' /etc/sudoers.d/90-cloud-init-users
t "lockdown: backup kept"            bash -c 'ls /etc/sudoers.d/ | grep -q "90-cloud-init-users.ajar-backup"'
f "lockdown: group rule untouched"   grep -q '^#' /etc/sudoers.d/00-installers
t "sudoers still valid"              visudo -c
t "lockdown left no temp copies"     bash -c '! ls -A /etc/sudoers.d /etc | grep -q "^\.ajar-lockdown"'
f "lockdown: other users untouched"  grep -q '^#' /etc/sudoers.d/91-bob
if grep -qi kali /etc/os-release; then
    f "lockdown: alice left kali-trusted" bash -c 'id -nG alice | tr " " "\n" | grep -qx kali-trusted'
fi

echo "== lockdown guards"
cp -r /src /home/bob/ajar && chown -R bob: /home/bob/ajar
echo 'bob ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/91-bob; chmod 440 /etc/sudoers.d/91-bob
su - bob -c 'cd ~/ajar && ./install.sh --dry-run --lockdown' > /tmp/bob.log 2>&1
t "no usable password: lockdown is report-only" grep -q 'Report only' /tmp/bob.log
f "  ...and plans no change to 91-bob"          grep -q 'will comment out' /tmp/bob.log
echo 'al.ice:pw' | chpasswd; usermod -aG installers al.ice
cp -r /src /home/al.ice/ajar && chown -R al.ice: /home/al.ice/ajar
su - al.ice -c 'cd ~/ajar && ./install.sh --dry-run --lockdown' > /tmp/alice-dot.log 2>&1
f "dotted user name does not match alXice"      grep -A1 '92-alxice' /tmp/alice-dot.log | grep -q 'will comment out'

echo "== state machine on this distro's sudo"
# alice still has the group grant, so turn it into a password-only setup for the state checks
rm -f /etc/sudoers.d/00-installers
t "status: off"                      bash -c "su - alice -c 'ajar status --json' | grep -q '\"state\":\"off\"'"
t "enable helper (as pkexec would)"  env PKEXEC_UID="$(id -u alice)" /usr/libexec/ajar/enable
t "status: on, ours"                 bash -c "su - alice -c 'ajar status --json' | grep -q '\"state\":\"on\",\"ours\":true,\"external\":false'"
t "rule is 0440 root"                test "$(stat -c '%a %U' /etc/sudoers.d/90-ajar-alice)" = "440 root"
t "alice really has passwordless sudo" su - alice -c 'sudo -n true'
echo 'alice ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/50-extra; chmod 440 /etc/sudoers.d/50-extra
t "status: on + external flag"       bash -c "su - alice -c 'ajar status --json' | grep -q '\"external\":true'"
t "disable helper (as pkexec would)" env PKEXEC_UID="$(id -u alice)" /usr/libexec/ajar/disable
t "status: external (other rule)"    bash -c "su - alice -c 'ajar status --json' | grep -q '\"state\":\"external\"'"
rm -f /etc/sudoers.d/50-extra
t "status: off again"                bash -c "su - alice -c 'ajar status --json' | grep -q '\"state\":\"off\"'"
f "alice needs a password again"     su - alice -c 'sudo -n true'
f "enable refuses without pkexec"    /usr/libexec/ajar/enable
f "enable refuses root"              env PKEXEC_UID=0 /usr/libexec/ajar/enable
f "enable refuses a user without sudo rights (carol)" env PKEXEC_UID="$(id -u carol)" /usr/libexec/ajar/enable
f "  ...and wrote nothing for carol"  test -e /etc/sudoers.d/90-ajar-carol
t "doctor runs"                      bash -c "su - alice -c 'ajar doctor' | grep -q 'sudo:'"

echo "== uninstall"
env PKEXEC_UID="$(id -u alice)" /usr/libexec/ajar/enable   # leave a rule behind on purpose
bash /usr/local/share/ajar/install.sh --uninstall --yes > /tmp/uninstall.log 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "uninstall exits 0" || { no "uninstall exit $rc"; tail -15 /tmp/uninstall.log; }
f "rule removed by uninstall"        test -e /etc/sudoers.d/90-ajar-alice
left="$(find / -xdev \( -name '*ajar*' -o -name 'io.github.techbysakh963*' \) -not -path '/home/*' -not -path '/proc/*' -not -path '/src/*' -not -name '*.ajar-backup-*' 2>/dev/null)"
[[ -z "$left" ]] && ok "nothing left behind" || { no "files left behind"; echo "$left"; }
echo "---- $pass passed, $fail failed"
exit $((fail > 0))
IN
done
exit $overall
