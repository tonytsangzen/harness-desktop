# DeepSeek Harness Desktop

A native macOS wrapper for the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) browser UI. It launches `npx @deepseek-ai/dsh web` as a child process and displays the served page in a `WKWebView` window — no compilation of the harness project itself is required.

Licensed under the [MIT License](LICENSE).

| | |
| --- | --- |
| Bundle identifier | `com.deepvisus.harness-desktop` |
| Display name | DeepSeek Harness |
| Executable | `DSHWebView` |
| Minimum macOS | 13.0 |

## Requirements

- macOS 13+ (arm64)
- Xcode command-line tools (`swift`, `swift build`)
- Node.js 22+ and npm/npx (for `@deepseek-ai/dsh`)

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

1. Spawns `npx @deepseek-ai/dsh web --host 127.0.0.1 --port 3080`.
2. Polls `127.0.0.1:3080` until the server accepts connections (up to 180 s).
3. Loads `http://127.0.0.1:3080/` in the `WKWebView` and shows the window.
4. Terminates the child process when the last window closes.

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

## Project layout

```
.
├── build-app.sh              Build script: compiles and assembles the .app
├── Package.swift             SwiftPM manifest (executable target DSHWebView)
├── Info.plist                Bundle configuration (identifier, icon, metadata)
├── AppIcon.icns              Application icon (committed)
├── .github/workflows/
│   └── release.yml           CI: build, package DMG, and publish releases
├── scripts/
│   └── create-dmg.sh         DMG packaging script
└── Sources/DSHWebView/
    └── main.swift            Application entry point, server manager, webview window
```
