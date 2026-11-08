#!/bin/bash
# End-to-end test against the real, installed Ajar. Run as your normal user.
#
# PRECONDITION (manual, on purpose): turn Ajar on yourself first, typing your password:
#     ajar on
# This script never tries to turn passwordless sudo on through polkit. It cannot grant
# anything: every root command below uses `sudo -n`, which only works because you already
# turned Ajar on. Whether turning on is password-gated is asked of polkit with `pkcheck`
# WITHOUT --allow-user-interaction, which returns a verdict and can never show a dialog.
#
# The script ends with passwordless sudo OFF (through the real pkexec disable path).
set -u
AJAR="${AJAR:-ajar}"
H=/usr/libexec/ajar
me="$(id -un)"; uid="$(id -u)"
rule="/etc/sudoers.d/90-ajar-$me"
dummy=/etc/sudoers.d/90-ajar-e2edummy
pass=0; fail=0
ok(){ echo "PASS  $1"; pass=$((pass+1)); }
no(){ echo "FAIL  $1"; fail=$((fail+1)); }
check(){ local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else no "$name"; fi; }
refuse(){ local name="$1"; shift; if "$@" >/dev/null 2>&1; then no "$name"; else ok "$name"; fi; }
state(){ "$AJAR" status --json | sed -E 's/.*"state":"([a-z]+)".*/\1/'; }

if [[ "$(state)" != on ]]; then
    echo "Precondition: run 'ajar on' yourself first (it asks for your password). State is: $(state)"
    exit 2
fi

echo "== 1. state while ON"
check "status says on"                         test "$(state)" = on
check "status json: ours=true"                 bash -c "'$AJAR' status --json | grep -q '\"ours\":true'"
check "rule file exists"                       test -e "$rule"
check "rule file is 0440 root:root"            test "$(stat -c '%a %U %G' "$rule")" = "440 root root"
check "rule file is not readable by user"      bash -c "! cat '$rule' 2>/dev/null"
check "rule content is exactly one grant"      bash -c "sudo -n cat '$rule' | grep -cv '^#' | grep -qx 1"
check "rule names this user only"              bash -c "sudo -n cat '$rule' | grep -qx '$me ALL=(ALL) NOPASSWD: ALL'"
check "whole sudoers config valid (visudo -c)" sudo -n visudo -c
check "no leftover temp files"                 bash -c "! ls -A /etc/sudoers.d | grep -q '^\.ajar'"

echo "== 2. helpers refuse misuse (run as root via sudo -n, so only refusal is possible to prove)"
refuse "enable refuses without PKEXEC_UID"     sudo -n "$H/enable"
refuse "enable refuses PKEXEC_UID=0 (root)"    sudo -n env PKEXEC_UID=0 "$H/enable"
refuse "enable refuses non-numeric uid"        sudo -n env PKEXEC_UID='1000;id' "$H/enable"
refuse "enable refuses arguments"              sudo -n env PKEXEC_UID="$uid" "$H/enable" extra
refuse "enable refuses unknown uid"            sudo -n env PKEXEC_UID=4000000000 "$H/enable"
refuse "disable --all refused under pkexec"    sudo -n env PKEXEC_UID="$uid" "$H/disable" --all
refuse "disable refuses unknown arguments"     sudo -n env PKEXEC_UID="$uid" "$H/disable" /etc/passwd
check  "enable is idempotent for this user"    sudo -n env PKEXEC_UID="$uid" "$H/enable"
check  "  ...still exactly one Ajar grant"     test "$(state)" = on

echo "== 3. disable only touches the caller's file"
sudo -n sh -c "printf '# inert e2e marker, no rules\n' > '$dummy' && chmod 0440 '$dummy'"
check "disable as another uid (nobody) runs"   sudo -n env PKEXEC_UID=65534 "$H/disable"
check "  ...this user's rule untouched"        test -e "$rule"
check "  ...other Ajar file untouched"         test -e "$dummy"
sudo -n rm -f "$dummy"

echo "== 4. polkit verdicts for this session (pkcheck, never interactive)"
pkcheck --action-id io.github.techbysakh963.ajar.enable --process $$ >/dev/null 2>&1; rc=$?
if [[ $rc -eq 2 ]]; then ok "turning ON needs authentication (pkcheck exit 2 = challenge)"
else no "turning ON needs authentication (pkcheck exit $rc, want 2)"; fi
pkcheck --action-id io.github.techbysakh963.ajar.disable --process $$ >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 ]]; then ok "turning OFF is free in this active local session (pkcheck exit 0)"
else no "turning OFF is free in this active local session (pkcheck exit $rc, want 0)"; fi
check "policy: enable auth_admin for any/inactive/active" bash -c \
  "pkaction --action-id io.github.techbysakh963.ajar.enable --verbose | grep -E 'implicit (any|inactive|active):' | grep -vc 'auth_admin$' | grep -qx 0"
check "policy: disable needs auth when remote or inactive" bash -c \
  "pkaction --action-id io.github.techbysakh963.ajar.disable --verbose | grep -E 'implicit (any|inactive):' | grep -vc 'auth_admin$' | grep -qx 0"

echo "== 5. reminder (user timer only; never changes privileges)"
check "ajar remind 10m schedules a timer"      "$AJAR" remind 10m
check "  ...timer is active"                   systemctl --user is-active ajar-reminder.timer
check "  ...status shows the reminder"         bash -c "'$AJAR' status --json | grep -q '\"remind_at\":\"'"
check "ajar remind cancel"                     "$AJAR" remind cancel
refuse "  ...timer gone"                       systemctl --user is-active ajar-reminder.timer
refuse "invalid duration rejected"             "$AJAR" remind 10minutes

echo "== 6. turn OFF through the real pkexec path (no password from the active session)"
check "ajar off succeeds"                      "$AJAR" off
check "state is off"                           test "$(state)" = off
refuse "rule file removed"                     test -e "$rule"
sudo -k 2>/dev/null
refuse "sudo -n now refused (password needed)" sudo -n true
check "journal has the ENABLED/DISABLED log"   bash -c "journalctl -t ajar --since '-10min' --no-pager | grep -q 'DISABLED for $me'"
check "reminder fire is a no-op when off"      "$AJAR" __fire-reminder 1m

echo
echo "Manual (not automated, by design): run 'ajar on' and confirm the password dialog appears,"
echo "then cancel it and check 'ajar status' still says OFF."
echo "---- $pass passed, $fail failed"
exit $((fail > 0))
