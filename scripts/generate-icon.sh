#!/usr/bin/env bash
# Generate the app icon (.icns) from icon.png (falls back to a rendered icon).
set -euo pipefail

cd "$(dirname "$0")/.."

WORK=".build/icon"
ICONSET="${WORK}/AppIcon.iconset"
ICNS="AppIcon.icns"
MASTER="${WORK}/icon_1024.png"

mkdir -p "${WORK}" "${ICONSET}"

# 1. Prepare the 1024px master PNG: use icon.png when present, otherwise
#    render one programmatically.
if [[ -f "icon.png" ]]; then
    if [[ "$(sips -g pixelWidth icon.png | awk '/pixelWidth/{print $2}')" == "1024" ]]; then
        cp icon.png "${MASTER}"
    else
        sips -z 1024 1024 icon.png --out "${MASTER}" >/dev/null
    fi
else
    swift scripts/generate-icon.swift "${MASTER}"
fi

# 2. Resize into the full iconset.
sips -z 16 16   "${MASTER}" --out "${ICONSET}/icon_16x16.png"       >/dev/null
sips -z 32 32   "${MASTER}" --out "${ICONSET}/icon_16x16@2x.png"    >/dev/null
sips -z 32 32   "${MASTER}" --out "${ICONSET}/icon_32x32.png"       >/dev/null
sips -z 64 64   "${MASTER}" --out "${ICONSET}/icon_32x32@2x.png"    >/dev/null
sips -z 128 128 "${MASTER}" --out "${ICONSET}/icon_128x128.png"     >/dev/null
sips -z 256 256 "${MASTER}" --out "${ICONSET}/icon_128x128@2x.png"  >/dev/null
sips -z 256 256 "${MASTER}" --out "${ICONSET}/icon_256x256.png"     >/dev/null
sips -z 512 512 "${MASTER}" --out "${ICONSET}/icon_256x256@2x.png"  >/dev/null
sips -z 512 512 "${MASTER}" --out "${ICONSET}/icon_512x512.png"     >/dev/null
sips -z 1024 1024 "${MASTER}" --out "${ICONSET}/icon_512x512@2x.png" >/dev/null

# 3. Package into a single .icns.
iconutil -c icns "${ICONSET}" -o "${ICNS}"
echo "wrote ${ICNS}"
