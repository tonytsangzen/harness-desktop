# DeepSeek Harness Desktop

Native desktop shells for the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) browser UI. Each shell launches `npx @deepseek-ai/dsh web` as a child process and displays the served page in the operating system's built-in webview — **no Electron, no bundled Chromium/Node**, and no compilation of the harness project itself.

Currently supported platforms:

| Platform | Shell | Webview |
| --- | --- | --- |
| macOS | Swift (`WKWebView`) | WebKit |
| Windows | Native C++ (Win32 + WebView2 COM) | WebView2 (system) |

Both shells follow the same behavior contract and are developed separately (their only shared ground is the launch command, port selection, update check, and mirror-based runtime download — each implemented natively per platform).

Licensed under the [MIT License](LICENSE).

### macOS

| | |
| --- | --- |
| Bundle identifier | `com.deepvisus.harness-desktop` |
| Display name | DeepSeek Harness |
| Executable | `DSHWebView` |
| Minimum macOS | 13.0 |

### Windows

| | |
| --- | --- |
| Display name | DeepSeek Harness |
| Executable | `DSHWebView.exe` |
| Architectures | x64, arm64 (Windows on ARM) |
| Target | Windows 10 1809+ |
| Runtime | Native C++ (MSVC, statically linked) — single ~0.5 MB exe |
| Installers | portable exe + WiX MSI, per architecture |

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

### Windows

Download the latest release from GitHub Releases and pick the file matching your
CPU architecture (`x64` for Intel/AMD 64-bit, `arm64` for ARM-based devices):

- **MSI installer** — `DSHWebView-<version>-x64.msi` (or `-arm64.msi`).
  Double-click to install into `Program Files\DeepSeek Harness` with a Start
  Menu shortcut and an uninstall entry, or install silently:

  ```sh
  msiexec /i DSHWebView-<version>-x64.msi /qn
  ```

- **Portable exe** — `DSHWebView-<version>-x64.exe` (or `-arm64.exe`). No
  installation required; run it directly. WebView2 Evergreen Runtime is the only
  dependency (preinstalled on Windows 11 and with Edge).

## Requirements (building macOS shell)

- macOS 13+ (Universal — arm64 + x86_64)
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

## Build (macOS)

```sh
./build-app.sh
```

This compiles the Swift release binary for both `arm64` and `x86_64`, merges
them into a universal binary with `lipo`, and assembles `dist/DeepSeek Harness.app`
(single bundle runs on Apple Silicon and Intel), copying the committed
`AppIcon.icns` into the bundle.

## Run (macOS)

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
2. Spawns `npx @deepseek-ai/dsh web --host 127.0.0.1 --port 3080` (or an automatically chosen free port — see below).
3. Polls the server until it accepts connections (up to 180 s).
4. Loads the served page in the `WKWebView` and shows the window.
5. Terminates the child process when the last window closes.

The first launch downloads `@deepseek-ai/dsh` via npx, so startup can take a while.

### Port selection

If the configured port (default `3080`) is already in use by another process, the app **does not kill it**; it automatically picks the next free port and starts the server there, loading the same port in the webview. The configured port is still preferred when it is available.

## Configuration

| CLI flag | Default | Effect |
| --- | --- | --- |
| `--host <host>` | `127.0.0.1` | Host for the dsh web server |
| `--port <port>` | `3080` | Preferred port for the dsh web server (falls back to a free port if taken) |
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

## Windows (build & behavior)

The Windows shell lives in [`windows/`](windows/) and is a **native C++ (Win32)
app that hosts WebView2 through the raw COM API** — no C#/.NET, no WinUI, no
WebView2Loader DLL (the static loader is linked in). It reproduces the macOS
shell's behavior:

1. Detects and provisions Node.js (downloads the official Windows `.zip`,
   extracts to `%LOCALAPPDATA%\Programs\nodejs`, and appends it to the user PATH —
   no administrator rights needed).
2. Spawns `npx @deepseek-ai/dsh web --host 127.0.0.1 --port 3080` without a
   console window; stdout/stderr are captured to `%TEMP%\DSHWebView-dsh.log`.
3. Polls the server until it accepts connections, then loads the served page in
   the WebView2 window. A loading overlay reports runtime provisioning progress.
   Downloads initiated from the page (including programmatic `<a download>`
   clicks outside a user gesture, e.g. the Session ZIP export — mirrored from
   the macOS shell via an in-page interceptor plus a native WinHTTP download)
   show a **Save As dialog** for the destination (defaulting to the user's
   Downloads folder, matching the macOS save panel), are tracked in a bottom
   progress bar, and surface an error dialog on failure.
