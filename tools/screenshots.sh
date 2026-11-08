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
    -c:v libx264 -crf 22 "$tmp/demo.mp4"
ffmpeg -loglevel error -y -i "$tmp/demo.mp4" \
    -vf "fps=10,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
    -loop 0 "$OUT/demo.gif"

ls -l "$OUT"/hero.jpg "$OUT"/demo.gif
