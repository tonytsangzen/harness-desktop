#!/usr/bin/env bash
# Build the Swift binary (universal: arm64 + x86_64) and wrap it into a
# macOS .app bundle that runs on both Apple Silicon and Intel.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="DSHWebView"
DISPLAY_NAME="DeepSeek Harness"
BUNDLE_ID="com.deepvisus.harness-desktop"
VERSION="${VERSION:-1.1.9}"

# Architectures to ship. Build a universal (fat) binary so one .app supports
# both Apple Silicon (arm64) and Intel (x86_64) Macs.
ARCHS=(arm64 x86_64)

# 1. Build per-architecture release binaries, then merge with lipo. Building
#    each arch separately (rather than relying on `swift build --arch a --arch b`)
#    keeps the output paths predictable across SwiftPM versions.
rm -rf .build/release
ARCH_BINS=()
for arch in "${ARCHS[@]}"; do
    swift build -c release --arch "${arch}"
    # SwiftPM per-arch output: .build/<arch>-apple-macosx/release/<name> (the
    # macOS deployment target from Package.swift may append a version).
    bin_path=""
    while IFS= read -r candidate; do
        # Accept only a single-arch binary whose arch set is exactly this arch
        # (avoids matching a stale universal/fat binary from a prior run).
        if [[ -x "${candidate}" ]] && [[ "$(lipo -archs "${candidate}" 2>/dev/null)" == "${arch}" ]]; then
            bin_path="${candidate}"
            break
        fi
    done < <(find .build -path '*/release/'"${APP_NAME}" -type f 2>/dev/null | sort)
    if [[ -z "${bin_path}" ]]; then
        echo "error: could not locate ${arch} build of ${APP_NAME}" >&2
        exit 1
    fi
    ARCH_BINS+=("${bin_path}")
    echo "built ${arch}: ${bin_path}"
done

UNIVERSAL_BIN=".build/release/${APP_NAME}"
mkdir -p .build/release
lipo -create "${ARCH_BINS[@]}" -output "${UNIVERSAL_BIN}"
echo "universal binary: $(lipo -info "${UNIVERSAL_BIN}")"

# 2. Assemble the .app bundle.
APP_DIR="dist/${DISPLAY_NAME}.app"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${UNIVERSAL_BIN}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"

# Ship the mobile relay bridge (Node script + its pure-JS dependencies) so
# the "Mobile Remote" menu can spawn it from the bundle resources. The bridge
# needs Node/npx at runtime, so prune the packaged node_modules down to what
# actually runs (drop source maps / TS sources / docs — werift & its media
# stack no longer ship, so node_modules is only the ws dependency).
cp -R mobile/bridge "${APP_DIR}/Contents/Resources/bridge"
rm -f "${APP_DIR}/Contents/Resources/bridge/package-lock.json"
node mobile/bridge/prune.mjs "${APP_DIR}/Contents/Resources/bridge"

# Write Info.plist with the resolved version stamped in.
sed -e "s|<string>1.1.9</string>|<string>${VERSION}</string>|g" Info.plist \
    > "${APP_DIR}/Contents/Info.plist"

# 3. Codesign ad-hoc so Gatekeeper doesn't complain when launched locally.
codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || true

echo "Built: ${APP_DIR} (version ${VERSION})"
echo "Run:   open \"${APP_DIR}\""
