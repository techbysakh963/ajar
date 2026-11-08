#!/bin/bash
# Run the `sudo -l` parser against real output recorded on each distro
# (tests/fixtures/sudo-l/<distro>--<scenario>.txt, made by tests/fixtures/capture-sudo-l.sh).
# No root, no system changes.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ajar="$here/../bin/ajar"

# scenario -> expected "passwordless" verdict (1 = sudo runs ALL as root with no password)
declare -A want=(
    [group-only]=0 [group-cached]=0
    [full-nopasswd]=1 [full-nopasswd-group]=1 [tags-setenv]=1 [kali-trusted]=1
    [defaults-noauth]=1
    [narrow-nopasswd]=0 [mixed-passwd-all]=0 [other-runas]=0
)

pass=0 fail=0
for f in "$here"/fixtures/sudo-l/*--*.txt; do
    name="${f##*/}"; scen="${name#*--}"; scen="${scen%.txt}"
    [[ -v "want[$scen]" ]] || continue
    exit_line="$(grep -m1 '^# exit=' "$f")"; code="${exit_line#\# exit=}"
    if [[ "$code" != 0 ]]; then
        got=0     # sudo -n -l failed: a password is required, so passwordless is off
    else
        read -r count noauth < <(grep -v '^# ' "$f" | "$ajar" __parse)
        got=$(( count > 0 || noauth ))
    fi
    if [[ "$got" == "${want[$scen]}" ]]; then pass=$((pass+1))
    else fail=$((fail+1)); echo "FAIL  $name: got $got, want ${want[$scen]}"; fi
done
fixtures=("$here"/fixtures/sudo-l/*--*.txt)
echo "parser: $pass passed, $fail failed (${#fixtures[@]} fixture files)"
(( pass > 0 && fail == 0 ))
