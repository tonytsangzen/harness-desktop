#!/usr/bin/env bash
# Package the built .app into a signed-friendly DMG with a /Applications link.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="DSHWebView"
DISPLAY_NAME="DeepSeek Harness"
VERSION="${VERSION:-1.0.0}"
APP_PATH="dist/${DISPLAY_NAME}.app"
DMG_PATH="dist/${DISPLAY_NAME}-${VERSION}.dmg"
STAGING=".build/dmg-staging"

if [[ ! -d "${APP_PATH}" ]]; then
    echo "error: ${APP_PATH} not found. Run ./build-app.sh first." >&2
    exit 1
fi

rm -rf "${STAGING}" "${DMG_PATH}"
mkdir -p "${STAGING}"

# Stage the app and a symlink to /Applications for drag-to-install.
cp -R "${APP_PATH}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

hdiutil create \
    -volname "${DISPLAY_NAME}" \
    -srcfolder "${STAGING}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

echo "wrote ${DMG_PATH}"
