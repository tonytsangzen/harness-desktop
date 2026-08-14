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

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private let settings: Settings
    private let server: ServerManager

    init(settings: Settings) {
        self.settings = settings
        self.server = ServerManager(settings: settings)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()

        let rect = NSRect(x: 0, y: 0, width: 1200, height: 800)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DeepSeek Harness"
        window.center()
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        server.start()
        server.waitUntilReady(timeout: startupTimeoutSeconds, completion: { [weak self] in
            DispatchQueue.main.async {
                self?.loadUI()
            }
        }, failure: { [weak self] in
            DispatchQueue.main.async {
                self?.showError("DeepSeek Harness server did not start within \(Int(startupTimeoutSeconds)) seconds.")
            }
        })
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
