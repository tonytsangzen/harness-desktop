import AppKit
import WebKit
import IOKit
import Security
import SystemConfiguration

// MARK: - Configuration

/// The host dsh web binds by default.
private let defaultHost = "127.0.0.1"
/// The port dsh web binds by default.
private let defaultPort: UInt16 = 3080
/// How long to wait for the dsh web server to come up before giving up.
private let startupTimeoutSeconds: TimeInterval = 180
/// Retry interval when probing the server.
private let probeIntervalSeconds: TimeInterval = 0.25

// MARK: - Theme & language

/// The app's UI theme. `system` follows the OS light/dark appearance.
enum Theme: Int {
    case system = 0
    case light = 1
    case dark = 2
}

/// The menu language. `system` follows the OS locale (中文 / English).
enum AppLanguage: Int {
    case system = 0
    case zh = 1
    case en = 2

    /// Resolve `.system` to the concrete UI language from the OS preference.
    var resolved: AppLanguage {
        if self != .system { return self }
        let first = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return first.hasPrefix("zh") ? .zh : .en
    }
}

/// Localized labels for every menu item. Two languages (中文 / English);
/// which one is active follows the system by default and can be switched from
/// the View > Language menu.
struct MenuStrings {
    let checkForUpdates: String
    let quitFormat: String
    let about: String
    let aboutVersion: String
    let aboutEngine: String
    let aboutNode: String
    let aboutNotInstalled: String
    let edit: String
    let undo: String
    let redo: String
    let cut: String
    let copy: String
    let paste: String
    let selectAll: String
    let view: String
    let theme: String
    let followSystem: String
    let light: String
    let dark: String
    let language: String
    let enterFullScreen: String
    let exitFullScreen: String
    let help: String
    let pluginsMarket: String
    let pluginsManager: String
    let mobileRemote: String
    let mobileRemoteActive: String
    let mobileRemoteStop: String
    let mobileRemoteRelay: String
    let mobileRemoteCode: String
    let mobileRemoteHint: String
    let mobileRemoteConnecting: String
    let mobileRemoteWaiting: String
    let mobileRemoteConnected: String
    let mobileRemoteFailed: String
    let mobileRemoteNoApp: String
    let mobileRemoteGenerating: String
    let relayUnreachable: String
    let relayNotConfigured: String
    let settings: String
    let customRelay: String
    let relayHint: String
    let pairingPin: String

    static let english = MenuStrings(
        checkForUpdates: "Check for Updates…",
        quitFormat: "Quit %@",
        about: "About DeepSeek Harness",
        aboutVersion: "Version",
        aboutEngine: "Engine (dsh web)",
        aboutNode: "Node.js",
        aboutNotInstalled: "not installed",
        edit: "Edit",
        undo: "Undo",
        redo: "Redo",
        cut: "Cut",
        copy: "Copy",
        paste: "Paste",
        selectAll: "Select All",
        view: "View",
        theme: "Theme",
        followSystem: "Follow System",
        light: "Light",
        dark: "Dark",
        language: "Language",
        enterFullScreen: "Enter Full Screen",
        exitFullScreen: "Exit Full Screen",
        help: "Help",
        pluginsMarket: "Plugins Market…",
        pluginsManager: "Plugins…",
        mobileRemote: "Remote Connect…",
        mobileRemoteActive: "Connected.",
        mobileRemoteStop: "Disconnect",
        mobileRemoteRelay: "Relay address",
        mobileRemoteCode: "Device ID",
        mobileRemoteHint: "Scan the QR code in the Harness Remote app, or enter the pairing code and PIN manually.",
        mobileRemoteConnecting: "Connecting to relay server…",
        mobileRemoteWaiting: "Waiting for the Remote app to connect…",
        mobileRemoteConnected: "Remote app connected.",
        mobileRemoteFailed: "Remote Connect failed to start.",
        mobileRemoteNoApp: "No app connected yet.",
        mobileRemoteGenerating: "Generating QR code…",
        relayUnreachable: "Relay server unreachable. Check the relay address in Settings… and try again.",
        relayNotConfigured: "Relay address not configured. Set it in Settings… first, then use Remote Connect.",
        settings: "Settings…",
        customRelay: "Custom relay server address",
        relayHint: "The remote app connects to this machine through this cloud relay. Used by Remote Connect.",
        pairingPin: "Pairing PIN"
    )

    static let chinese = MenuStrings(
        checkForUpdates: "检查更新…",
        quitFormat: "退出 %@",
        about: "关于 DeepSeek Harness",
        aboutVersion: "版本",
        aboutEngine: "引擎（dsh web）",
        aboutNode: "Node.js",
        aboutNotInstalled: "未安装",
        edit: "编辑",
        undo: "撤销",
        redo: "重做",
        cut: "剪切",
        copy: "拷贝",
        paste: "粘贴",
        selectAll: "全选",
        view: "视图",
        theme: "主题",
        followSystem: "跟随系统",
        light: "明亮",
        dark: "暗黑",
        language: "语言",
        enterFullScreen: "进入全屏",
        exitFullScreen: "退出全屏",
        help: "帮助",
        pluginsMarket: "插件市场…",
        pluginsManager: "插件管理…",
        mobileRemote: "远程连接…",
        mobileRemoteActive: "已连接。",
        mobileRemoteStop: "断开",
        mobileRemoteRelay: "中继地址",
        mobileRemoteCode: "设备 ID",
        mobileRemoteHint: "在 Harness 远程 App 中扫描下方二维码；或手动输入设备 ID 与 PIN。",
        mobileRemoteConnecting: "正在连接中继服务器…",
        mobileRemoteWaiting: "等待远程 App 连接…",
        mobileRemoteConnected: "远程 App 已连接。",
        mobileRemoteFailed: "远程连接启动失败。",
        mobileRemoteNoApp: "尚未有 App 连接。",
        mobileRemoteGenerating: "正在生成二维码…",
        relayUnreachable: "中继服务器不可用。请检查「设置…」中的中继地址后重试。",
        relayNotConfigured: "尚未配置中继地址。请先在「设置…」中填写中继地址，再使用远程连接。",
        settings: "设置…",
        customRelay: "自定义中继服务器地址",
        relayHint: "远程 App 通过该云端中继连接本机。保存后「远程连接」使用此地址。",
        pairingPin: "配对 PIN"
    )

    static func forLanguage(_ language: AppLanguage) -> MenuStrings {
        language.resolved == .zh ? .chinese : .english
    }
}

// MARK: - Command-line parsing

/// Resolved runtime settings, derived from CLI arguments and the environment.
struct Settings {
    let host: String
    let port: UInt16
    let dshCommand: [String]
    let url: URL

    init(arguments: [String], environment: [String: String]) {
        let args = arguments.dropFirst()

        var host = defaultHost
        var port = defaultPort
        // --verbose (an npx/npm flag, before the package name) makes npx print
        // its install/resolution log to stdout; the shell captures it, shows
        // the last line on the loading screen, and resets the startup timeout
        // while output keeps arriving.
        var command = ["npx", "--yes", "--verbose", "@deepseek-ai/dsh", "web"]

        if let envHost = environment["DSH_WEBVIEW_HOST"], !envHost.isEmpty {
            host = envHost
        }
        if let envPort = environment["DSH_WEBVIEW_PORT"], let parsed = UInt16(envPort) {
            port = parsed
        }
        if let envCmd = environment["DSH_WEBVIEW_COMMAND"], !envCmd.isEmpty {
            command = envCmd.split(separator: " ").map(String.init)
        }

        var i = args.startIndex
        while i < args.endIndex {
            let arg = args[i]
            switch arg {
            case "--host":
                i = args.index(after: i)
                if i < args.endIndex { host = args[i] } else { fatalError("--host needs a value") }
            case "--port":
                i = args.index(after: i)
                if i < args.endIndex, let p = UInt16(args[i]) { port = p } else { fatalError("--port needs a numeric value") }
            case "--command":
                i = args.index(after: i)
                if i < args.endIndex { command = args[i].split(separator: " ").map(String.init) } else { fatalError("--command needs a value") }
            case "--plugins":
                // Debug hook: open the plugins manager window on launch.
                // Swallowed here so the launcher accepts the flag.
                break
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                fatalError("unknown argument: \(arg)\n\n\(usageText())")
            }
            i = args.index(after: i)
        }

        // Append the resolved host/port onto the dsh web invocation so the
        // server and the webview agree, unless the caller supplied a full
        // custom command (which we take at face value). --no-open stops the
        // engine from popping the default browser at startup (the shell's
        // own webview is the UI).
        if command == ["npx", "--yes", "--verbose", "@deepseek-ai/dsh", "web"] {
            command.append(contentsOf: ["--host", host, "--port", String(port), "--no-open"])
        }

        self.host = host
        self.port = port
        self.dshCommand = command
        self.url = URL(string: "http://\(host):\(port)/")!
    }
}

private func usageText() -> String {
    """
    Usage: DSHWebView [--host <host>] [--port <port>] [--command "<cmd>"] [--help]

    Wraps the DeepSeek Harness web UI (`npx --yes --verbose @deepseek-ai/dsh web`) in a native
    macOS WKWebView window.

      --host <host>      Host for the dsh web server (default: 127.0.0.1)
      --port <port>      Port for the dsh web server (default: 3080)
      --command "<cmd>"  Full command to launch dsh web (space-separated)
      --help             Show this help

    Environment:
      DSH_WEBVIEW_HOST      overrides the default host
      DSH_WEBVIEW_PORT      overrides the default port
      DSH_WEBVIEW_COMMAND   overrides the launch command
    """
}

private func printUsage() {
    FileHandle.standardError.write(Data(usageText().utf8))
}

// MARK: - Server process management

/// Launches `dsh web` as a child process and reports when its port is ready.
final class ServerManager {
    private let settings: Settings
    private var process: Process?
    private var probeTimer: Timer?
    private var reusingInstance = false

    /// The port actually used this launch (may differ from `settings.port` if
    /// that port was taken, in which case a free port was chosen automatically).
    private(set) var activePort: UInt16
    /// The URL the webview should load for this launch.
    var activeURL: URL { URL(string: "http://\(settings.host):\(activePort)/")! }

    /// Called with each chunk of the child's stdout/stderr. The startup screen
    /// uses it to show the latest log line and to reset the readiness timeout.
    var onLog: ((String) -> Void)?

    /// Guards `lastActivity` (the log handler runs on a background pipe queue,
    /// while `probe` runs on the main run loop).
    private let activityLock = NSLock()
    private var lastActivity = Date()

