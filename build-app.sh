#!/usr/bin/env bash
# Build the Swift binary and wrap it into a macOS .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="DSHWebView"
DISPLAY_NAME="DeepSeek Harness"
BUNDLE_ID="com.deepvisus.harness-desktop"
VERSION="${VERSION:-1.0.0}"
RELEASE_BIN=".build/release/${APP_NAME}"

# 1. Build the release binary.
swift build -c release

# 2. Assemble the .app bundle.
APP_DIR="dist/${DISPLAY_NAME}.app"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${RELEASE_BIN}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"

# Write Info.plist with the resolved version stamped in.
sed -e "s|<string>1.0.0</string>|<string>${VERSION}</string>|g" Info.plist \
    > "${APP_DIR}/Contents/Info.plist"

# 3. Codesign ad-hoc so Gatekeeper doesn't complain when launched locally.
codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || true

echo "Built: ${APP_DIR} (version ${VERSION})"
echo "Run:   open \"${APP_DIR}\""
