#pragma once

#include <functional>
#include <string>

namespace dsh {

// Downloads and installs a user-level Node.js runtime when npx is missing,
// mirroring the macOS/Windows shells. No root needed: the runtime lands in
// ~/.local/share/deepseek-harness/nodejs and its bin/ directory is prepended
// to the process PATH (the shell uses it from then on; the user's shell
// configuration is left untouched).
namespace NodeRuntimeManager {

enum class State {
    Downloading, // fraction = download progress in [0,1], or -1 when unknown
    Installing,  // fraction = -1
    Done,        // fraction = 0
    Failed,      // fraction = 0
};

using ProgressFn = std::function<void(State, double)>;

// True when node+npx are usable, either on PATH or in the managed install dir.
bool RuntimeAvailable();

// The managed install directory (~/.local/share/deepseek-harness/nodejs).
std::string InstallDir();

// Prepends the managed bin/ dir to the process PATH when it is missing.
void EnsureOnPath();

// npm registry to use (npmmirror for China timezones, npmjs otherwise).
std::string NpmRegistryUrl();

// Ensures node/npx are available: returns immediately when RuntimeAvailable,
// otherwise resolves the latest LTS, downloads its tarball and extracts it.
// onState may be called from a worker thread; returns RuntimeAvailable().
bool Provide(const ProgressFn& onState);

// `node --version` output (e.g. "v22.14.0"), or "" when node is missing.
std::string NodeVersion();

} // namespace NodeRuntimeManager
} // namespace dsh