    init(settings: Settings) {
        self.settings = settings
        self.activePort = settings.port
    }

    /// Stamp the last-log/start activity timestamp.
    private func markActivity() {
        activityLock.lock()
        lastActivity = Date()
        activityLock.unlock()
    }

    /// Seconds since the last activity (start or log output).
    private func idleDuration() -> TimeInterval {
        activityLock.lock()
        defer { activityLock.unlock() }
        return Date().timeIntervalSince(lastActivity)
    }

    /// Spawn the server process. Streams its output to the app's stdout so
    /// logs stay observable from a terminal launch.
    func start() {
        // Reuse an already-running dsh instance on the preferred port (e.g. a
        // leftover from a previous launch or started by the user) instead of
        // spawning a second, empty instance — the remote app would connect to
        // that new instance and see no sessions.
        if looksLikeDshWeb(port: settings.port) {
            activePort = settings.port
            reusingInstance = true
            process = nil
            return
        }

        // Choose a port that is actually free, falling back to automatic
        // selection when the configured one is occupied by another process.
        activePort = resolveFreePort(startingAt: settings.port)

        let args = command(forPort: activePort)

        // Resolve node/npx to absolute paths so launch doesn't depend on the
        // minimal GUI PATH (which typically omits Homebrew and other dirs).
        // The spawned dsh web process also needs `node` on its PATH for nested
        // node invocations, so prepend the discovered bin dirs.
        let process = Process()
        var environment = ProcessInfo.processInfo.environment
        let first = args.first
        if first == "npx", let npxPath = NodeRuntimeManager.npxPath() {
            // Run npx by absolute path, dropping the bare `npx` argv[0].
            process.executableURL = URL(fileURLWithPath: npxPath)
            process.arguments = Array(args.dropFirst())
        } else {
            // Custom command (or npx not found): launch via env with PATH.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args
        }
        if let binDir = NodeRuntimeManager.binDirectoryFromNodePath() {
            let existing = environment["PATH"] ?? ""
            environment["PATH"] = "\(binDir):\(existing)"
        }
        // Never let npx block on its interactive "Ok to proceed? (y)" prompt
        // when the @deepseek-ai/dsh package needs installing on first launch
        // (a GUI app has no terminal to answer it, so the server would never
        // start and the webview would hang). Mirrors Windows/Linux shells.
        environment["npm_config_yes"] = "true"
        environment["npm_config_fund"] = "false"
        environment["npm_config_update_notifier"] = "false"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty {
                FileHandle.standardOutput.write(Data(text.utf8))
                self?.markActivity()
                self?.onLog?(text)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty {
                FileHandle.standardError.write(Data(text.utf8))
                self?.markActivity()
                self?.onLog?(text)
            }
        }

        process.terminationHandler = { [weak self] _ in
            self?.process = nil
        }

        self.process = process
        do {
            try process.run()
        } catch {
            fputs("DSHWebView: failed to launch dsh web: \(error)\n", stderr)
            exit(1)
        }
    }

    /// Probe the server until it accepts connections, calling `completion` on
    /// success or `failure` after the timeout elapses. The countdown resets
    /// whenever the child emits log output, so a slow-but-progressing startup
    /// (e.g. npx installing the dsh package) isn't killed by the timeout.
    func waitUntilReady(timeout: TimeInterval, completion: @escaping () -> Void, failure: @escaping () -> Void) {
        markActivity()
        probe(timeout: timeout, completion: completion, failure: failure)
    }

    private func probe(timeout: TimeInterval, completion: @escaping () -> Void, failure: @escaping () -> Void) {
        if self.process == nil && !self.reusingInstance {
            // The child already exited before we could connect.
            failure()
            return
        }
        if isPortOpen(host: settings.host, port: activePort) {
            completion()
            return
        }
        // No log output and no ready port for the whole timeout: stuck.
        if idleDuration() >= timeout {
            failure()
            return
        }
        probeTimer = Timer.scheduledTimer(withTimeInterval: probeIntervalSeconds, repeats: false) { [weak self] _ in
            self?.probe(timeout: timeout, completion: completion, failure: failure)
        }
    }

    private func isPortOpen(host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Find a free port to bind. If `startingAt` is available it is returned;
    /// otherwise ports are probed incrementally (avoiding the configured port
    /// staying blocked by another process).
    private func resolveFreePort(startingAt preferred: UInt16) -> UInt16 {
        var candidate = preferred
        for _ in 0..<512 {
            if !isPortOpen(host: settings.host, port: candidate) {
                return candidate
            }
            if candidate >= 49151 { candidate = 3080 } else { candidate += 1 }
        }
        // Should never happen; fall back to the preferred port and let the
        // server's own startup error surface if it still fails.
        return preferred
    }

    /// True when `http://host:port/` serves a web page — treated as an
    /// already-running dsh instance worth reusing.
    private func looksLikeDshWeb(port: UInt16) -> Bool {
        guard let url = URL(string: "http://\(settings.host):\(port)/") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, resp, _ in
            if let http = resp as? HTTPURLResponse,
               http.statusCode == 200,
               let type = http.allHeaderFields["Content-Type"] as? String,
               type.contains("text/html") {
                ok = true
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 2)
        return ok
    }

    /// Build the dsh web command for a specific port. If the configured command
    /// carries its own `--port <n>`, the value is replaced; commands without a
    /// `--port` are left as-is (custom commands are taken at face value).
    private func command(forPort port: UInt16) -> [String] {
        var args = settings.dshCommand
        for (i, a) in args.enumerated() where a == "--port" && i + 1 < args.count {
            args[i + 1] = String(port)
            return args
        }
        return args
    }

    /// Terminate the child process tree on app quit.
    func stop() {
        probeTimer?.invalidate()
        probeTimer = nil
        process?.interrupt()
        process?.terminate()
        process = nil
    }
}

// MARK: - Window and WebView

/// A WKWebView subclass that routes standard macOS editing shortcuts
/// (Cmd+C/X/V/A) to the web content via JavaScript when the platform's
/// default responder-chain handling does not apply to focused web elements.
final class ShortcutWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else {
            return super.performKeyEquivalent(with: event)
        }

        switch characters {
        case "x":
            evaluateJavaScript("document.execCommand('cut')", completionHandler: nil)
            return true
        case "c":
            evaluateJavaScript("document.execCommand('copy')", completionHandler: nil)
            return true
        case "a":
            evaluateJavaScript("document.execCommand('selectAll')", completionHandler: nil)
            return true
        case "v":
            pasteFromPasteboard()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// Paste the system clipboard text directly into the focused web element,
    /// bypassing WebKit's clipboard-permission round-trip so a single Cmd+V
    /// suffices.
    private func pasteFromPasteboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            // No text on the clipboard; fall back to the web's own paste.
            evaluateJavaScript("document.execCommand('paste')", completionHandler: nil)
            return
        }

        let script = """
        (() => {
            const text = \(Self.jsStringLiteral(text));
            const el = document.activeElement;
            if (el && (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT')) {
                const start = el.selectionStart ?? el.value.length;
                const end = el.selectionEnd ?? el.value.length;
                const next = el.value.slice(0, start) + text + el.value.slice(end);

                // Use the native value setter so React's value tracker sees the
                // change (React overrides the `value` property on the instance,
                // which would otherwise swallow a plain `el.value = ...`).
                const proto = el.tagName === 'TEXTAREA'
                    ? HTMLTextAreaElement.prototype
                    : HTMLInputElement.prototype;
                const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
                setter.call(el, next);

                // Set cursor position after the inserted text.
                const pos = start + text.length;
                try {
                    el.setSelectionRange(pos, pos);
                } catch (_) {}

                // Notify React via the `input` event it listens for.
                el.dispatchEvent(new Event('input', { bubbles: true }));
                return true;
            }
            if (el && el.isContentEditable) {
                document.execCommand('insertText', false, text);
                return true;
            }
            return false;
        })();
        """
        evaluateJavaScript(script, completionHandler: nil)
    }

    /// Render a Swift String as a JavaScript string literal (wrapped in double
    /// quotes, with all characters that would break the literal escaped).
    private static func jsStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(escaped)\""
    }
}

// MARK: - Mobile remote (bridge to the phone app)

/// Spawns the mobile relay bridge (`mobile/bridge/bridge.mjs`) and surfaces
/// pairing info (hostId / PIN) for the "Remote Connect" flow. The shell
/// generates the pairing QR code itself (relay host + device ID); the bridge
/// keeps running until stopped; stdout is line-delimited JSON.
final class MobileRemoteManager {
    struct Pairing {
        let hostId: String
        let hostToken: String
        let pin: String
        let pinExpiresAt: Int64
    }

    let nodePath: String
    let bridgePath: URL
    let relayURL: String
    let deviceID: String
    let dshPort: UInt16

    private var process: Process?
    private var stdoutBuffer = Data()
    private(set) var isRunning = false
    private var stopping = false
    private var restartWork: DispatchWorkItem?
    private var restartDelay = 2.0

    /// Called on the main thread once the relay acknowledged registration.
    var onRegistered: ((Pairing) -> Void)?
    /// Called on the main thread when the bridge exits (incl. stop()).
    var onExit: (() -> Void)?
    /// When true, an unexpected bridge exit is followed by a delayed re-spawn
    /// (exponential backoff) so the host re-registers with the relay — used
    /// while the Remote Connect toggle is on.
    var autoRestart = false

    init(nodePath: String, bridgePath: URL, relayURL: String, deviceID: String, dshPort: UInt16) {
        self.nodePath = nodePath
        self.bridgePath = bridgePath
        self.relayURL = relayURL
        self.deviceID = deviceID
        self.dshPort = dshPort
    }

