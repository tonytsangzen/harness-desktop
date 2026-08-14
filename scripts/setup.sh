#!/usr/bin/env bash
# One-shot setup for a clean macOS machine: installs everything needed to
# build and run DeepSeek Harness Desktop.
#
#   - Xcode Command Line Tools (swift, codesign, sips)
#   - Homebrew (package manager)
#   - Node.js 22+ (runtime; the app spawns `npx @deepseek-ai/dsh web`)
#
# Safe to re-run: each step checks whether it is already satisfied and skips.
set -euo pipefail

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

has() { command -v "$1" >/dev/null 2>&1; }

# --- 1. Xcode Command Line Tools -------------------------------------------
if ! has swift || ! xcode-select -p >/dev/null 2>&1; then
    log "Xcode Command Line Tools not found; installing…"
    xcode-select --install
    log "A GUI dialog will appear. Click 'Install', accept the license, and"
    log "wait for the download to finish, then re-run this script."
    exit 0
else
    log "Xcode Command Line Tools: found ($(xcode-select -p))"
fi

# --- 2. Homebrew -----------------------------------------------------------
if ! has brew; then
    log "Homebrew not found; installing…"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Apple Silicon installs brew under /opt/homebrew; Intel under /usr/local.
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -f /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
else
    log "Homebrew: found ($(brew --prefix))"
fi

# --- 3. Node.js 22 ---------------------------------------------------------
if has node; then
    log "Node.js: found $(node --version)"
else
    log "Node.js not found; installing via Homebrew…"
    brew install node@22
    if [[ -d "$(brew --prefix)/opt/node@22/bin" ]]; then
        log "Note: node@22 is keg-only. Add it to PATH or use full path:"
        log "  $(brew --prefix)/opt/node@22/bin"
    fi
fi

# --- 4. Verify -------------------------------------------------------------
log "Verifying toolchain…"
has swift   && swift --version   || err "swift is still missing"
has node    && node --version    || err "node is still missing"
has npm     && npm --version     || err "npm is still missing"
has npx     || err "npx is still missing"
has codesign || err "codesign is still missing"

log "Setup complete."
log "Build:   ./build-app.sh"
log "Package: ./scripts/create-dmg.sh"
log "Run:     open \"dist/DeepSeek Harness.app\""
