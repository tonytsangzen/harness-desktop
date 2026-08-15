#pragma once

#include <functional>
#include <string>

namespace dsh {

// Compares "1.2.3" style versions. Returns <0, 0, >0.
int CompareVersions(const std::string& a, const std::string& b);

// Checks the npm registry for a newer @deepseek-ai/dsh than the locally
// cached one and, if an update is desired, refreshes the npx cache.
namespace DSHUpdateManager {

enum class Status {
    Checking,
    UpdateAvailable,
    UpToDate,
    CheckingFailed,
    Refreshing,
    Refreshed,
    RefreshFailed,
};

// Reads the version of the locally cached @deepseek-ai/dsh package
// (from the npx cache or the global npm modules dir). Empty if not found.
std::string LocalVersion();

// The latest published version per the npm registry. Empty on failure.
std::string FetchLatest();

// Returns true and sets `latest` when an update is available.
bool LatestIfUpdateAvailable(std::string& latest);

// Clears the cached package and reinstalls @deepseek-ai/dsh@latest, so the
// next `npx @deepseek-ai/dsh` run picks it up. Runs synchronously; invokes
// `onStatus` on transitions.
bool RefreshToLatest(const std::function<void(Status)>& onStatus = {});

} // namespace DSHUpdateManager
} // namespace dsh