    func start() {
        guard !isRunning else { return }
        restartDelay = 2.0
        guard FileManager.default.isExecutableFile(atPath: nodePath),
              FileManager.default.fileExists(atPath: bridgePath.path) else {
            DispatchQueue.main.async { self.onExit?() }
            return
        }
        let p = Process()
        var args = [bridgePath.path, "--relay", relayURL, "--dsh-port", "\(dshPort)",
                    "--device-id", deviceID, "--pin", StablePairingPin()]
        // Persisted hostToken lets a bridge restart reconnect by token instead
        // of re-registering — the relay refuses anonymous re-registration of an
        // existing hostId (hijack protection).
        if let tok = UserDefaults.standard.string(forKey: "mobileHostToken"), !tok.isEmpty {
            args += ["--host-token", tok]
        }
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = FileHandle.nullDevice
        let pipe = p.standardOutput as! Pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard data.count > 0 else { return }
            self?.consume(data)
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRunning = false
                self.onExit?()
                // Unexpected exit while auto-restart is armed: re-register
                // with the relay after a short backoff.
                if self.autoRestart && !self.stopping {
                    self.scheduleRestart()
                }
            }
        }
        process = p
        isRunning = true
        do {
            try p.run()
        } catch {
            isRunning = false
            DispatchQueue.main.async { self.onExit?() }
        }
    }

    func stop() {
        stopping = true
        restartWork?.cancel()
        restartWork = nil
        guard let p = process, p.isRunning else { return }
        p.terminate()
    }

    /// Re-spawn the bridge after a growing delay (2s → 30s cap) so an
    /// intermittent failure doesn't hammer the relay.
    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.autoRestart, !self.stopping else { return }
            self.start()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay, execute: work)
        restartDelay = min(restartDelay * 2, 30)
    }

    /// Read handler runs on a background thread; parse whole lines and bounce
    /// recognized events to the main thread.
    private func consume(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer[..<nl]
            stdoutBuffer.removeSubrange(...nl)
            guard let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
                  !text.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                continue
            }
            DispatchQueue.main.async { [weak self] in self?.handleEvent(json) }
        }
    }

    private func handleEvent(_ json: [String: Any]) {
        switch json["event"] as? String {
        case "registered":
            guard let hostId = json["hostId"] as? String,
                  let hostToken = json["hostToken"] as? String,
                  let pin = json["pin"] as? String else { return }
            // Persist the token so the next bridge start reconnects by token.
            UserDefaults.standard.set(hostToken, forKey: "mobileHostToken")
            onRegistered?(Pairing(
                hostId: hostId,
                hostToken: hostToken,
                pin: pin,
                pinExpiresAt: (json["pinExpiresAt"] as? NSNumber)?.int64Value ?? 0
            ))
        case "online":
            break // bridge reconnected; pairing window already shown
        case "offline":
            break
        default:
            break
        }
    }
}

// MARK: - Device ID + pairing QR (shell-generated)

/// Stable pairing PIN: generated randomly on first launch, then kept in
/// UserDefaults until the user changes it in Settings…
func StablePairingPin() -> String {
    let key = "mobilePairingPin"
    if let existing = UserDefaults.standard.string(forKey: key),
       existing.count == 6, existing.allSatisfy({ $0.isNumber }), !isWeakPin(existing) {
        return existing
    }
    var pin: String
    repeat {
        pin = String((0..<6).map { _ in "0123456789".randomElement()! })
    } while isWeakPin(pin)
    UserDefaults.standard.set(pin, forKey: key)
    return pin
}

/// True for trivially guessable 6-digit PINs: all-same digits, ascending /
/// descending runs, and common defaults. Mirrors the relay's WeakPin check.
func isWeakPin(_ pin: String) -> Bool {
    guard pin.count == 6, pin.allSatisfy({ $0.isNumber }) else { return true }
    if pin.allSatisfy({ $0 == pin.first! }) { return true }
    let digits = pin.map { $0.wholeNumberValue! }
    var asc = true, desc = true
    for i in 1..<6 {
        if digits[i] != digits[i - 1] + 1 { asc = false }
        if digits[i] != digits[i - 1] - 1 { desc = false }
    }
    if asc || desc { return true }
    return ["123123", "112233", "121212", "111222", "000001", "123321"].contains(pin)
}

/// High-entropy device ID (32 random bytes, hex) used as the host ID on the
/// relay. Random and persisted, so it is stable across launches but cannot be
/// guessed or derived from device info — the previous 13-digit hash of
/// hostname+UUID was predictable from public machine info, which would let an
/// attacker who learns a victim's hostId hijack the host registration.
func DeviceID() -> String {
    let key = "mobileDeviceId"
    if let existing = UserDefaults.standard.string(forKey: key), existing.hasPrefix("h_"), existing.count == 66 {
        return existing
    }
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess {
        // Extremely unlikely; fall back to a time-seeded value rather than crash.
        return "h_" + String(format: "%016llx", UInt64(Date().timeIntervalSince1970 * 1000))
    }
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    let id = "h_" + hex
    UserDefaults.standard.set(id, forKey: key)
    return id
}

/// The pairing QR content: relay host + device ID, plus the relay's own
/// scheme (http for plaintext test relays, https otherwise) so the phone
/// connects with a matching protocol. `lanAddress` (e.g. "192.168.1.5:3080")
/// lets the phone prefer a direct LAN connection to this desktop's dsh web
/// and only fall back to the cloud relay when it can't reach it.
func PairingQRContent(relayURL: String, deviceID: String, lanAddress: String?) -> String {
    var host = relayURL
    var scheme = "https"
    if let url = URL(string: relayURL) {
        scheme = url.scheme ?? "https"
        host = url.host ?? ""
        if let port = url.port { host += ":\(port)" }
    }
    var qr = "relay://\(host)/pair?device=\(deviceID)&scheme=\(scheme)"
    if let lan = lanAddress { qr += "&lan=\(lan)" }
    return qr
}

/// The interface name that carries the default route (e.g. "en0"), read from
/// SystemConfiguration. Used to prefer the real Wi-Fi/Ethernet adapter over a
/// VM host-only / bridge address (bridge102, vmenet*, utun*, …) that the phone
/// cannot reach.
private func primaryInterfaceName() -> String? {
    guard let store = SCDynamicStoreCreate(nil, "DSHWebView" as CFString, nil, nil),
          let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
          let name = global["PrimaryInterface"] as? String else {
        return nil
    }
    return name
}

/// Best-effort LAN IPv4 for direct phone connect: the default-route interface
/// first, otherwise the first non-loopback, non-point-to-point private address
/// (192.168.* preferred).
func LocalLANAddress() -> String? {
    let primary = primaryInterfaceName()
    var fallback: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    defer { freeifaddrs(ifaddr) }
    var cursor = ifaddr
    while let ptr = cursor {
        let interface = ptr.pointee
        if let name = interface.ifa_name,
           interface.ifa_addr != nil && interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
            let flags = Int32(interface.ifa_flags)
            let usable = (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0 && (flags & IFF_POINTOPOINT) == 0
            if usable {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let saLen = socklen_t(interface.ifa_addr.pointee.sa_len)
                if getnameinfo(interface.ifa_addr, saLen, &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    let isPrivate = ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.")
                    if isPrivate {
                        if let p = primary, String(cString: name) == p { return ip }
                        if fallback == nil {
                            fallback = ip
                        } else if ip.hasPrefix("192.168.") && !fallback!.hasPrefix("192.168.") {
                            fallback = ip
                        }
                    }
                }
            }
        }
        cursor = ptr.pointee.ifa_next
    }
    return fallback
}

/// Renders a QR code as PNG data using CoreImage (CIQRCodeGenerator).
func GenerateQRPNG(content: String) -> Data? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    let data = Data(content.utf8)
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    // Scale up so the QR is crisp when displayed at 240pt.
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
    return png
}

// MARK: - Node.js runtime provisioning

/// Detects Node.js/npx and, when missing, downloads the official macOS .pkg
/// installer and installs it, reporting progress and completion. The app needs
/// Node at runtime to spawn `npx @deepseek-ai/dsh web`.
final class NodeRuntimeManager: NSObject {
    enum State: Equatable {
        case checking
        case downloading(Double)   // 0…1 progress
        case installing
        case done
        case failed(String)
    }

    private var downloadTask: URLSessionDownloadTask?
    private var dataTask: URLSessionDataTask?
    private var downloadData = Data()
    private var downloadFileURL: URL?
    private var session: URLSession!
    private var observations: [ObjectIdentifier: (State) -> Void] = [:]
    private var state: State = .checking { didSet { if state != oldValue { notify(state) } } }

    // Data-task state for accurate download progress.
    private var receivedBytes: Int64 = 0
    private var expectedBytes: Int64 = -1 {
        didSet { updateDownloadProgress() }
    }

    private(set) var nodeIsAvailable = false

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Download mirror selection

    /// The base URL for the Node.js dist (mirror chosen by the user's timezone
    /// so users in China hit the faster npmmirror CDN instead of nodejs.org).
    static var distBase: String {
        if isMainlandChinaTimeZone() {
            return "https://registry.npmmirror.com/-/binary/node"
        }
        return "https://nodejs.org/dist"
    }

    /// Heuristic: treat UTC+08:00 (±30 min) as mainland China for mirroring.
    private static func isMainlandChinaTimeZone() -> Bool {
        let seconds = TimeZone.current.secondsFromGMT()
        let hours = Double(seconds) / 3600.0
        return hours >= 7.5 && hours <= 8.5
    }

    /// The official Node.js pkg download URL for the current macOS arch.
    static func downloadURL(forVersion version: String) -> URL? {
        // node-<version>.pkg exists on all mirrors; the .pkg installer itself
        // is universal (works for both arm64 and x64).
        return URL(string: "\(distBase)/\(version)/node-\(version).pkg")
    }

