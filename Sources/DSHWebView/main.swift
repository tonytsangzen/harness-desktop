import AppKit
import WebKit

// MARK: - Configuration

/// The host dsh web binds by default.
private let defaultHost = "127.0.0.1"
/// The port dsh web binds by default.
private let defaultPort: UInt16 = 3080
/// How long to wait for the dsh web server to come up before giving up.
private let startupTimeoutSeconds: TimeInterval = 180
/// Retry interval when probing the server.
private let probeIntervalSeconds: TimeInterval = 0.25

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
        var command = ["npx", "@deepseek-ai/dsh", "web"]

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
        // custom command (which we take at face value).
        if command == ["npx", "@deepseek-ai/dsh", "web"] {
            command.append(contentsOf: ["--host", host, "--port", String(port)])
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

    Wraps the DeepSeek Harness web UI (`npx @deepseek-ai/dsh web`) in a native
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

    init(settings: Settings) {
        self.settings = settings
    }

    /// Spawn the server process. Streams its output to the app's stdout so
    /// logs stay observable from a terminal launch.
    func start() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = settings.dshCommand

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty {
                FileHandle.standardOutput.write(Data(text.utf8))
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty {
                FileHandle.standardError.write(Data(text.utf8))
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
    /// success or `failure` after the timeout elapses.
    func waitUntilReady(timeout: TimeInterval, completion: @escaping () -> Void, failure: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        probe(deadline: deadline, completion: completion, failure: failure)
    }

    private func probe(deadline: Date, completion: @escaping () -> Void, failure: @escaping () -> Void) {
        if self.process == nil {
            // The child already exited before we could connect.
            failure()
            return
        }
        if isPortOpen(host: settings.host, port: settings.port) {
            completion()
            return
        }
        if Date() >= deadline {
            failure()
            return
        }
        probeTimer = Timer.scheduledTimer(withTimeInterval: probeIntervalSeconds, repeats: false) { [weak self] _ in
            self?.probe(deadline: deadline, completion: completion, failure: failure)
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
                el.value = el.value.slice(0, start) + text + el.value.slice(end);
                const pos = start + text.length;
                el.selectionStart = el.selectionEnd = pos;
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
        if let p = findExecutable(named: "node") { return p }
        for dir in binaryCandidateDirs {
            let p = "\(dir)/node"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// First found path to the `npx` binary, or nil if none exists.
    static func npxPath() -> String? {
        if let p = findExecutable(named: "npx") { return p }
        for dir in binaryCandidateDirs {
            let p = "\(dir)/npx"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
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

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private let settings: Settings
    private let server: ServerManager
    private let runtimeManager = NodeRuntimeManager()
    private var runtimeToken: ObjectIdentifier?
    private var setupWindow: NSWindow?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?

    init(settings: Settings) {
        self.settings = settings
        self.server = ServerManager(settings: settings)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        ensureNodeRuntime()
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
            win.contentView = self.webView
            win.makeKeyAndOrderFront(nil)
            self.window = win
            NSApp.activate(ignoringOtherApps: true)

            self.server.start()
            self.server.waitUntilReady(timeout: startupTimeoutSeconds, completion: { [weak self] in
                DispatchQueue.main.async {
                    self?.loadUI()
                }
            }, failure: { [weak self] in
                DispatchQueue.main.async {
                    self?.showError("DeepSeek Harness server did not start within \(Int(startupTimeoutSeconds)) seconds.")
                }
            })
        }
    }

    private func buildWindow() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = ShortcutWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        self.webView = webView
    }

    /// Install a minimal main menu with the standard Edit shortcuts so that
    /// Cmd+C/X/V/A work through the responder chain and the app menu bar.
    private func buildMenu() {
        let mainMenu = NSMenu()

        // Application menu (Quit).
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        // Edit menu (copy/paste/cut/select-all/undo/redo).
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        editMenu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "Z"
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    private func loadUI() {
        let request = URLRequest(url: settings.url)
        webView.load(request)
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

// MARK: - Entry point

let settings = Settings(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate(settings: settings)
app.delegate = delegate
app.run()
