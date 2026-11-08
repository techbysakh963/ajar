#!/bin/bash
# The curl | bash path, end to end, in a container, against a local copy of the release:
#   1. good release installs   2. tampered tarball is refused   3. truncated script runs nothing
# Build assets first: tools/make-release.sh
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
img="${1:-debian:12}"; port=8765
engine="$(command -v docker || command -v podman)"
"$engine" run --rm -i -v "$repo/dist:/dist:ro" -e PORT="$port" "$img" bash -s <<'IN'
set -uo pipefail; export DEBIAN_FRONTEND=noninteractive
pass=0; fail=0
ok(){ echo "PASS  $1"; pass=$((pass+1)); }; no(){ echo "FAIL  $1"; fail=$((fail+1)); }
apt-get update -qq >/dev/null; apt-get install -y -qq sudo curl python3 procps >/dev/null 2>&1
groupadd installers; useradd -m -s /bin/bash -G sudo,installers alice
echo '%installers ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/00-installers; chmod 440 /etc/sudoers.d/00-installers
mkdir -p /srv/good /srv/bad /srv/cut
cp /dist/* /srv/good/
cp /dist/* /srv/bad/
tarball=(/srv/bad/ajar-*.tar.gz)           # resolve the glob first; dd's of= would not
before="$(sha256sum "${tarball[0]}")"
printf 'tampered' | dd of="${tarball[0]}" bs=1 seek=2000 conv=notrunc status=none
[[ "$(sha256sum "${tarball[0]}")" != "$before" ]] || { echo "harness: tampering failed"; exit 3; }
cp /dist/* /srv/cut/;  head -c 9000 /dist/install.sh > /srv/cut/install.sh
(cd /srv && python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 &); sleep 1
B="http://127.0.0.1:$PORT"
run(){ su - alice -c "curl -fsSL $B/$1/install.sh | AJAR_RELEASE_BASE=$B/$1 bash -s -- --yes" > "/tmp/$1.log" 2>&1; }

run cut; rc=$?
if [[ ! -e /usr/libexec/ajar && ! -e /usr/local/bin/ajar ]]; then ok "truncated script installs nothing (exit $rc)"; else no "truncated script changed the system"; fi
run bad; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'CHECKSUM MISMATCH' /tmp/bad.log && [[ ! -e /usr/libexec/ajar ]]; then ok "tampered tarball refused, nothing installed"
else no "tampered tarball (exit $rc)"; grep -E 'Checksum|CHECKSUM|Download' /tmp/bad.log; fi
run good; rc=$?
if [[ $rc -eq 0 ]] && grep -q 'Checksum OK' /tmp/good.log && su - alice -c 'ajar status' >/dev/null; then ok "good release: checksum OK, installed, ajar works"
else no "good release (exit $rc)"; tail -20 /tmp/good.log; fi
grep -q 'Proceed' /tmp/good.log && no "asked a question despite --yes" || ok "--yes ran without prompting"
su - alice -c 'curl -fsSL '"$B"'/good/install.sh | AJAR_RELEASE_BASE='"$B"'/good bash' > /tmp/notty.log 2>&1 </dev/null; rc=$?
[[ $rc -ne 0 ]] && grep -q 'with --yes' /tmp/notty.log && ok "no tty and no --yes: refuses, explains" || { no "no-tty behaviour (exit $rc)"; cat /tmp/notty.log; }
echo "---- $pass passed, $fail failed"; exit $((fail > 0))
IN
