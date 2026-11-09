#!/bin/bash
# Build the extensions.gnome.org upload: dist/ajar@techbysakh963.github.io.shell-extension.zip
# Only what the extension uses: JS, metadata, stylesheet and its three status icons.
set -euo pipefail
cd "$(dirname "$0")/.."
uuid=ajar@techbysakh963.github.io
src="$(mktemp -d)"; trap 'rm -rf "$src"' EXIT
cp gnome-extension/extension.js gnome-extension/ajarClient.js gnome-extension/metadata.json gnome-extension/stylesheet.css "$src/"
mkdir -p "$src/icons"
for i in closed open external; do cp "data/icons/hicolor/scalable/status/ajar-$i-symbolic.svg" "$src/icons/"; done
mkdir -p dist
gnome-extensions pack --force --out-dir=dist --extra-source=ajarClient.js --extra-source=icons "$src"
unzip -l "dist/$uuid.shell-extension.zip"
