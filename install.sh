#!/usr/bin/env bash
# One-shot installer for DeepSeek Harness Desktop on a clean macOS machine.
#
# Downloads the DMG from GitHub Releases, installs the app into /Applications,
# installs Node.js if missing (the app spawns `npx @deepseek-ai/dsh web` at
# runtime), and launches the app.
#
# Usage:
#   ./install.sh                 # install the latest release
#   ./install.sh v1.0.0          # install a specific release tag
#
# Environment:
#   GH_REPO    GitHub "owner/repo" (default: tonytsangzen/harness-desktop)
set -euo pipefail

GH_REPO="${GH_REPO:-tonytsangzen/harness-desktop}"
TAG="${1:-latest}"
APP_NAME="DeepSeek Harness"
APP_PATH="/Applications/${APP_NAME}.app"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

# --- 1. Resolve and download the DMG ---------------------------------------
RELEASE_URL="https://github.com/${GH_REPO}/releases/${TAG}"
log "Resolving release: ${RELEASE_URL}"

if [[ "${TAG}" == "latest" ]]; then
    # Follow GitHub's redirect from /releases/latest to the tagged release.
    LATEST_URL="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${GH_REPO}/releases/latest")"
    DMG_URL="${LATEST_URL}/download/${APP_NAME}.dmg"
else
    DMG_URL="https://github.com/${GH_REPO}/releases/download/${TAG}/${APP_NAME}.dmg"
fi

DMG_PATH="$(mktemp -t harness-desktop).dmg"
log "Downloading ${DMG_URL}"
curl -fL --progress-bar -o "${DMG_PATH}" "${DMG_URL}" || err "download failed (is the tag correct and the DMG asset present?)"

# --- 2. Mount the DMG and install the app ----------------------------------
MOUNT_DIR="$(mktemp -d -t harness-dmg)"
log "Mounting DMG…"
hdiutil attach "${DMG_PATH}" -nobrowse -readonly -mountpoint "${MOUNT_DIR}" >/dev/null \
    || err "failed to mount DMG"

log "Installing to /Applications…"
if [[ ! -d "${MOUNT_DIR}/${APP_NAME}.app" ]]; then
    hdiutil detach "${MOUNT_DIR}" >/dev/null 2>&1 || true
    err "app bundle not found inside DMG"
fi

# Replace any existing copy.
rm -rf "${APP_PATH}"
cp -R "${MOUNT_DIR}/${APP_NAME}.app" /Applications/ \
    || err "failed to copy app (permissions?)"

hdiutil detach "${MOUNT_DIR}" >/dev/null 2>&1 || true
rm -f "${DMG_PATH}"
rmdir "${MOUNT_DIR}" 2>/dev/null || true
log "Installed: ${APP_PATH}"

# Remove any quarantine flag so a locally-downloaded app launches cleanly.
if has xattr; then
    xattr -d com.apple.quarantine "${APP_PATH}" 2>/dev/null || true
fi

# --- 3. Ensure Node.js (runtime; npx launches dsh web) ---------------------
if has node && has npx; then
    log "Node.js: found $(node --version)"
else
    log "Node.js/npx not found; installing via Homebrew…"
    if ! has brew; then
        log "Installing Homebrew…"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        if [[ -f /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [[ -f /usr/local/bin/brew ]]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
    fi
    brew install node@22 || brew install node
    if [[ -d "$(brew --prefix)/opt/node@22/bin" ]] && ! has node; then
        export PATH="$(brew --prefix)/opt/node@22/bin:$PATH"
    fi
    has node || err "Node.js installation failed"
fi

# --- 4. Launch the app -----------------------------------------------------
log "Launching ${APP_NAME}…"
open "${APP_PATH}"

log "Done."
log "The app will download @deepseek-ai/dsh on first launch (may take a while)."
