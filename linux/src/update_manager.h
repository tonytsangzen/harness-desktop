#pragma once

#include <functional>
#include <string>

namespace dsh {

// Checks the npm registry for a newer @deepseek-ai/dsh version than the one
// in the local npx cache. Mirrors the macOS/Windows update managers.
namespace UpdateManager {

// Local version from the npx cache ("" when unknown).
std::string LocalVersion();

// Latest published version from the npm registry ("" on failure). Blocks.
std::string LatestVersion();

// True when latest is newer than local (also requires local to be known).
bool UpdateAvailable(std::string* latest);

} // namespace UpdateManager
} // namespace dsh
