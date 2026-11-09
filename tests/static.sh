#!/bin/bash
# Static checks that need no root and no desktop: shellcheck on every shell script,
# no function defined twice in one script (a later definition silently shadows the first),
# Python and JS syntax, JSON metadata.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
shell_files=(install.sh tools/*.sh bin/ajar libexec/enable libexec/disable tests/*.sh tests/fixtures/*.sh)
shellcheck -x "${shell_files[@]}" || fail=1
for f in "${shell_files[@]}"; do
    dups="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$f" | sort | uniq -d)"
    [[ -z "$dups" ]] || { echo "FAIL  $f defines twice: $dups"; fail=1; }
done
for f in tray/ajar-tray share/ajar-ask; do
    python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f" || fail=1
done
for f in gnome-extension/*.js tests/*.js; do node --check "$f" || fail=1; done
python3 -m json.tool gnome-extension/metadata.json >/dev/null || fail=1
# every published version string must match bin/ajar (links break silently otherwise)
ver="$(sed -n 's/^readonly VERSION="\(.*\)"/\1/p' bin/ajar)"
for f in README.md site/index.html gnome-extension/metadata.json; do
    stale="$(grep -noE '(v|ajar_|version-name": "|softwareVersion":"|Ajar )[0-9]+\.[0-9]+\.[0-9]+' "$f" | grep -v "$ver" || true)"
    [[ -z "$stale" ]] || { echo "FAIL  $f mentions a version other than $ver:"; echo "$stale"; fail=1; }
done
[[ $fail -eq 0 ]] && echo "static: all checks passed" || echo "static: FAILED"
exit $fail
