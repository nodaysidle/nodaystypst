#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE=${1:-$ROOT/Resources/AppIcon.png}
OUTPUT=${2:-$ROOT/Resources/AppIcon.icns}

if [[ ! -f "$SOURCE" ]]; then
    echo "ERROR: icon source not found: $SOURCE" >&2
    exit 1
fi

TEMP_ROOT=$(mktemp -d /tmp/nodaystypst-icon.XXXXXX)
trap 'rm -rf "$TEMP_ROOT"' EXIT
ICONSET="$TEMP_ROOT/AppIcon.iconset"
mkdir -p "$ICONSET"

make_icon() {
    local pixels=$1
    local filename=$2
    sips -s format png -z "$pixels" "$pixels" "$SOURCE" \
        --out "$ICONSET/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "Created $OUTPUT"