4. Terminates the whole child process tree on window close (Job Object).
5. Checks for `@deepseek-ai/dsh` updates against the npm registry on launch and
   offers to refresh the npx cache.

### Build (Windows)

Requires Visual Studio 2022 with the Desktop C++ workload (MSVC, CMake, Ninja).
From a Windows machine or the `windows-latest` GitHub runner:

```sh
./scripts/build-windows.sh
```

This produces a single portable exe at `dist/windows/DSHWebView.exe` (no MSIX, no
installed runtimes). The committed `AppIcon.ico` is embedded as the application
icon (Explorer, taskbar, and window title bar). Open `dist/windows/DSHWebView.exe`
to run it.

The [release workflow](.github/workflows/release-windows.yml) builds the shell
for **both x64 and arm64** (Visual Studio generator, `-A x64` / `-A ARM64`) and
publishes, per architecture, a portable exe plus a WiX MSI installer
(`windows/installer/DSHWebView.wxs`) — `DSHWebView-<version>-<arch>.exe` /
`.msi` — installing the exe to `Program Files\DeepSeek Harness` with a Start
Menu shortcut and an uninstall entry.

### Runtime provisioning (Windows)

On first launch, when `node`/`npx` are missing:

1. Resolves the latest LTS `node-<version>-win-<arch>.zip` from nodejs.org
   (mirrored to npmmirror for China timezones).
2. Extracts it to `%LOCALAPPDATA%\Programs\nodejs`.
3. Updates the current process `PATH` and persists the new dir to the user
   environment (`HKCU\Environment\Path`).

The only runtime dependency is the **Microsoft Edge WebView2 Evergreen Runtime**
(preinstalled on Windows 11 and with Edge, or available via the standard
WebView2 installer). No elevation or other tooling is required on a clean
Windows machine.

## Release

The macOS shell publishes a DMG via the [release workflow](.github/workflows/release.yml);
the Windows shell publishes, for **x64 and arm64**, a portable exe plus a WiX MSI
installer via [release-windows.yml](.github/workflows/release-windows.yml). Both
trigger on a `v*` tag (or manual dispatch) and attach to the same GitHub Release.

## Project layout

```
.
├── install.sh                End-user installer: downloads DMG, installs, launches
├── build-app.sh              macOS build script (Swift)
├── Package.swift             SwiftPM manifest (macOS executable target DSHWebView)
├── macos/                    macOS shell (native Swift / WKWebView)
│   └── DSHWebView/
│       └── main.swift        App entry point, server manager, webview window
├── windows/                  Windows shell (native C++ / Win32 / WebView2 COM)
│   ├── CMakeLists.txt        CMake build (downloads WebView2 SDK, static CRT; x64/arm64 loader)
│   ├── app.manifest          Embedded manifest (asInvoker, PerMonitorV2)
│   ├── resources.rc          Embeds app.manifest (RT_MANIFEST) + AppIcon.ico
│   ├── installer/
│   │   └── DSHWebView.wxs    WiX v3 source for the MSI installer (x64/arm64)
│   └── src/
│       ├── main.cpp          wWinMain: settings, window, message loop
│       ├── main_window.cpp   Win32 window, WebView2 COM wiring, overlay/download bar
│       ├── settings.cpp      CLI/env parsing (mirrors macOS)
│       ├── server_manager.cpp  spawn dsh web, port probe, Job Object child mgmt
│       ├── node_runtime_manager.cpp  Node detection + zip install + PATH
│       ├── dsh_update_manager.cpp    npm registry version check / npx refresh
│       ├── http.cpp          WinHTTP GET (string / to-file with progress)
│       └── json.cpp          Minimal JSON parser (npm/node metadata)
├── Info.plist                macOS bundle configuration
├── AppIcon.icns              macOS application icon (committed)
├── AppIcon.ico               Windows application icon (committed, embedded via `windows/resources.rc`)
├── CHANGELOG.md              Release notes (Keep a Changelog)
├── .github/workflows/
│   ├── release.yml           CI: macOS build, DMG, release
│   ├── release-windows.yml   CI: x64+arm64 exe & MSI, release
└── scripts/
    ├── setup.sh               macOS one-shot toolchain installer
    ├── create-dmg.sh          macOS DMG packaging
    └── build-windows.sh       Windows build (run on Windows)
```

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
