#!/bin/bash
# Build release assets into dist/: source tarball, install.sh with the tarball's SHA-256
# embedded, the .deb, and SHA256SUMS. Builds from the committed tree (git archive), so
# uncommitted changes never end up in a release.
set -euo pipefail
cd "$(dirname "$0")/.."
ver="$(sed -n 's/^readonly VERSION="\(.*\)"/\1/p' bin/ajar)"
[[ -z "$(git status --porcelain -- bin libexec polkit share tray gnome-extension data install.sh)" ]] \
    || { echo "uncommitted changes in shipped files; commit first" >&2; exit 1; }
mkdir -p dist
export SOURCE_DATE_EPOCH; SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"
tar_name="ajar-$ver.tar.gz"
git archive --format=tar --prefix="ajar-$ver/" HEAD | gzip -9n > "dist/$tar_name"
sum="$(sha256sum "dist/$tar_name" | cut -d' ' -f1)"
sed -e "s/@VERSION@/$ver/" -e "s/@SHA256@/$sum/" install.sh > dist/install.sh
chmod 755 dist/install.sh
grep -q "AJAR_TARBALL_SHA256=\"$sum\"" dist/install.sh || { echo "embedding failed" >&2; exit 1; }
tools/build-deb.sh >/dev/null
(cd dist && sha256sum "$tar_name" install.sh "ajar_${ver}_all.deb" > SHA256SUMS)
echo "release $ver assets:"; (cd dist && ls -l "$tar_name" install.sh "ajar_${ver}_all.deb" SHA256SUMS && cat SHA256SUMS)
