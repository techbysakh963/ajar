#!/bin/bash
# Ajar installer.  https://github.com/techbysakh963/ajar
#
#   curl -fsSL https://github.com/techbysakh963/ajar/releases/download/vX.Y.Z/install.sh | bash
#   ./install.sh                  from a source checkout
#
# Options:
#   --dry-run       show what would change, change nothing
#   --yes           do not ask for confirmation (non-interactive)
#   --lockdown      also remove OTHER passwordless-sudo grants for your user (shown first)
#   --no-deps       do not install missing packages with apt
#   --uninstall     remove everything a previous run installed (uses its manifest)
#
# Safety: the whole script is one function called on the last line, so a truncated
# download runs nothing. Every change is listed before it happens. A release download is
# checked against the SHA-256 embedded in this script for that exact version.
set -euo pipefail

main() {
    # Filled in by tools/make-release.sh for release copies of this script.
    local AJAR_VERSION="@VERSION@" AJAR_TARBALL_SHA256="@SHA256@"
    local REPO="techbysakh963/ajar"
    local UUID="ajar@techbysakh963.github.io"
    local PREFIX="/usr/local"
    local LIBEXEC="/usr/libexec/ajar"                 # fixed: the polkit policy names it
    local POLICY_DIR="/usr/share/polkit-1/actions"
    local MANIFEST="$PREFIX/share/ajar/MANIFEST"

    local dry=0 yes=0 lockdown=0 deps=1 mode=install
    for a in "$@"; do
        case "$a" in
            --dry-run) dry=1 ;;
            --yes|-y) yes=1 ;;
            --lockdown) lockdown=1 ;;
            --no-deps) deps=0 ;;
            --uninstall) mode=uninstall ;;
            -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || echo "see https://github.com/$REPO"; return 0 ;;
            *) echo "install.sh: unknown option '$a'" >&2; return 2 ;;
        esac
    done

    # ---- who and where -------------------------------------------------------------
    local SUDO="" user
    if [[ $EUID -eq 0 ]]; then
        user="${SUDO_USER:-}"
    else
        user="$(id -un)"
        command -v sudo >/dev/null || die_no_sudo
        SUDO="sudo"
    fi
    [[ -z "$user" || "$user" == root ]] && user=""

    say()  { printf '%s\n' "$*"; }
    head1(){ printf '\n\e[1m%s\e[0m\n' "$*"; }
    warn() { printf '  ! %s\n' "$*"; }
    run()  { if (( dry )); then printf '  (dry-run) %s\n' "$*"; else "$@"; fi; }
    root() { run $SUDO "$@"; }

    if [[ "$mode" == uninstall ]]; then uninstall; return; fi

    # ---- source: a checkout next to this script, or a verified release download ----------
    local src="" tmp=""
    local self="${BASH_SOURCE[0]:-}"
    # Only an unbuilt (development) copy may install from a local checkout. A release copy
    # always downloads and verifies, even when run from a directory that contains bin/ajar.
    # (The placeholder is split so the release build's substitution cannot rewrite this test.)
    if [[ "$AJAR_VERSION" == "@VER""SION@" && -n "$self" && -f "$(dirname "$self")/bin/ajar" ]]; then
        src="$(cd "$(dirname "$self")" && pwd)"
        AJAR_VERSION="$(sed -n 's/^readonly VERSION="\(.*\)"/\1/p' "$src/bin/ajar")"
    else
        fetch_release
    fi

    # ---- inspect the system ---------------------------------------------------------
    # shellcheck source=/dev/null
    . /etc/os-release 2>/dev/null || true
    local distro="${PRETTY_NAME:-unknown}"
    local gnome_ver=0
    command -v gnome-shell >/dev/null && gnome_ver="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1)"
    local want_ext=0 want_tray=1
    (( gnome_ver >= 45 && gnome_ver <= 50 )) && want_ext=1

    command -v apt-get >/dev/null || { warn "this installer supports Debian, Ubuntu and Kali (apt)."; return 1; }
    if command -v dpkg-query >/dev/null && dpkg-query -W -f='${Status}' ajar 2>/dev/null | grep -q installed; then
        say "The ajar .deb package is installed; update it with apt instead of this script."; return 1
    fi

    local pkgs=()
    command -v pkexec >/dev/null || pkgs+=("$(pkg_for_pkexec)")
    command -v notify-send >/dev/null || pkgs+=(libnotify-bin)
    python3 -c 'import gi' 2>/dev/null || pkgs+=(python3-gi)
    if (( want_tray )); then
        python3 -c 'import gi; gi.require_version("AyatanaAppIndicator3","0.1")' 2>/dev/null \
            || pkgs+=(gir1.2-ayatanaappindicator3-0.1)
        python3 -c 'import gi; gi.require_version("Gtk","3.0")' 2>/dev/null || pkgs+=(gir1.2-gtk-3.0)
    fi

    # ---- the plan -------------------------------------------------------------------
    head1 "Ajar $AJAR_VERSION installer on $distro"
    say "Source: ${src}"
    head1 "These changes will be made:"
    if (( ${#pkgs[@]} )); then
        if (( deps )); then say "  apt install: ${pkgs[*]}"
        else warn "missing packages (not installing, --no-deps): ${pkgs[*]}"; fi
    fi
    say "  $LIBEXEC/enable, disable           root helpers (the only code that runs as root)"
    say "  $POLICY_DIR/io.github.techbysakh963.ajar.policy"
    say "  $PREFIX/bin/ajar, ajar-tray            command line and tray icon"
    say "  $PREFIX/share/ajar/                    notification helper, uninstaller, manifest"
    say "  $PREFIX/share/icons, applications      icons and desktop entry"
    say "  /etc/xdg/autostart/ajar-tray.desktop   tray icon at login (steps aside on GNOME 45+)"
    (( want_ext )) && say "  $PREFIX/share/gnome-shell/extensions/$UUID   Quick Settings toggle (GNOME $gnome_ver)"
    (( want_ext )) && [[ -n "$user" ]] && say "  enable the toggle for $user (takes effect at next login)"
    say "Nothing in /etc/sudoers.d changes now; that only happens when you run 'ajar on'."

    local legacy=()
    [[ -e /etc/sudoers.d/90-sudo-gate ]] && legacy+=("/etc/sudoers.d/90-sudo-gate (old Sudo Gate rule)")
    [[ -e /usr/share/polkit-1/actions/org.sudogate.policy ]] && legacy+=("/usr/share/polkit-1/actions/org.sudogate.policy")
    [[ -d /usr/libexec/sudo-gate ]] && legacy+=("/usr/libexec/sudo-gate/")
    if (( ${#legacy[@]} )); then
        say "  remove the Sudo Gate prototype:"; printf '    - %s\n' "${legacy[@]}"
    fi

    local lock_actions=(); declare -A LOCK_TEXT=()
    if (( lockdown )) && [[ -n "$user" ]]; then
        find_other_grants
    fi
    report_environment

    if (( dry )); then head1 "Dry run: nothing was changed."; return 0; fi
    confirm || { say "Cancelled. Nothing was changed."; return 1; }

    # ---- do it ------------------------------------------------------------------------
    if (( deps && ${#pkgs[@]} )); then
        root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
    fi
    local files=()
    put 755 "$src/libexec/enable"  "$LIBEXEC/enable"
    put 755 "$src/libexec/disable" "$LIBEXEC/disable"
    put 644 "$src/polkit/io.github.techbysakh963.ajar.policy" "$POLICY_DIR/io.github.techbysakh963.ajar.policy"
    put 755 "$src/bin/ajar"        "$PREFIX/bin/ajar"
    put 755 "$src/tray/ajar-tray"  "$PREFIX/bin/ajar-tray"
    put 755 "$src/share/ajar-ask"  "$PREFIX/share/ajar/ajar-ask"
    put 755 "$src/install.sh"      "$PREFIX/share/ajar/install.sh"
    local f
    for f in "$src"/data/icons/hicolor/scalable/*/*.svg; do
        put 644 "$f" "$PREFIX/share/icons/hicolor/scalable/$(basename "$(dirname "$f")")/$(basename "$f")"
    done
    put 644 "$src/data/io.github.techbysakh963.Ajar.desktop" "$PREFIX/share/applications/io.github.techbysakh963.Ajar.desktop"
    put 644 "$src/data/ajar-tray.desktop" "/etc/xdg/autostart/ajar-tray.desktop"
    if (( want_ext )); then
        for f in extension.js ajarClient.js metadata.json stylesheet.css; do
            put 644 "$src/gnome-extension/$f" "$PREFIX/share/gnome-shell/extensions/$UUID/$f"
        done
        for f in "$src"/data/icons/hicolor/scalable/status/*.svg; do
            put 644 "$f" "$PREFIX/share/gnome-shell/extensions/$UUID/icons/$(basename "$f")"
        done
    fi
    # manifest: exactly what we wrote, so uninstall removes exactly that
    printf '%s\n' "${files[@]}" "$MANIFEST" | $SUDO tee "$MANIFEST.tmp" >/dev/null
    root mv -f "$MANIFEST.tmp" "$MANIFEST"
    if command -v gtk-update-icon-cache >/dev/null; then
        root gtk-update-icon-cache -qtf "$PREFIX/share/icons/hicolor" 2>/dev/null || true
    fi

    remove_legacy
    (( ${#lock_actions[@]} )) && apply_lockdown

    if (( want_ext )) && [[ -n "$user" ]]; then enable_extension_for "$user"; fi

    head1 "Done."
    say "  ajar status      show the real state"
    say "  ajar on          turn on (asks for your password)"
    say "  ajar doctor      check this system"
    say "  journalctl -t ajar   see every change"
    if (( want_ext )); then
        say ""
        say "GNOME on Wayland cannot load a new extension into a running session:"
        say "log out and back in once, then find 'Sudo' in Quick Settings."
    else
        say ""; say "The tray icon starts at your next login, or now with: ajar-tray &"
    fi
    say "Uninstall any time with: ajar uninstall"
}

# ---------------------------------------------------------------------------- helpers

die_no_sudo() {
    cat >&2 <<'EOF'
sudo is not installed. Ajar switches sudo's password prompt, so it needs sudo.
On Debian installed with a root password, as root:
    apt install sudo && usermod -aG sudo <your user>
then log out and back in, and run this installer again.
EOF
    exit 1
}

pkg_for_pkexec() {   # Debian 12+/Ubuntu 24.04+ split pkexec out of policykit-1
    if apt-cache show pkexec >/dev/null 2>&1; then echo pkexec; else echo policykit-1; fi
}

fetch_release() {
    [[ "$AJAR_VERSION" != @* && "$AJAR_TARBALL_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
        echo "This copy of install.sh is not a release build; run it from a source checkout," >&2
        echo "or download install.sh from https://github.com/$REPO/releases" >&2
        exit 1; }
    command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand now: the trap fires after main's locals are gone
    trap "rm -rf '$tmp'" EXIT
    # AJAR_RELEASE_BASE only exists for testing against a local mirror; the embedded
    # checksum still has to match, so it cannot be used to install something else.
    local base="${AJAR_RELEASE_BASE:-https://github.com/$REPO/releases/download/v$AJAR_VERSION}"
    local url="$base/ajar-$AJAR_VERSION.tar.gz" proto="=https"
    [[ "$base" == http://127.0.0.1:* ]] && proto="=http"
    say "Downloading $url"
    curl -fsSL --proto "$proto" --tlsv1.2 -o "$tmp/ajar.tar.gz" "$url"
    local got; got="$(sha256sum "$tmp/ajar.tar.gz" | cut -d' ' -f1)"
    if [[ "$got" != "$AJAR_TARBALL_SHA256" ]]; then
        echo "CHECKSUM MISMATCH: expected $AJAR_TARBALL_SHA256, got $got. Nothing was installed." >&2
        exit 1
    fi
    say "Checksum OK (sha256 $got)"
    tar -xzf "$tmp/ajar.tar.gz" -C "$tmp" --no-same-owner
    src="$tmp/ajar-$AJAR_VERSION"
    [[ -f "$src/bin/ajar" ]] || { echo "unexpected archive layout" >&2; exit 1; }
}

put() {   # put <mode> <src> <dest>: install as root:root and record in the manifest
    root install -D -m "$1" -o root -g root "$2" "$3"
    files+=("$3")
}

confirm() {
    (( yes )) && return 0
    local reply=""
    # -r /dev/tty can be true with no controlling terminal (cron, ssh -T); try to open it.
    if { exec 3<>/dev/tty; } 2>/dev/null; then
        printf '\nProceed? [y/N] ' >&3
        read -r reply <&3 || true
        exec 3>&-
    else
        echo "No terminal to ask on; re-run with --yes to proceed non-interactively." >&2
        return 1
    fi
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

report_environment() {
    head1 "Checks:"
    if [[ -n "$user" ]] && ! id -nG "$user" | tr ' ' '\n' | grep -qxE 'sudo|admin|wheel'; then
        warn "$user is not in the sudo group: turning Ajar on will ask for the ROOT password."
    else say "  ok  admin group membership"; fi
    if pgrep -l '^(gnome-shell|polkit-gnome-au|polkit-kde-auth|polkit-mate-aut|lxpolkit|lxqt-policykit|xfce-polkit|mate-polkit|cinnamon)$' >/dev/null; then
        say "  ok  polkit authentication agent"
    elif [[ -n "${XDG_CURRENT_DESKTOP:-}" ]]; then
        warn "no graphical polkit agent is running: the tray cannot show a password dialog."
        warn "  Install one, e.g.: sudo apt install mate-polkit  (Xfce, LXDE and others)"
    else say "  --  polkit agent not checked (no desktop session here, e.g. SSH)"; fi
    if (( gnome_ver > 0 && gnome_ver < 45 )); then
        warn "GNOME $gnome_ver is older than 45: you get the tray icon, not the Quick Settings toggle."
        warn "  GNOME needs an AppIndicator extension to show tray icons (gnome-shell-extension-appindicator)."
    fi
}

# Other rules that give $user passwordless sudo. Only exact per-user "NOPASSWD: ALL" lines
# and Kali's kali-trusted group are changed; anything else is reported, never edited.
find_other_grants() {
    head1 "Lockdown: other passwordless-sudo grants for $user"
    local found=0 line file can_lock=1 why=""
    # Never take away the only way to root: removing a grant is only offered when the user
    # can still use sudo with a password afterwards.
    if ! id -nG "$user" | tr ' ' '\n' | grep -qxE 'sudo|admin|wheel'; then
        can_lock=0; why="$user is not in an admin group (sudo/admin/wheel)"
    elif [[ "$($SUDO passwd -S "$user" 2>/dev/null | awk '{print $2}')" != P ]]; then
        can_lock=0; why="$user has no usable password (locked or empty), so sudo with a password would be impossible"
    fi
    (( can_lock )) || say "  Report only: $why. Removing a grant could lock you out of root."
    if getent group kali-trusted >/dev/null && id -nG "$user" | tr ' ' '\n' | grep -qx kali-trusted; then
        say "  - $user is in group kali-trusted (Kali: %kali-trusted ALL=(ALL:ALL) NOPASSWD: ALL)"
        if (( can_lock )); then
            say "      will run: gpasswd -d $user kali-trusted   (takes effect at next login)"
            lock_actions+=("group:kali-trusted")
        fi
        found=1
    fi
    local ure; ure="$(printf '%s' "$user" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"
    while IFS= read -r line; do
        file="${line%%:*}"; [[ "$file" == */90-ajar-* || "$file" == */90-sudo-gate ]] && continue
        local rest lineno text
        rest="${line#*:}"; lineno="${rest%%:*}"; text="${rest#*:}"
        [[ "$text" =~ ^[[:space:]]*%kali-trusted[[:space:]] ]] && continue   # handled by the group step
        say "  - $file:$lineno: $text"
        if (( can_lock )) && [[ "$text" =~ ^[[:space:]]*${ure}[[:space:]]+ALL[[:space:]]*=[[:space:]]*\(ALL(:ALL)?\)[[:space:]]+NOPASSWD:[[:space:]]*ALL[[:space:]]*$ ]]; then
            say "      will comment out this line (backup kept; edited copy checked with visudo first)"
            lock_actions+=("line:$file:$lineno"); LOCK_TEXT["$file:$lineno"]="$text"
        else
            say "      reported only: edit it yourself if you want it gone"
        fi
        found=1
    # the glob must expand as root: /etc/sudoers.d may not be readable by the user
    done < <($SUDO sh -c 'grep -nHE "^[[:space:]]*[^#].*NOPASSWD|!authenticate" /etc/sudoers /etc/sudoers.d/* 2>/dev/null' \
             | awk -v u="$user" -v groups=" $(id -nG "$user") " -F: '{
                   split($0, p, ":"); rest = substr($0, length(p[1]) + length(p[2]) + 3)
                   n = split(rest, w, /[ \t]+/); who = (w[1] == "" ? w[2] : w[1])
                   if (who == u || who == "ALL" || (who ~ /^%/ && index(groups, " " substr(who, 2) " "))) print }' || true)
    (( found )) || say "  none found"
}

apply_lockdown() {
    head1 "Lockdown"
    local a file lineno cur tmpf bak
    for a in "${lock_actions[@]}"; do
        case "$a" in
            group:kali-trusted) root gpasswd -d "$user" kali-trusted ;;
            line:*)
                IFS=: read -r _ file lineno <<<"$a"
                # the file may have changed since the plan was shown: re-check the exact line
                cur="$($SUDO sed -n "${lineno}p" "$file")"
                if [[ "$cur" != "${LOCK_TEXT[$file:$lineno]}" ]]; then
                    warn "$file changed since the scan; left it alone"; continue
                fi
                # edit a dotted copy (sudo ignores it), validate it, then move it into place
                tmpf="$($SUDO mktemp "$(dirname "$file")/.ajar-lockdown.XXXXXX")"
                # shellcheck disable=SC2016  # $1/$2 belong to the inner sh, passed as arguments
                root sh -c 'cat -- "$1" > "$2"' _ "$file" "$tmpf"
                root sed -i "${lineno}s/^/# disabled by ajar --lockdown: /" "$tmpf"
                if ! $SUDO visudo -cf "$tmpf" >/dev/null 2>&1; then
                    root rm -f "$tmpf"; warn "the edited copy of $file failed visudo; left it alone"; continue
                fi
                bak="$file.ajar-backup-$(date +%Y%m%d%H%M%S)"   # has a dot: sudo ignores it
                root cp -a "$file" "$bak"
                root chown --reference="$file" "$tmpf"
                root chmod --reference="$file" "$tmpf"
                root mv -f "$tmpf" "$file"
                say "  commented out $file:$lineno (backup: $bak)" ;;
        esac
    done
}

remove_legacy() {
    [[ -e /etc/sudoers.d/90-sudo-gate ]] && root rm -f /etc/sudoers.d/90-sudo-gate
    [[ -e /usr/share/polkit-1/actions/org.sudogate.policy ]] && root rm -f /usr/share/polkit-1/actions/org.sudogate.policy
    if [[ -d /usr/libexec/sudo-gate ]]; then
        root rm -f /usr/libexec/sudo-gate/enable /usr/libexec/sudo-gate/disable
        root rmdir /usr/libexec/sudo-gate 2>/dev/null || true
    fi
    return 0
}

enable_extension_for() {   # add our uuid to the user's enabled-extensions (read at login)
    local u="$1" cur
    local as=(); [[ "$(id -un)" != "$u" ]] && as=(sudo -u "$u")
    cur="$("${as[@]}" gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo '@as []')"
    [[ "$cur" == *"'$UUID'"* ]] && return 0
    local new
    if [[ "$cur" == "@as []" || "$cur" == "[]" ]]; then new="['$UUID']"; else new="${cur%]}, '$UUID']"; fi
    run "${as[@]}" gsettings set org.gnome.shell enabled-extensions "$new" || true
}

uninstall() {
    head1 "Uninstall Ajar"
    [[ -f "$MANIFEST" ]] || { say "No manifest at $MANIFEST: nothing to remove (or installed as a .deb: use apt remove ajar)."; return 1; }
    say "Turns passwordless sudo off for every user (removes /etc/sudoers.d/90-ajar-*), then removes:"
    sed 's/^/  /' "$MANIFEST"
    if (( dry )); then head1 "Dry run: nothing was changed."; return 0; fi
    confirm || { say "Cancelled."; return 1; }
    [[ -x "$LIBEXEC/disable" ]] && root env -u PKEXEC_UID "$LIBEXEC/disable" --all
    local f
    local pkg_installed=0
    dpkg-query -W -f='${Status}' ajar 2>/dev/null | grep -q 'ok installed' && pkg_installed=1
    local entries=(); mapfile -t entries < "$MANIFEST"   # read fully first: the loop deletes it
    for f in "${entries[@]}"; do
        # no relative parts, no symlinks: an entry must name exactly the file we wrote
        if [[ "$f" == *"/../"* || "$f" == *"/./"* || "$f" == *"/.." || -L "$f" ]]; then
            warn "skipping suspicious manifest entry: $f"; continue
        fi
        if (( pkg_installed )) && dpkg -S "$f" >/dev/null 2>&1; then
            warn "kept $f (owned by the installed ajar package)"; continue
        fi
        case "$f" in   # exactly the paths install() writes, nothing broader
            "$LIBEXEC"/enable|"$LIBEXEC"/disable \
            |"$POLICY_DIR"/io.github.techbysakh963.ajar.policy \
            |"$PREFIX"/bin/ajar|"$PREFIX"/bin/ajar-tray \
            |"$PREFIX"/share/ajar/ajar-ask|"$PREFIX"/share/ajar/install.sh|"$MANIFEST" \
            |"$PREFIX"/share/icons/hicolor/scalable/apps/io.github.techbysakh963.Ajar*.svg \
            |"$PREFIX"/share/icons/hicolor/scalable/status/ajar-*.svg \
            |"$PREFIX"/share/applications/io.github.techbysakh963.Ajar.desktop \
            |"$PREFIX/share/gnome-shell/extensions/$UUID"/*.js \
            |"$PREFIX/share/gnome-shell/extensions/$UUID"/metadata.json \
            |"$PREFIX/share/gnome-shell/extensions/$UUID"/stylesheet.css \
            |"$PREFIX/share/gnome-shell/extensions/$UUID"/icons/ajar-*.svg \
            |/etc/xdg/autostart/ajar-tray.desktop)
                root rm -f -- "$f" ;;
            *) warn "skipping unexpected manifest entry: $f" ;;
        esac
    done
    for d in "$PREFIX/share/gnome-shell/extensions/$UUID/icons" "$PREFIX/share/gnome-shell/extensions/$UUID" "$PREFIX/share/ajar" "$LIBEXEC"; do
        if [[ -d "$d" ]]; then root rmdir "$d" 2>/dev/null || true; fi
    done
    systemctl --user stop ajar-reminder.timer 2>/dev/null || true
    head1 "Ajar removed. sudo follows /etc/sudoers only."
}

main "$@"
