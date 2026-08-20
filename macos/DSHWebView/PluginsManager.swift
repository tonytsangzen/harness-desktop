// MARK: - Plugin management (market / installed / enabled)
//
// A plugin here is a dsh profile bundle: an npm package that declares
// `"dsh": { "bundle": { "patch": ... } }` in its manifest. The active profile
// lives at `~/.dsh/profiles/web` (package.json carries the installed
// dependencies and the `dsh.profile.bundles` layer list). Installing /
// removing goes through `dsh plugin --profile web …`, which forwards to pnpm
// and reconciles the bundles list automatically.

import AppKit

// MARK: - Market data model

/// One entry from the plugin market index (harness-market/data.js).
struct MarketPlugin {
    let id: String?          // "npm:<pkg>" / "gh:owner/repo" / nil
    let name: String         // npm package name or owner/repo path
    let displayName: String
    let type: String         // "package" | "repo"
    let category: String
    let summary: String      // localized description (zh preferred)
    let url: String
    let version: String?
    let stars: Int?

    /// The npm package name usable with `pnpm add`, when this entry is an
    /// installable npm package (not a bare GitHub repo).
    var npmPackage: String? {
        guard type == "package" else { return nil }
        if let id, id.hasPrefix("npm:") { return String(id.dropFirst(4)) }
        return name
    }

    /// True when this market entry matches an installed dependency name.
    func matches(installed: Set<String>) -> Bool {
        guard let pkg = npmPackage else { return false }
        return installed.contains(pkg)
    }
}

/// Loads and parses the plugin market index.
enum PluginMarket {
    static let dataURL = URL(string: "https://tonytsangzen.github.io/harness-market/data.js")!

    /// Fetch the market index. `completion` runs on the main thread with
    /// either the plugin list or an error message.
    static func fetch(completion: @escaping ([MarketPlugin]?, String?) -> Void) {
        URLSession.shared.dataTask(with: dataURL) { data, _, error in
            DispatchQueue.main.async {
                guard let data else {
                    completion(nil, error?.localizedDescription ?? "network error")
                    return
                }
                guard let text = String(data: data, encoding: .utf8),
                      let start = text.firstIndex(of: "{"),
                      let end = text.lastIndex(of: "}"),
                      start < end else {
                    completion(nil, "market index parse error")
                    return
                }
                let jsonText = String(text[start...end])
                guard let jsonData = jsonText.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let rawPlugins = root["plugins"] as? [[String: Any]] else {
                    completion(nil, "market index parse error")
                    return
                }
                let zh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
                let plugins = rawPlugins.compactMap { raw -> MarketPlugin? in
                    guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
                    let summary = (zh ? raw["description_zh"] : nil) as? String
                        ?? raw["description"] as? String
                        ?? ""
                    return MarketPlugin(
                        id: raw["id"] as? String,
                        name: name,
                        displayName: raw["display_name"] as? String ?? name,
                        type: raw["type"] as? String ?? "repo",
                        category: raw["category"] as? String ?? "",
                        summary: summary,
                        url: raw["url"] as? String ?? "",
                        version: raw["version"] as? String,
                        stars: raw["stars"] as? Int
                    )
                }
                completion(plugins, nil)
            }
        }.resume()
    }
}

// MARK: - Local profile state

