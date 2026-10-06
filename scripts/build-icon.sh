#!/bin/zsh
set -euo pipefail

# Rebuild all macOS icon representations from the transparent master artwork.
PROJECT_DIR="${0:A:h:h}"
SOURCE="$PROJECT_DIR/AppResources/AppIcon-source.png"
ICONSET="$PROJECT_DIR/AppResources/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$PROJECT_DIR/AppResources/AppIcon.icns"
echo "Updated AppResources/AppIcon.icns"
