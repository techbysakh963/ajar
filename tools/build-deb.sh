#!/bin/bash
# Build dist/ajar_<version>_all.deb from this checkout. No root needed.
set -euo pipefail
cd "$(dirname "$0")/.."
ver="$(sed -n 's/^readonly VERSION="\(.*\)"/\1/p' bin/ajar)"
uuid=ajar@techbysakh963.github.io
out="dist"; stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
umask 022; chmod 755 "$stage"
mkdir -p "$out"

i() { install -D -m "$1" "$2" "$stage/$3"; }   # i <mode> <src> <dest-in-package>
i 755 bin/ajar                  usr/bin/ajar
i 755 tray/ajar-tray            usr/bin/ajar-tray
i 755 libexec/enable            usr/libexec/ajar/enable
i 755 libexec/disable           usr/libexec/ajar/disable
i 644 polkit/io.github.techbysakh963.ajar.policy usr/share/polkit-1/actions/io.github.techbysakh963.ajar.policy
i 755 share/ajar-ask            usr/share/ajar/ajar-ask
for f in data/icons/hicolor/scalable/*/*.svg; do
    i 644 "$f" "usr/share/icons/hicolor/scalable/$(basename "$(dirname "$f")")/$(basename "$f")"
done
i 644 data/io.github.techbysakh963.Ajar.desktop usr/share/applications/io.github.techbysakh963.Ajar.desktop
i 644 data/ajar-tray.desktop    etc/xdg/autostart/ajar-tray.desktop
for f in extension.js ajarClient.js metadata.json stylesheet.css; do
    i 644 "gnome-extension/$f" "usr/share/gnome-shell/extensions/$uuid/$f"
done
for f in data/icons/hicolor/scalable/status/*.svg; do
    i 644 "$f" "usr/share/gnome-shell/extensions/$uuid/icons/$(basename "$f")"
done
i 644 LICENSE usr/share/doc/ajar/copyright
printf 'ajar (%s) stable; urgency=medium\n\n  * Release %s. See https://github.com/techbysakh963/ajar/releases\n\n -- techbysakh963 <techbysakh@gmail.com>  %s\n' \
    "$ver" "$ver" "$(date -R -d "@${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}")" | gzip -9n > "$stage/usr/share/doc/ajar/changelog.gz"

mkdir -p "$stage/DEBIAN"
cat > "$stage/DEBIAN/control" <<CTRL
Package: ajar
Version: $ver
Architecture: all
Maintainer: techbysakh963 <techbysakh@gmail.com>
Homepage: https://github.com/techbysakh963/ajar
Section: admin
Priority: optional
Depends: sudo | sudo-rs, pkexec | policykit-1, python3, python3-gi, libnotify-bin, libglib2.0-bin, systemd
Recommends: gir1.2-ayatanaappindicator3-0.1, gir1.2-gtk-3.0
Installed-Size: $(du -sk --exclude=DEBIAN "$stage" | cut -f1)
Description: switch passwordless sudo on and off from your desktop
 Ajar turns passwordless sudo on (asking for your password through polkit)
 and off (never asking) from a GNOME Quick Settings toggle, a tray icon for
 Xfce, KDE and other desktops, or the ajar command. An amber door in the
 panel shows while sudo is open, and an optional reminder asks whether to
 turn it off. Every change is logged: journalctl -t ajar
CTRL
echo /etc/xdg/autostart/ajar-tray.desktop > "$stage/DEBIAN/conffiles"
cat > "$stage/DEBIAN/prerm" <<'SH'
#!/bin/sh
# On removal (not upgrade), turn passwordless sudo off for every user Ajar enabled it for.
set -e
case "$1" in
    remove|deconfigure)
        # env -u: Synaptic and `pkexec apt` leak PKEXEC_UID into maintainer scripts, and
        # disable refuses --all when it looks like it was started through pkexec.
        if [ -x /usr/libexec/ajar/disable ] && ! env -u PKEXEC_UID /usr/libexec/ajar/disable --all; then
            echo "ajar: WARNING: could not remove /etc/sudoers.d/90-ajar-*; remove them by hand" >&2
        fi ;;
esac
exit 0
SH
cat > "$stage/DEBIAN/postinst" <<'SH'
#!/bin/sh
set -e
if [ "$1" = configure ] && [ -f /usr/local/share/ajar/MANIFEST ]; then
    echo "ajar: a script install exists in /usr/local; remove it with: sudo bash /usr/local/share/ajar/install.sh --uninstall" >&2
fi
exit 0
SH
chmod 755 "$stage/DEBIAN/prerm" "$stage/DEBIAN/postinst"
find "$stage" -exec touch -h -d "@${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}" {} +
deb="$out/ajar_${ver}_all.deb"
dpkg-deb --root-owner-group -Zxz --build "$stage" "$deb" >/dev/null
echo "$deb"
