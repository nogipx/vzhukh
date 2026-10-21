#!/usr/bin/env bash
# Builds every app icon from the two master drawings in assets/branding/.
#
# cat_color.svg and cat_mono.svg are drawn on a 100x100 canvas. Each platform
# needs the cat framed differently — full-bleed tile, adaptive layer with a
# round safe zone, macOS rounded plate, tiny status-bar glyph — so this
# script wraps the masters in small framing SVGs, renders them to PNG and
# hands the PNGs to flutter_launcher_icons (config in flutter_launcher_icons.yaml).
#
# Prerequisites:
#   - rsvg-convert (brew install librsvg)
#
# Usage:
#   ./scripts/build_icons.sh
#
# Output:
#   assets/branding/out/*.png             intermediate renders
#   android/ios/macos/windows/web icons   via flutter_launcher_icons
#   android/.../drawable-*/ic_stat_vzhukh.png   tunnel notification icon

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$ROOT/assets/branding"
OUT="$SRC/out"
RES="$ROOT/android/app/src/main/res"

BG="#FFC93D"

command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found: brew install librsvg"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

# cat_at MASTER X Y SIZE — the master drawing as a nested <svg> placed at
# X,Y and scaled to SIZE. Inlined rather than linked with <image>: rsvg
# rasterises a linked SVG at its own 100px size and then upscales the bitmap.
# Relies on the master's root <svg> tag being its first line.
cat_at() {
    sed "1s|.*|<svg x='$2' y='$3' width='$4' height='$4' viewBox='0 0 100 100'>|" "$SRC/$1.svg"
}

# frame NAME VIEWBOX BODY — writes $OUT/NAME.svg
frame() {
    cat > "$OUT/$1.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="$2">$3</svg>
EOF
}

render() { # render NAME SIZE [OUTFILE]
    rsvg-convert -w "$2" -h "$2" "$OUT/$1.svg" -o "${3:-$OUT/$1.png}"
}

# Full-bleed square tile: iOS, web, Android pre-26. The platform rounds it.
frame icon "0 0 100 100" \
    "<rect width='100' height='100' fill='$BG'/>
     $(cat_at cat_color -6.1 -1 110)"
render icon 1024

# Android adaptive layers, 108dp canvas. Launchers show at most the central
# 72dp circle, so the hat tip and the stars have to stay inside it.
frame adaptive_foreground "0 0 108 108" \
    "$(cat_at cat_color 14.2 15 78)"
render adaptive_foreground 1024
frame adaptive_monochrome "0 0 108 108" \
    "$(cat_at cat_mono 14.2 15 78)"
render adaptive_monochrome 1024

# iOS 18 dark appearance: the cat alone, the system draws the dark plate.
frame ios_dark "0 0 100 100" \
    "$(cat_at cat_color -6.1 -1 110)"
render ios_dark 1024
# iOS 18 tinted appearance: grayscale shape, the system applies the tint.
frame ios_tinted "0 0 100 100" \
    "<rect width='100' height='100' fill='#000'/>
     $(cat_at cat_mono -6.1 -1 110)"
render ios_tinted 1024

# macOS and Windows draw no mask: a rounded plate with Apple's 100px margin
# on a 1024 canvas, and a soft shadow.
frame plate "0 0 1024 1024" \
    "<defs>
       <clipPath id='c'><rect x='100' y='100' width='824' height='824' rx='185'/></clipPath>
       <filter id='sh' x='-10%' y='-10%' width='120%' height='130%'><feGaussianBlur stdDeviation='14'/></filter>
     </defs>
     <rect x='100' y='112' width='824' height='824' rx='185' fill='#000' opacity='.3' filter='url(#sh)'/>
     <g clip-path='url(#c)'>
       <rect x='100' y='100' width='824' height='824' fill='$BG'/>
       $(cat_at cat_color 49.7 91.8 906.4)
     </g>"
render plate 1024

# Android notification small icon: white silhouette on transparent, 24dp.
frame notification "0 0 24 24" \
    "$(cat_at cat_mono 0.3 0.06 23.4)"
for d in mdpi:24 hdpi:36 xhdpi:48 xxhdpi:72 xxxhdpi:96; do
    mkdir -p "$RES/drawable-${d%%:*}"
    render notification "${d##*:}" "$RES/drawable-${d%%:*}/ic_stat_vzhukh.png"
done

# Android TV launcher banner, 320x180dp: the cat and the app name.
frame tv_banner "0 0 320 180" \
    "<rect width='320' height='180' fill='$BG'/>
     $(cat_at cat_color -2 12 170)
     <text x='170' y='104' font-family='Avenir Next' font-weight='900' font-size='36'
           fill='#1A1A1F'>vzhukh</text>"
for d in xhdpi:320 xxhdpi:480 xxxhdpi:640; do
    mkdir -p "$RES/drawable-${d%%:*}"
    rsvg-convert -w "${d##*:}" -h "$(( ${d##*:} * 180 / 320 ))" "$OUT/tv_banner.svg" \
        -o "$RES/drawable-${d%%:*}/tv_banner.png"
done

# README header: the TV banner's layout, wider and rounded.
frame readme_banner "0 0 320 100" \
    "<defs><clipPath id='r'><rect width='320' height='100' rx='12'/></clipPath></defs>
     <g clip-path='url(#r)'>
       <rect width='320' height='100' fill='$BG'/>
       $(cat_at cat_color 40 6 100)
       <text x='150' y='63' font-family='Avenir Next' font-weight='900' font-size='34'
             fill='#1A1A1F'>vzhukh</text>
     </g>"
rsvg-convert -w 1600 -h 500 "$OUT/readme_banner.svg" -o "$SRC/readme_banner.png"

cd "$ROOT"
fvm dart run flutter_launcher_icons -f flutter_launcher_icons.yaml

# flutter_launcher_icons 0.14.4 rewrites this unrelated build setting to
# "AppIcon" when it adds the dark/tinted iOS icons; Xcode expects a boolean.
sed -i '' 's/ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = AppIcon;/ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;/' \
    ios/Runner.xcodeproj/project.pbxproj