    /// Resolve the latest LTS version from the Node.js dist index; falls back
    /// to a pinned version on any error.
    static func resolveLatestLTS() -> String {
        let fallback = "v22.14.0"
        guard let url = URL(string: "\(distBase)/index.json") else { return fallback }
        let sem = DispatchSemaphore(value: 0)
        var result = fallback
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            defer { sem.signal() }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            for entry in json {
                if let lts = entry["lts"] as? String, lts != "false", !lts.isEmpty,
                   let version = entry["version"] as? String {
                    result = version
                    break
                }
            }
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 10)
        return result
    }

    /// Detect whether `node` and `npx` are both available. Because a GUI
    /// app's `PATH` is a minimal system default (it misses Homebrew and other
    /// user paths), the search also probes common Node installation locations
    /// directly instead of relying on `which` alone.
    static func runtimeAvailable() -> Bool {
        nodePath() != nil && npxPath() != nil
    }

    // MARK: Cached binary discovery

    /// Cached results so repeated lookups (runtime check + child-process PATH
    /// wiring) do not re-spawn `/usr/bin/which` or re-walk candidate dirs on
    /// every call — this is the main source of slow app startup.
    private static let lookupLock = NSLock()
    private static var cachedNodePath: String??
    private static var cachedNpxPath: String??

    /// Common locations of the `node` binary outside the default GUI PATH.
    private static var binaryCandidateDirs: [String] {
        let home = NSHomeDirectory()
        var dirs: [String] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "\(home)/.local/bin",
            "\(home)/.volta/bin",
            "\(home)/.fnm/aliases/default/bin",
        ]
        // nvm keeps versioned dirs; add the newest first.
        let nvmVersions = "\(home)/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmVersions) {
            dirs += entries.sorted().reversed().map { "\(nvmVersions)/\($0)/bin" }
        }
        return dirs
    }

    /// First found path to the `node` binary, or nil if none exists.
    static func nodePath() -> String? {
        lookupLock.lock()
        if let cached = cachedNodePath { let v = cached; lookupLock.unlock(); return v }
        lookupLock.unlock()

        let result = findExecutable(named: "node") ?? binaryCandidateDirs
            .lazy
            .map { "\($0)/node" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }

        lookupLock.lock()
        cachedNodePath = result
        lookupLock.unlock()
        return result
    }

    /// First found path to the `npx` binary, or nil if none exists.
    static func npxPath() -> String? {
        lookupLock.lock()
        if let cached = cachedNpxPath { let v = cached; lookupLock.unlock(); return v }
        lookupLock.unlock()

        let result = findExecutable(named: "npx") ?? binaryCandidateDirs
            .lazy
            .map { "\($0)/npx" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }

        lookupLock.lock()
        cachedNpxPath = result
        lookupLock.unlock()
        return result
    }

    /// Directory containing the discovered `node` binary, used to prepend to a
    /// child process's `PATH` so nested `node`/`npx` invocations resolve.
    static func binDirectoryFromNodePath() -> String? {
        guard let node = nodePath() else { return nil }
        return (node as NSString).deletingLastPathComponent
    }

    /// `node --version` output (e.g. "v24.10.0"), or nil if node is missing.
    static func nodeVersion() -> String? {
        guard let node = nodePath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let version = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus == 0 && !(version?.isEmpty ?? true)) ? version : nil
    }

    private static func findExecutable(named name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false && process.terminationStatus == 0) ? path : nil
    }

    /// Subscribe to state changes. Returns a token for later removal.
    func observe(_ handler: @escaping (State) -> Void) -> ObjectIdentifier {
        let token = ObjectIdentifier(UUID() as NSUUID)
        observations[token] = handler
        handler(state)
        return token
    }

    func removeObservation(_ token: ObjectIdentifier) {
        observations.removeValue(forKey: token)
    }

    private func notify(_ state: State) {
        DispatchQueue.main.async { [weak self] in
            self?.observations.values.forEach { $0(state) }
        }
    }

    /// Begin provisioning: if Node is already present, completes immediately;
    /// otherwise download then install the official pkg.
    /// `completion` is called on the main thread with `(ok, errorMessage)`.
    func provide(completion: @escaping (Bool, String?) -> Void) {
        if Self.runtimeAvailable() {
            nodeIsAvailable = true
            state = .done
            completion(true, nil)
            return
        }

        let version = Self.resolveLatestLTS()
        guard let url = Self.downloadURL(forVersion: version) else {
            finishFailure("unsupported architecture", completion: completion)
            return
        }

        receivedBytes = 0
        expectedBytes = -1
        downloadData = Data()
        state = .downloading(0)

        // Use a data task so `expectedContentLength` from the HTTP response
        // (not the often-unknown download-task total) drives an accurate bar.
        dataTask = session.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                self.finishFailure("download failed: \(error.localizedDescription)", completion: completion)
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                self.finishFailure("download failed: HTTP \(code)", completion: completion)
                return
            }
            guard let data = data, !data.isEmpty else {
                self.finishFailure("download failed: empty file", completion: completion)
                return
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("node-installer-\(UUID().uuidString).pkg")
            do {
                try data.write(to: tmp)
            } catch {
                self.finishFailure("download failed: could not save file", completion: completion)
                return
            }
            self.install(from: tmp, completion: completion)
        }
        dataTask?.resume()
    }

    private func updateDownloadProgress() {
        guard case .downloading = state else { return }
        if expectedBytes > 0 {
            let fraction = Double(receivedBytes) / Double(expectedBytes)
            state = .downloading(min(max(fraction, 0), 1))
        } else {
            // Unknown total: show an indeterminate-but-moving indicator.
            state = .downloading(-1)
        }
    }

    private func install(from tempURL: URL, completion: @escaping (Bool, String?) -> Void) {
        state = .installing

        // `installer` requires root; this triggers the system auth prompt.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/installer")
        process.arguments = ["-pkg", tempURL.path, "-target", "/"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            finishFailure("installer failed to launch: \(error.localizedDescription)", completion: completion)
            return
        }

        // Refresh the process environment so PATH sees the newly installed node.
        if process.terminationStatus == 0 || Self.runtimeAvailable() {
            nodeIsAvailable = true
            state = .done
            completion(true, nil)
        } else {
            let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            finishFailure("installer exited \(process.terminationStatus): \(output.prefix(200))", completion: completion)
        }
    }

    private func finishFailure(_ message: String, completion: @escaping (Bool, String?) -> Void) {
        state = .failed(message)
        completion(false, message)
    }

    func cancel() {
        downloadTask?.cancel()
        dataTask?.cancel()
        downloadTask = nil
        dataTask = nil
        if case .downloading = state {
            state = .failed("cancelled")
        }
    }
}

extension NodeRuntimeManager: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            self.expectedBytes = http.expectedContentLength
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        downloadData.append(data)
        receivedBytes = Int64(downloadData.count)
        updateDownloadProgress()
    }
}

// MARK: - dsh version checking & update

/// Checks the locally-cached `@deepseek-ai/dsh` version against the npm
/// registry and (on demand) refreshes the npx cache + restarts the server.
final class DSHUpdateManager {
    private let packageSpec = "@deepseek-ai/dsh"

    /// Version of the locally cached package, or nil if not yet cached.
    var localVersion: String? {
        guard let packageJSON = locateLocalPackageJSON() else { return nil }
        let data = (try? Data(contentsOf: packageJSON)) ?? Data()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["version"] as? String else { return nil }
        return version
    }

