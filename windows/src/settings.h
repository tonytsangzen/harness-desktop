#pragma once

#include <string>
#include <vector>

namespace dsh {

// Resolved runtime settings, derived from CLI arguments and the environment.
// Mirrors the macOS shell's Settings type so behavior stays aligned.
struct Settings {
    std::wstring host = L"127.0.0.1";
    unsigned short port = 3080;
    // --verbose (an npx/npm flag, before the package name) makes npx print its
    // install/resolution log to stdout; the shell captures it (log file),
    // shows the last line on the loading screen, and resets the startup
    // timeout while output keeps arriving.
    std::vector<std::wstring> command{ L"npx", L"--yes", L"--verbose", L"@deepseek-ai/dsh", L"web" };
    bool customCommand = false;

    std::wstring Url() const { return L"http://" + host + L":" + std::to_wstring(port) + L"/"; }

    // args excludes argv[0].
    static Settings Parse(const std::vector<std::wstring>& args);
};

extern const wchar_t* kUsageText;

} // namespace dsh
