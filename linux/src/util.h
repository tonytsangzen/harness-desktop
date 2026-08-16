#pragma once

#include <string>

namespace dsh {

// Returns the value of an environment variable, or empty string if unset.
std::string GetEnv(const std::string& name);

// Best-effort mkdir -p for one directory path.
void EnsureDir(const std::string& path);

// The settings directory (~/.config/deepseek-harness).
std::string ConfigDir();

// The user data directory (XDG_DATA_HOME or ~/.local/share; no trailing
// "deepseek-harness" component).
std::string GetDataDir();

// Reads the whole file as text (empty string on failure).
std::string ReadFileText(const std::string& path);

// Writes text to a file (returns false on failure).
bool WriteFileText(const std::string& path, const std::string& text);

// Compares dotted versions like "1.2.3" (returns a> b).
bool VersionNewer(const std::string& a, const std::string& b);

// True when the first preferred system language is Chinese.
bool SystemLanguageIsChinese();

} // namespace dsh
