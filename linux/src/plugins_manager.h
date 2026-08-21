#pragma once

#include <gtk/gtk.h>

#include <functional>
#include <string>
#include <vector>

namespace dsh {

// Native plugins manager dialog (market / installed / enabled) — the Linux
// port of the macOS PluginsWindowController. Data operations are pure and
// reusable; the dialog itself is GTK UI owned by this module.
namespace PluginsManager {

// One node of the installed-plugin dependency tree.
struct PluginNode {
    std::string name;
    bool builtin = false; // enabled template bundle (not in dependencies)
    std::vector<PluginNode> children;
};

// One entry of the plugin market index (harness-market/data.js).
struct MarketPlugin {
    std::string id;
    std::string name;
    std::string displayName;
    std::string type; // "package" | "repo"
    std::string category;
    std::string summary;
    std::string url;
    std::string version;
    bool hasStars = false;
    int stars = 0;

    // npm package name installable via pnpm (nil for repo entries).
    std::string NpmPackage() const;
    // pnpm git dependency spec ("github:owner/repo") for repo entries.
    std::string GitSpec() const;
};

struct CommandResult {
    bool ok = false;
    std::string output; // tail of combined stdout + stderr
};

// ---- data layer (blocking, call from a worker thread where noted) ----

// $HOME/.dsh/profiles/web — the profile the shell boots (`dsh web`).
std::string ProfileDir();

// Directly installed dependency names (package.json `dependencies`).
std::vector<std::string> InstalledPackages();

// Enabled bundle names (`dsh.profile.bundles`), in layer order.
std::vector<std::string> EnabledBundles();

// Installed plugins organised by dependency (roots = directly installed +
// enabled template bundles; children = each package's own dependencies,
// resolved from the profile node_modules, depth-limited, cycle-guarded).
std::vector<PluginNode> DependencyTree();

// Enables/disables a bundle by rewriting `dsh.profile.bundles` in
// package.json (all other fields preserved). Returns false with *error set
// on failure. Changes apply after the dsh web server restarts.
bool SetEnabled(const std::string& name, bool enabled, std::string* error);

// Fetches and parses the plugin market index. Blocking (soup3 sync GET);
// empty vector on failure.
std::vector<MarketPlugin> FetchMarket();

// Runs `npx --yes @deepseek-ai/dsh plugin --profile web <args...>` with the
// profile directory as cwd and returns the tail of its output. Blocking.
CommandResult RunDshPlugin(const std::vector<std::string>& args);

// Whether pnpm is available (dsh plugin forwards to it).
bool PnpmAvailable();

// ---- dialog (main thread) ----

// Opens a modal plugins manager dialog. `zh` selects UI strings (call with
// MainWindow::IsChinese()); `onRestart` is invoked on the main thread when
// the user asks to restart the dsh web server (plugin layer changes only
// apply after a restart).
void ShowDialog(GtkWindow* parent, bool zh, const std::function<void()>& onRestart);

} // namespace PluginsManager
} // namespace dsh
