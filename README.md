# DeepSeek Harness Desktop

A native macOS wrapper for the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) browser UI. It launches `npx @deepseek-ai/dsh web` as a child process and displays the served page in a `WKWebView` window — no compilation of the harness project itself is required.

Licensed under the [MIT License](LICENSE).

| | |
| --- | --- |
| Bundle identifier | `com.deepvisus.harness-desktop` |
| Display name | DeepSeek Harness |
| Executable | `DSHWebView` |
| Minimum macOS | 13.0 |

## Install (end users)

Install the prebuilt app from GitHub Releases with one command — downloads the
DMG, copies the app into `/Applications`, and launches it:

```sh
curl -fsSL https://raw.githubusercontent.com/tonytsangzen/harness-desktop/main/install.sh | bash
```

Options:

- Install a specific release: `curl … | bash -s -- v1.0.0`
- Point at another fork: set `GH_REPO=owner/repo` before running.

You can also just download the `.dmg` from the release and drag the app into
`/Applications`.

### Runtime provisioning

The app spawns `npx @deepseek-ai/dsh web` at runtime, so it needs Node.js. It
**installs it automatically** on first launch when missing:

1. Detects whether `node` and `npx` are on `PATH`. If so, it starts immediately.
2. Otherwise it shows a "Preparing runtime…" window with a progress bar and
   state, downloads the official Node.js `.pkg` installer, and runs
   `/usr/sbin/installer` (a system auth prompt appears), then continues.

No Node.js, Homebrew, or other tooling needs to be pre-installed on a clean
macOS machine.

## Requirements (building from source)

- macOS 13+ (arm64)
- Xcode command-line tools (`swift`, `swift build`)
- Node.js 22+ and npm/npx (for `@deepseek-ai/dsh`)

### Automated setup

On a clean macOS machine, install all build tooling in one step:

```sh
./scripts/setup.sh
```

This installs (and is safe to re-run; each step skips when already satisfied):

| Tool | Purpose |
| --- | --- |
| Xcode Command Line Tools | `swift`, `swift build`, `codesign`, `sips` (build-time) |
| Homebrew | Package manager used to install Node.js |
| Node.js 22 + npm/npx | Runtime — the app spawns `npx @deepseek-ai/dsh web` |

Note: the `xcode-select --install` step pops a GUI dialog; click **Install**, accept the license, wait for the download to finish, then re-run the script.

## Build

```sh
./build-app.sh
```

This compiles the Swift release binary and assembles `dist/DeepSeek Harness.app`, copying the committed `AppIcon.icns` into the bundle.

## Run

```sh
open "dist/DeepSeek Harness.app"
```

Or run the bare binary directly in a terminal (useful for watching the harness logs, which are streamed to stdout):

```sh
swift run DSHWebView
```

## Behavior

On launch the app:

1. Checks for Node.js and installs it if missing (see [Runtime provisioning](#runtime-provisioning)).
2. Spawns `npx @deepseek-ai/dsh web --host 127.0.0.1 --port 3080`.
3. Polls `127.0.0.1:3080` until the server accepts connections (up to 180 s).
4. Loads `http://127.0.0.1:3080/` in the `WKWebView` and shows the window.
5. Terminates the child process when the last window closes.

The first launch downloads `@deepseek-ai/dsh` via npx, so startup can take a while.

## Configuration

| CLI flag | Default | Effect |
| --- | --- | --- |
| `--host <host>` | `127.0.0.1` | Host for the dsh web server |
| `--port <port>` | `3080` | Port for the dsh web server |
| `--command "<cmd>"` | `npx @deepseek-ai/dsh web` | Full launch command (space-separated) |
| `--help`, `-h` | — | Print usage to stderr and exit |

When the default command is used, the resolved host and port are appended automatically so the webview and the server stay in agreement. A custom `--command` is launched verbatim.

Environment overrides (lower priority than CLI flags):

| Variable | Effect |
| --- | --- |
| `DSH_WEBVIEW_HOST` | Override the default host |
| `DSH_WEBVIEW_PORT` | Override the default port |
| `DSH_WEBVIEW_COMMAND` | Override the launch command |

## Create a DMG

```sh
./build-app.sh
./scripts/create-dmg.sh
```

This produces `dist/DeepSeek Harness-<version>.dmg` (default version `1.0.0`, overridable via the `VERSION` environment variable). The DMG contains the app plus an `/Applications` symlink for drag-to-install.

## Release

The [release workflow](.github/workflows/release.yml) builds the app, packages a DMG, and publishes it:

- Pushing a `v*` tag (e.g. `v1.0.0`) triggers a run that attaches the DMG to the generated GitHub Release with release notes.
- Manual runs are available via the **Actions → Release → Run workflow** button, which uploads the DMG as a build artifact.

## Signing & notarization

The build script applies an **ad-hoc** signature (`codesign --sign -`), which is
fine for local use but not for public distribution. For a Gatekeeper-clean
release:

1. Sign with an Apple "Developer ID Application" certificate:
   ```sh
   codesign --force --deep --sign "Developer ID Application: …" \
     "dist/DeepSeek Harness.app"
   ```
2. Notarize and staple:
   ```sh
   # create a .zip for submission
   ditto -c -k --keepParent "dist/DeepSeek Harness.app" app.zip
   xcrun notarytool submit app.zip --apple-id … --team-id … --password … --wait
   xcrun stapler staple "dist/DeepSeek Harness.app"
   ```

Notes:

- The app is **not sandboxed** (no App Sandbox entitlements) so it can spawn
  `installer` (for runtime provisioning) and `npx`. Enabling sandbox would
  break these capabilities without additional entitlements.
- Installing Node.js via `/usr/sbin/installer` requires elevated privileges, so
  the system will prompt for authorization the first time it provisions the
  runtime.

## Project layout

```
.
├── install.sh                End-user installer: downloads DMG, installs, launches
├── build-app.sh              Build script: compiles and assembles the .app
├── Package.swift             SwiftPM manifest (executable target DSHWebView)
├── Info.plist                Bundle configuration (identifier, icon, metadata)
├── AppIcon.icns              Application icon (committed)
├── CHANGELOG.md              Release notes (Keep a Changelog)
├── .github/workflows/
│   └── release.yml           CI: build, package DMG, and publish releases
├── scripts/
│   ├── setup.sh               One-shot toolchain installer for clean macOS
│   └── create-dmg.sh          DMG packaging script
└── Sources/DSHWebView/
    └── main.swift            Application entry point, server manager, webview window
```
