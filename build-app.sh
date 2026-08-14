#!/usr/bin/env bash
# Build the Swift binary and wrap it into a macOS .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="DSHWebView"
DISPLAY_NAME="DeepSeek Harness"
BUNDLE_ID="com.deepvisus.harness-desktop"
RELEASE_BIN=".build/release/${APP_NAME}"

# 1. Build the release binary.
swift build -c release

# 2. Generate the .icns icon on first run (or whenever it's missing).
if [[ ! -f "AppIcon.icns" ]]; then
    ./scripts/generate-icon.sh
fi

# 3. Assemble the .app bundle.
APP_DIR="dist/${DISPLAY_NAME}.app"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${RELEASE_BIN}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${APP_DIR}/Contents/Info.plist"
cp AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"

# 4. Codesign ad-hoc so Gatekeeper doesn't complain when launched locally.
codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || true

echo "Built: ${APP_DIR}"
echo "Run:   open \"${APP_DIR}\""
