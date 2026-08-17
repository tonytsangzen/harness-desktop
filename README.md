# DeepSeek Harness Desktop

Native desktop shells for the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) browser UI. Each shell launches `npx @deepseek-ai/dsh web` as a child process and displays the served page in the operating system's built-in webview — **no Electron, no bundled Chromium/Node**, and no compilation of the harness project itself.

Currently supported platforms:

| Platform | Shell | Webview |
| --- | --- | --- |
| macOS | Swift (`WKWebView`) | WebKit |
| Windows | Native C++ (Win32 + WebView2 COM) | WebView2 (system) |
| Linux | Native C++ (GTK3 + WebKitGTK) | WebKitGTK (system) |

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

### Linux

| | |
| --- | --- |
| Display name | DeepSeek Harness |
| Executable | `dshwebview` |
| Architectures | x86_64, arm64 |
| Target | Ubuntu 22.04+ (any distro with WebKitGTK 4.1) |
| Runtime | Native C++ (GTK3 + WebKitGTK, system libraries) |
| Installers | portable tarball + `.deb`, per release |

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

### Linux

Download the latest release from GitHub Releases and pick the file matching your
CPU architecture (`x86_64` for Intel/AMD 64-bit, `aarch64` for ARM64):

- **`.deb` package** — `deepseek-harness_<version>_amd64.deb` (or
  `_arm64.deb`). Installs `dshwebview` to `/usr/bin` plus a desktop entry and
  icon:

  ```sh
  sudo apt install ./deepseek-harness_<version>_amd64.deb
  ```

- **Portable tarball** — `DeepSeek Harness-<version>-linux-x86_64.tar.gz`
  (or `-linux-aarch64.tar.gz`). Extract and run `./dshwebview` directly; no
  installation required.

