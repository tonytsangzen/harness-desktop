#pragma once

#include <functional>
#include <string>

namespace dsh {

// Detects Node.js/npx and, when missing, downloads the official Windows
// binary zip and installs it to %LOCALAPPDATA%\Programs\nodejs (user-level,
// no elevation), then prepends it to the user PATH.
namespace NodeRuntimeManager {

enum class State {
    Checking,
    Downloading, // progress in 0..1, or -1 = indeterminate
    Installing,
    Done,
    Failed,
};

bool RuntimeAvailable();

std::wstring NodePath();
std::wstring NpxPath();
std::wstring BinDirectoryFromNodePath();

// Mainland China uses npmmirror for both the node binary and the npm registry.
bool IsMainlandChinaTimeZone();
std::wstring DistBase();
std::wstring NpmRegistryUrl();
std::wstring ArchName();

// Runs synchronously (call from a worker thread). Invokes `onState` on state
// transitions. Returns true if node is available afterwards.
bool Provide(const std::function<void(State, double progress)>& onState);

std::wstring InstallDir();

} // namespace NodeRuntimeManager
} // namespace dsh
