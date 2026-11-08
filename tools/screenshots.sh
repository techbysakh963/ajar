#!/bin/bash
# Build the README images from real captures in screenshots/raw/ (not committed).
# Every pixel of every screenshot comes from a real desktop; this script only crops, adds
# rounded corners, a soft shadow, the hero's background, and crossfades between GIF frames.
#   tools/screenshots.sh            needs ImageMagick 7 (magick) and ffmpeg
set -euo pipefail
cd "$(dirname "$0")/.."
RAW=screenshots/raw
OUT=screenshots
U="$RAW/ubuntu24.04-gnome46-hidpi"     # 3840x2160 at 2x, captured area: logical x 640.., y 0..
K="$RAW/kali-xfce"                      # 1280x800 at 1x
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# card <in> <out> <radius> [shadow-opacity]: rounded corners + soft shadow, transparent around
card() {
    local w h; w=$(magick identify -format %w "$1"); h=$(magick identify -format %h "$1")
    magick "$1" -alpha set \
        \( -size "${w}x${h}" xc:none -fill white -draw "roundrectangle 0,0,$((w-1)),$((h-1)),$3,$3" \) \
        -compose DstIn -composite -compose Over \
        \( +clone -background black -shadow "${4:-45}x22+0+14" \) +swap -background none -layers merge +repage \
        -strip "$2"
}

# --- hero: the real top bar at 2x, the amber door lit from behind ----------------------------
magick "$U/bar-on.png" -crop 640x64+640+0 +repage -filter Lanczos -resize 200% "$tmp/strip.png"
card "$tmp/strip.png" "$tmp/strip-card.png" 32 60
magick -size 1600x480 radial-gradient:'#232631-#111317' \
    \( -size 1600x480 xc:none -fill 'rgba(255,176,0,0.34)' -draw "circle 912,240 912,380" -blur 0x80 \) \
    -compose Over -composite "$tmp/strip-card.png" -gravity center -composite -strip \
    -sampling-factor 4:4:4 -quality 92 "$OUT/hero.jpg"     # JPEG: a soft glow is 30 KB, not 770

# --- context shot (kept for later, not in the README yet) -------------------------------------
magick "$U/k6-qs-on.png" -crop 1000x660+1560+0 +repage "$tmp/qs.png"
card "$tmp/qs.png" "$tmp/qs-card.png" 30 60
magick -size 1600x820 radial-gradient:'#232631-#111317' \
    \( -size 1600x820 xc:none -fill 'rgba(255,176,0,0.24)' -draw "circle 1000,170 1000,330" -blur 0x110 \) \
    -compose Over -composite "$tmp/qs-card.png" -gravity center -composite -strip \
    -sampling-factor 4:4:4 -quality 92 "$OUT/hero-context.jpg"

# --- GNOME cards (transparent, work on GitHub light and dark) ---------------------------------
magick "$U/k7-qs-menu.png"      -crop 1000x1060+1560+0  +repage "$tmp/b.png"; card "$tmp/b.png" "$OUT/gnome-menu.png" 30
magick "$U/k3-dialog-typed.png" -crop 824x772+228+692   +repage "$tmp/c.png"; card "$tmp/c.png" "$OUT/gnome-password-dialog.png" 24
if [[ -f "$U/reminder.png" ]]; then
    magick "$U/reminder.png" -crop 1000x314+286+71 +repage "$tmp/d.png"; card "$tmp/d.png" "$OUT/reminder.png" 24
fi

# --- Kali Xfce cards ---------------------------------------------------------------------------
magick "$K/kali-01-tray-menu.png"     -crop 520x220+760+0  +repage "$tmp/e.png"; card "$tmp/e.png" "$OUT/kali-xfce-tray.png" 14
magick "$K/kali-02-polkit-dialog.png" -crop 530x250+380+322 +repage "$tmp/f.png"; card "$tmp/f.png" "$OUT/kali-xfce-dialog.png" 14

# --- demo loop: real frames of one run, crossfaded --------------------------------------------
# terminal: sudo asks for a password -> Quick Settings: Sudo off -> polkit dialog -> password ->
# Sudo on (amber door) -> terminal: the same command runs as root without asking.
# Every frame is a screen area captured at 2x with the same aspect ratio (1.28).
ST="$U/story"
frames=(t1a-typed t1-asks-password q1-off d1-dialog d2-typed q2-on t2a-typed t2-root)
holds=( 0.7       1.7              1.2    0.9       0.8      1.7   0.6       2.4)
fade=0.35
args=() filt="" prev="0:v" off=0
for i in "${!frames[@]}"; do
    magick "$ST/${frames[$i]}.png" -resize 800x624! -strip "$tmp/f$i.png"
    args+=(-loop 1 -t "$(awk -v a="${holds[$i]}" -v b="$fade" 'BEGIN{print a+b}')" -i "$tmp/f$i.png")
done
for (( i=1; i<${#frames[@]}; i++ )); do
    off=$(awk -v a="$off" -v b="${holds[$((i-1))]}" 'BEGIN{print a+b}')
    filt+="[$prev][$i:v]xfade=transition=fade:duration=$fade:offset=${off}[x$i];"; prev="x$i"
done
ffmpeg -loglevel error -y "${args[@]}" -filter_complex "${filt}[$prev]fps=20,format=yuv420p[v]" -map "[v]" \
    -c:v libx264 -crf 22 -movflags +faststart "$OUT/demo.mp4"
ffmpeg -loglevel error -y -i "$OUT/demo.mp4" \
    -vf "fps=10,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
    -loop 0 "$OUT/demo.gif"

ls -l "$OUT"/*.png "$OUT"/*.jpg "$OUT"/demo.*