Runtime dependencies (installed on virtually every desktop distro): GTK 3,
WebKitGTK 4.1, libsoup 3. **Node.js is required** at runtime — the app spawns
`npx @deepseek-ai/dsh web` — but if it is missing the shell downloads and
installs the latest LTS automatically (user-level, no root), like the
macOS/Windows shells.

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
6. Opens external links and new-window requests (`target="_blank"`, `window.open`) in the **system default browser**; only pages served by the local dsh server navigate inside the webview.
7. Provides a **Plugins Market…** item under the **Help** menu that opens the plugins market (https://tonytsangzen.github.io/harness-market/) in the default browser.
8. Offers theme and language settings under the **View** menu: theme follows the system by default with **Light**/**Dark** overrides (affects the native chrome and the web content's `prefers-color-scheme`), and the menu language follows the system locale by default with **简体中文**/**English** overrides. Both persist across launches.
9. Provides an **Enter/Exit Full Screen** item (⌃⌘F) under the **View** menu.

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
6. Opens external links and new-window requests (`target="_blank"`,
   `window.open`) in the **system default browser**; only pages served by the
   local dsh server navigate inside the webview.
7. Provides a **Plugins Market** item in the window menu bar that opens the
   plugins market (https://tonytsangzen.github.io/harness-market/) in the
   default browser.
8. Offers **Theme** and **Language** menus in the window menu bar: theme
   follows the system by default with **Light**/**Dark** overrides (dark mode
   also darkens the title bar and the WebView2 color scheme), and the menu
   language follows the system locale by default with **简体中文**/**English**
   overrides. Both persist across launches (HKCU registry).
9. Provides a **Full Screen** toggle in the window menu bar (borderless,
   fills the monitor; checkmark reflects the state).

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

The [release workflow](.github/workflows/release.yml) builds the shell
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

## Linux (build & behavior)

The Linux shell lives in [`linux/`](linux/) and is a **native C++ (GTK3)
app that hosts WebKitGTK** — the same engine that powers GNOME Web, so the
webview comes from the system. It reproduces the macOS/Windows shells'
behavior:

1. Detects `node`/`npx` (on `PATH` or in the managed install dir). When
   missing, it **auto-installs the latest LTS Node.js** to
   `~/.local/share/deepseek-harness/nodejs` (no root needed; mirrors
   macOS/Windows) with a progress dialog, then continues — a manual install
   dialog is only shown if the automatic install fails.
2. Spawns `npx @deepseek-ai/dsh web --host 127.0.0.1 --port 3080` as a child in
   its own process group; stdout/stderr are captured to
   `~/.cache/deepseek-harness/dsh-server.log(.err)`.
3. Polls the server until it accepts connections (up to 180 s), then loads the
   served page in the WebKitWebView. A spinner overlay covers startup.
   Downloads from the page show a **Save As dialog** (defaulting to
   `~/Downloads`) and are tracked in a bottom progress bar.
4. Terminates the whole child process tree on window close (process group).
5. Checks for `@deepseek-ai/dsh` updates against the npm registry on launch and
   offers to refresh the npx cache and restart the server.
6. Opens external links and new-window requests (`target="_blank"`,
   `window.open`) in the **system default browser** (`xdg-open` via GIO); only
   pages served by the local dsh server navigate inside the webview.
7. Provides a **Plugins Market** item in the menu bar that opens the plugins
   market (https://tonytsangzen.github.io/harness-market/) in the default
   browser.
8. Offers **Edit** (undo/redo/cut/copy/paste/select-all with the standard
   Ctrl+ shortcuts), **Theme**, and **Language** menus: theme follows the
   system by default with **Light**/**Dark** overrides (applies the GTK dark
   variant and the WebKitGTK preferred color scheme, affecting
   `prefers-color-scheme`), and the menu language follows the system locale by
   default with **简体中文**/**English** overrides. Both persist across launches
   (`~/.config/deepseek-harness/settings.conf`).
9. Provides a **Full Screen** toggle in the menu bar (checkmark reflects the
   state).

### Build (Linux)

Requires CMake ≥ 3.16, Ninja, pkg-config, and the WebKitGTK 4.1 development
headers (Ubuntu 22.04+):

```sh
sudo apt install cmake ninja-build pkg-config \
  libwebkit2gtk-4.1-dev libgtk-3-dev libsoup-3.0-dev
cmake -S linux -B linux/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build linux/build
./linux/build/dshwebview
```

The [release workflow](.github/workflows/release.yml) builds **x86_64**
natively and **arm64** cross-compiled (aarch64 toolchain), both on
ubuntu-22.04 so the artifacts share the same glibc baseline and run on
Ubuntu 22.04+ / Debian 12+. It publishes, per architecture, a portable
tarball plus a `.deb` package (`deepseek-harness_<version>_amd64.deb` /
`_arm64.deb`, installing `dshwebview`,
`/usr/share/applications/deepseek-harness.desktop`, and the icon).

## Release

A single [release workflow](.github/workflows/release.yml) builds all three
platforms and attaches everything to one GitHub Release:
- macOS: universal (arm64 + x86_64) DMG, built on macos-14;
- Windows: portable exe + WiX MSI for **x64 and arm64**, built on windows-2022;
- Linux: portable tarball + `.deb` for **x86_64 and arm64** (arm64
  cross-compiled), built on ubuntu-22.04.

A second [Flutter workflow](.github/workflows/flutter.yml) builds the mobile
app and its artifacts are attached to the same Release:
- Android: release APK (debug-keystore signed, sideloadable);
- iOS: unsigned `Runner.app` zip (re-sign locally or add codesign secrets).

All jobs run on a `v*` tag (or manual dispatch); a single `publish` job
collects every artifact and attaches it to the Release.

## Relay server (mobile remote connect)

The phone connects through a small Go relay (`mobile/relay`). To host it for
free — Oracle Cloud always-free VPS, Cloudflare Tunnel, or a domestic cloud
trial — see the [deployment guide](mobile/relay/deploy/README.md) which
includes a Dockerfile, an auto-HTTPS Caddy reverse proxy, and a
docker-compose stack.

## Mobile app (iOS & Android)

The Flutter app in [`mobile/app/`](mobile/app/) turns a phone into a remote
monitor for the desktop's dsh UI — pair by scanning the desktop's QR
(`relay://` URL) or typing the device ID + 6-digit PIN, then connect through,
in order of preference:

1. **LAN direct** (`lan=` carried in the pairing QR): the phone loads the
   desktop's dsh web straight over Wi-Fi through the local proxy — no tunnel.
2. **WebRTC P2P**: a direct NAT-traversed data channel, signaled through the
   relay — the default when the desktop isn't on the same LAN.
3. **Relay tunnel**: everything (page, assets, `/api` RPC, event stream)
   bounces through the Go relay (`mobile/relay`) — always works as a fallback,
   and P2P falls back to it automatically when the channel closes.

If P2P's round-trips feel slower than the tunnel on your network, block it:
flip the **屏蔽 P2P 直连** (block P2P direct) switch on the home page, or tap
the connection chip at the top-right of the remote view (shows
"P2P 直连" / "中继隧道") and toggle it there — the active P2P channel is
dropped immediately, the session keeps running over the relay tunnel, and the
choice persists for later sessions.

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
├── linux/                    Linux shell (native C++ / GTK3 / WebKitGTK)
│   ├── CMakeLists.txt        CMake build (pkg-config: webkit2gtk-4.1, gtk+-3.0, libsoup-3.0)
│   ├── resources/
│   │   ├── deepseek-harness.svg      App icon (installed to hicolor)
│   │   └── deepseek-harness.desktop  Desktop entry for the .deb
│   └── src/
│       ├── main.cpp          main: settings, GTK init, main loop
│       ├── main_window.cpp   GTK window, menu bar (theme/language/full screen/plugins market),
│       │                     WebKitWebView wiring, external links, downloads, overlay
│       ├── settings.cpp      CLI/env parsing (mirrors macOS/Windows)
│       ├── server_manager.cpp  spawn dsh web (process group), port probe/poll, log files
│       ├── update_manager.cpp  npm registry version check (libsoup3)
│       ├── node_runtime_manager.cpp  auto-install Node.js LTS (download + tar.xz + PATH)
│       └── util.cpp          env, config dir, file helpers, version compare
├── mobile/                   Mobile remote app + relay + bridge
│   ├── app/                  Flutter app (iOS & Android): pairing, LAN/P2P/relay connect
│   ├── bridge/               Node bridge: desktop ↔ relay tunnel / WebRTC P2P
│   ├── relay/                Go relay server (deploy/ has Docker + Caddy + nginx)
│   └── p2p_probe/            Standalone WebRTC probe tool (development)
├── Info.plist                macOS bundle configuration
├── AppIcon.icns              macOS application icon (committed)
├── AppIcon.ico               Windows application icon (committed, embedded via `windows/resources.rc`)
├── CHANGELOG.md              Release notes (Keep a Changelog)
├── .github/workflows/
│   └── release.yml           CI: macOS DMG, Windows exe+MSI, Linux tarball+.deb, release
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
