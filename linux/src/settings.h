#pragma once

#include <string>
#include <vector>

namespace dsh {

// Resolved runtime settings, derived from CLI arguments and the environment.
// Mirrors the macOS/Windows shells so behavior stays aligned.
struct Settings {
    std::string host = "127.0.0.1";
    unsigned short port = 3080;
    std::vector<std::string> command{ "npx", "@deepseek-ai/dsh", "web" };
    bool customCommand = false;

    // e.g. http://127.0.0.1:3080/
    std::string Url() const { return "http://" + host + ":" + std::to_string(port) + "/"; }

    // args excludes argv[0].
    static Settings Parse(const std::vector<std::string>& args);
};

extern const char* kUsageText;

} // namespace dsh