    /// Query the npm registry for the latest published version.
    /// Completion is `(version, errorMessage)`; exactly one is non-nil.
    func fetchLatestVersion(completion: @escaping (String?, String?) -> Void) {
        guard let url = URL(string: "https://registry.npmjs.org/\(packageSpec)/latest") else {
            completion(nil, "bad registry URL")
            return
        }
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                completion(nil, error.localizedDescription)
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = obj["version"] as? String else {
                completion(nil, "could not read registry response")
                return
            }
            completion(version, nil)
        }
        task.resume()
    }

    /// Whether an update is available (local version precedes the latest).
    func updateAvailable(completion: @escaping (Bool, String?) -> Void) {
        guard let local = localVersion else {
            completion(false, nil)
            return
        }
        fetchLatestVersion { latest, error in
            if let latest = latest {
                completion(latest != local, latest)
            } else {
                completion(false, nil)
            }
        }
    }

    /// Refresh the npx cache so the next `npx @deepseek-ai/dsh` resolves the
    /// latest version, then report completion.
    func refreshToLatest(completion: @escaping (Bool, String?) -> Void) {
        // `npm cache clean` is too aggressive; instead clear the npx cache for
        // this package and let npx re-install the latest on next invocation.
        clearNpxCache(for: packageSpec)

        // Pre-fetch so the subsequent server restart is fast.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "--yes", "\(packageSpec)@latest", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { proc in
            if proc.terminationStatus == 0 {
                completion(true, nil)
            } else {
                let out = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                completion(false, out.isEmpty ? "npx exited \(proc.terminationStatus)" : out)
            }
        }
        do {
            try process.run()
        } catch {
            completion(false, error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func locateLocalPackageJSON() -> URL? {
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".npm/_npx", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return nil
        }
        // Each npx run gets a hashed dir; find the first with our package.
        for dir in entries {
            let candidate = dir
                .appendingPathComponent("node_modules/\(packageSpec)/package.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func clearNpxCache(for packageSpec: String) {
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".npm/_npx", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return
        }
        for dir in entries {
            let pkgDir = dir.appendingPathComponent("node_modules/\(packageSpec)")
            if FileManager.default.fileExists(atPath: pkgDir.path) {
                try? FileManager.default.removeItem(at: pkgDir)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKDownloadDelegate, WKScriptMessageHandler, NSWindowDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private let settings: Settings
    private let server: ServerManager
    private let runtimeManager = NodeRuntimeManager()
    private var runtimeToken: ObjectIdentifier?
    private var setupWindow: NSWindow?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var pendingSuggestedFilename: String?
    private var pendingDownloadDestination: URL?
    private var downloadBar: NSProgressIndicator?
    private var downloadLabel: NSTextField?
    private var downloadBarContainer: NSView?
    private var activeDownloads: [WKDownload: NSKeyValueObservation] = [:]
    private var nativeDownloadObservation: NSKeyValueObservation?
    private var loadingOverlay: NSView?
    private var loadingLogLabel: NSTextField?
    /// Rolling tail of the server's stdout/stderr; the startup screen shows
    /// only its last line ("text after the last \n").
    private var pendingLogTail = ""
    private let updateManager = DSHUpdateManager()
    private var updateCheckInFlight = false
    private var pluginsController: PluginsWindowController?
    private var mobileRemote: MobileRemoteManager?
    private var relayPanel: NSPanel?
    private var relayField: NSTextField?
    private var relayHintRef: NSTextField?
    private var customRelaySwitchRef: NSSwitch?
    private var relayPinField: NSTextField?
    private var remoteSwitchRef: NSSwitch?
    private var remoteInfoView: NSStackView?
    private var remoteQrView: NSImageView?
    private var remoteCodeLabel: NSTextField?
    private var remoteRelayLabel: NSTextField?
    private var remoteStatusLabel: NSTextField?
    private var remotePollTimer: Timer?
    private var lastPairing: MobileRemoteManager.Pairing?
    private var lastQrPNG: Data?

    // MARK: Theme & language preferences (persisted in UserDefaults)

    private var preferredTheme: Theme {
        get { Theme(rawValue: UserDefaults.standard.integer(forKey: "appTheme")) ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "appTheme") }
    }

    private var preferredLanguage: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.integer(forKey: "appLanguage")) ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "appLanguage") }
    }

    /// The menu strings for the currently effective language.
    private var uiStrings: MenuStrings { MenuStrings.forLanguage(preferredLanguage) }

    /// Apply the stored theme to the app, the window, and the webview so the
    /// native chrome and the web content's prefers-color-scheme follow it.
    private func applyTheme() {
        let appearance: NSAppearance?
        switch preferredTheme {
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        case .system: appearance = nil
        }
        NSApp.appearance = appearance
        window?.appearance = appearance
        webView?.appearance = appearance
    }

    /// A checkable menu item used for radio groups (theme / language).
    private func radioItem(_ title: String, action: Selector, tag: Int, selected: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.tag = tag
        item.state = selected ? .on : .off
        return item
    }

    /// Menu action: switch the UI theme.
    @objc private func setTheme(_ sender: NSMenuItem) {
        preferredTheme = Theme(rawValue: sender.tag) ?? .system
        applyTheme()
        buildMenu()
    }

    /// Menu action: switch the menu language.
    @objc private func setLanguage(_ sender: NSMenuItem) {
        preferredLanguage = AppLanguage(rawValue: sender.tag) ?? .system
        buildMenu()
    }

    init(settings: Settings) {
        self.settings = settings
        self.server = ServerManager(settings: settings)
        super.init()
        // Feed the server's stdout/stderr into the loading screen (last line
        // only). Also reset by ServerManager the readiness timeout per output.
        self.server.onLog = { [weak self] text in
            self?.handleServerLog(text)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyTheme()
        buildMenu()
        buildWindow()
        // The first applyTheme() ran before the window/webView existed, so
        // their appearance was never set; propagate the theme again now that
        // they exist (otherwise the whole window — including the loading
        // overlay — renders with the system appearance instead of the app's).
        applyTheme()
        ensureNodeRuntime()
        // Debug/demo hook: `DSHWebView --plugins` opens the plugins manager
        // window right away (also used by the smoke test).
        if CommandLine.arguments.contains("--plugins") {
            openPluginsManager(nil)
        }
    }

    // MARK: - Runtime provisioning

    /// Ensure Node.js is available before starting the dsh server. Missing
    /// runtime shows a progress window while downloading/installing.
    private func ensureNodeRuntime() {
        // Fast path: already installed.
        if NodeRuntimeManager.runtimeAvailable() {
            startMainUI()
            return
        }

        showSetupWindow()

        runtimeToken = runtimeManager.observe { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .checking:
                self.setStatus("Checking for Node.js…")
            case .downloading(let fraction):
                if fraction < 0 {
                    // Unknown total size: show indeterminate spinner.
                    self.setStatus("Downloading Node.js…")
                    self.progressBar?.isIndeterminate = true
                    self.progressBar?.startAnimation(nil)
                } else {
                    self.progressBar?.isIndeterminate = false
                    self.progressBar?.stopAnimation(nil)
                    self.progressBar?.doubleValue = fraction * 100
                    self.setStatus(String(format: "Downloading Node.js… %.0f%%", fraction * 100))
                }
            case .installing:
                self.setStatus("Installing Node.js… (you may be prompted for your password)")
                self.progressBar?.isIndeterminate = true
                self.progressBar?.startAnimation(nil)
            case .done:
                self.closeSetupWindow()
                self.startMainUI()
            case .failed(let message):
                self.setupFailed(message)
            }
        }

        runtimeManager.provide { [weak self] ok, _ in
            // Failure is surfaced through the state observation above; success
            // also arrives via the .done state. Nothing extra to do here.
            _ = self
            _ = ok
        }
    }

    private func showSetupWindow() {
        let rect = NSRect(x: 0, y: 0, width: 420, height: 140)
        let win = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "DeepSeek Harness"
        win.isReleasedWhenClosed = false
        win.center()

        let content = NSView(frame: rect)

        let label = NSTextField(labelWithString: "Preparing runtime…")
        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        label.frame = NSRect(x: 20, y: 100, width: 380, height: 24)
        content.addSubview(label)
        statusLabel = label

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 60, width: 380, height: 20))
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        bar.doubleValue = 0
        bar.style = .bar
        content.addSubview(bar)
        progressBar = bar

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSetup))
        cancel.frame = NSRect(x: 20, y: 20, width: 100, height: 28)
        content.addSubview(cancel)

        win.contentView = content
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow = win
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel?.stringValue = text
        }
    }

    private func closeSetupWindow() {
        DispatchQueue.main.async { [weak self] in
            self?.setupWindow?.close()
            self?.setupWindow = nil
            if let token = self?.runtimeToken {
                self?.runtimeManager.removeObservation(token)
            }
        }
    }

    @objc private func cancelSetup() {
        runtimeManager.cancel()
        closeSetupWindow()
        NSApp.terminate(nil)
    }

    private func setupFailed(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.closeSetupWindow()
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Runtime installation failed"
            alert.informativeText = "Could not install Node.js, which is required to run DeepSeek Harness.\n\n\(message)\n\nInstall Node.js 22+ manually, then relaunch."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func startMainUI() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let rect = NSRect(x: 0, y: 0, width: 1200, height: 800)
            let win = NSWindow(
                contentRect: rect,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "DeepSeek Harness"
            win.center()

            // Container: webView fills the window, with a download progress
            // bar overlaid at the bottom (hidden until a download starts).
            let container = NSView(frame: rect)
            self.webView.frame = container.bounds
            self.webView.autoresizingMask = [.width, .height]
            container.addSubview(self.webView)

            let barContainer = NSView(frame: NSRect(x: 0, y: 0, width: rect.width, height: 32))
            barContainer.autoresizingMask = [.width]
            barContainer.wantsLayer = true
            barContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

            let bar = NSProgressIndicator(frame: NSRect(x: 12, y: 12, width: rect.width - 24, height: 14))
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 100
            bar.doubleValue = 0
            bar.style = .bar
            bar.autoresizingMask = [.width]
            barContainer.addSubview(bar)
            self.downloadBar = bar

            let label = NSTextField(labelWithString: "")
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 12, y: 0, width: rect.width - 24, height: 12)
            label.autoresizingMask = [.width]
            label.lineBreakMode = .byTruncatingTail
            barContainer.addSubview(label)
            self.downloadLabel = label

            // Pin barContainer to the bottom of the container.
            barContainer.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(barContainer)
            NSLayoutConstraint.activate([
                barContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                barContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                barContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                barContainer.heightAnchor.constraint(equalToConstant: 32),
            ])
            self.downloadBarContainer = barContainer
            barContainer.isHidden = true

            win.contentView = container
            win.makeKeyAndOrderFront(nil)
            self.window = win
            NSApp.activate(ignoringOtherApps: true)

            // Re-apply the theme now that the window/webview exist so the web
            // content's prefers-color-scheme and the native chrome match.
            self.applyTheme()

            // Show a loading overlay over the (still-empty) webview so the
            // user isn't staring at a blank window while the server starts.
            self.showLoadingOverlay(over: container)

            self.server.start()
            self.server.waitUntilReady(timeout: startupTimeoutSeconds, completion: { [weak self] in
                DispatchQueue.main.async {
                    self?.loadUI()
                    self?.autoCheckForUpdates()
                    // Auto-start the remote bridge when the toggle was left on.
                    if UserDefaults.standard.bool(forKey: "mobileRemoteEnabled") {
                        self?.startMobileBridge(silent: true)
                    }
                }
            }, failure: { [weak self] in
                DispatchQueue.main.async {
                    self?.dismissLoadingOverlay()
                    self?.showError("DeepSeek Harness server did not start within \(Int(startupTimeoutSeconds)) seconds.")
                }
            })
        }
    }

    private func buildWindow() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        // Inject a script that intercepts programmatic <a download> clicks
        // (which WebKit does not reliably deliver as navigation downloads) and
        // forwards them to native for a URLSession-based download.
        let contentController = WKUserContentController()
        contentController.add(self, name: "download")
        contentController.addUserScript(WKUserScript(
            source: Self.downloadInterceptorScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        config.userContentController = contentController

        let webView = ShortcutWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView
    }

    /// JavaScript that hooks <a download> clicks and posts them to native via
    /// webkit.messageHandlers.download.
    private static let downloadInterceptorScript = """
    (() => {
        const originalClick = HTMLAnchorElement.prototype.click;
        HTMLAnchorElement.prototype.click = function () {
            const href = this.href || this.getAttribute('href');
            const download = this.download || this.getAttribute('download');
            if (download !== undefined && download !== null && download !== '' && href) {
                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.download) {
                        window.webkit.messageHandlers.download.postMessage({
                            url: href,
                            filename: download || ''
                        });
                        return;
                    }
                } catch (e) {}
            }
            return originalClick.call(this);
        };
    })();
    """

    // MARK: - Web download support

    /// Intercept navigation actions: anything that isn't served by the local
    /// dsh server (external links, target="_blank" / window.open requests) is
    /// handed to the system default browser instead of navigating the webview
    /// away from the harness UI. Downloads are routed to WKDownload as before.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        NSLog("DSHWebView navigationAction: url=%@ shouldPerformDownload=%@",
              url?.absoluteString ?? "nil",
              String(describing: navigationAction.shouldPerformDownload))

        // External URLs open in the default browser. New-window navigations
        // (targetFrame == nil) are caught here as a fallback for cases the
        // WKUIDelegate.createWebViewWith path does not cover.
        if let url = url, !isAppURL(url) {
            openInDefaultBrowser(url)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            return
        }

        // macOS 11+: WKNavigationAction.shouldPerformDownload is set when the
        // web content asks the browser to download rather than navigate.
        if #available(macOS 11.3, *), navigationAction.shouldPerformDownload {
            pendingSuggestedFilename = url?.lastPathComponent ?? "download"
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    /// Detect a download response and route it to a WKDownload (with a save
    /// panel to choose the destination).
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        NSLog("DSHWebView navigationResponse: mime=%@ url=%@ isMainFrame=%@",
              response.mimeType ?? "nil",
              response.url?.absoluteString ?? "nil",
              String(describing: navigationResponse.isForMainFrame))

        if navigationResponse.isForMainFrame {
            decisionHandler(.allow)
            return
        }

        let isDownload = Self.looksLikeDownload(response)
        NSLog("DSHWebView navigationResponse looksLikeDownload=%@", String(isDownload))

        if isDownload {
            pendingSuggestedFilename = response.suggestedFilename ?? "download"
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    /// Heuristic for whether a response should be downloaded rather than
    /// rendered inline.
    private static func looksLikeDownload(_ response: URLResponse) -> Bool {
        let mime = (response.mimeType ?? "").lowercased()

        // Explicit attachment disposition always means download.
        if let http = response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().contains("attachment") {
            return true
        }

        // MIME types WKWebView can render inline.
        let renderable = [
            "text/html", "text/plain", "application/xhtml+xml",
            "image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml",
            "text/css", "application/javascript", "application/json",
        ]
        if mime.isEmpty { return false }
        if renderable.contains(mime) { return false }
        // Text/* is generally renderable inline.
        if mime.hasPrefix("text/") { return false }
        return true
    }

    /// Install the main menu with the standard Edit shortcuts, plus View >
    /// Theme / Language settings. Labels follow the chosen menu language.
    private func buildMenu() {
        let s = uiStrings
        let mainMenu = NSMenu()

        // Application menu (Quit).
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(
            withTitle: s.about,
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: s.checkForUpdates,
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: String(format: s.quitFormat, appName),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        // Edit menu (copy/paste/cut/select-all/undo/redo).
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: s.edit)
        editMenu.addItem(
            withTitle: s.undo,
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        editMenu.addItem(
            withTitle: s.redo,
            action: Selector(("redo:")),
            keyEquivalent: "Z"
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: s.cut,
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: s.copy,
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: s.paste,
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: s.selectAll,
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenuItem.submenu = editMenu

        // View menu: theme + language settings.
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: s.view)

        let themeTitle = NSMenuItem(title: s.theme, action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: s.theme)
        themeMenu.addItem(radioItem(s.followSystem, action: #selector(setTheme(_:)),
                                    tag: Theme.system.rawValue, selected: preferredTheme == .system))
        themeMenu.addItem(radioItem(s.light, action: #selector(setTheme(_:)),
                                    tag: Theme.light.rawValue, selected: preferredTheme == .light))
        themeMenu.addItem(radioItem(s.dark, action: #selector(setTheme(_:)),
                                    tag: Theme.dark.rawValue, selected: preferredTheme == .dark))
        themeTitle.submenu = themeMenu
        viewMenu.addItem(themeTitle)

        // Language submenu: follow system (labeled in the current menu
        // language) plus each language under its native name. The checked
        // state mirrors the explicit preference so "follow system" stays a
        // distinct, restorable choice.
        let langTitle = NSMenuItem(title: s.language, action: nil, keyEquivalent: "")
        let langMenu = NSMenu(title: s.language)
        langMenu.addItem(radioItem(s.followSystem, action: #selector(setLanguage(_:)),
                                   tag: AppLanguage.system.rawValue, selected: preferredLanguage == .system))
        langMenu.addItem(radioItem("简体中文", action: #selector(setLanguage(_:)),
                                   tag: AppLanguage.zh.rawValue, selected: preferredLanguage == .zh))
        langMenu.addItem(radioItem("English", action: #selector(setLanguage(_:)),
                                   tag: AppLanguage.en.rawValue, selected: preferredLanguage == .en))
        langTitle.submenu = langMenu
        viewMenu.addItem(langTitle)

        // Standard full-screen toggle (⌃⌘F); the title switches between
        // "Enter Full Screen" and "Exit Full Screen" via validateMenuItem.
        viewMenu.addItem(.separator())
        let fullScreenItem = NSMenuItem(title: s.enterFullScreen,
                                        action: #selector(NSWindow.toggleFullScreen(_:)),
                                        keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreenItem)

        // Remote Connect now lives inside Settings… (toggle + QR + PIN).
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: s.pluginsManager,
            action: #selector(openPluginsManager(_:)),
            keyEquivalent: ""
        )
        viewMenu.addItem(
            withTitle: s.settings,
            action: #selector(openSettings(_:)),
            keyEquivalent: ""
        )

        viewMenuItem.submenu = viewMenu

        // Help menu (external links / documentation / plugin management).
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: s.help)
        helpMenu.addItem(
            withTitle: s.pluginsMarket,
            action: #selector(openPluginsManager(_:)),
            keyEquivalent: ""
        )
        helpMenuItem.submenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    private func loadUI() {
        let request = URLRequest(url: server.activeURL)
        webView.load(request)
    }

    // MARK: - Update checking

    /// Menu action: open the native plugins manager window (installed /
    /// enabled / market tabs with install, uninstall, enable, disable).
    @objc private func openPluginsManager(_ sender: Any?) {
        if pluginsController == nil {
            let controller = PluginsWindowController()
            controller.onRestartRequested = { [weak self] in self?.restartServer() }
            pluginsController = controller
        }
        pluginsController?.show()
    }

    /// Restart the dsh web server so plugin layer changes take effect, then
    /// reload the webview. Used by the plugins manager.
    private func restartServer() {
        server.stop()
        // Give the old process a moment to release its port before the
        // readiness probe decides whether another instance is already there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.server.start()
            self.loadUI()
        }
    }

    // MARK: - Settings

    /// Menu action: open Settings… — now hosts the Remote Connect toggle,
    /// pairing info and QR code inline (no separate pairing window).
    @objc private func openSettings(_ sender: Any?) {
        let s = uiStrings

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 0),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = s.settings
        panel.isReleasedWhenClosed = false
        panel.center()

        // Custom relay switch row — off uses the default relay server
        // (relay.deepvisus.top); on reveals the address field below.
        let customRelayLabel = NSTextField(labelWithString: s.customRelay)
        customRelayLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let customRelaySwitch = NSSwitch()
        customRelaySwitch.target = self
        customRelaySwitch.action = #selector(customRelayToggled(_:))
        let customOn = UserDefaults.standard.bool(forKey: "mobileRelayCustom")
        customRelaySwitch.state = customOn ? .on : .off
        let customRelaySpacer = NSView()
        customRelaySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let customRelayRow = NSStackView(views: [customRelayLabel, customRelaySpacer, customRelaySwitch])
        customRelayRow.orientation = .horizontal
        customRelayRow.spacing = 10

        // Address input — only shown while the custom switch is on.
        let field = NSTextField(string: UserDefaults.standard.string(forKey: "mobileRelayURL") ?? "https://relay.deepvisus.top")
        field.placeholderString = "relay.deepvisus.top"
        field.font = NSFont.systemFont(ofSize: 14)
        field.focusRingType = .default
        field.delegate = self
        field.isHidden = !customOn

        // Hint (wrapping, dimmer).
        let hint = NSTextField(wrappingLabelWithString: s.relayHint)
        hint.font = NSFont.systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 388
        hint.isHidden = !customOn

        // Pairing PIN row — label left, field right (form-row style).
        let pinLabel = NSTextField(labelWithString: s.pairingPin)
        pinLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let pinField = NSTextField(string: StablePairingPin())
        pinField.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        pinField.focusRingType = .default
        pinField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let pinRow = NSStackView(views: [pinLabel, pinField])
        pinRow.orientation = .horizontal
        pinRow.spacing = 10

        // Separator before the Remote Connect section.
        let divider = NSBox()
        divider.boxType = .separator

        // Remote Connect toggle row — label left, switch right.
        let remoteTitle = NSTextField(labelWithString: s.mobileRemote)
        remoteTitle.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let remoteSwitch = NSSwitch()
        remoteSwitch.target = self
        remoteSwitch.action = #selector(remoteToggleChanged(_:))
        // Restore the persisted toggle state (the bridge may not be running
        // yet right after launch even though the toggle is on).
        remoteSwitch.state = UserDefaults.standard.bool(forKey: "mobileRemoteEnabled") ? .on : .off
        let remoteSpacer = NSView()
        remoteSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let remoteRow = NSStackView(views: [remoteTitle, remoteSpacer, remoteSwitch])
        remoteRow.orientation = .horizontal
        remoteRow.spacing = 10

        // Connection info area (QR + code + status) — hidden until on.
        let qrView = NSImageView()
        qrView.imageScaling = .scaleProportionallyUpOrDown
        let infoCode = NSTextField(labelWithString: "")
        infoCode.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        infoCode.alignment = .left
        infoCode.isSelectable = true
        let infoRelay = NSTextField(labelWithString: "")
        infoRelay.font = NSFont.systemFont(ofSize: 12)
        infoRelay.textColor = .secondaryLabelColor
        infoRelay.alignment = .left
        let infoStatus = NSTextField(labelWithString: s.mobileRemoteWaiting)
        infoStatus.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        infoStatus.alignment = .left
        infoStatus.lineBreakMode = .byTruncatingTail
        let infoView = NSStackView(views: [qrView, infoCode, infoRelay, infoStatus])
        infoView.orientation = .vertical
        infoView.alignment = .width
        infoView.spacing = 10
        infoView.isHidden = !(mobileRemote?.isRunning ?? false)

        // Buttons: Cancel | OK on a single horizontal row (one-row grid,
        // immune to the nested-stack stacking bug), pushed to the trailing
        // edge by an elastic spacer.
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelRelaySettings(_:)))
        let save = NSButton(title: "OK", target: self, action: #selector(saveRelaySettings(_:)))
        save.keyEquivalent = "\r"
        let buttonsGrid = NSGridView(views: [[cancel, save]])
        buttonsGrid.columnSpacing = 8
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [buttonSpacer, buttonsGrid])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [customRelayRow, field, hint,
                                        pinRow,
                                        divider, remoteRow, infoView, buttons])
        stack.orientation = .vertical
        stack.alignment = .width   // children fill the panel width
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 420),
            field.heightAnchor.constraint(equalToConstant: 24),
            hint.widthAnchor.constraint(equalToConstant: 388),
            qrView.widthAnchor.constraint(equalToConstant: 250),
            qrView.heightAnchor.constraint(equalToConstant: 250),
            qrView.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
        ])

        panel.contentView = stack
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        relayPanel = panel
        relayField = field
        relayHintRef = hint
        customRelaySwitchRef = customRelaySwitch
        relayPinField = pinField
        remoteSwitchRef = remoteSwitch
        remoteInfoView = infoView
        remoteQrView = qrView
        remoteCodeLabel = infoCode
        remoteRelayLabel = infoRelay
        remoteStatusLabel = infoStatus

        // If the bridge is already running, repopulate its info and polling.
        if let pairing = lastPairing, let qr = lastQrPNG {
            fillRemoteInfo(pairing, qrPNG: qr, deviceID: DeviceID())
            startRemotePolling(hostToken: pairing.hostToken)
        }
        NSApp.runModal(for: panel)
        remotePollTimer?.invalidate()
        remotePollTimer = nil
    }

    /// The settings panel is `.closable`; closing via the window button must
    /// also end the modal session, otherwise the app gets stuck in the
    /// runModal loop (menu misbehaves, app can't quit).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === relayPanel {
            remotePollTimer?.invalidate()
            remotePollTimer = nil
            NSApp.stopModal()
        }
        return true
    }

    /// Settings panel: reveal/hide the custom relay address field, and persist
    /// the switch state immediately so Remote Connect never uses stale settings.
    @objc private func customRelayToggled(_ sender: Any?) {
        let on = (customRelaySwitchRef?.state ?? .off) == .on
        UserDefaults.standard.set(on, forKey: "mobileRelayCustom")
        relayField?.isHidden = !on
        relayHintRef?.isHidden = !on
    }

    /// Persist the relay address as the user types (before OK is pressed), so
    /// toggling Remote Connect on right after an edit uses the new value.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === relayField else { return }
        UserDefaults.standard.set(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                  forKey: "mobileRelayURL")
    }

    @objc private func saveRelaySettings(_ sender: Any?) {
        guard let panel = relayPanel else { return }
        let defaultRelay = "https://relay.deepvisus.top"
        let oldCustom = UserDefaults.standard.bool(forKey: "mobileRelayCustom")
        let oldRelay = UserDefaults.standard.string(forKey: "mobileRelayURL")
        let oldPin = UserDefaults.standard.string(forKey: "mobilePairingPin")
        let oldEffective = oldCustom ? (oldRelay ?? defaultRelay) : defaultRelay
        var relayChanged = false
        var pinChanged = false
        // Custom switch: off → always use the default relay server; the
        // previously entered custom address is kept for the next time the
        // switch is turned on.
        let newCustom = (customRelaySwitchRef?.state ?? .off) == .on
        UserDefaults.standard.set(newCustom, forKey: "mobileRelayCustom")
        var relay = defaultRelay
        if newCustom {
            let raw = (relayField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                relay = normalizeRelay(raw)
                UserDefaults.standard.set(relay, forKey: "mobileRelayURL")
            } else {
                relay = "" // custom on but empty → treated as unconfigured
            }
        }
        relayChanged = relay != oldEffective
        // Save the pairing PIN when it is a valid 6-digit number and not a
        // trivially guessable one (the relay refuses weak fixed PINs too).
        if let pinText = relayPinField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
           pinText.count == 6, pinText.allSatisfy({ $0.isNumber }) {
            if isWeakPin(pinText) {
                let alert = NSAlert()
                alert.messageText = s.settings
                alert.informativeText = "该 PIN 过于简单，无法使用（例如 000000、123456、连续或相同数字）。请换一个。"
                alert.runModal()
                NSApp.stopModal()
                panel.orderOut(nil)
                return
            }
            UserDefaults.standard.set(pinText, forKey: "mobilePairingPin")
            pinChanged = pinText != oldPin
        }
        // If the relay address or PIN changed while the bridge is running,
        // restart it so it re-registers with the new values — otherwise the
        // pairing info would be stale and pairing would fail.
        if (relayChanged || pinChanged), mobileRemote?.isRunning == true {
            mobileRemote?.stop()
            mobileRemote = nil
            lastPairing = nil
            lastQrPNG = nil
            remotePollTimer?.invalidate()
            remotePollTimer = nil
            startMobileBridge()
        }
        NSApp.stopModal()
        panel.orderOut(nil)
    }

    /// True for localhost / 127.x / ::1 — where a plain-HTTP relay is expected
    /// during testing.
    private func isLoopbackHost(_ hostOrAddr: String) -> Bool {
        let h = hostOrAddr.lowercased()
        return h == "localhost" || h == "::1" || h.hasPrefix("127.")
    }

    /// Normalize a relay address: strip whitespace and default the scheme —
    /// http:// for loopback hosts, https:// otherwise.
    private func normalizeRelay(_ raw: String) -> String {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return r }
        if r.lowercased().hasPrefix("http://") || r.lowercased().hasPrefix("https://") { return r }
        return (isLoopbackHost(r) ? "http://" : "https://") + r
    }

    @objc private func cancelRelaySettings(_ sender: Any?) {
        NSApp.stopModal()
        relayPanel?.orderOut(nil)
    }

    // MARK: - Mobile remote

    /// Settings panel toggle: start/stop the relay bridge. The state is
    /// persisted so the bridge auto-starts on the next launch.
    @objc private func remoteToggleChanged(_ sender: Any?) {
        if (remoteSwitchRef?.state ?? .off) == .on {
            UserDefaults.standard.set(true, forKey: "mobileRemoteEnabled")
            startMobileBridge()
        } else {
            UserDefaults.standard.set(false, forKey: "mobileRemoteEnabled")
            stopMobileBridge()
            remoteInfoView?.isHidden = true
        }
    }

    /// Start the bridge (from the Settings toggle, config changes, or app
    /// launch when the toggle is on) and surface pairing info + QR inline in
    /// the settings panel. `silent` suppresses error alerts (app-launch path).
    private func startMobileBridge(silent: Bool = false) {
        if let m = mobileRemote, m.isRunning { return }
        let s = uiStrings

        // Relay: default server unless the custom address switch is on.
        let defaultRelay = "https://relay.deepvisus.top"
        let relay: String
        if UserDefaults.standard.bool(forKey: "mobileRelayCustom") {
            relay = normalizeRelay(UserDefaults.standard.string(forKey: "mobileRelayURL") ?? "")
        } else {
            relay = defaultRelay
        }
        guard !relay.isEmpty else {
            if !silent {
                let alert = NSAlert()
                alert.messageText = s.mobileRemote
                alert.informativeText = s.relayNotConfigured
                alert.runModal()
            }
            remoteSwitchRef?.state = .off
            return
        }
        guard let node = NodeRuntimeManager.nodePath() else {
            // No popup — surface the failure inline in the settings panel.
            setRemoteStatus(s.mobileRemoteFailed, color: .systemRed)
            remoteSwitchRef?.state = .off
            return
        }
        guard let bridge = Bundle.main.resourceURL?.appendingPathComponent("bridge/bridge.mjs") else {
            setRemoteStatus(s.mobileRemoteFailed, color: .systemRed)
            remoteSwitchRef?.state = .off
            return
        }

        // Shell-generated identity + pairing QR (relay host + device ID, plus
        // the LAN address of the bridge's direct-connect proxy so the phone
        // can prefer a direct connection and fall back to the relay).
        let deviceID = DeviceID()
        let lan = LocalLANAddress().map { "\($0):13080" }
        let qrContent = PairingQRContent(relayURL: relay, deviceID: deviceID, lanAddress: lan)
        guard let qrPNG = GenerateQRPNG(content: qrContent) else {
            setRemoteStatus(s.mobileRemoteFailed, color: .systemRed)
            remoteSwitchRef?.state = .off
            return
        }

        // Show the status area right away (QR + device ID + relay + a
        // "connecting" state) while the bridge registers with the relay —
        // no popup, everything lives in the settings panel.
        if relayPanel != nil {
            remoteInfoView?.isHidden = false
            remoteQrView?.image = NSImage(data: qrPNG)
            remoteCodeLabel?.stringValue = "\(s.mobileRemoteCode): \(deviceID)"
            remoteRelayLabel?.stringValue = "\(s.mobileRemoteRelay): \(relay)"
            setRemoteStatus(s.mobileRemoteConnecting, color: .systemOrange)
        }

        let m = MobileRemoteManager(nodePath: node, bridgePath: bridge,
                                    relayURL: relay, deviceID: deviceID,
                                    dshPort: server.activePort)
        // While the toggle is on, an unexpected bridge exit re-spawns and
        // re-registers with the relay automatically.
        m.autoRestart = true
        mobileRemote = m

        // Registration must succeed within 12s or the relay is unreachable.
        // On failure: no popup — show the status inline and flip the toggle.
        var registered = false
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, !registered else { return }
            self.mobileRemote?.stop()
            self.mobileRemote = nil
            self.lastPairing = nil
            self.lastQrPNG = nil
            self.remoteSwitchRef?.state = .off
            self.setRemoteStatus(self.uiStrings.relayUnreachable, color: .systemRed)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
        m.onRegistered = { [weak self] pairing in
            registered = true
            timeout.cancel()
            self?.lastPairing = pairing
            self?.lastQrPNG = qrPNG
            // Only populate the inline info when the settings panel is open.
            if self?.relayPanel != nil {
                self?.fillRemoteInfo(pairing, qrPNG: qrPNG, deviceID: deviceID)
                self?.startRemotePolling(hostToken: pairing.hostToken)
            }
        }
        m.start()
    }

    private func stopMobileBridge() {
        mobileRemote?.stop()
        mobileRemote = nil
        remotePollTimer?.invalidate()
        remotePollTimer = nil
        lastPairing = nil
        lastQrPNG = nil
    }

    /// Update the inline status line in the settings panel (no popups).
    private func setRemoteStatus(_ text: String, color: NSColor?) {
        remoteStatusLabel?.stringValue = text
        if let color { remoteStatusLabel?.textColor = color }
    }

    /// Fill the settings-panel connection info area (QR + PIN + code + status).
    private func fillRemoteInfo(_ pairing: MobileRemoteManager.Pairing, qrPNG: Data, deviceID: String) {
        let s = uiStrings
        remoteInfoView?.isHidden = false
        remoteQrView?.image = NSImage(data: qrPNG)
        remoteCodeLabel?.stringValue = "\(s.mobileRemoteCode): \(deviceID)"
        remoteRelayLabel?.stringValue = "\(s.mobileRemoteRelay): \(mobileRemote?.relayURL ?? "")"
        setRemoteStatus(s.mobileRemoteWaiting, color: .systemOrange)
    }

    /// Poll the relay for connected devices every 2s while the settings panel
    /// is open — the connection state is queried, not guessed.
    private func startRemotePolling(hostToken: String) {
        remotePollTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollRemoteDevices(hostToken: hostToken)
        }
        remotePollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        pollRemoteDevices(hostToken: hostToken)
    }

    private func pollRemoteDevices(hostToken: String) {
        guard let relay = mobileRemote?.relayURL, let url = URL(string: "\(relay)/relay/v1/host/devices") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(hostToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { [weak self] data, resp, err in
            guard let self = self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let devices = json["devices"] as? [[String: Any]] else { return }
            let online = devices.contains { ($0["online"] as? Bool) ?? false }
            let count = devices.count
            DispatchQueue.main.async {
                let s = self.uiStrings
                if online {
                    self.setRemoteStatus(s.mobileRemoteConnected, color: .systemGreen)
                } else {
                    self.setRemoteStatus(count == 0 ? s.mobileRemoteWaiting : s.mobileRemoteNoApp,
                                         color: .systemOrange)
                }
            }
        }.resume()
    }

    /// Called once on launch (in the background) to check for a newer dsh
    /// version without blocking startup.
    private func autoCheckForUpdates() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            self.updateManager.updateAvailable { available, latest in
                guard available, let latest = latest else { return }
                DispatchQueue.main.async {
                    self.presentUpdatePrompt(latestVersion: latest)
                }
            }
        }
    }

    /// Menu action: manually check for updates.
    @objc private func showAbout(_ sender: Any?) {
        let s = uiStrings
        let appName = ProcessInfo.processInfo.processName
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let engine = updateManager.localVersion ?? s.aboutNotInstalled
        let node = NodeRuntimeManager.nodeVersion() ?? s.aboutNotInstalled

        let alert = NSAlert()
        alert.messageText = appName
        alert.informativeText = """
        \(s.aboutVersion): \(version)\(build.isEmpty ? "" : " (\(build))")
        \(s.aboutEngine): \(engine)
        \(s.aboutNode): \(node)
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        guard !updateCheckInFlight else { return }
        updateCheckInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            self.updateManager.updateAvailable { available, latest in
                self.updateCheckInFlight = false
                DispatchQueue.main.async {
                    if available, let latest = latest {
                        self.presentUpdatePrompt(latestVersion: latest)
                    } else {
                        self.showAlreadyUpToDate()
                    }
                }
            }
        }
    }

    private func presentUpdatePrompt(latestVersion: String) {
        let local = updateManager.localVersion ?? "unknown"
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = "A newer version of DeepSeek Harness engine is available.\n\nCurrent: \(local)\nLatest: \(latestVersion)\n\nUpdate now?"
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            performUpdate()
        }
    }

    private func showAlreadyUpToDate() {
        let alert = NSAlert()
        alert.messageText = "Up to date"
        alert.informativeText = "You are running the latest version."
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func performUpdate() {
        showLoadingOverlay(over: window.contentView ?? webView)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            self.updateManager.refreshToLatest { success, message in
                DispatchQueue.main.async {
                    self.dismissLoadingOverlay()
                    if success {
                        self.restartServerAfterUpdate()
                    } else {
                        self.showError("Update failed: \(message ?? "unknown error")")
                    }
                }
            }
        }
    }

    /// Stop the current server and start a fresh one (which will resolve the
    /// newly refreshed dsh version), then reload the UI.
    private func restartServerAfterUpdate() {
        server.stop()
        showLoadingOverlay(over: window.contentView ?? webView)
        server.start()
        server.waitUntilReady(timeout: startupTimeoutSeconds, completion: { [weak self] in
            DispatchQueue.main.async {
                self?.webView.reload()
                self?.dismissLoadingOverlay()
            }
        }, failure: { [weak self] in
            DispatchQueue.main.async {
                self?.dismissLoadingOverlay()
                self?.showError("Server did not restart after update.")
            }
        })
    }

    // MARK: - Loading overlay

    private func showLoadingOverlay(over container: NSView) {
        // The dsh web UI is dark-themed; keep the startup screen dark too so
        // it matches the page it hands off to, regardless of the system or
        // app appearance. (Light text on a fixed dark background.)
        let overlay = NSView(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor =
            NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.118, alpha: 1).cgColor

        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .regular
        // Force the light appearance so the spinner stays visible on the
        // fixed dark background in light mode too.
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(spinner)

        let label = NSTextField(labelWithString: "Starting DeepSeek Harness…")
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = NSColor(calibratedWhite: 0.91, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(label)

        // Last server log line, pinned to the bottom of the startup screen
        // (single line, truncated on the right). Light monospaced text on the
        // dark background, like a terminal.
        let logLabel = NSTextField(labelWithString: "")
        logLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        logLabel.textColor = NSColor(calibratedWhite: 0.82, alpha: 1)
        logLabel.lineBreakMode = .byTruncatingTail
        logLabel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(logLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -16),
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            logLabel.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 16),
            logLabel.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -16),
            logLabel.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -12),
        ])
        spinner.startAnimation(nil)
        loadingLogLabel = logLabel

        overlay.layer?.zPosition = 10
        container.addSubview(overlay, positioned: .above, relativeTo: container.subviews.first)
        loadingOverlay = overlay
    }

    /// Keep only the last log line visible on the startup screen: append to a
    /// rolling tail, then show the segment after the last newline *or* the
    /// last carriage return — npm's progress redraws use \r without newlines,
    /// so the latest progress frame is what should be shown.
    private func handleServerLog(_ text: String) {
        pendingLogTail += text
        if pendingLogTail.count > 8192 {
            pendingLogTail = String(pendingLogTail.suffix(4096))
        }
        let lastSegment = pendingLogTail
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .last
            .map(String.init) ?? ""
        let trimmed = lastSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.loadingLogLabel?.stringValue = trimmed
        }
    }

    private func dismissLoadingOverlay() {
        DispatchQueue.main.async { [weak self] in
            self?.loadingLogLabel = nil
            self?.loadingOverlay?.removeFromSuperview()
            self?.loadingOverlay = nil
        }
    }

    // MARK: - WKNavigationDelegate (page load)

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        dismissLoadingOverlay()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dismissLoadingOverlay()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "DeepSeek Harness"
        alert.informativeText = message
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - External links: open in the system default browser

extension AppDelegate: WKUIDelegate {
    /// New-window requests (target="_blank" links, window.open) never create a
    /// second webview; the URL is opened in the system default browser instead.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            openInDefaultBrowser(url)
        }
        return nil
    }
}

extension AppDelegate {
    /// True when `url` points at the local dsh server — the only content the
    /// webview is meant to host. Everything else belongs to the default browser.
    private func isAppURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host?.lowercased() else { return false }
        let appHost = settings.host.lowercased()
        let sameHost = host == appHost
            || (appHost == "127.0.0.1" && host == "localhost")
            || (appHost == "localhost" && host == "127.0.0.1")
        // The app URL always carries an explicit port; a URL without one is
        // not ours (this also cleanly rejects lookalikes like 127.0.0.1:30800).
        guard sameHost, let port = url.port else { return false }
        return port == server.activePort
    }

    /// Open a URL in the system default browser (http/https only).
    private func openInDefaultBrowser(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Keep the full-screen menu item's title in sync with the window state
    /// and disable it while no window exists (e.g. during provisioning).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(NSWindow.toggleFullScreen(_:)) else { return true }
        guard let window = window else { return false }
        menuItem.title = window.styleMask.contains(.fullScreen) ? uiStrings.exitFullScreen : uiStrings.enterFullScreen
        return true
    }
}

// MARK: - WKDownloadDelegate

extension AppDelegate {
    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        NSLog("DSHWebView download decideDestination: name=%@ pendingName=%@",
              suggestedFilename, pendingSuggestedFilename ?? "nil")
        let name = pendingSuggestedFilename ?? suggestedFilename
        pendingSuggestedFilename = nil

        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.canCreateDirectories = true
            panel.begin { [weak self] result in
                guard let self = self else { completionHandler(nil); return }
                if result == .OK, let url = panel.url {
                    self.pendingDownloadDestination = url
                    completionHandler(url)
                    self.beginDownloadProgress(download, filename: name)
                } else {
                    completionHandler(nil)   // cancel the download
                }
            }
        }
    }

    private func beginDownloadProgress(_ download: WKDownload, filename: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.downloadBarContainer?.isHidden = false
            self.downloadBar?.doubleValue = 0

            let obs = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    let percent = progress.fractionCompleted * 100
                    self.downloadBar?.doubleValue = percent
                    self.downloadLabel?.stringValue = String(format: "%@ — %.0f%%", filename, percent)
                }
            }
            self.activeDownloads[download] = obs
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        activeDownloads[download]?.invalidate()
        activeDownloads[download] = nil
        pendingDownloadDestination = nil
        DispatchQueue.main.async { [weak self] in
            self?.downloadBarContainer?.isHidden = true
            self?.downloadBar?.doubleValue = 0
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        activeDownloads[download]?.invalidate()
        activeDownloads[download] = nil
        pendingDownloadDestination = nil
        DispatchQueue.main.async { [weak self] in
            self?.downloadBarContainer?.isHidden = true
            self?.showError("Download failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - WKScriptMessageHandler (JS-intercepted downloads)

extension AppDelegate {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "download",
              let body = message.body as? [String: Any],
              let urlString = body["url"] as? String,
              let url = URL(string: urlString) else {
            return
        }
        let filename = (body["filename"] as? String) ?? url.lastPathComponent
        performNativeDownload(url: url, suggestedFilename: filename.isEmpty ? url.lastPathComponent : filename)
    }

    /// Download a URL using URLSession (bypassing WebKit's download navigation),
    /// with a save panel and the shared bottom progress bar.
    private func performNativeDownload(url: URL, suggestedFilename: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            panel.canCreateDirectories = true
            panel.begin { [weak self] result in
                guard let self = self, result == .OK, let destination = panel.url else { return }
                self.startNativeDownload(url: url, to: destination, filename: suggestedFilename)
            }
        }
    }

    private func startNativeDownload(url: URL, to destination: URL, filename: String) {
        var request = URLRequest(url: url)
        // The session export endpoint is GET; carry cookies/headers as needed.
        request.httpMethod = "GET"

        let task = URLSession.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async {
                    self.downloadBarContainer?.isHidden = true
                    self.showError("Download failed: \(error.localizedDescription)")
                }
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                DispatchQueue.main.async {
                    self.downloadBarContainer?.isHidden = true
                    self.showError("Download failed: bad HTTP response")
                }
                return
            }
            guard let tempURL = tempURL else {
                DispatchQueue.main.async {
                    self.downloadBarContainer?.isHidden = true
                    self.showError("Download failed: no data")
                }
                return
            }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
                DispatchQueue.main.async {
                    self.downloadBarContainer?.isHidden = true
                    self.downloadBar?.doubleValue = 0
                }
            } catch {
                DispatchQueue.main.async {
                    self.downloadBarContainer?.isHidden = true
                    self.showError("Download failed: \(error.localizedDescription)")
                }
            }
        }

        // Observe progress and drive the shared bottom bar.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.downloadBarContainer?.isHidden = false
            self.downloadBar?.doubleValue = 0
            self.downloadLabel?.stringValue = filename
        }

        let observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let percent = progress.fractionCompleted * 100
                self.downloadBar?.doubleValue = percent
                self.downloadLabel?.stringValue = String(format: "%@ — %.0f%%", filename, percent)
            }
        }
        nativeDownloadObservation = observation
        task.resume()
    }
}

// MARK: - Entry point

let settings = Settings(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate(settings: settings)
app.delegate = delegate
app.run()