/// Reads and mutates the dsh web profile (`~/.dsh/profiles/web`).
enum ProfilePlugins {
    /// `~/.dsh/profiles/web` — the profile the shell boots (`dsh web`).
    static var profileDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".dsh/profiles/web", isDirectory: true)
    }

    private static var packageJSONURL: URL {
        profileDir.appendingPathComponent("package.json")
    }

    /// Installed dependency names (package.json `dependencies`) plus any
    /// top-level directories in the profile's node_modules.
    static func installedPackages() -> [String] {
        var names = Set<String>()
        if let dict = readPackageJSON(),
           let deps = dict["dependencies"] as? [String: Any] {
            names.formUnion(deps.keys)
        }
        let nm = profileDir.appendingPathComponent("node_modules", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: nm, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for entry in entries {
                let name = entry.lastPathComponent
                if name == ".pnpm" || name == ".bin" || name.hasPrefix(".") { continue }
                if name.hasPrefix("@"), let subs = try? FileManager.default.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for sub in subs { names.insert("@\(name)/\(sub.lastPathComponent)") }
                } else {
                    names.insert(name)
                }
            }
        }
        return names.sorted()
    }

    /// Enabled bundle names (`dsh.profile.bundles`), in layer order.
    static func enabledBundles() -> [String] {
        guard let dict = readPackageJSON(),
              let dsh = dict["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String] else { return [] }
        return bundles
    }

    private static func readPackageJSON() -> [String: Any]? {
        guard let data = try? Data(contentsOf: packageJSONURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Enable or disable a bundle by rewriting `dsh.profile.bundles`.
    /// Throws on read/write errors. Changes only take effect after the
    /// dsh web server is restarted (the shell shows a restart prompt).
    static func setEnabled(_ name: String, enabled: Bool) throws {
        guard var dict = readPackageJSON() else {
            throw NSError(domain: "ProfilePlugins", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot read \(packageJSONURL.path)"])
        }
        var dsh = dict["dsh"] as? [String: Any] ?? [:]
        var profile = dsh["profile"] as? [String: Any] ?? [:]
        var bundles = profile["bundles"] as? [String] ?? []
        if enabled, !bundles.contains(name) {
            bundles.append(name)
        } else if !enabled {
            bundles.removeAll { $0 == name }
        }
        profile["bundles"] = bundles
        dsh["profile"] = profile
        dict["dsh"] = dsh
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: packageJSONURL, options: .atomic)
    }

    /// Run `dsh plugin --profile web <args…>` via npx, streaming the tail of
    /// its output. `completion(Bool, String)` runs on the main thread.
    static func runDshPlugin(args: [String], completion: @escaping (Bool, String) -> Void) {
        guard let npx = NodeRuntimeManager.npxPath() else {
            DispatchQueue.main.async { completion(false, "npx not found") }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.arguments = ["--yes", "@deepseek-ai/dsh", "plugin", "--profile", "web"] + args
        process.currentDirectoryURL = profileDir
        var env = ProcessInfo.processInfo.environment
        env["npm_config_yes"] = "true"
        env["npm_config_fund"] = "false"
        env["npm_config_update_notifier"] = "false"
        // The GUI app's PATH is minimal; dsh plugin forwards to pnpm, so make
        // sure the node bin dir (which usually also holds pnpm) is on PATH.
        if let binDir = NodeRuntimeManager.binDirectoryFromNodePath() {
            let existing = env["PATH"] ?? ""
            env["PATH"] = "\(binDir):\(existing)"
        }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var output = ""
        let lock = NSLock()
        func append(_ data: Data) {
            if let s = String(data: data, encoding: .utf8) {
                lock.lock(); output += s; lock.unlock()
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = { h in append(h.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { h in append(h.availableData) }

        process.terminationHandler = { p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let text: String
            lock.lock(); text = output; lock.unlock()
            // Keep only the meaningful tail (pnpm prints a lot).
            let lines = text.split(separator: "\n").map(String.init)
            let tail = Array(lines.suffix(12)).joined(separator: "\n")
            DispatchQueue.main.async {
                completion(p.terminationStatus == 0, tail.isEmpty ? "exit \(p.terminationStatus)" : tail)
            }
        }
        do { try process.run() } catch {
            DispatchQueue.main.async { completion(false, error.localizedDescription) }
        }
    }

    /// Whether pnpm is available for `dsh plugin` to forward to.
    static func pnpmAvailable() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", "pnpm"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }
}

// MARK: - Window strings

private struct PluginsStrings {
    let title, installedTab, enabledTab, marketTab: String
    let searchPlaceholder, refresh, install, uninstall, enable, disable, open: String
    let loading, loadFailed, emptyInstalled, emptyEnabled, emptyMarket: String
    let enabled, disabled, notInstalled, version, category, stars, npmPackage, repo: String
    let restartHint, restartNow, doneInstall, doneUninstall, pnpmMissing: String
    let noRestartNeeded: String

    static func current() -> PluginsStrings {
        let lang = AppLanguage(rawValue: UserDefaults.standard.integer(forKey: "appLanguage")) ?? .system
        let zh = lang.resolved == .zh
        if zh {
            return PluginsStrings(
                title: "插件管理", installedTab: "已安装", enabledTab: "已启用", marketTab: "插件市场",
                searchPlaceholder: "搜索插件…", refresh: "刷新", install: "安装", uninstall: "卸载",
                enable: "启用", disable: "停用", open: "打开",
                loading: "正在加载…", loadFailed: "加载失败", emptyInstalled: "尚未安装任何插件",
                emptyEnabled: "没有已启用的插件", emptyMarket: "没有匹配的插件",
                enabled: "已启用", disabled: "已停用", notInstalled: "未安装",
                version: "版本", category: "分类", stars: "星标", npmPackage: "npm 包", repo: "GitHub 仓库",
                restartHint: "插件层变更需重启 dsh web 生效", restartNow: "重启 dsh web",
                doneInstall: "安装完成", doneUninstall: "卸载完成",
                pnpmMissing: "未找到 pnpm（安装插件需要它，请先安装 corepack/pnpm）",
                noRestartNeeded: "无需重启（未声明为 bundle 的包作为普通依赖安装）")
        }
        return PluginsStrings(
            title: "Plugins", installedTab: "Installed", enabledTab: "Enabled", marketTab: "Market",
            searchPlaceholder: "Search plugins…", refresh: "Refresh", install: "Install", uninstall: "Uninstall",
            enable: "Enable", disable: "Disable", open: "Open",
            loading: "Loading…", loadFailed: "Failed to load", emptyInstalled: "No plugins installed yet",
            emptyEnabled: "No enabled plugins", emptyMarket: "No matching plugins",
            enabled: "Enabled", disabled: "Disabled", notInstalled: "Not installed",
            version: "Version", category: "Category", stars: "Stars", npmPackage: "npm package", repo: "GitHub repo",
            restartHint: "Plugin layer changes need a dsh web restart to take effect",
            restartNow: "Restart dsh web",
            doneInstall: "Installed", doneUninstall: "Uninstalled",
            pnpmMissing: "pnpm not found (required to install plugins; install corepack/pnpm first)",
            noRestartNeeded: "No restart needed (installed as a plain dependency, not a bundle)")
    }
}

// MARK: - Plugin management window

/// A top-down laid-out container used as the scroll view's document view.
/// Rows are positioned manually so the list grows without scroll glitches.
final class PluginListContainer: NSView {
    override var isFlipped: Bool { true }
}

/// Native plugins manager window: Installed / Enabled / Market tabs with
/// install, uninstall, enable and disable actions.
final class PluginsWindowController: NSObject {
    private var panel: NSPanel?
    private var segmented: NSSegmentedControl?
    private var searchField: NSSearchField?
    private var listContainer: PluginListContainer?
    private var statusLabel: NSTextField?
    private var restartButton: NSButton?
    private var refreshButton: NSButton?

    private var marketPlugins: [MarketPlugin] = []
    private var installed: Set<String> = []
    private var enabled: [String] = []
    private var busy = false
    private var needsRestartHint = false

    /// Called when the user asks to restart the dsh web server (plugin layer
    /// changes only apply after a restart). Wired up by AppDelegate.
    var onRestartRequested: (() -> Void)?

    private var s: PluginsStrings { .current() }

    /// Row metrics for the manual document layout.
    private let rowHeight: CGFloat = 56
    private let rowGap: CGFloat = 6
    private let listWidth: CGFloat = 716

    /// Show (and focus) the window, creating it on first use. Refreshes
    /// installed/enabled state every time so the window is never stale.
    func show() {
        if panel == nil { buildPanel() }
        refreshLocal()
        refreshMarketIfNeeded()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI construction

    private func buildPanel() {
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = s.title
        win.isReleasedWhenClosed = false
        win.center()

        let seg = NSSegmentedControl(labels: [s.installedTab, s.enabledTab, s.marketTab],
                                     trackingMode: .selectOne,
                                     target: self, action: #selector(tabChanged(_:)))
        seg.selectedSegment = 0

        let search = NSSearchField()
        search.placeholderString = s.searchPlaceholder
        search.target = self
        search.action = #selector(searchChanged(_:))
        search.isEnabled = false

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [seg, search])
        topRow.orientation = .horizontal
        topRow.spacing = 12
        root.addArrangedSubview(topRow)

        let list = PluginListContainer()
        list.frame = NSRect(x: 0, y: 0, width: listWidth, height: 440)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.borderType = .bezelBorder
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(scroll)

        let status = NSTextField(labelWithString: "")
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let restart = NSButton(title: s.restartNow, target: self, action: #selector(restartPressed(_:)))
        restart.bezelStyle = .rounded
        restart.isHidden = true

        let refresh = NSButton(title: s.refresh, target: self, action: #selector(refreshPressed(_:)))
        refresh.bezelStyle = .rounded

        let bottomRow = NSStackView(views: [status, NSView(), restart, refresh])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 10
        root.addArrangedSubview(bottomRow)

        win.contentView = root

        NSLayoutConstraint.activate([
            topRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(equalToConstant: 440),
            bottomRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
        ])

        self.panel = win
        self.segmented = seg
        self.searchField = search
        self.listContainer = list
        self.statusLabel = status
        self.restartButton = restart
        self.refreshButton = refresh
    }

    // MARK: - Data loading

    private func refreshLocal() {
        installed = Set(ProfilePlugins.installedPackages())
        enabled = ProfilePlugins.enabledBundles()
    }

    private func refreshMarketIfNeeded() {
        guard marketPlugins.isEmpty else { return }
        loadMarket()
    }

    private func loadMarket() {
        setBusy(true, s.loading)
        PluginMarket.fetch { [weak self] plugins, error in
            guard let self else { return }
            self.setBusy(false, nil)
            if let plugins {
                self.marketPlugins = plugins
            } else {
                self.setStatus(error ?? s.loadFailed)
            }
            self.render()
        }
    }

    /// Refresh everything (used by the Refresh button and after mutations).
    private func refreshAll() {
        refreshLocal()
        if marketPlugins.isEmpty {
            loadMarket()
        } else {
            render()
        }
    }

    // MARK: - Rendering

    private func render() {
        guard let list = listContainer else { return }
        for view in list.subviews { view.removeFromSuperview() }

        let selected = segmented?.selectedSegment ?? 0
        let searchText = (searchField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        searchField?.isEnabled = selected == 2

        let rows: [NSView]
        switch selected {
        case 0: rows = installedRows()
        case 1: rows = enabledRows()
        default: rows = marketRows(search: searchText)
        }

        var y: CGFloat = 6
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: listWidth, height: rowHeight)
            list.addSubview(row)
            y += rowHeight + rowGap
        }
        list.frame = NSRect(x: 0, y: 0, width: listWidth, height: max(y, 440))
        list.needsDisplay = true

        restartButton?.isHidden = !needsRestartHint
        refreshButton?.isEnabled = !busy
    }

    private func installedRows() -> [NSView] {
        let all = installed.sorted()
        if all.isEmpty { return [emptyRow(s.emptyInstalled)] }
        return all.map { name in
            let isEnabled = enabled.contains(name)
            let toggle = actionButton(isEnabled ? s.disable : s.enable,
                                      action: #selector(toggleEnabledPressed(_:)),
                                      identifier: name)
            let remove = actionButton(s.uninstall, action: #selector(uninstallPressed(_:)), identifier: name)
            return pluginRow(title: name,
                             subtitle: isEnabled ? s.enabled : s.disabled,
                             titleColor: isEnabled ? .labelColor : .secondaryLabelColor,
                             actions: [toggle, remove])
        }
    }

    private func enabledRows() -> [NSView] {
        if enabled.isEmpty { return [emptyRow(s.emptyEnabled)] }
        return enabled.enumerated().map { index, name in
            let disable = actionButton(s.disable, action: #selector(toggleEnabledPressed(_:)), identifier: name)
            return pluginRow(title: name,
                             subtitle: String(format: "%d. %@", index + 1, s.enabled),
                             titleColor: .labelColor,
                             actions: [disable])
        }
    }

    private func marketRows(search: String) -> [NSView] {
        if marketPlugins.isEmpty { return [emptyRow(s.loading)] }
        var items = marketPlugins
        if !search.isEmpty {
            items = items.filter {
                $0.name.localizedCaseInsensitiveContains(search)
                    || $0.displayName.localizedCaseInsensitiveContains(search)
                    || $0.category.localizedCaseInsensitiveContains(search)
                    || $0.summary.localizedCaseInsensitiveContains(search)
            }
        }
        if items.isEmpty { return [emptyRow(s.emptyMarket)] }
        return items.map { plugin in
            let isInstalled = plugin.matches(installed: installed)
            let isEnabled = plugin.npmPackage.map { enabled.contains($0) } ?? false
            var subtitleParts = [isInstalled ? (isEnabled ? s.enabled : s.disabled) : s.notInstalled]
            if let version = plugin.version, !version.isEmpty { subtitleParts.append("\(s.version) \(version)") }
            if !plugin.category.isEmpty { subtitleParts.append(plugin.category) }
            if let stars = plugin.stars { subtitleParts.append("★ \(stars)") }
            subtitleParts.append(plugin.npmPackage != nil ? s.npmPackage : s.repo)

            var actions: [NSButton] = []
            if let pkg = plugin.npmPackage {
                // Already installed → the button toggles enable/disable;
                // not installed → it installs.
                let button = actionButton(
                    isInstalled ? (isEnabled ? s.disable : s.enable) : s.install,
                    action: isInstalled ? #selector(toggleEnabledPressed(_:)) : #selector(installPressed(_:)),
                    identifier: pkg)
                button.isEnabled = true
                actions.append(button)
            }
            actions.append(actionButton(s.open, action: #selector(openPressed(_:)), identifier: plugin.url))
            return pluginRow(title: plugin.displayName,
                             subtitle: subtitleParts.joined(separator: " · "),
                             titleColor: .labelColor,
                             actions: actions,
                             toolTip: plugin.summary.isEmpty ? nil : plugin.summary)
        }
    }

    private func emptyRow(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func actionButton(_ title: String, action: Selector, identifier: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.controlSize = .small
        return button
    }

    /// Build one plugin row: title + subtitle + trailing action buttons.
    private func pluginRow(title: String, subtitle: String, titleColor: NSColor,
                           actions: [NSButton], toolTip: String? = nil) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = titleColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let texts = NSStackView(views: [titleLabel, subtitleLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        let actionsStack = NSStackView(views: actions)
        actionsStack.orientation = .horizontal
        actionsStack.spacing = 6

        let row = NSStackView(views: [texts, NSView(), actionsStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.toolTip = toolTip
        return row
    }

    // MARK: - Actions

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        render()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        render()
    }

    @objc private func refreshPressed(_ sender: Any?) {
        refreshAll()
    }

    @objc private func installPressed(_ sender: NSButton) {
        guard let pkg = sender.identifier?.rawValue else { return }
        performInstall(pkg)
    }

    @objc private func uninstallPressed(_ sender: NSButton) {
        guard let pkg = sender.identifier?.rawValue else { return }
        performUninstall(pkg)
    }

    @objc private func toggleEnabledPressed(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        let targetEnabled = !enabled.contains(name)
        do {
            try ProfilePlugins.setEnabled(name, enabled: targetEnabled)
            refreshLocal()
            needsRestartHint = true
            render()
            setStatus(targetEnabled
                      ? "\(name) — \(s.enabled) · \(s.restartHint)"
                      : "\(name) — \(s.disabled) · \(s.restartHint)")
        } catch {
            setStatus("\(name): \(error.localizedDescription)")
        }
    }

    @objc private func openPressed(_ sender: NSButton) {
        guard let url = sender.identifier?.rawValue, let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }

    @objc private func restartPressed(_ sender: Any?) {
        needsRestartHint = false
        restartButton?.isHidden = true
        onRestartRequested?()
    }

    // MARK: - Install / uninstall via `dsh plugin`

    private func performInstall(_ pkg: String) {
        guard !busy else { return }
        guard ProfilePlugins.pnpmAvailable() else {
            setStatus(s.pnpmMissing)
            return
        }
        setBusy(true, "\(s.install) \(pkg)…")
        ProfilePlugins.runDshPlugin(args: ["add", pkg]) { [weak self] ok, output in
            guard let self else { return }
            self.setBusy(false, nil)
            self.refreshLocal()
            if ok {
                self.needsRestartHint = self.enabled.contains(pkg)
                self.render()
                self.setStatus(self.needsRestartHint
                               ? "\(pkg) — \(s.doneInstall) · \(s.restartHint)"
                               : "\(pkg) — \(s.doneInstall) · \(s.noRestartNeeded)")
            } else {
                self.setStatus("\(s.install) \(pkg): \(output)")
            }
        }
    }

    private func performUninstall(_ pkg: String) {
        guard !busy else { return }
        setBusy(true, "\(s.uninstall) \(pkg)…")
        ProfilePlugins.runDshPlugin(args: ["remove", pkg]) { [weak self] ok, output in
            guard let self else { return }
            self.setBusy(false, nil)
            self.refreshLocal()
            self.needsRestartHint = true
            self.render()
            if ok {
                self.setStatus("\(pkg) — \(s.doneUninstall) · \(s.restartHint)")
            } else {
                self.setStatus("\(s.uninstall) \(pkg): \(output)")
            }
        }
    }

    // MARK: - Status helpers

    private func setBusy(_ busy: Bool, _ message: String?) {
        self.busy = busy
        if let message { setStatus(message) }
    }

    private func setStatus(_ text: String) {
        statusLabel?.stringValue = text
    }
}
