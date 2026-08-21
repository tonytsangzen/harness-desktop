#pragma once

// Minimal HWND forward declaration (avoid pulling windows.h here so that
// translation units can order winsock2.h before it).
struct HWND__;
typedef HWND__* HWND;

#include <string>
#include <vector>

namespace dsh {
namespace PluginsManager {

// One node of the installed-plugin dependency tree (direct installs + their
// transitive deps, resolved from the profile's node_modules).
struct PluginNode {
    std::wstring name;
    bool builtin = false; // enabled template bundle (not in dependencies)
    std::vector<PluginNode> children;
};

// One entry of the plugin market index (harness-market/data.js).
struct MarketPlugin {
    std::wstring id;
    std::wstring name;
    std::wstring displayName;
    std::wstring type; // "package" | "repo"
    std::wstring category;
    std::wstring summary;
    std::wstring url;
    std::wstring version;
    bool hasStars = false;
    int stars = 0;
    // For type == "package": the npm package name (pnpm-addable); for
    // "repo": a pnpm git spec "github:owner/repo". Empty when not installable.
    std::wstring installSpec;
};

// The active dsh web profile directory: %USERPROFILE%\.dsh\profiles\web.
std::wstring ProfileDir();

// Directly installed dependency names (package.json `dependencies` keys).
std::vector<std::wstring> InstalledPackages();

// Enabled bundle layer (`dsh.profile.bundles`), in order.
std::vector<std::wstring> EnabledBundles();

// Installed plugins organised by dependency: roots are direct installs plus
// enabled template bundles; children are each package's own dependencies
// (depth-limited, cycle-guarded).
std::vector<PluginNode> DependencyTree();

// Enable/disable a bundle by rewriting `dsh.profile.bundles`. Returns false
// (with `error`) when the profile's package.json can't be read or updated.
bool SetEnabled(const std::wstring& name, bool enabled, std::wstring& error);

// Whether pnpm is available (dsh plugin forwards to it).
bool PnpmAvailable();

// Fetches and parses the plugin market index. Synchronous — call from a
// worker thread. `zh` prefers Chinese descriptions. Returns the plugins;
// `error` carries a human-readable failure message when the list is empty.
std::vector<MarketPlugin> FetchMarket(bool zh, std::wstring& error);

// Runs `dsh plugin --profile web <args…>` via npx (cwd = profile dir) and
// captures stdout+stderr. Synchronous — call from a worker thread. Returns
// true on exit code 0; `output` holds the captured output (tail-friendly).
bool RunDshPlugin(const std::vector<std::wstring>& args, std::wstring& output);

// Shows the plugins manager dialog (modal, owned by `owner`).
void Show(HWND owner);

} // namespace PluginsManager
} // namespace dsh
